"""API-key auth via X-API-Key header. Reads the expected key from the
API_KEY env var at process start; never echoes it back to clients."""

import os
import secrets

from fastapi import Header, HTTPException, status

_EXPECTED = os.environ.get("API_KEY", "")
if not _EXPECTED:
    raise RuntimeError("API_KEY env var must be set")


async def require_api_key(x_api_key: str | None = Header(default=None)) -> None:
    if x_api_key is None or not secrets.compare_digest(x_api_key, _EXPECTED):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="invalid or missing X-API-Key",
        )
