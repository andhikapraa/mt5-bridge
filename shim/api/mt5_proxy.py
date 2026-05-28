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
        try:
            info = await self.call("account_info")
            return (info is not None), (_as_dict(info) if info else None)
        except Exception as e:  # noqa: BLE001
            log.debug("health probe failed: %s", e)
            return False, None


def _as_dict(obj: Any) -> dict:
    """MetaTrader5 returns named tuples; turn into plain dicts for JSON."""
    if obj is None:
        return {}
    if hasattr(obj, "_asdict"):
        return obj._asdict()
    if isinstance(obj, (list, tuple)):
        return {"items": [_as_dict(x) for x in obj]}
    return dict(obj) if isinstance(obj, dict) else {"value": str(obj)}


# Process-wide singleton.
proxy = MT5Proxy()
