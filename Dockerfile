# syntax=docker/dockerfile:1.7
#
# mt5-bridge: MetaTrader 5 in Wine with mt5linux RPyC + FastAPI REST shim.
#
# Built on linuxserver's KasmVNC base — same lineage as gmag11/MetaTrader5-Docker,
# which is the only widely-used MT5 Docker image that boots cleanly with no
# Wine bootstrap surgery. We add: clean FastAPI shim, correct mt5linux 1.0.x
# CLI (not the removed -w flag), and our s6 service definitions.

FROM ghcr.io/linuxserver/baseimage-kasmvnc:debianbookworm

ARG DEBIAN_FRONTEND=noninteractive

# Title shown in the KasmVNC web UI.
ENV TITLE="mt5-bridge" \
    WINEPREFIX=/config/.wine \
    WINEDEBUG=-all \
    WINEDLLOVERRIDES="mscoree,mshtml=" \
    PYTHONUNBUFFERED=1 \
    MT5_HOST=127.0.0.1 \
    MT5_PORT=18812 \
    API_PORT=8000

# ---- Wine (i386 + winehq-stable) + Python 3 + helpers ----
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg2 \
      python3 python3-pip python3-venv \
      net-tools socat procps x11-utils; \
    install -d -m 0755 /etc/apt/keyrings; \
    wget -qO /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key; \
    wget -qO /etc/apt/sources.list.d/winehq-bookworm.sources \
      https://dl.winehq.org/wine-builds/debian/dists/bookworm/winehq-bookworm.sources; \
    dpkg --add-architecture i386; \
    apt-get update; \
    apt-get install -y --install-recommends winehq-stable; \
    wine --version; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# ---- Host (Linux) Python deps for the FastAPI shim ----
COPY requirements.txt /tmp/requirements.txt
# --break-system-packages required because bookworm marks the system python
# as PEP-668 externally-managed. Safe here — this is a single-purpose container.
RUN pip3 install --no-cache-dir --break-system-packages -r /tmp/requirements.txt

# ---- App code ----
WORKDIR /app
COPY api/                 /app/api/
COPY scripts/             /app/scripts/
COPY requirements-wine.txt /app/requirements-wine.txt
RUN chmod +x /app/scripts/*.sh

# ---- linuxserver custom services ----
# /custom-services.d/<name> is launched as a long-running service AFTER
# linuxserver's core services (KasmVNC, etc) come up — so DISPLAY is set
# and Wine can actually open windows during install. The mt5linux service
# performs first-boot install internally; no cont-init scripts needed.
COPY custom-services.d/   /custom-services.d/
RUN chmod +x /custom-services.d/*

EXPOSE 3000 8000 8001

LABEL org.opencontainers.image.source="https://github.com/andhikapraa/mt5-bridge" \
      org.opencontainers.image.title="mt5-bridge" \
      org.opencontainers.image.description="MetaTrader 5 in Wine with mt5linux RPyC + FastAPI REST" \
      org.opencontainers.image.licenses="MIT"
