#!/usr/bin/env bash
# Container entrypoint. Validates env, prepares dirs, hands off to supervisord.
set -euo pipefail

: "${VNC_PASSWORD:?VNC_PASSWORD is required}"
: "${API_KEY:?API_KEY is required}"

# Wine + supervisor working dirs.
mkdir -p /var/log/supervisor /config "${WINEPREFIX}"

# Wine prefix lives under /config which is the persisted volume mount point.
# Make sure it's writable (named-volume first-init can leave odd permissions).
chmod -R u+rwX /config || true

echo "=== mt5-bridge starting ==="
echo "  WINEPREFIX:    ${WINEPREFIX}"
echo "  MT5_PORT:      ${MT5_PORT}    (mt5linux RPyC, internal)"
echo "  API_PORT:      ${API_PORT}    (FastAPI shim)"
echo "  VNC_PORT:      ${VNC_PORT}    (noVNC web)"
echo "  External 8001: socat → ${MT5_PORT}"

exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
