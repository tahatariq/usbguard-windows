"""
Pydantic v2 request and response models for the USBGuard API.
"""

from datetime import datetime
from typing import Any, Optional

from pydantic import BaseModel, field_validator, model_validator
import re


class CreateExceptionRequest(BaseModel):
    """Request body for POST /api/exceptions."""

    pc_name: str
    username: str
    ritm: str
    start_date: str
    number_of_days: int

    @field_validator("pc_name")
    @classmethod
    def pc_name_not_empty(cls, v: str) -> str:
        if not v or not v.strip():
            raise ValueError("pc_name must not be empty.")
        return v.strip()

    @field_validator("username")
    @classmethod
    def username_not_empty(cls, v: str) -> str:
        if not v or not v.strip():
            raise ValueError("username must not be empty.")
        return v.strip()

    @field_validator("ritm")
    @classmethod
    def ritm_format(cls, v: str) -> str:
        r"""Validate that RITM matches pattern RITM\d{7} (case-insensitive)."""
        if not re.fullmatch(r"RITM\d{7}", v, re.IGNORECASE):
            raise ValueError(
                f"ritm must match the pattern RITM followed by 7 digits (e.g. RITM0012345). Got: '{v}'"
            )
        return v.upper()

    @field_validator("number_of_days")
    @classmethod
    def days_in_range(cls, v: int) -> int:
        if v < 1 or v > 365:
            raise ValueError("number_of_days must be between 1 and 365 (inclusive).")
        return v


class ExceptionStatus(BaseModel):
    """Current USB exception status for a given PC."""

    pc_name: str
    has_active_exception: bool
    expiry_time: Optional[datetime] = None
    granted_to_user: Optional[str] = None
    ritm: Optional[str] = None


class ApiResponse(BaseModel):
    """Generic API response envelope."""

    success: bool
    message: str = ""
    data: Optional[Any] = None
    warning: Optional[str] = None
