#!/usr/bin/env bash
# Container entrypoint. Validates env, seeds the Wine prefix from the
# build-time template if needed, hands off to supervisord.
set -euo pipefail

: "${VNC_PASSWORD:?VNC_PASSWORD is required}"
: "${API_KEY:?API_KEY is required}"

mkdir -p /var/log/supervisor /config

# Seed Wine prefix from the pre-baked template if the persisted volume is fresh.
# The template was wineboot-initialised at build time when there was no display,
# avoiding the kernel32.dll bootstrap crash that hits when Wine tries to first-boot
# inside the container at runtime.
if [[ ! -f "${WINEPREFIX}/system.reg" ]]; then
  echo "=== first boot: seeding Wine prefix from ${WINE_TEMPLATE} → ${WINEPREFIX} ==="
  mkdir -p "${WINEPREFIX}"
  cp -a "${WINE_TEMPLATE}/." "${WINEPREFIX}/"
  echo "    seeded: $(du -sh ${WINEPREFIX} | awk '{print $1}')"
else
  echo "=== existing Wine prefix found at ${WINEPREFIX} (system.reg present) ==="
fi

chmod -R u+rwX /config || true

echo "=== mt5-bridge starting ==="
echo "  WINEPREFIX:    ${WINEPREFIX}"
echo "  MT5_PORT:      ${MT5_PORT}    (mt5linux RPyC, internal)"
echo "  API_PORT:      ${API_PORT}    (FastAPI shim)"
echo "  VNC_PORT:      ${VNC_PORT}    (noVNC web)"
echo "  External 8001: socat → ${MT5_PORT}"

exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
