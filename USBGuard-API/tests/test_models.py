"""
Unit tests for app.models — Pydantic v2 request validation.
"""

import pytest
from pydantic import ValidationError

from app.models import CreateExceptionRequest


VALID_PAYLOAD = {
    "pc_name": "DESKTOP-01",
    "username": "john.doe",
    "ritm": "RITM0012345",
    "start_date": "2026-05-15",
    "number_of_days": 5,
}


class TestCreateExceptionRequest:
    def test_valid_full_request(self):
        """A fully-populated valid request should deserialise without errors."""
        req = CreateExceptionRequest(**VALID_PAYLOAD)
        assert req.pc_name == "DESKTOP-01"
        assert req.ritm == "RITM0012345"
        assert req.number_of_days == 5

    def test_number_of_days_zero_raises(self):
        """number_of_days=0 is below the minimum of 1."""
        payload = {**VALID_PAYLOAD, "number_of_days": 0}
        with pytest.raises(ValidationError) as exc_info:
            CreateExceptionRequest(**payload)
        assert "number_of_days" in str(exc_info.value).lower() or "1" in str(exc_info.value)

    def test_number_of_days_366_raises(self):
        """number_of_days=366 exceeds the maximum of 365."""
        payload = {**VALID_PAYLOAD, "number_of_days": 366}
        with pytest.raises(ValidationError):
            CreateExceptionRequest(**payload)

    def test_number_of_days_boundary_low(self):
        """number_of_days=1 is the minimum valid value."""
        req = CreateExceptionRequest(**{**VALID_PAYLOAD, "number_of_days": 1})
        assert req.number_of_days == 1

    def test_number_of_days_boundary_high(self):
        """number_of_days=365 is the maximum valid value."""
        req = CreateExceptionRequest(**{**VALID_PAYLOAD, "number_of_days": 365})
        assert req.number_of_days == 365

    def test_empty_pc_name_raises(self):
        """An empty pc_name should fail validation."""
        payload = {**VALID_PAYLOAD, "pc_name": ""}
        with pytest.raises(ValidationError):
            CreateExceptionRequest(**payload)

    def test_whitespace_pc_name_raises(self):
        """A whitespace-only pc_name should fail validation."""
        payload = {**VALID_PAYLOAD, "pc_name": "   "}
        with pytest.raises(ValidationError):
            CreateExceptionRequest(**payload)

    def test_ritm_valid_uppercase(self):
        """RITM0012345 (uppercase) should be accepted."""
        req = CreateExceptionRequest(**{**VALID_PAYLOAD, "ritm": "RITM0012345"})
        assert req.ritm == "RITM0012345"

    def test_ritm_valid_lowercase(self):
        """ritm0012345 (lowercase) should be accepted and normalised to uppercase."""
        req = CreateExceptionRequest(**{**VALID_PAYLOAD, "ritm": "ritm0012345"})
        assert req.ritm == "RITM0012345"

    def test_ritm_invalid_prefix_raises(self):
        """INC0012345 does not match the RITM pattern."""
        payload = {**VALID_PAYLOAD, "ritm": "INC0012345"}
        with pytest.raises(ValidationError) as exc_info:
            CreateExceptionRequest(**payload)
        errors = exc_info.value.errors()
        assert any(e["loc"] == ("ritm",) for e in errors)

    def test_ritm_too_few_digits_raises(self):
        """RITM012345 has only 6 digits — needs 7."""
        payload = {**VALID_PAYLOAD, "ritm": "RITM012345"}
        with pytest.raises(ValidationError):
            CreateExceptionRequest(**payload)

    def test_missing_required_field_raises(self):
        """Omitting a required field (username) should fail validation."""
        payload = {k: v for k, v in VALID_PAYLOAD.items() if k != "username"}
        with pytest.raises(ValidationError) as exc_info:
            CreateExceptionRequest(**payload)
        errors = exc_info.value.errors()
        assert any(e["loc"] == ("username",) for e in errors)
