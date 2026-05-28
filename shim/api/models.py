"""Pydantic request/response schemas for the REST surface.

Kept thin — the underlying MetaTrader5 API returns named tuples that we
serialise to dicts on the way out.
"""

from typing import Literal

from pydantic import BaseModel, Field


class OrderRequest(BaseModel):
    symbol: str = Field(..., examples=["XAUUSD", "EURUSD"])
    volume: float = Field(..., gt=0, examples=[0.01])
    order_type: Literal["BUY", "SELL"]
    sl: float | None = Field(default=None, description="Stop loss price")
    tp: float | None = Field(default=None, description="Take profit price")
    deviation: int = Field(default=20, ge=0, le=1000)
    magic: int = Field(default=0, description="EA magic number for filtering")
    comment: str = Field(default="mt5-bridge", max_length=31)


class CandlesRequest(BaseModel):
    symbol: str
    timeframe: Literal["M1", "M5", "M15", "M30", "H1", "H4", "D1", "W1", "MN1"]
    count: int = Field(default=200, ge=1, le=5000)
    start_pos: int = Field(default=0, ge=0)


class HealthResponse(BaseModel):
    status: Literal["ok", "degraded"]
    mt5_connected: bool
    account_login: int | None = None
    server: str | None = None
