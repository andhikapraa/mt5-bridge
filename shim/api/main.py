"""mt5-bridge FastAPI shim.

Exposes a small, opinionated REST + WebSocket surface on top of mt5linux.
Auth: X-API-Key header on everything except /health.
"""

from __future__ import annotations

import asyncio
import logging
import os
from typing import Any

from fastapi import Depends, FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware

from api.auth import require_api_key
from api.models import CandlesRequest, HealthResponse, OrderRequest
from api.mt5_proxy import _as_dict, proxy

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
log = logging.getLogger("api")

# Timeframe name → MetaTrader5 enum integer (avoids depending on MT5 constants
# being importable on the host Python).
_TIMEFRAME = {
    "M1": 1, "M5": 5, "M15": 15, "M30": 30,
    "H1": 16385, "H4": 16388, "D1": 16408, "W1": 32769, "MN1": 49153,
}
_ORDER_TYPE = {"BUY": 0, "SELL": 1}
_TRADE_ACTION_DEAL = 1

# MT5 filling mode enum values:
_FILL_FOK = 0  # Fill or Kill
_FILL_IOC = 1  # Immediate or Cancel
_FILL_RETURN = 2  # Return — for pending orders, NOT market orders
_FILL_BOC = 3  # Book or Cancel

# Symbol filling_mode is a bitmask (1=FOK, 2=IOC, 4=BOC). Try in order of
# what brokers most commonly support, picking the first match.
_FILL_PREFERENCE = [(_FILL_FOK, 1), (_FILL_IOC, 2), (_FILL_BOC, 4)]


def _pick_filling_mode(symbol_filling_mask: int | None) -> int:
    """Choose a compatible filling mode for a market order from the symbol's
    declared bitmask. Falls back to FOK if the mask is missing/zero."""
    if not symbol_filling_mask:
        return _FILL_FOK
    for mode, bit in _FILL_PREFERENCE:
        if symbol_filling_mask & bit:
            return mode
    return _FILL_FOK

from contextlib import asynccontextmanager


@asynccontextmanager
async def _lifespan(app: FastAPI):
    # Eagerly establish the mt5linux RPyC connection so the first /health
    # request doesn't have to do the cold handshake within its own timeout.
    # Runs in the background so we don't block uvicorn startup if mt5linux
    # isn't reachable yet.
    asyncio.create_task(proxy.warmup())
    yield


app = FastAPI(
    title="mt5-bridge",
    description="MetaTrader 5 REST + WebSocket bridge over mt5linux.",
    version="0.1.0",
    lifespan=_lifespan,
)

_allowed = os.environ.get("ALLOWED_ORIGINS", "*").split(",")
app.add_middleware(
    CORSMiddleware,
    allow_origins=[o.strip() for o in _allowed if o.strip()],
    allow_credentials=False,
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)

# ---- Health (no auth — used by Docker healthcheck) ----

@app.get("/health", response_model=HealthResponse, tags=["meta"])
async def health() -> HealthResponse:
    alive, acct = await proxy.is_alive()
    return HealthResponse(
        status="ok" if alive else "degraded",
        mt5_connected=alive,
        account_login=(acct or {}).get("login"),
        server=(acct or {}).get("server"),
    )

# ---- Account / terminal ----

@app.get("/account", dependencies=[Depends(require_api_key)], tags=["account"])
async def account() -> dict[str, Any]:
    info = await proxy.call("account_info")
    if info is None:
        raise HTTPException(503, "mt5 not connected / not logged in")
    return _as_dict(info)

@app.get("/terminal", dependencies=[Depends(require_api_key)], tags=["account"])
async def terminal() -> dict[str, Any]:
    return _as_dict(await proxy.call("terminal_info"))

# ---- Symbols ----

@app.get("/symbols", dependencies=[Depends(require_api_key)], tags=["market"])
async def symbols() -> dict[str, Any]:
    syms = await proxy.call("symbols_get")
    return {"count": len(syms) if syms else 0,
            "symbols": [s.name for s in syms] if syms else []}

@app.get("/symbols/{symbol}", dependencies=[Depends(require_api_key)], tags=["market"])
async def symbol_info(symbol: str) -> dict[str, Any]:
    info = await proxy.call("symbol_info", symbol)
    if info is None:
        raise HTTPException(404, f"symbol {symbol!r} not found")
    return _as_dict(info)

@app.get("/symbols/{symbol}/tick", dependencies=[Depends(require_api_key)], tags=["market"])
async def symbol_tick(symbol: str) -> dict[str, Any]:
    tick = await proxy.call("symbol_info_tick", symbol)
    if tick is None:
        raise HTTPException(404, f"symbol {symbol!r} not found")
    return _as_dict(tick)

# ---- Candles ----

@app.post("/candles", dependencies=[Depends(require_api_key)], tags=["market"])
async def candles(req: CandlesRequest) -> dict[str, Any]:
    tf = _TIMEFRAME[req.timeframe]
    rates = await proxy.call("copy_rates_from_pos", req.symbol, tf, req.start_pos, req.count)
    if rates is None:
        err = await proxy.call("last_error")
        raise HTTPException(502, f"copy_rates_from_pos failed: {err}")
    # Each row is a numpy.void — turn into plain dict.
    out = [
        {"time": int(r["time"]), "open": float(r["open"]), "high": float(r["high"]),
         "low": float(r["low"]), "close": float(r["close"]),
         "tick_volume": int(r["tick_volume"]), "spread": int(r["spread"]),
         "real_volume": int(r["real_volume"])}
        for r in rates
    ]
    return {"symbol": req.symbol, "timeframe": req.timeframe, "count": len(out), "candles": out}

# ---- Orders & positions ----

@app.get("/positions", dependencies=[Depends(require_api_key)], tags=["trade"])
async def positions() -> dict[str, Any]:
    pos = await proxy.call("positions_get")
    return {"count": len(pos) if pos else 0,
            "positions": [_as_dict(p) for p in (pos or [])]}

@app.post("/order", dependencies=[Depends(require_api_key)], tags=["trade"])
async def place_order(req: OrderRequest) -> dict[str, Any]:
    # Fetch the symbol's full metadata + a fresh tick in parallel — we need
    # tick.ask/bid for the price and symbol.filling_mode to pick a filling
    # mode the broker actually supports (hardcoded IOC/RETURN was rejected
    # by HF Markets with retcode 10030 "Unsupported filling mode").
    sym = await proxy.call("symbol_info", req.symbol)
    tick = await proxy.call("symbol_info_tick", req.symbol)
    if sym is None or tick is None:
        raise HTTPException(404, f"symbol {req.symbol!r} not found")

    price = tick.ask if req.order_type == "BUY" else tick.bid
    fill_mode = _pick_filling_mode(getattr(sym, "filling_mode", None))

    request = {
        "action":       _TRADE_ACTION_DEAL,
        "symbol":       req.symbol,
        "volume":       req.volume,
        "type":         _ORDER_TYPE[req.order_type],
        "price":        price,
        "deviation":    req.deviation,
        "magic":        req.magic,
        "comment":      req.comment,
        "type_filling": fill_mode,
    }
    if req.sl is not None: request["sl"] = req.sl
    if req.tp is not None: request["tp"] = req.tp

    result = await proxy.call("order_send", request)
    if result is None:
        err = await proxy.call("last_error")
        raise HTTPException(502, f"order_send returned None: {err}")
    return _as_dict(result)


@app.post("/positions/{ticket}/close", dependencies=[Depends(require_api_key)], tags=["trade"])
async def close_position(ticket: int, deviation: int = 50) -> dict[str, Any]:
    """Close an open position by ticket. Sends a counter-DEAL bound to the
    position id, which works in both netting and hedging accounts."""
    positions = await proxy.call("positions_get", ticket=ticket)
    if not positions:
        raise HTTPException(404, f"no open position with ticket {ticket}")
    p = positions[0]
    sym = await proxy.call("symbol_info", p.symbol)
    tick = await proxy.call("symbol_info_tick", p.symbol)
    if sym is None or tick is None:
        raise HTTPException(502, f"symbol {p.symbol!r} info unavailable")

    # Position type 0=BUY, 1=SELL. Close = opposite side at current opposite price.
    close_type = 1 if p.type == 0 else 0
    close_price = tick.bid if close_type == 1 else tick.ask
    fill_mode = _pick_filling_mode(getattr(sym, "filling_mode", None))

    request = {
        "action":       _TRADE_ACTION_DEAL,
        "symbol":       p.symbol,
        "volume":       p.volume,
        "type":         close_type,
        "position":     ticket,
        "price":        close_price,
        "deviation":    deviation,
        "magic":        p.magic,
        "comment":      "mt5-bridge close",
        "type_filling": fill_mode,
    }
    result = await proxy.call("order_send", request)
    if result is None:
        err = await proxy.call("last_error")
        raise HTTPException(502, f"order_send returned None: {err}")
    return _as_dict(result)

# ---- WebSocket: live ticks ----

@app.websocket("/ws/ticks/{symbol}")
async def ws_ticks(ws: WebSocket, symbol: str, api_key: str | None = None) -> None:
    # WebSocket auth via query string (browsers can't set custom headers on WS connect).
    if not api_key or api_key != os.environ.get("API_KEY"):
        await ws.close(code=4401)
        return
    await ws.accept()
    last_time = 0
    try:
        while True:
            tick = await proxy.call("symbol_info_tick", symbol)
            if tick is None:
                await ws.send_json({"error": "symbol not found", "symbol": symbol})
                await ws.close()
                return
            if tick.time_msc != last_time:
                last_time = tick.time_msc
                await ws.send_json(_as_dict(tick))
            await asyncio.sleep(0.25)
    except WebSocketDisconnect:
        return
