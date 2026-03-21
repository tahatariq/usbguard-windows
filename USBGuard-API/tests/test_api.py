"""
Integration tests for the USBGuard API using FastAPI TestClient.

BigFixClient is fully mocked so no real BigFix server is required.
API key authentication is exercised in each test that needs it.

State injection strategy
------------------------
FastAPI's lifespan context manager runs when TestClient enters its ``__enter__``
block, which means any ``app.state`` writes done *before* the ``with`` block are
overwritten.  We therefore inject mocks *after* the client has started but
before each request, using a pytest fixture that is set up once per test
function inside the live client context.
"""

from datetime import date, datetime, timedelta
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import app
from app.models import ExceptionStatus


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

API_KEY = "test-key"
HEADERS = {"X-API-Key": API_KEY}

_TEST_SETTINGS = Settings(
    bigfix_server="bigfix.test",
    bigfix_port=52311,
    bigfix_username="admin",
    bigfix_password="secret",
    api_keys=[API_KEY],
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture()
def mock_bigfix():
    """
    Build a MagicMock for BigFixClient with sensible defaults.
    Callers can override individual return values / side effects.
    """
    bf = MagicMock()
    bf.computer_exists.return_value = True
    bf.create_exception_action.return_value = "12345"
    bf.revoke_exception_action.return_value = "99999"
    bf.get_exception_status.return_value = ExceptionStatus(
        pc_name="DESKTOP-01",
        has_active_exception=False,
        expiry_time=None,
        granted_to_user=None,
        ritm=None,
    )
    return bf


@pytest.fixture()
def client(mock_bigfix):
    """
    Yield a TestClient with both app.state.settings and app.state.bigfix
    injected *after* the lifespan has finished overwriting them.
    """
    with TestClient(app, raise_server_exceptions=False) as c:
        # Lifespan has now run — overwrite with test doubles.
        app.state.settings = _TEST_SETTINGS
        app.state.bigfix = mock_bigfix
        yield c


# ---------------------------------------------------------------------------
# Helper: base valid POST payload
# ---------------------------------------------------------------------------

def _valid_post_payload(start_date: str = None) -> dict:
    future = (date.today() + timedelta(days=3)).isoformat()
    return {
        "pc_name": "DESKTOP-01",
        "username": "john.doe",
        "ritm": "RITM0012345",
        "start_date": start_date or future,
        "number_of_days": 5,
    }


# ---------------------------------------------------------------------------
# Authentication tests
# ---------------------------------------------------------------------------

class TestAuthentication:
    def test_get_no_api_key_returns_401(self, client):
        """Missing X-API-Key header → 401."""
        resp = client.get("/api/exceptions/DESKTOP-01")
        assert resp.status_code == 401
        body = resp.json()
        assert body["success"] is False
        assert "missing" in body["message"].lower()

    def test_get_wrong_api_key_returns_403(self, client):
        """Incorrect X-API-Key → 403."""
        resp = client.get(
            "/api/exceptions/DESKTOP-01", headers={"X-API-Key": "wrong-key"}
        )
        assert resp.status_code == 403
        body = resp.json()
        assert body["success"] is False
        assert "invalid" in body["message"].lower()


# ---------------------------------------------------------------------------
# GET /api/exceptions/{pc_name}
# ---------------------------------------------------------------------------

class TestGetStatus:
    def test_pc_not_in_bigfix_returns_404(self, client, mock_bigfix):
        """Computer not enrolled in BigFix → 404."""
        mock_bigfix.computer_exists.return_value = False
        resp = client.get("/api/exceptions/DESKTOP-01", headers=HEADERS)
        assert resp.status_code == 404
        body = resp.json()
        assert body["success"] is False

    def test_pc_found_no_exception_returns_200(self, client, mock_bigfix):
        """PC found, no active exception → 200 with has_active_exception=False."""
        mock_bigfix.computer_exists.return_value = True
        mock_bigfix.get_exception_status.return_value = ExceptionStatus(
            pc_name="DESKTOP-01",
            has_active_exception=False,
            expiry_time=None,
            granted_to_user=None,
            ritm=None,
        )
        resp = client.get("/api/exceptions/DESKTOP-01", headers=HEADERS)
        assert resp.status_code == 200
        body = resp.json()
        assert body["success"] is True
        assert body["data"]["has_active_exception"] is False

    def test_pc_found_active_exception_returns_200(self, client, mock_bigfix):
        """PC found with an active exception → 200 with has_active_exception=True."""
        expiry = datetime.now() + timedelta(days=5)
        mock_bigfix.computer_exists.return_value = True
        mock_bigfix.get_exception_status.return_value = ExceptionStatus(
            pc_name="DESKTOP-01",
            has_active_exception=True,
            expiry_time=expiry,
            granted_to_user="john.doe",
            ritm="RITM0012345",
        )
        resp = client.get("/api/exceptions/DESKTOP-01", headers=HEADERS)
        assert resp.status_code == 200
        body = resp.json()
        assert body["success"] is True
        assert body["data"]["has_active_exception"] is True
        assert body["data"]["granted_to_user"] == "john.doe"
        assert body["data"]["ritm"] == "RITM0012345"


# ---------------------------------------------------------------------------
# POST /api/exceptions
# ---------------------------------------------------------------------------

class TestCreateException:
    def test_valid_future_date_returns_201_no_warning(self, client, mock_bigfix):
        """Valid request with a future start date → 201, action_id in data, no warning."""
        mock_bigfix.create_exception_action.return_value = "12345"
        future = (date.today() + timedelta(days=3)).isoformat()
        resp = client.post("/api/exceptions", json=_valid_post_payload(start_date=future), headers=HEADERS)
        assert resp.status_code == 201
        body = resp.json()
        assert body["success"] is True
        assert body["data"]["action_id"] == "12345"
        assert body["data"]["pc_name"] == "DESKTOP-01"
        assert body["data"]["ritm"] == "RITM0012345"
        assert body["data"]["start_date"] == future
        assert body["data"]["scheduled"] is True
        assert "scheduled" in body["message"].lower()
        assert body["warning"] is None

    def test_same_day_start_is_not_scheduled(self, client, mock_bigfix):
        """A start_date of today → scheduled=False, different message."""
        mock_bigfix.create_exception_action.return_value = "12345"
        today = date.today().isoformat()
        resp = client.post("/api/exceptions", json=_valid_post_payload(start_date=today), headers=HEADERS)
        assert resp.status_code == 201
        body = resp.json()
        assert body["data"]["scheduled"] is False
        assert "scheduled" not in body["message"].lower()

    def test_past_date_returns_201_with_warning(self, client, mock_bigfix):
        """Request with a past start date → 201 with a warning field."""
        resp = client.post(
            "/api/exceptions",
            json=_valid_post_payload(start_date="2020-01-01"),
            headers=HEADERS,
        )
        assert resp.status_code == 201
        body = resp.json()
        assert body["success"] is True
        assert body["warning"] is not None
        assert "past" in body["warning"].lower()

    def test_unparseable_date_returns_201_with_warning(self, client, mock_bigfix):
        """Unparseable start date → 201 using today's date, warning present."""
        resp = client.post(
            "/api/exceptions",
            json=_valid_post_payload(start_date="not-a-date"),
            headers=HEADERS,
        )
        assert resp.status_code == 201
        body = resp.json()
        assert body["success"] is True
        assert body["warning"] is not None
        assert "not-a-date" in body["warning"]

    def test_pc_not_in_bigfix_returns_422(self, client, mock_bigfix):
        """Computer not in BigFix → 422 with descriptive message."""
        mock_bigfix.computer_exists.return_value = False
        resp = client.post("/api/exceptions", json=_valid_post_payload(), headers=HEADERS)
        assert resp.status_code == 422
        body = resp.json()
        assert body["success"] is False
        assert "DESKTOP-01" in body["message"]

    def test_number_of_days_zero_returns_422(self, client):
        """number_of_days=0 fails Pydantic validation → 422."""
        payload = {**_valid_post_payload(), "number_of_days": 0}
        resp = client.post("/api/exceptions", json=payload, headers=HEADERS)
        assert resp.status_code == 422

    def test_number_of_days_31_returns_422(self, client):
        """number_of_days=31 fails Pydantic validation → 422."""
        payload = {**_valid_post_payload(), "number_of_days": 31}
        resp = client.post("/api/exceptions", json=payload, headers=HEADERS)
        assert resp.status_code == 422

    def test_invalid_ritm_returns_422(self, client):
        """INC-style RITM fails Pydantic validation → 422."""
        payload = {**_valid_post_payload(), "ritm": "INC0012345"}
        resp = client.post("/api/exceptions", json=payload, headers=HEADERS)
        assert resp.status_code == 422

    def test_bigfix_http_error_returns_502(self, client, mock_bigfix):
        """BigFix returning an HTTP error → 502."""
        import httpx as _httpx

        mock_request = _httpx.Request("POST", "https://bigfix.test:52311/api/actions")
        mock_response = _httpx.Response(500, request=mock_request)
        mock_bigfix.create_exception_action.side_effect = _httpx.HTTPStatusError(
            "Server error", request=mock_request, response=mock_response
        )
        resp = client.post("/api/exceptions", json=_valid_post_payload(), headers=HEADERS)
        assert resp.status_code == 502
        body = resp.json()
        assert body["success"] is False
        assert "bigfix" in body["message"].lower()


# ---------------------------------------------------------------------------
# DELETE /api/exceptions/{pc_name}
# ---------------------------------------------------------------------------

class TestRevokeException:
    def test_pc_found_returns_200(self, client, mock_bigfix):
        """Successful revoke → 200 with action_id."""
        mock_bigfix.revoke_exception_action.return_value = "99999"
        resp = client.delete("/api/exceptions/DESKTOP-01", headers=HEADERS)
        assert resp.status_code == 200
        body = resp.json()
        assert body["success"] is True
        assert "revoked" in body["message"].lower()
        assert body["data"]["action_id"] == "99999"
        assert body["data"]["pc_name"] == "DESKTOP-01"

    def test_pc_not_in_bigfix_returns_404(self, client, mock_bigfix):
        """Computer not in BigFix → 404."""
        mock_bigfix.computer_exists.return_value = False
        resp = client.delete("/api/exceptions/DESKTOP-01", headers=HEADERS)
        assert resp.status_code == 404
        body = resp.json()
        assert body["success"] is False
