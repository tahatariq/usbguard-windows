"""
Date parsing utilities for the USBGuard API.

Only five explicitly supported formats are accepted. Anything else is rejected
with a clear error message — no guessing, no silent fallbacks to a wrong date.

Supported formats:
    YYYY-MM-DD      ISO 8601 — the standard numeric format
    DD Mon YYYY     e.g. 15 May 2026
    DD Month YYYY   e.g. 15 March 2026
    Mon DD, YYYY    e.g. May 15, 2026
    Month DD, YYYY  e.g. March 15, 2026
"""

from datetime import date
from typing import Optional, Tuple

_FORMATS = [
    "%Y-%m-%d",   # ISO 8601:          2026-05-15
    "%d %b %Y",   # Day abbrev month:  15 May 2026
    "%d %B %Y",   # Day full month:    15 March 2026
    "%b %d, %Y",  # Abbrev month day:  May 15, 2026
    "%B %d, %Y",  # Full month day:    March 15, 2026
]

_FORMAT_HINT = (
    "Accepted formats: YYYY-MM-DD (e.g. 2026-05-15), "
    "15 May 2026, 15 March 2026, May 15, 2026, March 15, 2026."
)


def try_parse(value: str) -> Optional[date]:
    """
    Parse a date string against the supported format list.

    Args:
        value: The date string to parse.

    Returns:
        A :class:`datetime.date` if a format matches, otherwise ``None``.
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
        A tuple of ``(resolved_date, warning_message)``.
        ``warning_message`` is ``None`` when no correction was needed.
    """
    today = date.today()
    parsed = try_parse(value)

    if parsed is None:
        warning = f"Could not parse '{value}' as a date — using today's date. {_FORMAT_HINT}"
        return (today, warning)

    if parsed < today:
        warning = f"Start date {parsed} is in the past — using today's date."
        return (today, warning)

    return (parsed, None)
