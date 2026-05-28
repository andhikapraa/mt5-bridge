# mt5-bridge

Trade your MetaTrader 5 account from anything that speaks HTTP — REST, WebSocket, or `mt5linux` directly — without running a Windows machine.

Two-container Docker stack: **MT5 + Wine** on one side, **FastAPI shim** on the other. Drop it on any Linux VPS with `seccomp:unconfined` enabled, and you have a working trading API in ~10 minutes (~5 of which is just downloading installers).

> [!NOTE]
> Built because the two popular upstream images each have current bugs that break out of the box: `gmag11/metatrader5_vnc` invokes `mt5linux` with the removed pre-1.0 `-w` flag, and `jsfrnc/mt5-docker-api` uses `RUN pip install … || true` on Python 3.14 which silently ships a broken image. This repo fixes both.

---

## Table of contents

- [What you get](#what-you-get)
- [Quick start](#quick-start)
- [Agent skill (Claude / Cursor / Codex / …)](#agent-skill-claude--cursor--codex--)
- [REST endpoints](#rest-endpoints)
- [WebSocket](#websocket)
- [Configuration](#configuration)
- [Architecture](#architecture)
- [Deployment notes](#deployment-notes)
- [Security](#security)
- [Repository layout](#repository-layout)
- [Development](#development)
- [Known upstream quirks](#known-upstream-quirks)
- [License](#license)

---

## What you get

- **REST API** on `:8000` — `/account`, `/positions`, `/symbols`, `/candles`, `/order`, `/positions/{ticket}/close`. Swagger UI at `/docs`.
- **WebSocket** at `/ws/ticks/{symbol}` — live bid/ask stream, only sends on change.
- **mt5linux RPyC** (internal) — same RPyC server `gmag11` ships, **pinned to mt5linux 0.1.9** so the `-w` startup flag actually works.
- **KasmVNC** on `:3000` — browser desktop for the one-time MT5 install + broker login.
- **`X-API-Key` header auth** on every REST/WS call. KasmVNC has its own user/pass.
- **Verified end-to-end on a live broker account** — placed and closed a real order through `/order` and `/positions/{ticket}/close`.

---

## Quick start

> [!IMPORTANT]
> Wine inside Docker needs the host's default seccomp profile relaxed. Without `security_opt: [seccomp:unconfined]`, every Wine subprocess fails with `wine: socket : Function not implemented` and MT5 will never finish installing. This is in the compose file already — don't strip it.

### 1. Clone and configure

```bash
git clone https://github.com/andhikapraa/mt5-bridge
cd mt5-bridge/deploy
cp .env.example .env
$EDITOR .env   # fill API_KEY, PASSWORD, and MT5_LOGIN/PASSWORD/SERVER
```

Generate strong secrets with `openssl rand -hex 32`.

**Finding your broker's `MT5_SERVER`:** open the MT5 desktop app (any machine, even on Windows) → File → Login to Trade Account → the **Server** dropdown lists every endpoint your broker supports. Copy the exact string (e.g. `HFMarketsGlobal-Live15`, `Exness-MT5Trial7`, `XMGlobal-Demo 3`). If you don't have the desktop app, your broker's website usually publishes the list.

**Different broker than HF Markets?** Set `MT5_SETUP_URL` in `.env` to your broker's branded installer URL (find it on their site under "MT5 download"). Otherwise the default lands on HF's login dialog — works, just shows the wrong logo. Or use the vanilla MetaQuotes installer: `https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe`.

### 2. Start it

```bash
docker compose up -d
```

First boot installs Mono → MT5 → Python 3.9 in Wine → pip deps → mt5linux server. **Allow ~10 minutes.** State persists in the `mt5_state` named volume; subsequent restarts skip install entirely.

Watch the install progress in the logs:
```bash
docker compose logs -f mt5
```

You'll see `[1/7] Mono installed.` through `[7/7] mt5linux server is running on port 8001.` (the `[7/7] FAILED` line is a benign timing false-positive — the next line `INFO:SLAVE/8001:server started` confirms it actually started).

### 3. First-time MT5 setup (one time, via KasmVNC)

Open the noVNC desktop in a browser:
```
http://<host>:3000
```
Log in with user `trader`, password from `.env`. You'll see the MT5 terminal — already logged in if `MT5_LOGIN/PASSWORD/SERVER` were set correctly. If not, **File → Login to Trade Account**, paste your credentials.

> [!IMPORTANT]
> **Enable algorithmic trading or `/order` will fail.** In MT5: **Tools → Options → Expert Advisors → check "Allow algorithmic trading"** → OK. Verify with:
> ```bash
> curl -H "X-API-Key: $API_KEY" http://<host>:8000/account | grep trade_allowed
> ```
> Must show `"trade_allowed": true`. Without this, `/order` posts return `retcode: 10027` (autotrading disabled).

After this is done you can stop port 3000 entirely: comment out the `3000:3000` line in compose and redeploy — VNC only needed for first setup and emergency debugging.

### 4. Verify end-to-end

```bash
# Health (no auth) — should show mt5_connected: true
curl http://<host>:8000/health

# Live account
curl -H "X-API-Key: $API_KEY" http://<host>:8000/account

# What symbols does your broker expose? (cent accounts add 'c', mini 'm', etc.)
curl -H "X-API-Key: $API_KEY" http://<host>:8000/symbols

# Live tick
curl -H "X-API-Key: $API_KEY" http://<host>:8000/symbols/EURUSD/tick

# Swagger UI
open http://<host>:8000/docs
```

If `mt5_connected: false` persists after 10 minutes, check VNC: MT5 may have crashed or hit a login prompt that needs manual interaction.

---

## Agent skill (Claude / Cursor / Codex / …)

This repo ships a [Vercel-style agent skill](https://github.com/vercel-labs/skills) at [`skills/mt5-bridge/`](./skills/mt5-bridge/) — installable into any of 50+ coding agents (Claude Code, Cursor, Codex, Amp, Cline, OpenCode, etc.):

```bash
# Install globally for Claude Code
npx skills add andhikapraa/mt5-bridge -g -a claude-code

# Or interactively — picks your agent
npx skills add andhikapraa/mt5-bridge
```

Then fill in the skill's `.env`:

```bash
# Find install location:
npx skills list mt5-bridge

# Copy template and edit:
cd <skill-install-dir>
cp .env.example .env
$EDITOR .env   # set BASE_URL + API_KEY (matches your deploy/.env API_KEY)
```

The skill ships a `mt5` CLI wrapper that the agent uses for everything: `mt5 account`, `mt5 tick XAUUSD`, `mt5 candles XAUUSD H1 10`, `mt5 order BUY XAUUSD 0.01 --confirm`, etc. Built-in guardrails: max-volume cap, `--confirm` required on every write, never invents SL/TP, refuses sub-minute scalping. See [`skills/mt5-bridge/SKILL.md`](./skills/mt5-bridge/SKILL.md) for the agent-facing prompt and [`skills/mt5-bridge/REFERENCE.md`](./skills/mt5-bridge/REFERENCE.md) for the full endpoint reference.

After that you can just tell the agent things like *"what's my balance"*, *"what's gold doing right now"*, or *"buy 0.01 gold"* — and it'll route through the skill, ask you to confirm before any trade, then place it.

## REST endpoints

All authenticated routes require `X-API-Key: $API_KEY`.

| Method | Path | Notes |
|---|---|---|
| `GET` | `/health` | No auth. Liveness + MT5 connection state. |
| `GET` | `/account` | Login, balance, equity, leverage, currency, `trade_allowed`. |
| `GET` | `/terminal` | MT5 terminal info (build, install path, connection state). |
| `GET` | `/symbols` | List all instruments in MarketWatch (count + names). |
| `GET` | `/symbols/{symbol}` | Full symbol metadata (digits, vol limits, currencies, filling mode). |
| `GET` | `/symbols/{symbol}/tick` | Live bid/ask/last + timestamps. |
| `POST` | `/candles` | OHLC history. Body: `{symbol, timeframe, count, start_pos}`. Timeframes: `M1 M5 M15 M30 H1 H4 D1 W1 MN1`. |
| `GET` | `/positions` | All currently open positions. |
| `POST` | `/order` | Market order. Body: `{symbol, volume, order_type:"BUY"\|"SELL", sl?, tp?, deviation?, magic?, comment?}`. Filling mode auto-detected from `symbol.filling_mode`. |
| `POST` | `/positions/{ticket}/close` | Close one position via counter-DEAL bound to ticket. Works in netting and hedging accounts. |
| `GET` | `/docs` | Swagger UI. |

### Example — place and close

```bash
# Open
curl -X POST http://<host>:8000/order \
  -H "X-API-Key: $API_KEY" -H "Content-Type: application/json" \
  -d '{"symbol":"XAUUSDc","volume":0.01,"order_type":"BUY","deviation":50,"comment":"test"}'
# → {"retcode":10009,"order":19728074981,"price":4426.42,...}

# Close
curl -X POST http://<host>:8000/positions/19728074981/close \
  -H "X-API-Key: $API_KEY"
# → {"retcode":10009,"deal":...,"price":4427.33,...}
```

---

## WebSocket

```
ws://<host>:8000/ws/ticks/{symbol}?api_key=<API_KEY>
```

Auth via query string (browsers can't set custom headers on WS connect). Server only emits a frame when `time_msc` advances — about 2–10 frames/sec on a liquid pair during market hours. Bad symbol → server sends `{"error":"symbol not found","symbol":"..."}` and closes.

```python
import asyncio, json, websockets
async def main():
    async with websockets.connect(
        "ws://<host>:8000/ws/ticks/XAUUSDc?api_key=...") as ws:
        for _ in range(10):
            print(json.loads(await ws.recv()))
asyncio.run(main())
```

---

## Configuration

All via env vars in `deploy/.env`.

| Variable | Required | Default | Description |
|---|---|---|---|
| `API_KEY` | ✅ | — | `X-API-Key` value for every REST/WS request. Generate with `openssl rand -hex 32`. |
| `PASSWORD` | ✅ | — | KasmVNC web auth password (user is `CUSTOM_USER`). |
| `CUSTOM_USER` |  | `trader` | KasmVNC web auth username. |
| `MT5_LOGIN` |  | — | Broker account number. If set with PASSWORD+SERVER, shim auto-logs in. |
| `MT5_PASSWORD` |  | — | Broker account password. |
| `MT5_SERVER` |  | — | Broker server name (e.g. `YourBroker-Demo`, `Exness-MT5Trial7`). Find it via MT5 desktop → File → Login. |
| `MT5_SETUP_URL` |  | broker-branded installer | URL of a broker's branded MT5 installer. Defaults to one example broker — override for yours (or use the vanilla `https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe`). |
| `ALLOWED_ORIGINS` |  | `*` | CORS origins for the REST API (browser callers only). |
| `LOG_LEVEL` |  | `INFO` | Shim FastAPI log level. |

> [!WARNING]
> `MT5_SETUP_URL` defaults to a specific broker's branded installer. **Override it for your broker** — branded installers land directly on the broker's login dialog (vs the MetaQuotes generic that needs server selection). The script auto-discovers `terminal64.exe` regardless of which install folder the broker uses.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Your agent / Claude / browser / Python script                  │
│                          │                                       │
│              X-API-Key   │   HTTP / WebSocket                    │
└──────────────────────────┼───────────────────────────────────────┘
                           ▼
┌───────────────────── Docker host ─────────────────────────────┐
│  shim container (Python 3.12 + FastAPI)                       │
│    • /health, /account, /symbols, /candles, /order, …         │
│    • WebSocket /ws/ticks/{symbol}                             │
│    • API-key auth, CORS, request validation                   │
│    • mt5linux client → talks to mt5 over docker DNS           │
│                       │  RPyC :8001 (docker network only)     │
│                       ▼                                       │
│  mt5 container (linuxserver/baseimage-kasmvnc + Wine)         │
│    • KasmVNC web (:3000) for one-time install + manual login  │
│    • Wine + MetaTrader 5 terminal (HFM branded)               │
│    • Wine-side Python 3.9 + MetaTrader5 + mt5linux 0.1.9      │
│    • RPyC server bound to 0.0.0.0:8001 inside docker network  │
│    • /config volume: persistent Wine prefix + MT5 install     │
└───────────────────────────────────────────────────────────────┘
                           │
                           ▼   broker MT5 protocol
                  ┌────────────────┐
                  │  Your broker   │
                  └────────────────┘
```

Two-container split exists because Wine and FastAPI have very different runtime requirements (Wine wants `seccomp:unconfined` + `SYS_PTRACE`; the shim doesn't). Keeping them separate means the shim can be redeployed in seconds without touching Wine state.

---

## Deployment notes

### Tailscale-only binding

Recommended for any non-LAN deploy: bind both ports to your Tailscale interface so nothing is exposed publicly.

```yaml
# deploy/docker-compose.yml
ports:
  - "100.x.y.z:3000:3000"   # KasmVNC
  - "100.x.y.z:8000:8000"   # REST + WS
```

Get the IP from `tailscale ip -4` on the host. After applying, public-internet curls to the box's public IP refuse the connection while tailnet members reach it normally.

### Dokploy (or any docker-compose runner)

Works out of the box. Point Dokploy at this repo or paste `deploy/docker-compose.yml` as a raw compose service, then add the `.env` values as Dokploy secrets. The CI workflow auto-publishes `ghcr.io/<owner>/mt5-bridge:latest-mt5` and `:latest-shim` on every push to `main`.

### Resource sizing

- **mt5 container**: 2–4 GB RAM during install, idles at ~1.5 GB. CPU mostly idle except during install (~5 min one-time).
- **shim container**: ~50 MB RAM, negligible CPU.
- **Disk**: ~3 GB for the Wine prefix + MT5 + Python; ~1.6 GB for the mt5 image; ~200 MB for the shim image.

A €5/mo VPS handles it. Avoid GCP container-runtime VMs unless you can disable their restrictive seccomp profile — bare Linux VPS hosts (Hetzner, Contabo, OVH) work without ceremony.

---

## Security

- **Never expose `:3000` or `:8000` directly to the public internet.** Tailscale-bind, Cloudflare Tunnel, or front with HTTPS reverse proxy.
- **`X-API-Key` is constant-time compared** via `secrets.compare_digest`. Still rotate it if it leaks.
- **MT5 credentials live only in the container's `/config` volume** and in your `.env`. The shim image doesn't bake them.
- **Trade execution requires `trade_allowed: true`** in MT5 — enable from VNC desktop: Tools → Options → Expert Advisors → Allow algorithmic trading.
- **GitHub repo is public; `.env` is gitignored.** Always run `git check-ignore deploy/.env` to confirm before committing.

> [!CAUTION]
> **Always test against a demo account first.** Point `MT5_SERVER` at a `*-Demo` server before granting `/order` permission to any non-human caller. Real money is real money.

---

## Repository layout

```
mt5-bridge/
├── mt5/                          # MT5 + Wine container
│   ├── Dockerfile                # FROM gmag11/metatrader5_vnc
│   └── start.sh                  # patched: mt5linux 0.1.9 pin + branded installer + auto-discover
├── shim/                         # FastAPI REST/WS container
│   ├── Dockerfile                # python:3.12-slim + uvicorn
│   ├── requirements.txt          # mt5linux installed via --no-deps (skips its py3.12-incompatible numpy pin)
│   └── api/
│       ├── main.py               # routes + lifespan warmup
│       ├── auth.py               # X-API-Key dependency
│       ├── models.py             # OrderRequest, CandlesRequest, HealthResponse
│       └── mt5_proxy.py          # mt5linux client w/ reconnect + value coercion
├── skills/mt5-bridge/            # Agent skill — installable via `npx skills add andhikapraa/mt5-bridge`
│   ├── SKILL.md                  # agent-facing prompt + workflows + safety rules
│   ├── REFERENCE.md              # full endpoint reference (loaded on demand)
│   ├── scripts/mt5.sh            # CLI wrapper the skill uses
│   └── .env.example              # template for BASE_URL + API_KEY
├── deploy/
│   ├── docker-compose.yml        # two-service stack
│   └── .env.example              # template
├── .github/workflows/build.yml   # CI: matrix-builds both images → GHCR
├── README.md
└── LICENSE                       # MIT
```

---

## Development

```bash
# Build both images locally
docker build -t mt5-bridge:mt5  mt5/
docker build -t mt5-bridge:shim shim/

# Or push a change and let CI publish to GHCR
git push origin main
```

CI uses a matrix build to push `ghcr.io/<owner>/mt5-bridge:latest-{mt5,shim}` and version-tagged images on `v*` tags.

To iterate on the shim without touching the mt5 container, rebuild just the shim and `docker compose up -d shim`. MT5 stays connected — the shim reconnects automatically on its next call.

---

## Known upstream quirks

These aren't bugs in this repo — they're things to know about MT5 / mt5linux / Wine in containers.

- **`contract_size` returns `null`** on some symbols via `/symbols/{name}`. mt5linux 0.1.9 doesn't always populate every nullable double field. Workaround: derive from `trade_tick_value / trade_tick_size` or hard-code per-account (cent gold = `0.1` oz, cent forex = `100` units).
- **`ShellExecuteEx failed: File not found`** when MT5 first launches. Cosmetic — MT5's auto-launch helper isn't found, but the terminal itself starts fine.
- **`wine: socket : Function not implemented`** if you remove `seccomp:unconfined`. Wine literally cannot do network I/O without it on a Docker host.
- **`Unsupported filling mode` (retcode 10030)** on `/order` if your symbol declares a `filling_mode` other than what's hardcoded. This is auto-detected in this repo — but if you fork the shim, keep `_pick_filling_mode()`.
- **mt5 service first boot takes ~10 min.** Mono (80 MB) + MT5 (22 MB) + Python (26 MB) + pip deps. Subsequent boots are <30 seconds.
- **Health check stays `degraded` for 1–2 minutes after redeploy** even on warm volumes, because MT5 has to re-establish its broker socket. Expected.

---

## License

[MIT](./LICENSE) — do whatever you want, no warranty, real trading at your own risk.
