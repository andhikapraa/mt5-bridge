# syntax=docker/dockerfile:1.7
#
# mt5-bridge: MetaTrader 5 in Wine with mt5linux RPyC + FastAPI REST shim.
#
# Build:    docker build -t ghcr.io/andhikapraa/mt5-bridge:dev .
# Run dev:  docker compose -f deploy/docker-compose.yml up
#
# Lineage: borrows the Wine+KasmVNC+mt5linux pattern from gmag11/MetaTrader5-Docker
# (proven base) but adds a clean FastAPI REST shim and uses the correct mt5linux 1.0.3
# CLI. Avoids jefrnc's broken-build pitfalls (Python 3.14 wheel gaps + silent pip fails).

FROM python:3.12-slim-bookworm

ARG DEBIAN_FRONTEND=noninteractive
ARG MONO_VERSION=8.0.0
ARG MT5_INSTALLER_URL=https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe

# ---- System layer: Wine + display + supervisor ----
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
    rm -rf /var/lib/apt/lists/*

# ---- Host Python deps (FastAPI shim + mt5linux client) ----
COPY requirements.txt /tmp/requirements.txt
# NOTE: NO `|| true` here. If install fails, build fails — loudly.
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# ---- App layout ----
WORKDIR /app
COPY api/                /app/api/
COPY scripts/            /app/scripts/
COPY requirements-wine.txt /app/requirements-wine.txt
COPY supervisord.conf    /etc/supervisor/conf.d/supervisord.conf
RUN chmod +x /app/scripts/*.sh

# Wine prefix lives in /config so it persists when the volume is mounted there.
ENV WINEPREFIX=/config/.wine \
    WINEARCH=win64 \
    WINEDEBUG=-all \
    DISPLAY=:1 \
    PYTHONUNBUFFERED=1 \
    MT5_HOST=127.0.0.1 \
    MT5_PORT=18812 \
    API_PORT=8000 \
    VNC_PORT=3000 \
    NOVNC_PORT=3000 \
    X11VNC_PORT=5900

EXPOSE 3000 8000 8001

# tini as PID 1 → clean signal handling → supervisord
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/scripts/entrypoint.sh"]

LABEL org.opencontainers.image.source="https://github.com/andhikapraa/mt5-bridge" \
      org.opencontainers.image.title="mt5-bridge" \
      org.opencontainers.image.description="MetaTrader 5 in Wine with mt5linux RPyC + FastAPI REST" \
      org.opencontainers.image.licenses="MIT"
