"""
Unit tests for app.date_parser — flexible date parsing and start-date resolution.
"""

from datetime import date, timedelta
from unittest.mock import patch

import pytest

from app.date_parser import resolve_start_date, try_parse


# ---------------------------------------------------------------------------
# try_parse — format coverage
# ---------------------------------------------------------------------------

class TestTryParse:
    def test_iso_format(self):
        """2026-05-15 → date(2026, 5, 15)"""
        assert try_parse("2026-05-15") == date(2026, 5, 15)

    def test_iso_slash_format(self):
        """2026/05/15 → date(2026, 5, 15)"""
        assert try_parse("2026/05/15") == date(2026, 5, 15)

    def test_uk_slash_format(self):
        """15/05/2026 → date(2026, 5, 15)"""
        assert try_parse("15/05/2026") == date(2026, 5, 15)

    def test_uk_dash_format(self):
        """15-05-2026 → date(2026, 5, 15)"""
        assert try_parse("15-05-2026") == date(2026, 5, 15)

    def test_us_slash_format(self):
        """05/15/2026 → date(2026, 5, 15)"""
        assert try_parse("05/15/2026") == date(2026, 5, 15)

    def test_abbreviated_month_name(self):
        """15 May 2026 → date(2026, 5, 15)"""
        assert try_parse("15 May 2026") == date(2026, 5, 15)

    def test_full_month_name(self):
        """15 May 2026 (full) → date(2026, 5, 15)"""
        assert try_parse("15 May 2026") == date(2026, 5, 15)

    def test_month_day_year_comma(self):
        """May 15, 2026 → date(2026, 5, 15)"""
        assert try_parse("May 15, 2026") == date(2026, 5, 15)

    def test_full_month_day_year_comma(self):
        """May 15, 2026 (full month name) → date(2026, 5, 15)"""
        assert try_parse("May 15, 2026") == date(2026, 5, 15)

    def test_compact_format(self):
        """20260515 → date(2026, 5, 15)"""
        assert try_parse("20260515") == date(2026, 5, 15)

    def test_invalid_string_returns_none(self):
        """Completely unrecognisable string → None"""
        assert try_parse("not-a-date") is None

    def test_empty_string_returns_none(self):
        """Empty string → None"""
        assert try_parse("") is None

    def test_whitespace_only_returns_none(self):
        """Whitespace-only string → None"""
        assert try_parse("   ") is None


# ---------------------------------------------------------------------------
# resolve_start_date — business logic
# ---------------------------------------------------------------------------

class TestResolveStartDate:
    def test_future_date_returned_unchanged(self):
        """A future date is returned as-is with no warning."""
        future = date.today() + timedelta(days=10)
        resolved, warning = resolve_start_date(future.strftime("%Y-%m-%d"))
        assert resolved == future
        assert warning is None

    def test_today_returned_unchanged(self):
        """Today's date is not considered 'in the past'."""
        today = date.today()
        resolved, warning = resolve_start_date(today.strftime("%Y-%m-%d"))
        assert resolved == today
        assert warning is None

    def test_past_date_falls_back_to_today(self):
        """A past date should be replaced by today with a warning."""
        past = date(2020, 1, 1)
        resolved, warning = resolve_start_date("2020-01-01")
        assert resolved == date.today()
        assert warning is not None
        assert "past" in warning.lower()
        assert "2020-01-01" in warning

    def test_unparseable_falls_back_to_today(self):
        """An unparseable string should fall back to today with a warning."""
        resolved, warning = resolve_start_date("garbage-input")
        assert resolved == date.today()
        assert warning is not None
        assert "garbage-input" in warning

    def test_empty_string_falls_back_to_today(self):
        """Empty string is unparseable → today with warning."""
        resolved, warning = resolve_start_date("")
        assert resolved == date.today()
        assert warning is not None
