#!/usr/bin/env bash
# Idempotent first-boot install:
#   1. Bootstrap Wine prefix
#   2. Install Mono (Wine's .NET) if missing
#   3. Install MT5 terminal if missing
#   4. Install Python (Windows) into Wine if missing
#   5. pip install MetaTrader5 + mt5linux + pywin32 into the Wine python
#
# Skips any step whose artefact already exists, so restart is cheap.
set -euo pipefail

PREFIX="${WINEPREFIX}"
MT5_EXE="${PREFIX}/drive_c/Program Files/MetaTrader 5/terminal64.exe"
WINE_PYTHON="${PREFIX}/drive_c/users/root/AppData/Local/Programs/Python/Python311/python.exe"
MARKER_DIR="/config/.mt5bridge"
MONO_MARKER="${MARKER_DIR}/mono.ok"
PY_MARKER="${MARKER_DIR}/python.ok"
PIP_MARKER="${MARKER_DIR}/pip.ok"

mkdir -p "${MARKER_DIR}"

log() { printf '[install_mt5] %s\n' "$*"; }

# Give xvfb a moment to bind :1 (supervisor priorities run us after it but
# socket creation isn't instantaneous).
sleep 3

# 0. Wineboot — fast no-op once initialised.
log "wineboot init..."
WINEDEBUG=-all wineboot --init >/dev/null 2>&1 || true

# 1. Mono (Wine's .NET runtime; MT5 installer needs it for some features).
if [[ ! -f "${MONO_MARKER}" ]]; then
  log "Downloading Mono..."
  curl -fsSL -o /tmp/mono.msi \
    "https://dl.winehq.org/wine/wine-mono/8.0.0/wine-mono-8.0.0-x86.msi"
  log "Installing Mono..."
  WINEDEBUG=-all wine msiexec /i /tmp/mono.msi /qn || true
  rm -f /tmp/mono.msi
  touch "${MONO_MARKER}"
fi

# 2. MT5 terminal.
if [[ ! -f "${MT5_EXE}" ]]; then
  log "Downloading MT5 installer..."
  curl -fsSL -o /tmp/mt5setup.exe \
    "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"
  log "Installing MetaTrader 5 (silent)..."
  # /auto = unattended install. May exit non-zero even on success; we verify by file.
  WINEDEBUG=-all wine /tmp/mt5setup.exe /auto >/dev/null 2>&1 || true
  rm -f /tmp/mt5setup.exe
  # Wait up to 120s for terminal64.exe to appear.
  for _ in $(seq 1 60); do
    [[ -f "${MT5_EXE}" ]] && break
    sleep 2
  done
  if [[ ! -f "${MT5_EXE}" ]]; then
    log "ERROR: MT5 install did not produce terminal64.exe"
    exit 1
  fi
  log "MT5 installed."
fi

# 3. Python 3.11 (Windows) into Wine.
#    3.11 has the broadest wheel availability for our deps.
if [[ ! -f "${WINE_PYTHON}" && ! -f "${PY_MARKER}" ]]; then
  log "Downloading Python 3.11.9 (Windows)..."
  curl -fsSL -o /tmp/py.exe \
    "https://www.python.org/ftp/python/3.11.9/python-3.11.9.exe"
  log "Installing Python into Wine (silent)..."
  WINEDEBUG=-all wine /tmp/py.exe /quiet InstallAllUsers=0 PrependPath=1 Include_test=0 >/dev/null 2>&1 || true
  rm -f /tmp/py.exe
  touch "${PY_MARKER}"
fi

# Resolve actual wine-python path (installer may pick a slightly different dir).
if [[ ! -f "${WINE_PYTHON}" ]]; then
  WINE_PYTHON="$(find "${PREFIX}/drive_c/users" -type f -name python.exe 2>/dev/null | head -n1)"
fi
if [[ -z "${WINE_PYTHON}" || ! -f "${WINE_PYTHON}" ]]; then
  log "ERROR: could not locate Wine python.exe after install"
  exit 1
fi
log "Wine python: ${WINE_PYTHON}"

# 4. pip install MetaTrader5 + mt5linux + pywin32 inside Wine.
if [[ ! -f "${PIP_MARKER}" ]]; then
  log "Installing Wine-side Python deps..."
  WINEDEBUG=-all wine "${WINE_PYTHON}" -m pip install --no-warn-script-location --upgrade pip
  WINEDEBUG=-all wine "${WINE_PYTHON}" -m pip install --no-warn-script-location -r /app/requirements-wine.txt
  touch "${PIP_MARKER}"
fi

# Record path for start_mt5linux.sh.
printf '%s\n' "${WINE_PYTHON}" > "${MARKER_DIR}/wine_python_path"

log "Install/verify complete."
