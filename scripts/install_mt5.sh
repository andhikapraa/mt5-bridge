#!/usr/bin/env bash
# Idempotent first-boot install:
#   1. Bootstrap Wine prefix
#   2. Install Mono (Wine's .NET) if missing
#   3. Install MT5 terminal if missing
#   4. Install Python (Windows) into Wine at a deterministic path
#   5. pip install MetaTrader5 + mt5linux + pywin32 into the Wine python
#
# Markers under /config/.mt5bridge/ are ADVISORY — every gate also verifies
# the real artefact exists and runs. A stale marker on its own won't fool us.
set -euo pipefail

PREFIX="${WINEPREFIX}"
MT5_EXE="${PREFIX}/drive_c/Program Files/MetaTrader 5/terminal64.exe"
# Pinned TargetDir: installer always puts python.exe here. No more guessing.
WINE_PYTHON_DIR="${PREFIX}/drive_c/Python311"
WINE_PYTHON="${WINE_PYTHON_DIR}/python.exe"

MARKER_DIR="/config/.mt5bridge"
MONO_MARKER="${MARKER_DIR}/mono.ok"
PY_MARKER="${MARKER_DIR}/python.ok"
PIP_MARKER="${MARKER_DIR}/pip.ok"

mkdir -p "${MARKER_DIR}"

log() { printf '[install_mt5] %s\n' "$*" >&2; }
trap 'log "FAILED line $LINENO: exit $? running: $BASH_COMMAND"' ERR

# Reconcile any stale markers vs reality. If a marker says "done" but the
# real artefact is gone, drop the marker so we re-install.
reconcile() {
  if [[ -f "${MONO_MARKER}" && ! -d "${PREFIX}/drive_c/windows/mono" ]]; then
    log "stale mono.ok (no mono dir) → removing"; rm -f "${MONO_MARKER}"
  fi
  if [[ -f "${PY_MARKER}" && ! -x "${WINE_PYTHON}" ]]; then
    log "stale python.ok (no python.exe at ${WINE_PYTHON}) → removing"
    rm -f "${PY_MARKER}" "${PIP_MARKER}"
  fi
  if [[ -f "${PIP_MARKER}" && ! -x "${WINE_PYTHON}" ]]; then
    log "stale pip.ok (no python) → removing"; rm -f "${PIP_MARKER}"
  fi
}

debug_dump() {
  log "===== state dump ====="
  log "WINEPREFIX = ${PREFIX}"
  log "MT5_EXE present:   $([[ -f ${MT5_EXE} ]] && echo yes || echo NO)"
  log "WINE_PYTHON_DIR contents:"
  ls -la "${WINE_PYTHON_DIR}" 2>&1 | head -10 | sed 's/^/[install_mt5]   /' >&2 || true
  log "Markers: $(ls -la ${MARKER_DIR} 2>/dev/null | tail -n +2 | awk '{print $NF}' | tr '\n' ' ')"
  log "====================="
}

sleep 3
reconcile
debug_dump

# ---- 0. Wineboot ----
log "wineboot init..."
WINEDEBUG=-all wineboot --init >/dev/null 2>&1 || true

# ---- 1. Mono ----
if [[ ! -f "${MONO_MARKER}" ]]; then
  log "downloading Mono..."
  curl -fsSL --connect-timeout 10 --max-time 120 \
    -o /tmp/mono.msi \
    "https://dl.winehq.org/wine/wine-mono/8.0.0/wine-mono-8.0.0-x86.msi"
  log "installing Mono (silent)..."
  WINEDEBUG=-all wine msiexec /i /tmp/mono.msi /qn 2>&1 | sed 's/^/[mono] /' >&2 || true
  rm -f /tmp/mono.msi
  touch "${MONO_MARKER}"
  log "Mono done."
fi

# ---- 2. MT5 terminal ----
if [[ ! -f "${MT5_EXE}" ]]; then
  log "downloading MT5 installer..."
  curl -fsSL --connect-timeout 10 --max-time 120 \
    -o /tmp/mt5setup.exe \
    "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"
  log "running MT5 installer (silent, may take ~60s)..."
  WINEDEBUG=-all wine /tmp/mt5setup.exe /auto 2>&1 | sed 's/^/[mt5setup] /' >&2 || true
  rm -f /tmp/mt5setup.exe
  for i in $(seq 1 60); do
    [[ -f "${MT5_EXE}" ]] && break
    sleep 2
  done
  if [[ ! -f "${MT5_EXE}" ]]; then
    log "ERROR: MT5 install did not produce terminal64.exe"
    log "  Wine MT5 dir contents:"
    ls -la "${PREFIX}/drive_c/Program Files/MetaTrader 5" 2>&1 | head -20 | sed 's/^/[install_mt5]   /' >&2 || true
    exit 1
  fi
  log "MT5 installed."
fi

# ---- 3. Python 3.11 32-bit into Wine at a FIXED path ----
if [[ ! -x "${WINE_PYTHON}" ]]; then
  log "downloading Python 3.11.9 (Windows 32-bit)..."
  curl -fsSL --connect-timeout 10 --max-time 180 \
    -o /tmp/py.exe \
    "https://www.python.org/ftp/python/3.11.9/python-3.11.9.exe"
  log "installing Python into ${WINE_PYTHON_DIR}..."
  # TargetDir = deterministic path. /quiet = unattended. PrependPath=0 because
  # we always invoke python via its absolute path.
  WINEDEBUG=-all wine /tmp/py.exe /quiet \
    TargetDir="C:\\Python311" \
    InstallAllUsers=1 \
    PrependPath=0 \
    Include_test=0 \
    Include_launcher=0 \
    2>&1 | sed 's/^/[py-install] /' >&2 || true
  rm -f /tmp/py.exe
  # Wait for installer to finish writing files.
  for i in $(seq 1 60); do
    [[ -x "${WINE_PYTHON}" ]] && break
    sleep 2
  done
  if [[ ! -x "${WINE_PYTHON}" ]]; then
    log "ERROR: Python install did not produce ${WINE_PYTHON}"
    log "  Search results across the prefix:"
    find "${PREFIX}/drive_c" -maxdepth 6 -type f -name python.exe 2>/dev/null \
      | sed 's/^/[install_mt5]   found: /' >&2 || true
    exit 1
  fi
  # Validate by running it.
  if ! WINEDEBUG=-all wine "${WINE_PYTHON}" --version >/dev/null 2>&1; then
    log "ERROR: ${WINE_PYTHON} exists but won't execute under Wine"
    exit 1
  fi
  touch "${PY_MARKER}"
  log "Python installed and validated."
fi

# ---- 4. Wine-side pip deps ----
if [[ ! -f "${PIP_MARKER}" ]]; then
  log "upgrading pip in Wine python..."
  WINEDEBUG=-all wine "${WINE_PYTHON}" -m pip install --no-warn-script-location --upgrade pip \
    2>&1 | sed 's/^/[pip] /' >&2
  log "installing Wine-side deps from requirements-wine.txt..."
  WINEDEBUG=-all wine "${WINE_PYTHON}" -m pip install --no-warn-script-location \
    -r /app/requirements-wine.txt \
    2>&1 | sed 's/^/[pip] /' >&2
  touch "${PIP_MARKER}"
  log "pip deps installed."
fi

# Record path for start_mt5linux.sh.
printf '%s\n' "${WINE_PYTHON}" > "${MARKER_DIR}/wine_python_path"

log "install complete. ready for mt5linux server."
