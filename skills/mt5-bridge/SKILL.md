---
name: mt5-bridge
description: Trade and query a MetaTrader 5 account through a self-hosted mt5-bridge REST API. Use when the user asks about account balance, equity, positions, live prices, candles, or placing/closing trades on their MT5 account — especially symbols like XAUUSD/XAUUSDc, EURUSD/EURUSDc, or mentions gold, forex, or "my MT5 account".
---

# mt5-bridge

Thin wrapper for a [mt5-bridge](https://github.com/andhikapraa/mt5-bridge) deployment — a FastAPI shim on top of MetaTrader 5 running in Wine, exposed via REST + WebSocket.

## Install

```bash
npx skills add andhikapraa/mt5-bridge
```

Then **fill in your `.env`** (one-time):

```bash
# Find where the skill was installed:
npx skills list mt5-bridge

# Copy the template and edit:
cd <skill-install-dir>
cp .env.example .env
$EDITOR .env   # set BASE_URL + API_KEY
```

The skill won't function until `API_KEY` is set. Required env vars:

| Var | Purpose |
|---|---|
| `BASE_URL` | Where your mt5-bridge runs (e.g. `http://100.x.y.z:8000` for Tailscale, or `https://mt5.example.com` behind a reverse proxy) |
| `API_KEY` | The `X-API-Key` your bridge expects |
| `MAX_VOLUME` | Optional hard cap per order (default `0.10`) |
| `TIMEOUT` | Optional curl timeout in seconds (default `15`) |

If you don't have a bridge yet, deploy one from https://github.com/andhikapraa/mt5-bridge first.

## Quick start

All calls go through `scripts/mt5.sh` (the wrapper auto-loads the `.env`):

```bash
mt5 health                       # liveness + mt5_connected
mt5 account                      # balance, equity, leverage, trade_allowed
mt5 positions                    # open positions w/ tickets + P&L
mt5 tick XAUUSD                  # live bid/ask (try XAUUSDc on cent accounts)
mt5 candles XAUUSD H1 10         # last 10 H1 candles
mt5 order BUY XAUUSD 0.01 --confirm   # market order
mt5 close <ticket> --confirm          # close by ticket
```

## Symbol convention

MT5 brokers commonly suffix symbols. Examples:

| Broker / account type | Suffix | Examples |
|---|---|---|
| Standard / vanilla | none | `XAUUSD`, `EURUSD`, `USDJPY` |
| Cent accounts (HF, RoboForex) | `c` | `XAUUSDc`, `EURUSDc` |
| Mini accounts (some brokers) | `m` | `XAUUSDm` |
| Pro/raw spread | `.pro` / `.r` | `XAUUSD.pro` |

Try the bare symbol first with `mt5 tick <symbol>`. If you get `{"detail":"symbol 'X' not found"}`, run `mt5 symbols` to list what your broker actually exposes, then translate.

## Safety rules (binding — do not bypass)

1. **Never place or close an order without explicit user confirmation in the current turn.** The user must say "yes", "place it", "go ahead" — AFTER you've shown them the proposed order with current price + estimated cost.
2. **Hard cap: `MAX_VOLUME` per order** (default 0.10). The wrapper enforces this. Refuse anything larger and explain; require the user to override via `MAX_VOLUME=…` env if they really want it.
3. **Refuse scalping / HFT.** This bridge has ~100ms round-trip latency. Sub-second trading isn't what it's for. If the user asks for a strategy with hold time < 1 minute, propose a higher timeframe instead.
4. **Read `/account` before every order.** Verify `trade_allowed: true` and `margin_free` covers the position. Refuse if either fails.
5. **No SL/TP without explicit user-provided levels.** Don't invent stops. If the user says "with a 50-pip stop", convert pip → price using `digits` from `mt5 info <symbol>`.
6. **Currency awareness.** Many MT5 accounts use **USC** (US cents) for cent accounts, not USD. 100 USC = 1 USD. Always translate to USD when speaking to the user.

## Common workflows

### "What's my balance?"
```bash
mt5 account
```
Report: balance (translate USC → USD if needed), equity, leverage, `trade_allowed`, open P&L from `mt5 positions`.

### "What's gold doing right now?"
```bash
mt5 tick XAUUSD                  # or XAUUSDc on cent accounts
mt5 candles XAUUSD M15 8         # last 2h of 15-min candles
```
Summarize: current bid/ask, spread (digits matter — `mt5 info` for the symbol), last 8 candles direction.

### "Buy 0.01 gold"
1. `mt5 account` → confirm `trade_allowed: true` and `margin_free` ≥ position margin (rough: price × volume × 100 / leverage).
2. `mt5 tick XAUUSD` → grab current ask.
3. Show user:
   > "Proposing **BUY 0.01 XAUUSD** at market (~$X.XX ask). Margin used ≈ Y. Reply 'yes' to place."
4. Wait for explicit yes.
5. `mt5 order BUY XAUUSD 0.01 --confirm` → capture `order` (ticket).
6. Confirm to user: "Filled at $Z, ticket N."

### "Close position N"
1. `mt5 positions` → show current state (open price, current price, P&L) of that ticket.
2. Ask: "Close ticket N (currently P/L = $X)? [yes/no]"
3. On yes: `mt5 close <ticket> --confirm`.

### "Open and auto-close in 5 min"
Don't promise auto-close — this skill has no timer. Place the order, then **tell the user**: "Open. Ask me again in ~5 min and I'll close ticket N."

## Endpoint details

See [REFERENCE.md](REFERENCE.md) for full request/response schemas, error codes (10009 = done, 10030 = unsupported filling, etc.), WebSocket auth pattern, and timeframe constants.

## Source

The bridge: https://github.com/andhikapraa/mt5-bridge
