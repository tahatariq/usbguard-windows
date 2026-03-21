"""
Flexible date parsing utilities for the USBGuard API.

Supports a wide variety of date string formats and provides a resolver
that handles past/unparseable dates by falling back to today.
"""

from datetime import date
from typing import Optional, Tuple


# Ordered list of format strings to attempt when parsing a date string.
_FORMATS = [
    "%Y-%m-%d",    # ISO 8601: 2026-05-15
    "%Y/%m/%d",    # ISO with slashes: 2026/05/15
    "%d-%m-%Y",    # UK dashed: 15-05-2026
    "%d/%m/%Y",    # UK slashed: 15/05/2026
    "%m-%d-%Y",    # US dashed: 05-15-2026
    "%m/%d/%Y",    # US slashed: 05/15/2026
    "%d %b %Y",    # Day abbrev month: 15 May 2026
    "%d %B %Y",    # Day full month: 15 May 2026
    "%b %d, %Y",   # Abbrev month, day: May 15, 2026
    "%B %d, %Y",   # Full month, day: May 15, 2026
    "%d.%m.%Y",    # Dotted EU: 15.05.2026
    "%Y.%m.%d",    # Dotted ISO: 2026.05.15
    "%Y%m%d",      # Compact: 20260515
]


def try_parse(value: str) -> Optional[date]:
    """
    Attempt to parse a date string using a sequence of known formats.

    Args:
        value: The date string to parse.

    Returns:
        A :class:`datetime.date` if any format matches, otherwise ``None``.
    """
    if not value or not value.strip():
        return None

    stripped = value.strip()

    for fmt in _FORMATS:
        try:
            from datetime import datetime as _dt
            return _dt.strptime(stripped, fmt).date()
        except ValueError:
            continue

    return None


def resolve_start_date(value: str) -> Tuple[date, Optional[str]]:
    """
    Parse a start date string and apply business rules:

    - If the string cannot be parsed, fall back to today with a warning.
    - If the parsed date is in the past, fall back to today with a warning.
    - Otherwise, return the parsed date with no warning.

    Args:
        value: The raw date string supplied by the caller.

    Returns:
        A tuple of ``(resolved_date, warning_message)``.  ``warning_message``
        is ``None`` when no correction was needed.
    """
    today = date.today()
    parsed = try_parse(value)

    if parsed is None:
        warning = (
            f"Could not parse '{value}' as a date — using today's date."
        )
        return (today, warning)

    if parsed < today:
        warning = (
            f"Start date {parsed} is in the past — using today's date."
        )
        return (today, warning)

    return (parsed, None)
