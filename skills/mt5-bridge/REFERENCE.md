# mt5-bridge — endpoint reference

Full API surface for any [mt5-bridge](https://github.com/andhikapraa/mt5-bridge) deployment. All authenticated endpoints require `X-API-Key: $API_KEY` (the wrapper adds this automatically).

## Auth model

- **Header**: `X-API-Key: <key>` on every REST call except `/health`.
- **WebSocket**: query string `?api_key=<key>` because browsers can't set custom headers on WS handshake.
- 401 means missing/wrong key. 403 means wrong key on WS.

## GET endpoints

| Path | Returns | Notes |
|---|---|---|
| `/health` | `{status, mt5_connected, account_login, server}` | No auth. `status` is `"ok"` or `"degraded"`. |
| `/account` | full account namedtuple as dict | login, balance, equity, currency, leverage, margin, trade_allowed, name, server, company |
| `/terminal` | MT5 terminal info | build, install path, connected state |
| `/positions` | `{count, positions: [...]}` | Each position: ticket, type (0=BUY 1=SELL), volume, price_open, price_current, sl, tp, profit, symbol, magic |
| `/symbols` | `{count, symbols: [name...]}` | List of all symbols in MarketWatch |
| `/symbols/{symbol}` | full SymbolInfo dict | digits, spread, filling_mode bitmask, trade_mode, volume_min/max/step, currency_base/profit |
| `/symbols/{symbol}/tick` | latest tick | time, bid, ask, last, volume, time_msc, flags |
| `/docs` | Swagger UI | browser-friendly |

## POST endpoints

### `/candles`

```json
{
  "symbol": "XAUUSD",
  "timeframe": "H1",
  "count": 100,
  "start_pos": 0
}
```

Timeframes: `M1 M5 M15 M30 H1 H4 D1 W1 MN1`.

Returns `{symbol, timeframe, count, candles: [{time, open, high, low, close, tick_volume, spread, real_volume}, ...]}` — most recent first when `start_pos=0`.

### `/order`

```json
{
  "symbol": "XAUUSD",
  "volume": 0.01,
  "order_type": "BUY",     // or "SELL"
  "sl": 4380.0,            // optional
  "tp": 4420.0,            // optional
  "deviation": 50,         // optional, slippage tolerance in points
  "magic": 0,              // optional, EA id for filtering
  "comment": "claude"      // optional, ≤31 chars
}
```

Server auto-detects filling mode from `symbol.filling_mode` bitmask (1=FOK, 2=IOC, 4=BOC). Don't hardcode.

Returns `OrderSendResult` dict. Key fields:
- `retcode` — see retcode table below
- `order` — ticket of the new position (or 0 on fail)
- `deal` — deal id (or 0 on fail)
- `price` — fill price
- `comment` — broker message (e.g. "Request executed", "Unsupported filling mode")

### `/positions/{ticket}/close`

No body. Closes that specific position with a counter-DEAL bound to the ticket — works in netting AND hedging accounts.

Returns same `OrderSendResult` shape as `/order`.

## WebSocket

```
ws://<host>/ws/ticks/{symbol}?api_key=<key>
```

Only emits a frame when `time_msc` changes. On bad symbol, server sends `{"error":"symbol not found","symbol":"..."}` then closes. ~2-10 frames/sec on liquid pairs during market hours.

Python:
```python
import asyncio, json, websockets
async def main():
    async with websockets.connect(
        "ws://<host>/ws/ticks/XAUUSD?api_key=KEY") as ws:
        for _ in range(10):
            print(json.loads(await ws.recv()))
asyncio.run(main())
```

## MT5 retcode glossary

Most common codes returned in `OrderSendResult.retcode`:

| Code | Meaning | What to do |
|---|---|---|
| 10009 | `TRADE_RETCODE_DONE` — order filled | success, capture `order`/`deal` |
| 10004 | requote | retry with current price |
| 10006 | rejected | broker rejected; check `comment` |
| 10013 | invalid request | malformed body |
| 10014 | invalid volume | check `volume_min/max/step` from symbol_info |
| 10015 | invalid price | usually stale; refresh tick + retry |
| 10016 | invalid stops | SL/TP too close to price (check `stops_level`) |
| 10018 | market closed | weekend or holiday |
| 10019 | not enough money | check `margin_free` |
| 10027 | autotrading disabled by server | broker-side |
| 10030 | unsupported filling mode | upstream bug if seen — wrapper auto-detects, shouldn't happen |
| 10031 | no connection | broker dropped; usually auto-reconnects |

## Cent currency translation

Many MT5 cent accounts use **USC** (US cents) as the account currency. 100 USC = 1 USD.
- Balance `2866.61` USC → "$28.66 USD"
- 0.01 lot XAUUSDc ≈ 0.001 oz gold ≈ $4 USD notional exposure
- Tick value typically fractions of a USC

When reporting to user, always translate to USD for readability.
