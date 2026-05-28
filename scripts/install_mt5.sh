#!/usr/bin/env bash
# Idempotent install of MT5 + Wine Python + pip deps.
#
# Designed to be called from the mt5linux SERVICE (not cont-init), because
# wineboot needs a display and KasmVNC isn't up during cont-init. By the time
# this runs we're a service, KasmVNC is up, DISPLAY is set, and we're running
# as abc (the linuxserver user that owns /config) — no chown gymnastics needed.
set -euo pipefail

export WINEPREFIX="${WINEPREFIX:-/config/.wine}"
export WINEDEBUG="${WINEDEBUG:--all}"
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"

PREFIX="${WINEPREFIX}"
MT5_EXE="${PREFIX}/drive_c/Program Files/MetaTrader 5/terminal64.exe"
WINE_PYTHON_DIR="${PREFIX}/drive_c/Python311"
WINE_PYTHON="${WINE_PYTHON_DIR}/python.exe"

MARKER_DIR=/config/.mt5bridge
mkdir -p "${MARKER_DIR}"
WINEPATH_FILE="${MARKER_DIR}/wine_python_path"

log() { printf '[install_mt5] %s\n' "$*" >&2; }
trap 'log "FAILED line $LINENO: rc=$? cmd: $BASH_COMMAND"' ERR

# Reconcile stale markers.
[[ -f "${MARKER_DIR}/pip.ok"    && ! -x "${WINE_PYTHON}" ]] && rm -f "${MARKER_DIR}/pip.ok"
[[ -f "${MARKER_DIR}/python.ok" && ! -x "${WINE_PYTHON}" ]] && rm -f "${MARKER_DIR}/python.ok"
[[ -f "${MARKER_DIR}/mt5.ok"    && ! -f "${MT5_EXE}" ]] && rm -f "${MARKER_DIR}/mt5.ok"

log "===== state ====="
log "user:         $(id)"
log "DISPLAY:      ${DISPLAY:-unset}"
log "PREFIX:       ${PREFIX}"
log "MT5_EXE:      $([[ -f ${MT5_EXE} ]] && echo present || echo MISSING)"
log "WINE_PYTHON:  $([[ -x ${WINE_PYTHON} ]] && echo present || echo MISSING)"
log "markers:      $(ls ${MARKER_DIR} 2>/dev/null | tr '\n' ' ')"
log "================="

# ---- 1. Wineboot ----
if [[ ! -f "${PREFIX}/system.reg" ]]; then
  log "wineboot --init (timeout 180s)..."
  timeout 180 wine wineboot --init 2>&1 | sed 's/^/[wineboot] /' >&2 || {
    log "wineboot rc=$? — continuing"
  }
fi

# ---- 2. MetaTrader 5 ----
if [[ ! -f "${MT5_EXE}" ]]; then
  log "downloading MT5 installer..."
  curl -fsSL --connect-timeout 10 --max-time 180 \
    -o /tmp/mt5setup.exe \
    "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"
  log "installing MT5 (silent, ~60s)..."
  timeout 300 wine /tmp/mt5setup.exe /auto 2>&1 | sed 's/^/[mt5setup] /' >&2 || true
  rm -f /tmp/mt5setup.exe
  for _ in $(seq 1 60); do [[ -f "${MT5_EXE}" ]] && break; sleep 2; done
  if [[ ! -f "${MT5_EXE}" ]]; then
    log "ERROR: terminal64.exe not produced"
    ls -la "${PREFIX}/drive_c/Program Files/MetaTrader 5/" 2>&1 \
      | head -10 | sed 's/^/[install_mt5]   /' >&2 || true
    exit 1
  fi
  touch "${MARKER_DIR}/mt5.ok"
  log "MT5 installed."
fi

# ---- 3. Python 3.11 (Windows, 32-bit) at C:\Python311 ----
if [[ ! -x "${WINE_PYTHON}" ]]; then
  log "downloading Python 3.11.9 (Windows, 32-bit)..."
  curl -fsSL --connect-timeout 10 --max-time 180 \
    -o /tmp/py.exe \
    "https://www.python.org/ftp/python/3.11.9/python-3.11.9.exe"
  log "installing Python to ${WINE_PYTHON_DIR}..."
  timeout 300 wine /tmp/py.exe /quiet \
    TargetDir="C:\\Python311" \
    InstallAllUsers=1 PrependPath=0 Include_test=0 Include_launcher=0 Include_doc=0 \
    2>&1 | sed 's/^/[py-install] /' >&2 || true
  rm -f /tmp/py.exe
  for _ in $(seq 1 60); do [[ -x "${WINE_PYTHON}" ]] && break; sleep 2; done
  if [[ ! -x "${WINE_PYTHON}" ]]; then
    log "ERROR: python.exe missing at ${WINE_PYTHON}"
    find "${PREFIX}/drive_c" -maxdepth 6 -type f -name python.exe 2>/dev/null \
      | sed 's/^/[install_mt5]   found: /' >&2 || true
    exit 1
  fi
  wine "${WINE_PYTHON}" --version 2>&1 | sed 's/^/[py-validate] /' >&2
  touch "${MARKER_DIR}/python.ok"
  log "Python installed."
fi

# ---- 4. pip deps inside Wine ----
if [[ ! -f "${MARKER_DIR}/pip.ok" ]]; then
  log "upgrading pip..."
  wine "${WINE_PYTHON}" -m pip install --no-warn-script-location --upgrade pip \
    2>&1 | sed 's/^/[pip] /' >&2
  log "installing requirements-wine.txt..."
  wine "${WINE_PYTHON}" -m pip install --no-warn-script-location \
    -r /app/requirements-wine.txt 2>&1 | sed 's/^/[pip] /' >&2
  touch "${MARKER_DIR}/pip.ok"
  log "pip deps installed."
fi

printf '%s\n' "${WINE_PYTHON}" > "${WINEPATH_FILE}"
log "install complete."
