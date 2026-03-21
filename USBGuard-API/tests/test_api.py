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

import os
import tempfile
from datetime import date, datetime, timedelta
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import _rate_limits, app
from app.models import ExceptionStatus


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

API_KEY = "test-key"
HEADERS = {"X-API-Key": API_KEY}

# RBAC keys: readonly, approver, and admin
READONLY_KEY = "readonly-key"
APPROVER_KEY = "approver-key"
ADMIN_KEY = API_KEY  # default admin

READONLY_HEADERS = {"X-API-Key": READONLY_KEY}
APPROVER_HEADERS = {"X-API-Key": APPROVER_KEY}

_TEST_SETTINGS = Settings(
    bigfix_server="bigfix.test",
    bigfix_port=52311,
    bigfix_username="admin",
    bigfix_password="secret",
    api_keys=[
        API_KEY,  # legacy plain string — treated as admin
        {"key": READONLY_KEY, "role": "readonly"},
        {"key": APPROVER_KEY, "role": "approver"},
    ],
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture()
def mock_bigfix():
    """
    Build an AsyncMock for BigFixClient with sensible defaults.
    Callers can override individual return values / side effects.
    """
    bf = AsyncMock()
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
    bf.health_check.return_value = {"status": "healthy", "detail": "BigFix server reachable."}
    bf.start.return_value = None
    bf.close.return_value = None
    bf._query_registry_value.return_value = None
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
        # Clear rate limit buckets between tests
        _rate_limits.clear()
        yield c


@pytest.fixture(autouse=True)
def _clear_rate_limits():
    """Ensure rate limit state does not leak between tests."""
    _rate_limits.clear()
    yield
    _rate_limits.clear()


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


def _valid_bulk_payload(start_date: str = None) -> dict:
    future = (date.today() + timedelta(days=3)).isoformat()
    return {
        "pc_names": ["DESKTOP-01", "DESKTOP-02"],
        "username": "john.doe",
        "ritm": "RITM0012345",
        "start_date": start_date or future,
        "number_of_days": 5,
    }


# ---------------------------------------------------------------------------
# Health check (no auth required)
# ---------------------------------------------------------------------------

class TestHealthCheck:
    def test_health_returns_200_when_healthy(self, client, mock_bigfix):
        """GET /api/health returns 200 with status=healthy when BigFix is reachable."""
        mock_bigfix.health_check.return_value = {"status": "healthy", "detail": "BigFix server reachable."}
        resp = client.get("/api/health")
        assert resp.status_code == 200
        body = resp.json()
        assert body["status"] == "healthy"
        assert "version" in body
        assert "timestamp" in body

    def test_health_no_auth_required(self, client):
        """GET /api/health should not require X-API-Key header."""
        resp = client.get("/api/health")
        # Should not be 401 or 403 — health is public
        assert resp.status_code in (200, 503)

    def test_health_returns_503_when_unhealthy(self, client, mock_bigfix):
        """GET /api/health returns 503 when BigFix is unreachable."""
        mock_bigfix.health_check.return_value = {"status": "unhealthy", "detail": "Connection refused."}
        resp = client.get("/api/health")
        assert resp.status_code == 503
        body = resp.json()
        assert body["status"] == "unhealthy"


# ---------------------------------------------------------------------------
# Authentication tests
# ---------------------------------------------------------------------------

class TestAuthentication:
    def test_get_no_api_key_returns_401(self, client):
        """Missing X-API-Key header -> 401."""
        resp = client.get("/api/exceptions/DESKTOP-01")
        assert resp.status_code == 401
        body = resp.json()
        assert body["success"] is False
        assert "missing" in body["message"].lower()

    def test_get_wrong_api_key_returns_403(self, client):
        """Incorrect X-API-Key -> 403."""
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
        """Computer not enrolled in BigFix -> 404."""
        mock_bigfix.computer_exists.return_value = False
        resp = client.get("/api/exceptions/DESKTOP-01", headers=HEADERS)
        assert resp.status_code == 404
        body = resp.json()
        assert body["success"] is False

    def test_pc_found_no_exception_returns_200(self, client, mock_bigfix):
        """PC found, no active exception -> 200 with has_active_exception=False."""
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
        """PC found with an active exception -> 200 with has_active_exception=True."""
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
        """Valid request with a future start date -> 201, action_id in data, no warning."""
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
        """A start_date of today -> scheduled=False, different message."""
        mock_bigfix.create_exception_action.return_value = "12345"
        today = date.today().isoformat()
        resp = client.post("/api/exceptions", json=_valid_post_payload(start_date=today), headers=HEADERS)
        assert resp.status_code == 201
        body = resp.json()
        assert body["data"]["scheduled"] is False
        assert "scheduled" not in body["message"].lower()

    def test_past_date_returns_201_with_warning(self, client, mock_bigfix):
        """Request with a past start date -> 201 with a warning field."""
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
        """Unparseable start date -> 201 using today's date, warning present."""
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
        """Computer not in BigFix -> 422 with descriptive message."""
        mock_bigfix.computer_exists.return_value = False
        resp = client.post("/api/exceptions", json=_valid_post_payload(), headers=HEADERS)
        assert resp.status_code == 422
        body = resp.json()
        assert body["success"] is False
        assert "DESKTOP-01" in body["message"]

    def test_number_of_days_zero_returns_422(self, client):
        """number_of_days=0 fails Pydantic validation -> 422."""
        payload = {**_valid_post_payload(), "number_of_days": 0}
        resp = client.post("/api/exceptions", json=payload, headers=HEADERS)
        assert resp.status_code == 422

    def test_number_of_days_366_returns_422(self, client):
        """number_of_days=366 exceeds the maximum of 365 -> 422."""
        payload = {**_valid_post_payload(), "number_of_days": 366}
        resp = client.post("/api/exceptions", json=payload, headers=HEADERS)
        assert resp.status_code == 422

    def test_empty_ritm_returns_422(self, client):
        """Empty ritm fails Pydantic validation -> 422."""
        payload = {**_valid_post_payload(), "ritm": ""}
        resp = client.post("/api/exceptions", json=payload, headers=HEADERS)
        assert resp.status_code == 422

    def test_bigfix_http_error_returns_502(self, client, mock_bigfix):
        """BigFix returning an HTTP error -> 502."""
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
# POST /api/exceptions/bulk
# ---------------------------------------------------------------------------

class TestBulkCreateException:
    def test_bulk_all_succeed_returns_201(self, client, mock_bigfix):
        """All PCs exist and actions succeed -> 201 with success=True."""
        mock_bigfix.computer_exists.return_value = True
        mock_bigfix.create_exception_action.return_value = "12345"
        resp = client.post("/api/exceptions/bulk", json=_valid_bulk_payload(), headers=HEADERS)
        assert resp.status_code == 201
        body = resp.json()
        assert body["success"] is True
        assert "2 succeeded" in body["message"]
        assert "0 failed" in body["message"]
        assert len(body["data"]["results"]) == 2
        for r in body["data"]["results"]:
            assert r["success"] is True
            assert r["action_id"] == "12345"

    def test_bulk_partial_failure_returns_201(self, client, mock_bigfix):
        """One PC not found -> 201 with partial failure (success=False at top)."""
        # First PC exists, second does not
        mock_bigfix.computer_exists.side_effect = [True, False]
        mock_bigfix.create_exception_action.return_value = "12345"
        resp = client.post("/api/exceptions/bulk", json=_valid_bulk_payload(), headers=HEADERS)
        assert resp.status_code == 201
        body = resp.json()
        assert body["success"] is False  # not all succeeded
        assert "1 succeeded" in body["message"]
        assert "1 failed" in body["message"]

    def test_bulk_empty_pc_names_returns_422(self, client):
        """Empty pc_names list -> 422 validation error."""
        payload = {**_valid_bulk_payload(), "pc_names": []}
        resp = client.post("/api/exceptions/bulk", json=payload, headers=HEADERS)
        assert resp.status_code == 422

    def test_bulk_includes_start_date_and_expiry(self, client, mock_bigfix):
        """Bulk response should include resolved start_date and expiry."""
        mock_bigfix.computer_exists.return_value = True
        mock_bigfix.create_exception_action.return_value = "55555"
        future = (date.today() + timedelta(days=3)).isoformat()
        resp = client.post(
            "/api/exceptions/bulk",
            json=_valid_bulk_payload(start_date=future),
            headers=HEADERS,
        )
        assert resp.status_code == 201
        body = resp.json()
        assert body["data"]["start_date"] == future
        assert "expiry" in body["data"]
        assert body["data"]["ritm"] == "RITM0012345"


# ---------------------------------------------------------------------------
# DELETE /api/exceptions/{pc_name}
# ---------------------------------------------------------------------------

class TestRevokeException:
    def test_pc_found_returns_200(self, client, mock_bigfix):
        """Successful revoke -> 200 with action_id."""
        mock_bigfix.revoke_exception_action.return_value = "99999"
        resp = client.delete("/api/exceptions/DESKTOP-01", headers=HEADERS)
        assert resp.status_code == 200
        body = resp.json()
        assert body["success"] is True
        assert "revoked" in body["message"].lower()
        assert body["data"]["action_id"] == "99999"
        assert body["data"]["pc_name"] == "DESKTOP-01"

    def test_pc_not_in_bigfix_returns_404(self, client, mock_bigfix):
        """Computer not in BigFix -> 404."""
        mock_bigfix.computer_exists.return_value = False
        resp = client.delete("/api/exceptions/DESKTOP-01", headers=HEADERS)
        assert resp.status_code == 404
        body = resp.json()
        assert body["success"] is False


# ---------------------------------------------------------------------------
# GET /api/audit
# ---------------------------------------------------------------------------

class TestAudit:
    def test_audit_returns_200_no_log_file(self, client):
        """When audit.log does not exist, return 200 with empty entries."""
        with patch.dict(os.environ, {"ProgramData": "/nonexistent/path"}):
            resp = client.get("/api/audit", headers=HEADERS)
        assert resp.status_code == 200
        body = resp.json()
        assert body["success"] is True
        assert body["data"]["entries"] == []
        assert body["data"]["total"] == 0

    def test_audit_parses_log_entries(self, client):
        """Audit endpoint should parse well-formed log lines."""
        log_content = (
            "[2026-03-01 10:00:00] ACTION=block USER=CORP\\admin All 7 layers applied\n"
            "[2026-03-01 11:00:00] ACTION=unblock USER=CORP\\admin Exception granted\n"
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            audit_dir = os.path.join(tmpdir, "USBGuard")
            os.makedirs(audit_dir)
            audit_path = os.path.join(audit_dir, "audit.log")
            with open(audit_path, "w") as f:
                f.write(log_content)

            with patch.dict(os.environ, {"ProgramData": tmpdir}):
                resp = client.get("/api/audit", headers=HEADERS)

        assert resp.status_code == 200
        body = resp.json()
        assert body["success"] is True
        assert body["data"]["total"] == 2
        # Most recent first
        assert body["data"]["entries"][0]["action"] == "unblock"
        assert body["data"]["entries"][1]["action"] == "block"

    def test_audit_filter_by_action(self, client):
        """Audit should filter entries by action query parameter."""
        log_content = (
            "[2026-03-01 10:00:00] ACTION=block USER=CORP\\admin\n"
            "[2026-03-01 11:00:00] ACTION=unblock USER=CORP\\admin\n"
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            audit_dir = os.path.join(tmpdir, "USBGuard")
            os.makedirs(audit_dir)
            audit_path = os.path.join(audit_dir, "audit.log")
            with open(audit_path, "w") as f:
                f.write(log_content)

            with patch.dict(os.environ, {"ProgramData": tmpdir}):
                resp = client.get("/api/audit?action=block", headers=HEADERS)

        assert resp.status_code == 200
        body = resp.json()
        assert body["data"]["total"] == 1
        assert body["data"]["entries"][0]["action"] == "block"


# ---------------------------------------------------------------------------
# GET /api/fleet/compliance
# ---------------------------------------------------------------------------

class TestFleetCompliance:
    def test_compliance_returns_200(self, client, mock_bigfix):
        """Fleet compliance endpoint should return structured counts."""
        # Mock the internal _count_by_relevance calls by mocking the HTTP client
        # on the bigfix object.  The fleet endpoint calls _count_by_relevance,
        # which uses bigfix._http.get internally.
        mock_http_response = MagicMock()
        mock_http_response.status_code = 200
        mock_http_response.text = '<BESAPI><Query><Result><Answer>42</Answer></Result></Query></BESAPI>'
        mock_http_response.raise_for_status = MagicMock()

        mock_bigfix._http = AsyncMock()
        mock_bigfix._http.get.return_value = mock_http_response
        mock_bigfix._base_url = "https://bigfix.test:52311"

        resp = client.get("/api/fleet/compliance", headers=HEADERS)
        assert resp.status_code == 200
        body = resp.json()
        assert body["success"] is True
        assert "total" in body["data"]
        assert "compliant" in body["data"]
        assert "non_compliant" in body["data"]
        assert "compliance_rate" in body["data"]


# ---------------------------------------------------------------------------
# GET /api/inventory/{pc_name}
# ---------------------------------------------------------------------------

class TestDeviceInventory:
    def test_inventory_returns_200(self, client, mock_bigfix):
        """Device inventory returns 200 with layer status and exception data."""
        mock_bigfix.computer_exists.return_value = True
        mock_bigfix._query_registry_value.return_value = "4"
        mock_bigfix.get_exception_status.return_value = ExceptionStatus(
            pc_name="DESKTOP-01",
            has_active_exception=False,
            expiry_time=None,
            granted_to_user=None,
            ritm=None,
        )
        resp = client.get("/api/inventory/DESKTOP-01", headers=HEADERS)
        assert resp.status_code == 200
        body = resp.json()
        assert body["success"] is True
        assert body["data"]["pc_name"] == "DESKTOP-01"
        assert "layers" in body["data"]
        assert "exception" in body["data"]

    def test_inventory_pc_not_found_returns_404(self, client, mock_bigfix):
        """Device inventory returns 404 when PC not in BigFix."""
        mock_bigfix.computer_exists.return_value = False
        resp = client.get("/api/inventory/UNKNOWN-PC", headers=HEADERS)
        assert resp.status_code == 404
        body = resp.json()
        assert body["success"] is False


# ---------------------------------------------------------------------------
# RBAC tests
# ---------------------------------------------------------------------------

class TestRBAC:
    def test_readonly_can_get_status(self, client, mock_bigfix):
        """Readonly key should be able to GET exception status."""
        resp = client.get("/api/exceptions/DESKTOP-01", headers=READONLY_HEADERS)
        assert resp.status_code == 200

    def test_readonly_cannot_create_exception(self, client, mock_bigfix):
        """Readonly key should be rejected for POST /api/exceptions (403)."""
        resp = client.post("/api/exceptions", json=_valid_post_payload(), headers=READONLY_HEADERS)
        assert resp.status_code == 403

    def test_readonly_cannot_delete_exception(self, client, mock_bigfix):
        """Readonly key should be rejected for DELETE /api/exceptions (403)."""
        resp = client.delete("/api/exceptions/DESKTOP-01", headers=READONLY_HEADERS)
        assert resp.status_code == 403

    def test_approver_can_create_exception(self, client, mock_bigfix):
        """Approver key should be able to create exceptions."""
        mock_bigfix.create_exception_action.return_value = "12345"
        resp = client.post("/api/exceptions", json=_valid_post_payload(), headers=APPROVER_HEADERS)
        assert resp.status_code == 201

    def test_approver_cannot_revoke_exception(self, client, mock_bigfix):
        """Approver key should NOT be able to revoke (requires admin)."""
        resp = client.delete("/api/exceptions/DESKTOP-01", headers=APPROVER_HEADERS)
        assert resp.status_code == 403

    def test_admin_can_revoke_exception(self, client, mock_bigfix):
        """Admin key should be able to revoke exceptions."""
        mock_bigfix.revoke_exception_action.return_value = "99999"
        resp = client.delete("/api/exceptions/DESKTOP-01", headers=HEADERS)
        assert resp.status_code == 200


# ---------------------------------------------------------------------------
# Rate limiting tests
# ---------------------------------------------------------------------------

class TestRateLimiting:
    def test_rate_limit_returns_429_after_exceeded(self, client, mock_bigfix):
        """After exceeding the write rate limit, the API should return 429."""
        from app.main import _RATE_LIMIT_MAX_WRITE

        # Exhaust the write rate limit by sending many POST requests
        for i in range(_RATE_LIMIT_MAX_WRITE):
            resp = client.post("/api/exceptions", json=_valid_post_payload(), headers=HEADERS)
            # All should succeed (201) until limit is hit
            assert resp.status_code in (201, 429), f"Request {i} returned {resp.status_code}"

        # The next request should be rate-limited
        resp = client.post("/api/exceptions", json=_valid_post_payload(), headers=HEADERS)
        assert resp.status_code == 429
        body = resp.json()
        assert body["success"] is False
        assert "rate limit" in body["message"].lower()

    def test_read_rate_limit_returns_429(self, client, mock_bigfix):
        """After exceeding the read rate limit, GET should return 429."""
        from app.main import _RATE_LIMIT_MAX_READ

        for i in range(_RATE_LIMIT_MAX_READ):
            resp = client.get("/api/exceptions/DESKTOP-01", headers=HEADERS)
            assert resp.status_code in (200, 429), f"Request {i} returned {resp.status_code}"

        resp = client.get("/api/exceptions/DESKTOP-01", headers=HEADERS)
        assert resp.status_code == 429
        body = resp.json()
        assert body["success"] is False
        assert "rate limit" in body["message"].lower()
