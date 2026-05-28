#!/usr/bin/env bash
# Idempotent first-boot install:
#   1. Bootstrap Wine prefix (with mscoree/mshtml disabled to avoid Mono/Gecko nag dialogs)
#   2. Install MT5 terminal
#   3. Install Python 3.11 (Windows) into Wine at a deterministic TargetDir
#   4. pip install MetaTrader5 + mt5linux + pywin32 into the Wine python
#
# Mono is intentionally NOT installed. It's only needed for MT5's .NET-based
# chart plugins, which we don't use; the Python API works without it. Skipping
# Mono shaves ~80 MB of download and avoids the Wine 10 first-boot nag dialog
# that hangs wineboot indefinitely on headless displays.
set -euo pipefail

PREFIX="${WINEPREFIX}"
MT5_EXE="${PREFIX}/drive_c/Program Files/MetaTrader 5/terminal64.exe"
WINE_PYTHON_DIR="${PREFIX}/drive_c/Python311"
WINE_PYTHON="${WINE_PYTHON_DIR}/python.exe"

MARKER_DIR="/config/.mt5bridge"
WINEBOOT_MARKER="${MARKER_DIR}/wineboot.ok"
PY_MARKER="${MARKER_DIR}/python.ok"
PIP_MARKER="${MARKER_DIR}/pip.ok"

# WINEDLLOVERRIDES is set in the Dockerfile ENV too, but re-export here so
# subshells from wine subprocesses inherit it.
export WINEDLLOVERRIDES="mscoree,mshtml="

mkdir -p "${MARKER_DIR}"

log() { printf '[install_mt5] %s\n' "$*" >&2; }
trap 'log "FAILED line $LINENO: exit $? running: $BASH_COMMAND"' ERR

reconcile() {
  if [[ -f "${PY_MARKER}" && ! -x "${WINE_PYTHON}" ]]; then
    log "stale python.ok (no python.exe) → removing"
    rm -f "${PY_MARKER}" "${PIP_MARKER}"
  fi
  if [[ -f "${PIP_MARKER}" && ! -x "${WINE_PYTHON}" ]]; then
    log "stale pip.ok (no python) → removing"
    rm -f "${PIP_MARKER}"
  fi
}

debug_dump() {
  log "===== state dump ====="
  log "WINEPREFIX = ${PREFIX}"
  log "WINEDLLOVERRIDES = ${WINEDLLOVERRIDES}"
  log "MT5_EXE present:   $([[ -f ${MT5_EXE} ]] && echo yes || echo NO)"
  log "WINE_PYTHON present: $([[ -x ${WINE_PYTHON} ]] && echo yes || echo NO)"
  log "Markers: $(ls ${MARKER_DIR} 2>/dev/null | tr '\n' ' ')"
  log "====================="
}

sleep 3
reconcile
debug_dump

# ---- 0. Wineboot ----
# Skipped: the prefix is now seeded from a build-time template by entrypoint.sh.
# If somehow it's still raw, fall back to wineboot here.
if [[ ! -f "${PREFIX}/system.reg" ]]; then
  log "WARN: prefix not seeded from template; running wineboot fallback"
  timeout 120 wine wineboot --init 2>&1 | sed 's/^/[wineboot] /' >&2 || true
fi

# ---- 1. MT5 terminal ----
if [[ ! -f "${MT5_EXE}" ]]; then
  log "downloading MT5 installer (~25 MB)..."
  curl -fsSL --connect-timeout 10 --max-time 180 \
    -o /tmp/mt5setup.exe \
    "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"
  log "running MT5 installer (silent, ~60s)..."
  timeout 300 wine /tmp/mt5setup.exe /auto 2>&1 | sed 's/^/[mt5setup] /' >&2 || true
  rm -f /tmp/mt5setup.exe
  for i in $(seq 1 60); do
    [[ -f "${MT5_EXE}" ]] && break
    sleep 2
  done
  if [[ ! -f "${MT5_EXE}" ]]; then
    log "ERROR: MT5 install did not produce terminal64.exe"
    ls -la "${PREFIX}/drive_c/Program Files/MetaTrader 5" 2>&1 \
      | head -20 | sed 's/^/[install_mt5]   /' >&2 || true
    exit 1
  fi
  log "MT5 installed."
fi

# ---- 2. Python 3.11 32-bit at C:\Python311 ----
if [[ ! -x "${WINE_PYTHON}" ]]; then
  log "downloading Python 3.11.9 (Windows 32-bit, ~25 MB)..."
  curl -fsSL --connect-timeout 10 --max-time 180 \
    -o /tmp/py.exe \
    "https://www.python.org/ftp/python/3.11.9/python-3.11.9.exe"
  log "installing Python to ${WINE_PYTHON_DIR}..."
  timeout 300 wine /tmp/py.exe /quiet \
    TargetDir="C:\\Python311" \
    InstallAllUsers=1 \
    PrependPath=0 \
    Include_test=0 \
    Include_launcher=0 \
    Include_doc=0 \
    2>&1 | sed 's/^/[py-install] /' >&2 || true
  rm -f /tmp/py.exe
  for i in $(seq 1 60); do
    [[ -x "${WINE_PYTHON}" ]] && break
    sleep 2
  done
  if [[ ! -x "${WINE_PYTHON}" ]]; then
    log "ERROR: Python install did not produce ${WINE_PYTHON}"
    find "${PREFIX}/drive_c" -maxdepth 6 -type f -name python.exe 2>/dev/null \
      | sed 's/^/[install_mt5]   found: /' >&2 || true
    exit 1
  fi
  if ! wine "${WINE_PYTHON}" --version 2>&1 | sed 's/^/[py-validate] /' >&2; then
    log "ERROR: ${WINE_PYTHON} exists but won't execute under Wine"
    exit 1
  fi
  touch "${PY_MARKER}"
  log "Python installed and validated."
fi

# ---- 3. pip deps inside Wine ----
if [[ ! -f "${PIP_MARKER}" ]]; then
  log "upgrading pip..."
  wine "${WINE_PYTHON}" -m pip install --no-warn-script-location --upgrade pip \
    2>&1 | sed 's/^/[pip] /' >&2
  log "installing Wine-side deps from requirements-wine.txt..."
  wine "${WINE_PYTHON}" -m pip install --no-warn-script-location \
    -r /app/requirements-wine.txt \
    2>&1 | sed 's/^/[pip] /' >&2
  touch "${PIP_MARKER}"
  log "pip deps installed."
fi

printf '%s\n' "${WINE_PYTHON}" > "${MARKER_DIR}/wine_python_path"
log "install complete — mt5linux server can now start."
