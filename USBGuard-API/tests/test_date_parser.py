"""
Unit tests for app.date_parser.

Covers every supported format, explicit rejection of unsupported formats
(including previously ambiguous ones), and the resolve_start_date business rules.
"""

from datetime import date, timedelta

import pytest

from app.date_parser import resolve_start_date, try_parse


# ---------------------------------------------------------------------------
# Supported formats
# ---------------------------------------------------------------------------

class TestSupportedFormats:
    def test_iso_8601(self):
        assert try_parse("2026-05-15") == date(2026, 5, 15)

    def test_day_abbrev_month_year(self):
        assert try_parse("15 May 2026") == date(2026, 5, 15)

    def test_day_full_month_year(self):
        assert try_parse("15 March 2026") == date(2026, 3, 15)

    def test_abbrev_month_day_year(self):
        assert try_parse("May 15, 2026") == date(2026, 5, 15)

    def test_full_month_day_year(self):
        assert try_parse("March 15, 2026") == date(2026, 3, 15)


# ---------------------------------------------------------------------------
# Unsupported / rejected formats
# ---------------------------------------------------------------------------

class TestRejectedFormats:
    def test_iso_slash_rejected(self):
        """2026/05/15 is not a supported format."""
        assert try_parse("2026/05/15") is None

    def test_iso_dot_rejected(self):
        """2026.05.15 is not a supported format."""
        assert try_parse("2026.05.15") is None

    def test_compact_rejected(self):
        """20260515 is not a supported format."""
        assert try_parse("20260515") is None

    def test_ambiguous_slash_rejected(self):
        """09/03/2026 — March 9 or September 3? Rejected."""
        assert try_parse("09/03/2026") is None

    def test_ambiguous_dash_rejected(self):
        """09-03-2026 — March 9 or September 3? Rejected."""
        assert try_parse("09-03-2026") is None

    def test_ambiguous_dot_rejected(self):
        """09.03.2026 — March 9 or September 3? Rejected."""
        assert try_parse("09.03.2026") is None

    def test_invalid_string_rejected(self):
        assert try_parse("not-a-date") is None

    def test_empty_string_rejected(self):
        assert try_parse("") is None

    def test_whitespace_only_rejected(self):
        assert try_parse("   ") is None


# ---------------------------------------------------------------------------
# resolve_start_date — business rules
# ---------------------------------------------------------------------------

class TestResolveStartDate:
    def test_future_date_returned_unchanged(self):
        future = date.today() + timedelta(days=10)
        resolved, warning = resolve_start_date(future.strftime("%Y-%m-%d"))
        assert resolved == future
        assert warning is None

    def test_today_returned_unchanged(self):
        today = date.today()
        resolved, warning = resolve_start_date(today.strftime("%Y-%m-%d"))
        assert resolved == today
        assert warning is None

    def test_past_date_falls_back_to_today(self):
        resolved, warning = resolve_start_date("2020-01-01")
        assert resolved == date.today()
        assert "past" in warning.lower()
        assert "2020-01-01" in warning

    def test_unparseable_falls_back_to_today_with_hint(self):
        resolved, warning = resolve_start_date("garbage-input")
        assert resolved == date.today()
        assert "garbage-input" in warning
        assert "YYYY-MM-DD" in warning

    def test_empty_string_falls_back_to_today(self):
        resolved, warning = resolve_start_date("")
        assert resolved == date.today()
        assert warning is not None
