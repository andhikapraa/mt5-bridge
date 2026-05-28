"""Thin wrapper around the mt5linux RPyC client with reconnect-on-failure.

The Wine-side mt5linux server may not be up when FastAPI boots (first install
takes minutes). Connections are lazy and auto-retry on RPyC EOFError /
ConnectionRefusedError. Single shared instance per worker process.
"""

from __future__ import annotations

import asyncio
import logging
import os
import threading
from typing import Any

from mt5linux import MetaTrader5

log = logging.getLogger("mt5_proxy")

_HOST = os.environ.get("MT5_HOST", "127.0.0.1")
_PORT = int(os.environ.get("MT5_PORT", "18812"))

# Optional auto-login env (only used if all three are set).
_LOGIN = os.environ.get("MT5_LOGIN")
_PASSWORD = os.environ.get("MT5_PASSWORD")
_SERVER = os.environ.get("MT5_SERVER")


class MT5Proxy:
    """One client per process. Methods are sync; FastAPI offloads via asyncio."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._mt5: MetaTrader5 | None = None
        self._initialised = False
        self._logged_in = False

    # ---- connection ----

    def _connect(self) -> MetaTrader5:
        log.info("connecting to mt5linux at %s:%s", _HOST, _PORT)
        mt5 = MetaTrader5(host=_HOST, port=_PORT)
        if not mt5.initialize():
            err = mt5.last_error()
            raise RuntimeError(f"mt5.initialize() failed: {err}")
        self._initialised = True
        if _LOGIN and _PASSWORD and _SERVER and not self._logged_in:
            ok = mt5.login(login=int(_LOGIN), password=_PASSWORD, server=_SERVER)
            if not ok:
                err = mt5.last_error()
                log.warning("auto-login failed: %s — manual login via VNC required", err)
            else:
                self._logged_in = True
                log.info("auto-logged in to %s as %s", _SERVER, _LOGIN)
        return mt5

    def _client(self) -> MetaTrader5:
        with self._lock:
            if self._mt5 is None:
                self._mt5 = self._connect()
            return self._mt5

    def _reset(self) -> None:
        with self._lock:
            self._mt5 = None
            self._initialised = False
            self._logged_in = False

    async def call(self, method: str, *args: Any, **kwargs: Any) -> Any:
        """Call any MetaTrader5 method by name, with one reconnect retry."""
        def _do() -> Any:
            mt5 = self._client()
            return getattr(mt5, method)(*args, **kwargs)

        try:
            return await asyncio.to_thread(_do)
        except (ConnectionRefusedError, EOFError, OSError) as e:
            log.warning("mt5 call %s failed (%s); reconnecting", method, e)
            self._reset()
            return await asyncio.to_thread(_do)

    # ---- health ----

    async def is_alive(self) -> tuple[bool, dict | None]:
        # Generous timeout — the FIRST RPyC handshake against a freshly-booted
        # mt5linux server takes ~5-8s (Wine subprocess spawn + initialize() +
        # optional login). Once warm, subsequent calls are <100ms.
        try:
            info = await asyncio.wait_for(self.call("account_info"), timeout=10.0)
            return (info is not None), (_as_dict(info) if info else None)
        except asyncio.TimeoutError:
            log.warning("health probe timed out after 10s — MT5 terminal likely not running")
            return False, None
        except Exception as e:  # noqa: BLE001
            log.warning("health probe failed: %s", e)
            return False, None

    async def warmup(self) -> None:
        """Best-effort eager connect at FastAPI startup.

        Without this, the first /health call has to do the full RPyC handshake
        cold, which can exceed our timeout and falsely report mt5_connected=false.
        """
        try:
            await asyncio.wait_for(self.call("account_info"), timeout=15.0)
            log.info("mt5_proxy: warmup OK")
        except Exception as e:  # noqa: BLE001
            log.warning("mt5_proxy: warmup failed (will retry on first request): %s", e)


def _coerce(v: Any) -> Any:
    """Strip RPyC netref / proxy wrappers from a value so FastAPI/JSON can serialise.

    mt5linux returns namedtuples whose fields are RPyC netrefs to Python
    primitives on the Wine side. Most of them auto-coerce when used, but some
    (notably SymbolInfo.contract_size, a double) come back as netrefs that
    json.dumps doesn't recognise and FastAPI's pydantic v2 turns into None.
    Forcing a native conversion here fixes that.
    """
    if v is None:
        return None
    if isinstance(v, bool):
        return bool(v)
    if isinstance(v, int):
        return int(v)
    if isinstance(v, float):
        return float(v)
    if isinstance(v, str):
        return str(v)
    if isinstance(v, (list, tuple)):
        return [_coerce(x) for x in v]
    if isinstance(v, dict):
        return {str(k): _coerce(val) for k, val in v.items()}
    # Try common conversions for RPyC-wrapped numeric/string types.
    try:
        f = float(v)
        return f
    except (TypeError, ValueError):
        pass
    try:
        return str(v)
    except Exception:  # noqa: BLE001
        return None


def _as_dict(obj: Any) -> dict:
    """MetaTrader5 returns named tuples; turn into plain dicts for JSON.

    Uses _asdict() to enumerate fields (RPyC proxies the call correctly),
    then runs every value through _coerce() to materialise RPyC netrefs into
    real Python primitives so FastAPI/pydantic can serialise them. The latter
    is what fixes contract_size showing as null on /symbols/{name}.
    """
    if obj is None:
        return {}
    if hasattr(obj, "_asdict"):
        d = obj._asdict()
        return {str(k): _coerce(v) for k, v in d.items()}
    if isinstance(obj, (list, tuple)):
        return {"items": [_as_dict(x) for x in obj]}
    if isinstance(obj, dict):
        return {str(k): _coerce(v) for k, v in obj.items()}
    return {"value": _coerce(obj)}


# Process-wide singleton.
proxy = MT5Proxy()
