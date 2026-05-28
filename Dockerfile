# syntax=docker/dockerfile:1.7
#
# mt5-bridge: MetaTrader 5 in Wine with mt5linux RPyC + FastAPI REST shim.

FROM python:3.12-slim-bookworm

ARG DEBIAN_FRONTEND=noninteractive
ARG MT5_INSTALLER_URL=https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe

# ---- System layer: Wine (64+32 bit) + display + supervisor ----
RUN set -eux; \
    dpkg --add-architecture i386; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg2 \
      xvfb x11vnc novnc websockify \
      supervisor procps net-tools tini socat \
      libgl1 libnss3 libxcb-cursor0; \
    install -d -m 0755 /etc/apt/keyrings; \
    wget -qO /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key; \
    wget -qO /etc/apt/sources.list.d/winehq-bookworm.sources \
      https://dl.winehq.org/wine-builds/debian/dists/bookworm/winehq-bookworm.sources; \
    apt-get update; \
    apt-get install -y --install-recommends winehq-stable; \
    # Explicit smoke test — fail the build if wine can't even print its version.
    wine --version; \
    rm -rf /var/lib/apt/lists/*

# ---- Host Python deps (FastAPI shim + mt5linux client) ----
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# ---- App layout ----
WORKDIR /app
COPY api/                /app/api/
COPY scripts/            /app/scripts/
COPY requirements-wine.txt /app/requirements-wine.txt
COPY supervisord.conf    /etc/supervisor/conf.d/supervisord.conf
RUN chmod +x /app/scripts/*.sh

# ---- Pre-bake the Wine prefix at build time ----
# Building has no display, so Wine's first-boot auto-detects headless and
# completes cleanly (no Mono/Gecko nag dialogs to hang on). We save the
# initialised prefix at /opt/wine-template and copy it to /config/.wine at
# runtime — sidesteps the volume-mount + runtime bootstrap issues that cause
# `wine: could not load kernel32.dll, status c0000135`.
ENV WINEDLLOVERRIDES="mscoree,mshtml="
RUN set -eux; \
    export WINEPREFIX=/opt/wine-template; \
    export WINEARCH=win64; \
    export WINEDEBUG=-all; \
    mkdir -p /opt/wine-template; \
    # Use timeout as a safety net — if wineboot hangs at BUILD time we want
    # CI to fail loud, not wait 6 hours.
    timeout 180 wine wineboot --init 2>&1 | tail -40 || (echo "wineboot --init failed at build" && exit 1); \
    timeout 60 wineserver -w || true; \
    test -f /opt/wine-template/drive_c/windows/system32/kernel32.dll \
      || (echo "kernel32.dll missing after build-time wineboot" && exit 1); \
    echo "wine template prefix ready: $(du -sh /opt/wine-template | awk '{print $1}')"

# ---- Runtime env ----
ENV WINEPREFIX=/config/.wine \
    WINEARCH=win64 \
    WINEDEBUG=-all \
    WINEDLLOVERRIDES="mscoree,mshtml=" \
    WINE_TEMPLATE=/opt/wine-template \
    DISPLAY=:1 \
    PYTHONUNBUFFERED=1 \
    MT5_HOST=127.0.0.1 \
    MT5_PORT=18812 \
    API_PORT=8000 \
    VNC_PORT=3000 \
    NOVNC_PORT=3000 \
    X11VNC_PORT=5900

EXPOSE 3000 8000 8001

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/scripts/entrypoint.sh"]

LABEL org.opencontainers.image.source="https://github.com/andhikapraa/mt5-bridge" \
      org.opencontainers.image.title="mt5-bridge" \
      org.opencontainers.image.description="MetaTrader 5 in Wine with mt5linux RPyC + FastAPI REST" \
      org.opencontainers.image.licenses="MIT"
