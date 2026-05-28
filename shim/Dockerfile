# REST/WebSocket shim over mt5linux RPyC.
# Tiny image — just Python + FastAPI + the mt5linux client lib.

FROM python:3.12-slim-bookworm

WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY api/ /app/api/

ENV PYTHONUNBUFFERED=1 \
    MT5_HOST=mt5 \
    MT5_PORT=8001 \
    API_PORT=8000

EXPOSE 8000

CMD ["python3", "-m", "uvicorn", "api.main:app", "--host", "0.0.0.0", "--port", "8000", "--log-level", "info", "--no-access-log"]
