#!/usr/bin/env bash
# mt5 — thin wrapper for mt5-bridge REST API.
#
# Loads BASE_URL + API_KEY from a .env in the skill directory, enforces a
# max-volume cap, and requires --confirm on every write.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$SKILL_DIR/.env"

if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a
fi

: "${BASE_URL:?BASE_URL not set; populate $ENV_FILE (see .env.example)}"
: "${API_KEY:?API_KEY not set; populate $ENV_FILE (see .env.example)}"
: "${MAX_VOLUME:=0.10}"
: "${TIMEOUT:=15}"

call() {
    local method="$1" path="$2" body="${3:-}"
    local args=(-sS --max-time "$TIMEOUT" -H "X-API-Key: $API_KEY" -X "$method")
    [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" -d "$body")
    curl "${args[@]}" "$BASE_URL$path"
}

require_confirm() {
    for arg in "$@"; do
        [[ "$arg" == "--confirm" ]] && return 0
    done
    echo "REFUSED: this is a write to a live account; add --confirm" >&2
    return 3
}

over_max_volume() {
    awk -v v="$1" -v m="$MAX_VOLUME" 'BEGIN{ exit !(v+0 > m+0) }'
}

cmd="${1:-help}"; shift || true

case "$cmd" in
    health)     call GET /health ;;
    account)    call GET /account ;;
    terminal)   call GET /terminal ;;
    positions)  call GET /positions ;;
    symbols)    call GET /symbols ;;
    info)       call GET "/symbols/${1:?symbol required}" ;;
    tick)       call GET "/symbols/${1:?symbol required}/tick" ;;
    candles)
        sym="${1:?symbol}"; tf="${2:?timeframe (M1|M5|M15|M30|H1|H4|D1|W1|MN1)}"; count="${3:-100}"
        call POST /candles "{\"symbol\":\"$sym\",\"timeframe\":\"$tf\",\"count\":$count,\"start_pos\":0}"
        ;;
    order)
        side="${1:?BUY or SELL}"; sym="${2:?symbol}"; vol="${3:?volume}"
        shift 3
        if over_max_volume "$vol"; then
            echo "REFUSED: volume $vol exceeds MAX_VOLUME=$MAX_VOLUME." >&2
            echo "Override for this call: MAX_VOLUME=1.0 mt5 order $side $sym $vol --confirm" >&2
            exit 2
        fi
        require_confirm "$@" || exit $?
        extras=""
        [[ -n "${SL:-}" ]] && extras+=",\"sl\":$SL"
        [[ -n "${TP:-}" ]] && extras+=",\"tp\":$TP"
        body=$(printf '{"symbol":"%s","volume":%s,"order_type":"%s","deviation":50,"comment":"claude-skill"%s}' \
                      "$sym" "$vol" "$side" "$extras")
        call POST /order "$body"
        ;;
    close)
        ticket="${1:?position ticket}"; shift
        require_confirm "$@" || exit $?
        call POST "/positions/$ticket/close"
        ;;
    raw)
        # Escape hatch: mt5 raw GET /some/path
        # Or:           mt5 raw POST /some/path '{"json":"body"}'
        m="${1:?method}"; p="${2:?path}"; b="${3:-}"
        call "$m" "$p" "$b"
        ;;
    help|--help|-h|"")
        cat <<'EOF'
mt5 — wrapper for mt5-bridge REST API

READ commands (no confirmation):
  mt5 health
  mt5 account
  mt5 terminal
  mt5 positions
  mt5 symbols
  mt5 info <symbol>
  mt5 tick <symbol>
  mt5 candles <symbol> <timeframe> [count=100]

WRITE commands (require --confirm):
  mt5 order <BUY|SELL> <symbol> <volume> --confirm
  mt5 close <ticket> --confirm

Optional SL/TP on order:
  SL=4380 TP=4420 mt5 order BUY XAUUSD 0.01 --confirm

Override volume cap (default 0.10):
  MAX_VOLUME=0.5 mt5 order BUY XAUUSD 0.3 --confirm

Escape hatch for endpoints not yet wrapped:
  mt5 raw GET /symbols
  mt5 raw POST /candles '{"symbol":"XAUUSD","timeframe":"M1","count":5,"start_pos":0}'

Config (.env next to this script):
  BASE_URL       required (e.g. http://100.x.y.z:8000)
  API_KEY        required
  MAX_VOLUME     default 0.10 lots
  TIMEOUT        default 15s

EOF
        ;;
    *)
        echo "unknown command: $cmd (try: mt5 help)" >&2
        exit 1
        ;;
esac
