"""
Pydantic v2 request and response models for the USBGuard API.
"""

import re
from datetime import datetime
from typing import Any, List, Optional

from pydantic import BaseModel, field_validator

# Safe character patterns — prevent injection into PowerShell, BES XML, and
# BigFix relevance queries.  These are intentionally restrictive.
_PC_NAME_RE = re.compile(r"^[A-Za-z0-9\-]{1,15}$")
_USERNAME_RE = re.compile(r"^[A-Za-z0-9_\-\.@\\]{1,100}$")
_RITM_RE = re.compile(r"^[A-Za-z0-9\-_]{1,50}$")


class CreateExceptionRequest(BaseModel):
    """Request body for POST /api/exceptions."""

    pc_name: str
    username: str
    ritm: str
    start_date: str
    number_of_days: int

    @field_validator("pc_name")
    @classmethod
    def pc_name_safe(cls, v: str) -> str:
        v = v.strip()
        if not v:
            raise ValueError("pc_name must not be empty.")
        if not _PC_NAME_RE.match(v):
            raise ValueError(
                "pc_name must be 1-15 characters, alphanumeric and hyphens only "
                "(standard Windows computer name)."
            )
        return v

    @field_validator("username")
    @classmethod
    def username_safe(cls, v: str) -> str:
        v = v.strip()
        if not v:
            raise ValueError("username must not be empty.")
        if not _USERNAME_RE.match(v):
            raise ValueError(
                "username contains disallowed characters. "
                "Allowed: letters, digits, _ - . @ \\ (max 100 chars)."
            )
        return v

    @field_validator("ritm")
    @classmethod
    def ritm_safe(cls, v: str) -> str:
        v = v.strip()
        if not v:
            raise ValueError("ritm must not be empty.")
        if not _RITM_RE.match(v):
            raise ValueError(
                "ritm must be alphanumeric with hyphens/underscores only "
                "(e.g. RITM0012345, max 50 chars)."
            )
        return v

    @field_validator("number_of_days")
    @classmethod
    def days_in_range(cls, v: int) -> int:
        if v < 1 or v > 365:
            raise ValueError("number_of_days must be between 1 and 365 (inclusive).")
        return v


class BulkCreateExceptionRequest(BaseModel):
    """Request body for POST /api/exceptions/bulk."""

    pc_names: List[str]
    username: str
    ritm: str
    start_date: str
    number_of_days: int

    @field_validator("pc_names")
    @classmethod
    def pc_names_valid(cls, v: List[str]) -> List[str]:
        if not v:
            raise ValueError("pc_names must contain at least one computer name.")
        if len(v) > 500:
            raise ValueError("pc_names cannot exceed 500 entries per request.")
        cleaned = []
        for name in v:
            name = name.strip()
            if not name:
                raise ValueError("pc_names must not contain empty strings.")
            if not _PC_NAME_RE.match(name):
                raise ValueError(
                    f"Invalid pc_name '{name}': must be 1-15 chars, alphanumeric and hyphens only."
                )
            cleaned.append(name)
        return cleaned

    @field_validator("username")
    @classmethod
    def username_safe(cls, v: str) -> str:
        v = v.strip()
        if not v:
            raise ValueError("username must not be empty.")
        if not _USERNAME_RE.match(v):
            raise ValueError(
                "username contains disallowed characters. "
                "Allowed: letters, digits, _ - . @ \\ (max 100 chars)."
            )
        return v

    @field_validator("ritm")
    @classmethod
    def ritm_safe(cls, v: str) -> str:
        v = v.strip()
        if not v:
            raise ValueError("ritm must not be empty.")
        if not _RITM_RE.match(v):
            raise ValueError(
                "ritm must be alphanumeric with hyphens/underscores only "
                "(e.g. RITM0012345, max 50 chars)."
            )
        return v

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
