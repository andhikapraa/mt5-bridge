#!/usr/bin/env bash
# Launches the Wine-side mt5linux RPyC server on ${MT5_HOST}:${MT5_PORT}.
# Uses the mt5linux 1.0.3 CLI (--host / -p / -m). The legacy `-w` flag from
# pre-1.0 versions does NOT exist any more — using it = "Unknown switch -w".
set -euo pipefail

MARKER_DIR="/config/.mt5bridge"
WPY_FILE="${MARKER_DIR}/wine_python_path"
PIP_MARKER="${MARKER_DIR}/pip.ok"

log() { printf '[mt5linux] %s\n' "$*"; }

# Block until install_mt5.sh has finished provisioning Wine + deps.
while [[ ! -f "${PIP_MARKER}" || ! -f "${WPY_FILE}" ]]; do
  log "waiting for Wine python + deps to be installed..."
  sleep 5
done

WINE_PYTHON="$(cat "${WPY_FILE}")"
if [[ ! -f "${WINE_PYTHON}" ]]; then
  log "ERROR: wine python missing at ${WINE_PYTHON}"
  exit 1
fi

log "starting mt5linux server inside Wine"
log "  python:  ${WINE_PYTHON}"
log "  bind:    0.0.0.0:${MT5_PORT}"

exec wine "${WINE_PYTHON}" -m mt5linux \
  --host 0.0.0.0 \
  --port "${MT5_PORT}" \
  --mode threaded
