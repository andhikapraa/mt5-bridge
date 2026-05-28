#!/usr/bin/env bash
# Container entrypoint. Validates env, seeds the Wine prefix from the
# build-time template if needed, hands off to supervisord.
set -euo pipefail

: "${VNC_PASSWORD:?VNC_PASSWORD is required}"
: "${API_KEY:?API_KEY is required}"

mkdir -p /var/log/supervisor /config

# Seed Wine prefix from the pre-baked template if the persisted volume is
# either fresh OR holds a HALF-INITIALISED prefix (kernel32.dll absent — a
# previous failed runtime wineboot can leave system.reg behind without ever
# copying the system DLLs in, which then causes every future wine invocation
# to crash with `could not load kernel32.dll, status c0000135`).
PREFIX_HEALTHY=0
if [[ -f "${WINEPREFIX}/system.reg" \
   && -f "${WINEPREFIX}/drive_c/windows/system32/kernel32.dll" ]]; then
  PREFIX_HEALTHY=1
fi

if [[ ${PREFIX_HEALTHY} -eq 0 ]]; then
  echo "=== seeding Wine prefix from ${WINE_TEMPLATE} → ${WINEPREFIX} ==="
  if [[ -d "${WINEPREFIX}" ]]; then
    # Don't rm /config itself (the mountpoint) — only nuke the prefix subdir.
    # Also drop our own markers so the installer doesn't think work was done.
    echo "    removing partial prefix and stale markers"
    rm -rf "${WINEPREFIX}" /config/.mt5bridge
  fi
  mkdir -p "${WINEPREFIX}"
  cp -a "${WINE_TEMPLATE}/." "${WINEPREFIX}/"
  echo "    seeded: $(du -sh ${WINEPREFIX} | awk '{print $1}')"
  echo "    kernel32.dll present: $([[ -f ${WINEPREFIX}/drive_c/windows/system32/kernel32.dll ]] && echo yes || echo NO)"
else
  echo "=== existing healthy Wine prefix at ${WINEPREFIX} (system.reg + kernel32.dll present) ==="
fi

chmod -R u+rwX /config || true

echo "=== mt5-bridge starting ==="
echo "  WINEPREFIX:    ${WINEPREFIX}"
echo "  MT5_PORT:      ${MT5_PORT}    (mt5linux RPyC, internal)"
echo "  API_PORT:      ${API_PORT}    (FastAPI shim)"
echo "  VNC_PORT:      ${VNC_PORT}    (noVNC web)"
echo "  External 8001: socat → ${MT5_PORT}"

exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
