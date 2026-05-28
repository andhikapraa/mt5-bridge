# REST/WebSocket shim over mt5linux RPyC.
# Tiny image — just Python + FastAPI + the mt5linux client lib.

FROM python:3.12-slim-bookworm

WORKDIR /app
COPY requirements.txt /app/requirements.txt

# Install mt5linux without its pinned-too-tight transitive deps (numpy==1.21.4
# has no Python 3.12 wheel). Then install our requirements which pull modern
# rpyc/plumbum/numpy versions that mt5linux is actually fine with at runtime.
RUN pip install --no-cache-dir --no-deps mt5linux==0.1.9 && \
    pip install --no-cache-dir -r /app/requirements.txt

COPY api/ /app/api/

ENV PYTHONUNBUFFERED=1 \
    MT5_HOST=mt5 \
    MT5_PORT=8001 \
    API_PORT=8000

EXPOSE 8000

CMD ["python3", "-m", "uvicorn", "api.main:app", "--host", "0.0.0.0", "--port", "8000", "--log-level", "info", "--no-access-log"]
