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
_ORDER_FILLING_IOC = 2

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
    tick = await proxy.call("symbol_info_tick", req.symbol)
    if tick is None:
        raise HTTPException(404, f"symbol {req.symbol!r} not found")
    price = tick.ask if req.order_type == "BUY" else tick.bid

    request = {
        "action":       _TRADE_ACTION_DEAL,
        "symbol":       req.symbol,
        "volume":       req.volume,
        "type":         _ORDER_TYPE[req.order_type],
        "price":        price,
        "deviation":    req.deviation,
        "magic":        req.magic,
        "comment":      req.comment,
        "type_filling": _ORDER_FILLING_IOC,
    }
    if req.sl is not None: request["sl"] = req.sl
    if req.tp is not None: request["tp"] = req.tp

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
