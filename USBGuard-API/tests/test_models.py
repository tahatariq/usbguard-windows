"""
Unit tests for app.models — Pydantic v2 request validation.
"""

import pytest
from pydantic import ValidationError

from app.models import BulkCreateExceptionRequest, CreateExceptionRequest


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

    def test_ritm_any_format_accepted(self):
        """Any non-empty RITM string is accepted (format is not validated)."""
        for ritm in ("RITM0012345", "RITM00000001", "INC0012345", "CHG9999999"):
            req = CreateExceptionRequest(**{**VALID_PAYLOAD, "ritm": ritm})
            assert req.ritm == ritm

    def test_ritm_empty_raises(self):
        """An empty ritm should fail validation."""
        payload = {**VALID_PAYLOAD, "ritm": ""}
        with pytest.raises(ValidationError):
            CreateExceptionRequest(**payload)

    def test_missing_required_field_raises(self):
        """Omitting a required field (username) should fail validation."""
        payload = {k: v for k, v in VALID_PAYLOAD.items() if k != "username"}
        with pytest.raises(ValidationError) as exc_info:
            CreateExceptionRequest(**payload)
        errors = exc_info.value.errors()
        assert any(e["loc"] == ("username",) for e in errors)


# ---------------------------------------------------------------------------
# pc_name validator tests
# ---------------------------------------------------------------------------

class TestPcNameValidator:
    """Tests for the pc_name field validator (injection prevention + length)."""

    def test_pc_name_rejects_double_quotes(self):
        """Double quotes in pc_name should be rejected (XML/PS injection)."""
        payload = {**VALID_PAYLOAD, "pc_name": 'DESK"TOP'}
        with pytest.raises(ValidationError):
            CreateExceptionRequest(**payload)

    def test_pc_name_rejects_single_quotes(self):
        """Single quotes in pc_name should be rejected."""
        payload = {**VALID_PAYLOAD, "pc_name": "DESK'TOP"}
        with pytest.raises(ValidationError):
            CreateExceptionRequest(**payload)

    def test_pc_name_rejects_semicolons(self):
        """Semicolons in pc_name should be rejected (command injection)."""
        payload = {**VALID_PAYLOAD, "pc_name": "DESK;TOP"}
        with pytest.raises(ValidationError):
            CreateExceptionRequest(**payload)

    def test_pc_name_rejects_spaces(self):
        """Spaces within pc_name should be rejected (not a valid Windows name)."""
        payload = {**VALID_PAYLOAD, "pc_name": "DESK TOP"}
        with pytest.raises(ValidationError):
            CreateExceptionRequest(**payload)

    def test_pc_name_rejects_longer_than_15_chars(self):
        """Windows computer names cannot exceed 15 characters."""
        payload = {**VALID_PAYLOAD, "pc_name": "A" * 16}
        with pytest.raises(ValidationError):
            CreateExceptionRequest(**payload)

    def test_pc_name_accepts_exactly_15_chars(self):
        """15 characters is the maximum valid length."""
        name = "A" * 15
        req = CreateExceptionRequest(**{**VALID_PAYLOAD, "pc_name": name})
        assert req.pc_name == name

    def test_pc_name_accepts_alphanumeric_and_hyphens(self):
        """Standard Windows computer names: letters, digits, hyphens."""
        for name in ("DESKTOP-01", "PC123", "A", "my-pc-name-01"):
            req = CreateExceptionRequest(**{**VALID_PAYLOAD, "pc_name": name})
            assert req.pc_name == name

    def test_pc_name_rejects_pipe(self):
        """Pipe character should be rejected."""
        payload = {**VALID_PAYLOAD, "pc_name": "DESK|TOP"}
        with pytest.raises(ValidationError):
            CreateExceptionRequest(**payload)

    def test_pc_name_rejects_ampersand(self):
        """Ampersand should be rejected."""
        payload = {**VALID_PAYLOAD, "pc_name": "DESK&TOP"}
        with pytest.raises(ValidationError):
            CreateExceptionRequest(**payload)


# ---------------------------------------------------------------------------
# username validator tests
# ---------------------------------------------------------------------------

class TestUsernameValidator:
    """Tests for the username field validator (PS injection prevention)."""

    def test_username_rejects_dollar_sign(self):
        """Dollar sign enables PS variable expansion — must be rejected."""
        payload = {**VALID_PAYLOAD, "username": "$env:COMPUTERNAME"}
        with pytest.raises(ValidationError):
            CreateExceptionRequest(**payload)

    def test_username_rejects_backtick(self):
        """Backtick is the PS escape character — must be rejected."""
        payload = {**VALID_PAYLOAD, "username": "user`nname"}
        with pytest.raises(ValidationError):
            CreateExceptionRequest(**payload)

    def test_username_rejects_semicolon(self):
        """Semicolons allow PS command chaining — must be rejected."""
        payload = {**VALID_PAYLOAD, "username": "user;Remove-Item"}
        with pytest.raises(ValidationError):
            CreateExceptionRequest(**payload)

    def test_username_rejects_parentheses(self):
        """Parentheses enable PS subexpressions — must be rejected."""
        payload = {**VALID_PAYLOAD, "username": "user(whoami)"}
        with pytest.raises(ValidationError):
            CreateExceptionRequest(**payload)

    def test_username_accepts_domain_backslash_format(self):
        """DOMAIN\\user format is standard for Windows auth."""
        req = CreateExceptionRequest(**{**VALID_PAYLOAD, "username": r"CORP\john.doe"})
        assert req.username == r"CORP\john.doe"

    def test_username_accepts_upn_format(self):
        """user@domain.com UPN format should be accepted."""
        req = CreateExceptionRequest(**{**VALID_PAYLOAD, "username": "john.doe@corp.local"})
        assert req.username == "john.doe@corp.local"

    def test_username_accepts_simple_name(self):
        """Simple username with dots, underscores, hyphens."""
        for name in ("john.doe", "admin_user", "j-doe", "john_doe.admin"):
            req = CreateExceptionRequest(**{**VALID_PAYLOAD, "username": name})
            assert req.username == name


# ---------------------------------------------------------------------------
# ritm validator tests
# ---------------------------------------------------------------------------

class TestRitmValidator:
    """Tests for the ritm field validator (special character rejection)."""

    def test_ritm_rejects_spaces(self):
        """Spaces in ritm should be rejected."""
        payload = {**VALID_PAYLOAD, "ritm": "RITM 0012345"}
        with pytest.raises(ValidationError):
            CreateExceptionRequest(**payload)

    def test_ritm_rejects_special_characters(self):
        """Characters outside alphanumeric/hyphen/underscore should be rejected."""
        for ritm in ("RITM;DROP", "RITM'123", "RITM\"123", "RITM<script>", "RITM&123"):
            payload = {**VALID_PAYLOAD, "ritm": ritm}
            with pytest.raises(ValidationError):
                CreateExceptionRequest(**payload)

    def test_ritm_accepts_standard_format(self):
        """Standard ServiceNow RITM format should be accepted."""
        req = CreateExceptionRequest(**{**VALID_PAYLOAD, "ritm": "RITM0012345"})
        assert req.ritm == "RITM0012345"

    def test_ritm_accepts_hyphens_and_underscores(self):
        """Hyphens and underscores are allowed in ritm."""
        for ritm in ("RITM-001", "RITM_001", "INC-2024_001"):
            req = CreateExceptionRequest(**{**VALID_PAYLOAD, "ritm": ritm})
            assert req.ritm == ritm

    def test_ritm_rejects_longer_than_50_chars(self):
        """ritm cannot exceed 50 characters."""
        payload = {**VALID_PAYLOAD, "ritm": "R" * 51}
        with pytest.raises(ValidationError):
            CreateExceptionRequest(**payload)


# ---------------------------------------------------------------------------
# BulkCreateExceptionRequest tests
# ---------------------------------------------------------------------------

VALID_BULK_PAYLOAD = {
    "pc_names": ["DESKTOP-01", "DESKTOP-02"],
    "username": "john.doe",
    "ritm": "RITM0012345",
    "start_date": "2026-05-15",
    "number_of_days": 5,
}


class TestBulkCreateExceptionRequest:
    """Tests for the BulkCreateExceptionRequest model."""

    def test_valid_bulk_request(self):
        """A valid bulk request with two PCs should deserialise correctly."""
        req = BulkCreateExceptionRequest(**VALID_BULK_PAYLOAD)
        assert req.pc_names == ["DESKTOP-01", "DESKTOP-02"]
        assert req.ritm == "RITM0012345"

    def test_empty_pc_names_raises(self):
        """An empty pc_names list should fail validation."""
        payload = {**VALID_BULK_PAYLOAD, "pc_names": []}
        with pytest.raises(ValidationError):
            BulkCreateExceptionRequest(**payload)

    def test_pc_names_exceeds_500_raises(self):
        """More than 500 pc_names should fail validation."""
        payload = {**VALID_BULK_PAYLOAD, "pc_names": [f"PC-{i:04d}" for i in range(501)]}
        with pytest.raises(ValidationError):
            BulkCreateExceptionRequest(**payload)

    def test_pc_names_exactly_500_accepted(self):
        """Exactly 500 pc_names should be accepted."""
        payload = {**VALID_BULK_PAYLOAD, "pc_names": [f"PC-{i:04d}" for i in range(500)]}
        req = BulkCreateExceptionRequest(**payload)
        assert len(req.pc_names) == 500

    def test_pc_names_contains_empty_string_raises(self):
        """An empty string in pc_names should fail validation."""
        payload = {**VALID_BULK_PAYLOAD, "pc_names": ["DESKTOP-01", ""]}
        with pytest.raises(ValidationError):
            BulkCreateExceptionRequest(**payload)

    def test_pc_names_contains_invalid_name_raises(self):
        """An invalid pc_name (with spaces) in the list should fail validation."""
        payload = {**VALID_BULK_PAYLOAD, "pc_names": ["DESKTOP-01", "BAD NAME"]}
        with pytest.raises(ValidationError):
            BulkCreateExceptionRequest(**payload)

    def test_pc_names_all_validated_individually(self):
        """Each name in pc_names is validated against the same regex as single pc_name."""
        payload = {**VALID_BULK_PAYLOAD, "pc_names": ["OK-PC", "DESK;TOP"]}
        with pytest.raises(ValidationError):
            BulkCreateExceptionRequest(**payload)

    def test_single_pc_name_accepted(self):
        """A list with a single valid pc_name is fine."""
        payload = {**VALID_BULK_PAYLOAD, "pc_names": ["DESKTOP-01"]}
        req = BulkCreateExceptionRequest(**payload)
        assert req.pc_names == ["DESKTOP-01"]
