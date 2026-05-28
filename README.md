# mt5-bridge

MetaTrader 5 running under Wine in Docker, with two access surfaces:

- **mt5linux RPyC** on `:8001` — native MetaTrader5 Python API from any host
- **FastAPI REST + Swagger** on `:8000` — language-agnostic, X-API-Key auth, includes WebSocket tick stream

Built because the popular existing images each have a current bug that no longer makes them work out of the box:

- `gmag11/metatrader5_vnc` ships an entrypoint that invokes mt5linux with the pre-1.0 `-w` flag, which mt5linux ≥ 1.0 removed → `Error: Unknown switch -w` on every boot.
- `jsfrnc/mt5-docker-api` uses `RUN pip install ... || true` on Python 3.14, which silently swallows install failures so `uvicorn`/`fastapi` end up missing from the image → `api` and `mt5` supervisor processes exit 1 in <100 ms.

This image avoids both: Python 3.12, strict pinning, no `|| true`, and the correct mt5linux 1.0.x CLI (`--host`, `-p`, `-m`).

## Quick start (Dokploy / docker compose)

```bash
cd deploy
cp .env.example .env
$EDITOR .env       # fill API_KEY, VNC_PASSWORD, and optionally MT5 creds
docker compose up -d
```

Then visit:
- `http://<host>:8000/docs` — Swagger UI
- `http://<host>:8000/health` — liveness
- `http://<host>:3000` — noVNC desktop (first time only, to verify MT5 install / login)

First boot installs Mono, MT5, Wine-side Python, and Wine-side Python deps. Takes 3–5 min. State persists in the `mt5_config` named volume.

## Critical compose knobs

```yaml
security_opt:
  - seccomp:unconfined    # Wine needs unrestricted sockets
cap_add:
  - SYS_PTRACE            # Wine NT thread emulation
```

Without these, the GCP / Container-Optimized-OS-style runtimes will print `wine: socket : Function not implemented` for every Wine subprocess. Most VPS hosts (Contabo, Hetzner, etc.) don't need them but it's safe to leave on.

## REST surface

| Method | Path | Notes |
|---|---|---|
| GET    | `/health`               | No auth. Returns mt5 connection state. |
| GET    | `/account`              | Account info. |
| GET    | `/terminal`             | Terminal info. |
| GET    | `/symbols`              | List all symbols. |
| GET    | `/symbols/{symbol}`     | Symbol metadata. |
| GET    | `/symbols/{symbol}/tick`| Current bid/ask. |
| POST   | `/candles`              | OHLC from position. Body: `{symbol, timeframe, count, start_pos}`. |
| GET    | `/positions`            | Open positions. |
| POST   | `/order`                | Market order. Body: `{symbol, volume, order_type, sl?, tp?, deviation?, magic?, comment?}`. |
| WS     | `/ws/ticks/{symbol}?api_key=...` | Live tick stream (~4 Hz). |

All authenticated routes require `X-API-Key: $API_KEY` header (WebSocket uses query string).

## Python client

Either talk REST, or use the native MetaTrader5 API directly via mt5linux:

```bash
pip install mt5linux
```

```python
from mt5linux import MetaTrader5
m = MetaTrader5(host="<bridge-host>", port=8001)
m.initialize()
print(m.account_info())
print(m.symbol_info_tick("XAUUSD"))
```

## Hooking Claude

- **MCP server on your machine** — install `leeroyanesu/metatrader-mcp-server` (or similar) locally, point its HTTP backend at `http://<bridge-host>:8000`, and Claude Desktop/Code can drive trading via natural language.
- **Direct agent** — Python script using the Anthropic SDK that calls the REST API. Schedule via Claude Code Routines or cron.

## Building locally

```bash
docker build -t mt5-bridge:dev .
docker run --rm -it \
  --security-opt seccomp=unconfined --cap-add=SYS_PTRACE \
  -p 3000:3000 -p 8000:8000 -p 8001:8001 \
  -e API_KEY=test -e VNC_PASSWORD=test \
  -v mt5_config:/config \
  mt5-bridge:dev
```

## CI

`.github/workflows/build.yml` builds and pushes to `ghcr.io/<owner>/<repo>` on every push to `main` and every `v*` tag. Pull requests build but don't push.

## License

MIT.
