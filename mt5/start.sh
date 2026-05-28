#!/bin/bash
# Fork of gmag11's /Metatrader/start.sh, single change:
#   mt5linux pinned to <1.0 (i.e. 0.1.9) on BOTH Wine and Linux sides because
#   mt5linux 1.0.x removed the `-w` flag this script uses to start the RPyC
#   server, and the script breaks at step [7/7] with "Unknown switch -w".

# Configuration variables
WINEPREFIX='/config/.wine'
WINEDEBUG='-all'
wine_executable="wine"
metatrader_version="5.0.36"
mt5linux_version="0.1.9"          # <-- pinned (was unpinned in upstream)
mt5server_port="8001"
MT5_CMD_OPTIONS="${MT5_CMD_OPTIONS:-}"
mono_url="https://dl.winehq.org/wine/wine-mono/10.3.0/wine-mono-10.3.0-x86.msi"
python_url="https://www.python.org/ftp/python/3.9.13/python-3.9.13.exe"

# Broker-branded MT5 installer. Comes pre-configured with the broker's server
# so the first launch lands directly on the login dialog for HFMarketsGlobal,
# rather than the MetaQuotes generic terminal that needs server selection.
# Override with MT5_SETUP_URL env var for other brokers.
mt5setup_url="${MT5_SETUP_URL:-https://download.terminal.free/cdn/web/12018/mt5/hfmarketsglobal5setup.exe}"

# Auto-discover terminal64.exe across any "Program Files" subfolder, since
# broker-branded installers use names like "HF Markets Global MT5" instead
# of the vanilla "MetaTrader 5".
find_mt5() {
    find "/config/.wine/drive_c/Program Files" -maxdepth 3 \
        -type f -name terminal64.exe 2>/dev/null | head -1
}
mt5file="$(find_mt5)"

show_message() { echo "$1"; }

check_dependency() {
    if ! command -v $1 &> /dev/null; then
        echo "$1 is not installed. Please install it to continue."
        exit 1
    fi
}

is_python_package_installed() {
    python3 -c "import pkg_resources; exit(not pkg_resources.require('$1'))" 2>/dev/null
}

is_wine_python_package_installed() {
    $wine_executable python -c "import pkg_resources; exit(not pkg_resources.require('$1'))" 2>/dev/null
}

check_dependency "curl"
check_dependency "$wine_executable"

# Mono
if [ ! -e "/config/.wine/drive_c/windows/mono" ]; then
    show_message "[1/7] Downloading and installing Mono..."
    curl -o /config/.wine/drive_c/mono.msi $mono_url
    WINEDLLOVERRIDES=mscoree=d $wine_executable msiexec /i /config/.wine/drive_c/mono.msi /qn
    rm /config/.wine/drive_c/mono.msi
    show_message "[1/7] Mono installed."
else
    show_message "[1/7] Mono is already installed."
fi

# MT5
if [ -n "$mt5file" ] && [ -e "$mt5file" ]; then
    show_message "[2/7] $mt5file already exists."
else
    show_message "[2/7] MT5 not installed. Installing from ${mt5setup_url}..."
    $wine_executable reg add "HKEY_CURRENT_USER\\Software\\Wine" /v Version /t REG_SZ /d "win10" /f
    show_message "[3/7] Downloading MT5 installer..."
    curl -L -o /config/.wine/drive_c/mt5setup.exe "$mt5setup_url"
    show_message "[3/7] Installing MetaTrader 5..."
    $wine_executable "/config/.wine/drive_c/mt5setup.exe" "/auto" &
    wait
    rm -f /config/.wine/drive_c/mt5setup.exe
    # Re-discover after install — the broker installer chooses its own folder.
    mt5file="$(find_mt5)"
fi

if [ -n "$mt5file" ] && [ -e "$mt5file" ]; then
    show_message "[4/7] $mt5file installed. Running MT5..."
    $wine_executable "$mt5file" $MT5_CMD_OPTIONS &
else
    show_message "[4/7] MT5 not installed. MT5 cannot be run."
fi

# Python in Wine
if ! $wine_executable python --version 2>/dev/null; then
    show_message "[5/7] Installing Python in Wine..."
    curl -L $python_url -o /tmp/python-installer.exe
    $wine_executable /tmp/python-installer.exe /quiet InstallAllUsers=1 PrependPath=1
    rm /tmp/python-installer.exe
    show_message "[5/7] Python installed in Wine."
else
    show_message "[5/7] Python already installed in Wine."
fi

# pip + Wine-side Python packages
show_message "[6/7] Upgrading pip..."
$wine_executable python -m pip install --upgrade --no-cache-dir pip

show_message "[6/7] Installing MetaTrader5==${metatrader_version} in Wine..."
if ! is_wine_python_package_installed "MetaTrader5==$metatrader_version"; then
    $wine_executable python -m pip install --no-cache-dir MetaTrader5==$metatrader_version
fi

show_message "[6/7] Installing mt5linux==${mt5linux_version} in Wine..."
if ! is_wine_python_package_installed "mt5linux==$mt5linux_version"; then
    $wine_executable python -m pip install --no-cache-dir "mt5linux==$mt5linux_version"
fi

if ! is_wine_python_package_installed "python-dateutil"; then
    show_message "[6/7] Installing python-dateutil in Wine..."
    $wine_executable python -m pip install --no-cache-dir python-dateutil
fi

# Linux-side mt5linux (pinned to 0.1.9 — has the -w flag we use below)
show_message "[6/7] Installing mt5linux==${mt5linux_version} on Linux..."
if ! is_python_package_installed "mt5linux==$mt5linux_version"; then
    pip install --break-system-packages --no-cache-dir --no-deps "mt5linux==$mt5linux_version" && \
    pip install --break-system-packages --no-cache-dir rpyc plumbum numpy
fi

if ! is_python_package_installed "pyxdg"; then
    show_message "[6/7] Installing pyxdg on Linux..."
    pip install --break-system-packages --no-cache-dir pyxdg
fi

# RPyC server
show_message "[7/7] Starting mt5linux ${mt5linux_version} server on port $mt5server_port..."
python3 -m mt5linux --host 0.0.0.0 -p $mt5server_port -w $wine_executable python.exe &

sleep 5

if ss -tuln | grep ":$mt5server_port" > /dev/null; then
    show_message "[7/7] mt5linux server is running on port $mt5server_port."
else
    show_message "[7/7] FAILED to start mt5linux server on port $mt5server_port."
fi

# Keep the foreground alive so s6 doesn't restart us.
sleep infinity
