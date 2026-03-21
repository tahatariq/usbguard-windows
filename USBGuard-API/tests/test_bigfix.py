"""
Unit tests for BigFix utility functions.

These tests cover pure functions (scheduling offset calculation, PowerShell
encoding) that do not require a real BigFix server.
"""

import base64
from datetime import date, timedelta

import pytest

from app.bigfix import _compute_offsets, _encode_powershell


# ---------------------------------------------------------------------------
# _compute_offsets
# ---------------------------------------------------------------------------

class TestComputeOffsets:
    def test_today_start_has_zero_start_offset(self):
        """If start_date is today, the action fires immediately."""
        start, _ = _compute_offsets(date.today(), 5)
        assert start == "+00:00:00:00"

    def test_today_start_end_offset_is_duration_plus_buffer(self):
        """End offset = 0 + number_of_days + 14-day buffer."""
        _, end = _compute_offsets(date.today(), 5)
        assert end == "+19:00:00:00"  # 0 + 5 + 14

    def test_future_start_three_days_away(self):
        """Action should be held for 3 days before executing."""
        future = date.today() + timedelta(days=3)
        start, end = _compute_offsets(future, 7)
        assert start == "+03:00:00:00"
        assert end == "+24:00:00:00"  # 3 + 7 + 14

    def test_future_start_ten_days_away(self):
        future = date.today() + timedelta(days=10)
        start, end = _compute_offsets(future, 2)
        assert start == "+10:00:00:00"
        assert end == "+26:00:00:00"  # 10 + 2 + 14

    def test_past_date_clamped_to_zero(self):
        """A past start_date is treated as immediate (offset = 0)."""
        past = date.today() - timedelta(days=5)
        start, _ = _compute_offsets(past, 3)
        assert start == "+00:00:00:00"

    def test_past_date_end_offset_uses_zero_start(self):
        """Even with a past date the end window is buffer + duration from today."""
        past = date.today() - timedelta(days=5)
        _, end = _compute_offsets(past, 3)
        assert end == "+17:00:00:00"  # 0 + 3 + 14

    def test_one_day_exception(self):
        start, end = _compute_offsets(date.today(), 1)
        assert start == "+00:00:00:00"
        assert end == "+15:00:00:00"  # 0 + 1 + 14

    def test_max_30_day_exception(self):
        start, end = _compute_offsets(date.today(), 30)
        assert start == "+00:00:00:00"
        assert end == "+44:00:00:00"  # 0 + 30 + 14

    def test_offset_format_two_digit_days(self):
        """Day component is zero-padded to two digits."""
        future = date.today() + timedelta(days=9)
        start, _ = _compute_offsets(future, 1)
        assert start == "+09:00:00:00"

    def test_large_future_date(self):
        """Large future offset is formatted correctly (no truncation)."""
        future = date.today() + timedelta(days=20)
        start, end = _compute_offsets(future, 10)
        assert start == "+20:00:00:00"
        assert end == "+44:00:00:00"  # 20 + 10 + 14


# ---------------------------------------------------------------------------
# _encode_powershell
# ---------------------------------------------------------------------------

class TestEncodePowershell:
    def test_output_is_valid_base64(self):
        """Encoded output should decode without error."""
        encoded = _encode_powershell("Write-Host 'hello'")
        decoded_bytes = base64.b64decode(encoded)
        assert len(decoded_bytes) > 0

    def test_decoded_bytes_are_utf16le(self):
        """PowerShell -EncodedCommand expects UTF-16-LE encoding."""
        script = "Set-ItemProperty -Path 'HKLM:\\Test' -Name 'Val' -Value 1"
        encoded = _encode_powershell(script)
        decoded = base64.b64decode(encoded).decode("utf-16-le")
        assert decoded == script

    def test_empty_script_encodes(self):
        encoded = _encode_powershell("")
        assert isinstance(encoded, str)
        # Decodes back to empty string
        decoded = base64.b64decode(encoded).decode("utf-16-le")
        assert decoded == ""

    def test_multiline_script(self):
        script = "line1\nline2\nline3"
        encoded = _encode_powershell(script)
        decoded = base64.b64decode(encoded).decode("utf-16-le")
        assert decoded == script
