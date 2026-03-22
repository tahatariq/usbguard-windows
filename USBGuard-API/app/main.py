"""
USBGuard API — FastAPI application entry point.

Routes:
    GET    /api/health                  — Health check (no auth required)
    GET    /api/exceptions/{pc_name}    — Query current exception status
    POST   /api/exceptions              — Create a new USB access exception
    POST   /api/exceptions/bulk         — Create exceptions for multiple PCs
    DELETE /api/exceptions/{pc_name}    — Revoke an existing exception
    GET    /api/audit                   — Query audit log entries
"""

import logging
import os
import re
from contextlib import asynccontextmanager
from datetime import date, datetime, timedelta
from typing import Any, List, Optional

import httpx
from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import JSONResponse

from app.auth import ApiKeyMiddleware
from app.bigfix import BigFixClient
from app.config import load_settings
from app.date_parser import resolve_start_date
from app.models import ApiResponse, BulkCreateExceptionRequest, CreateExceptionRequest

logger = logging.getLogger("usbguard.api")

# Valid roles for RBAC enforcement
ROLE_ADMIN = "admin"
ROLE_APPROVER = "approver"
ROLE_READONLY = "readonly"


def _require_role(request: Request, *allowed_roles: str) -> str:
    """Check that the request has one of the allowed roles.  Returns the role."""
    role = getattr(request.state, "role", ROLE_ADMIN)
    if role not in allowed_roles:
        raise HTTPException(
            status_code=403,
            detail=f"Insufficient permissions.  Required role: {' or '.join(allowed_roles)}, current: {role}.",
        )
    return role


# ---------------------------------------------------------------------------
# Lifespan — load config and build BigFix client at startup
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Load configuration and initialise the BigFix client on startup."""
    settings = load_settings()
    app.state.settings = settings
    bigfix = BigFixClient(
        server=settings.bigfix_server,
        port=settings.bigfix_port,
        username=settings.bigfix_username,
        password=settings.bigfix_password,
        ca_cert=settings.bigfix_ca_cert,
    )
    await bigfix.start()
    app.state.bigfix = bigfix

    # Probe BigFix connectivity at startup (non-fatal)
    probe = await bigfix.health_check()
    if probe["status"] == "healthy":
        logger.info("BigFix connectivity OK at startup.")
    else:
        logger.warning("BigFix connectivity issue at startup: %s", probe["detail"])

    yield

    await bigfix.close()


# ---------------------------------------------------------------------------
# Application factory
# ---------------------------------------------------------------------------

def _docs_url() -> str | None:
    """Disable Swagger UI in production (set USBGUARD_DISABLE_DOCS=1)."""
    return None if os.environ.get("USBGUARD_DISABLE_DOCS") == "1" else "/docs"


def _redoc_url() -> str | None:
    return None if os.environ.get("USBGUARD_DISABLE_DOCS") == "1" else "/redoc"


app = FastAPI(
    title="USBGuard API",
    description=(
        "Manages USB access exceptions on Windows endpoints via IBM BigFix.  "
        "All endpoints (except /api/health) require an X-API-Key header."
    ),
    version="2.0.0",
    lifespan=lifespan,
    docs_url=_docs_url(),
    redoc_url=_redoc_url(),
)

app.add_middleware(ApiKeyMiddleware)


# ---------------------------------------------------------------------------
# Rate limiting (lightweight in-memory limiter)
# ---------------------------------------------------------------------------

from collections import defaultdict
import time

_rate_limits: dict[str, list[float]] = defaultdict(list)
_RATE_LIMIT_WINDOW = 60  # seconds
_RATE_LIMIT_MAX_WRITE = 30  # max write requests per key per window
_RATE_LIMIT_MAX_READ = 120  # max read requests per key per window


def _check_rate_limit(api_key: str, is_write: bool) -> bool:
    """Return True if the request should be allowed, False if rate-limited."""
    now = time.monotonic()
    bucket_key = f"{api_key}:{'w' if is_write else 'r'}"
    timestamps = _rate_limits[bucket_key]
    # Prune old entries
    _rate_limits[bucket_key] = [t for t in timestamps if now - t < _RATE_LIMIT_WINDOW]
    limit = _RATE_LIMIT_MAX_WRITE if is_write else _RATE_LIMIT_MAX_READ
    if len(_rate_limits[bucket_key]) >= limit:
        return False
    _rate_limits[bucket_key].append(now)
    return True


# ---------------------------------------------------------------------------
# Exception handlers
# ---------------------------------------------------------------------------

@app.exception_handler(httpx.HTTPStatusError)
async def httpx_error_handler(request: Request, exc: httpx.HTTPStatusError) -> JSONResponse:
    """Convert BigFix HTTP errors into a 502 Bad Gateway response."""
    return JSONResponse(
        status_code=502,
        content={
            "success": False,
            "message": (
                f"BigFix returned an error: "
                f"HTTP {exc.response.status_code} from {exc.request.url}.  "
                f"Check BigFix server connectivity and credentials."
            ),
        },
    )


@app.exception_handler(ValueError)
async def value_error_handler(request: Request, exc: ValueError) -> JSONResponse:
    """Convert ValueErrors (e.g. bad action IDs) into 422 responses."""
    return JSONResponse(
        status_code=422,
        content={"success": False, "message": str(exc)},
    )


# ---------------------------------------------------------------------------
# Health check (no auth required)
# ---------------------------------------------------------------------------

@app.get(
    "/api/health",
    summary="Health check",
    responses={200: {"description": "Service health status"}},
)
async def health_check(request: Request) -> JSONResponse:
    """
    Returns the health status of the API and its BigFix connection.

    No authentication required — suitable for load balancers and monitoring.
    """
    bigfix: BigFixClient = request.app.state.bigfix
    probe = await bigfix.health_check()

    status_code = 200 if probe["status"] == "healthy" else 503
    return JSONResponse(
        status_code=status_code,
        content={
            "status": probe["status"],
            "detail": probe["detail"],
            "version": "2.0.0",
            "timestamp": datetime.utcnow().isoformat() + "Z",
        },
    )


# ---------------------------------------------------------------------------
# Exception routes
# ---------------------------------------------------------------------------

@app.get(
    "/api/exceptions/{pc_name}",
    response_model=ApiResponse,
    summary="Get USB exception status for a PC",
    responses={
        200: {"description": "Status retrieved successfully"},
        404: {"description": "Computer not found in BigFix"},
    },
)
async def get_status(pc_name: str, request: Request) -> JSONResponse:
    """
    Return the current USB exception status for the given PC.

    Requires role: readonly, approver, or admin.
    """
    _require_role(request, ROLE_READONLY, ROLE_APPROVER, ROLE_ADMIN)

    api_key = request.headers.get("X-API-Key", "")
    if not _check_rate_limit(api_key, is_write=False):
        return JSONResponse(status_code=429, content={"success": False, "message": "Rate limit exceeded."})

    bigfix: BigFixClient = request.app.state.bigfix

    if not await bigfix.computer_exists(pc_name):
        return JSONResponse(
            status_code=404,
            content={
                "success": False,
                "message": f"Computer '{pc_name}' was not found in BigFix.",
            },
        )

    status = await bigfix.get_exception_status(pc_name)

    return JSONResponse(
        status_code=200,
        content=ApiResponse(
            success=True,
            message="Exception status retrieved.",
            data=status.model_dump(mode="json"),
        ).model_dump(mode="json"),
    )


@app.post(
    "/api/exceptions",
    response_model=ApiResponse,
    status_code=201,
    summary="Create a USB access exception",
    responses={
        201: {"description": "Exception created successfully"},
        422: {"description": "Validation error or computer not found"},
        502: {"description": "BigFix API error"},
    },
)
async def create_exception(body: CreateExceptionRequest, request: Request) -> JSONResponse:
    """
    Deploy a BigFix action that grants USB storage access on the target PC.

    Requires role: approver or admin.
    """
    _require_role(request, ROLE_APPROVER, ROLE_ADMIN)

    api_key = request.headers.get("X-API-Key", "")
    if not _check_rate_limit(api_key, is_write=True):
        return JSONResponse(status_code=429, content={"success": False, "message": "Rate limit exceeded."})

    bigfix: BigFixClient = request.app.state.bigfix

    resolved_date, warning = resolve_start_date(body.start_date)

    if not await bigfix.computer_exists(body.pc_name):
        return JSONResponse(
            status_code=422,
            content={
                "success": False,
                "message": (
                    f"Computer '{body.pc_name}' was not found in BigFix.  "
                    "Verify the name and try again."
                ),
            },
        )

    action_id = await bigfix.create_exception_action(
        pc_name=body.pc_name,
        username=body.username,
        ritm=body.ritm,
        start_date=resolved_date,
        number_of_days=body.number_of_days,
    )

    expiry_date = resolved_date + timedelta(days=body.number_of_days)
    scheduled = resolved_date > date.today()

    if scheduled:
        message = (
            f"Exception scheduled.  BigFix will activate USB access on "
            f"{resolved_date.isoformat()} and the PC will be unblocked the next "
            f"time it checks in on or after that date (even if currently offline)."
        )
    else:
        message = "Exception created.  USB access will be active on next BigFix agent check-in."

    response_data = {
        "action_id": action_id,
        "pc_name": body.pc_name,
        "start_date": resolved_date.isoformat(),
        "expiry": expiry_date.isoformat(),
        "ritm": body.ritm,
        "scheduled": scheduled,
    }

    return JSONResponse(
        status_code=201,
        content=ApiResponse(
            success=True,
            message=message,
            data=response_data,
            warning=warning,
        ).model_dump(mode="json"),
    )


@app.post(
    "/api/exceptions/bulk",
    response_model=ApiResponse,
    status_code=201,
    summary="Create USB access exceptions for multiple PCs",
    responses={
        201: {"description": "Bulk exceptions created (partial failures possible)"},
        422: {"description": "Validation error"},
        502: {"description": "BigFix API error"},
    },
)
async def create_bulk_exception(body: BulkCreateExceptionRequest, request: Request) -> JSONResponse:
    """
    Deploy BigFix actions that grant USB storage access on multiple PCs.

    Returns per-machine results; partial failures do not roll back successful grants.
    Requires role: approver or admin.
    """
    _require_role(request, ROLE_APPROVER, ROLE_ADMIN)

    api_key = request.headers.get("X-API-Key", "")
    if not _check_rate_limit(api_key, is_write=True):
        return JSONResponse(status_code=429, content={"success": False, "message": "Rate limit exceeded."})

    bigfix: BigFixClient = request.app.state.bigfix
    resolved_date, warning = resolve_start_date(body.start_date)

    results = []
    success_count = 0
    fail_count = 0

    for pc_name in body.pc_names:
        try:
            if not await bigfix.computer_exists(pc_name):
                results.append({"pc_name": pc_name, "success": False, "error": "Computer not found in BigFix."})
                fail_count += 1
                continue

            action_id = await bigfix.create_exception_action(
                pc_name=pc_name,
                username=body.username,
                ritm=body.ritm,
                start_date=resolved_date,
                number_of_days=body.number_of_days,
            )
            results.append({"pc_name": pc_name, "success": True, "action_id": action_id})
            success_count += 1
        except Exception as exc:
            results.append({"pc_name": pc_name, "success": False, "error": str(exc)})
            fail_count += 1

    expiry_date = resolved_date + timedelta(days=body.number_of_days)
    message = f"Bulk operation complete: {success_count} succeeded, {fail_count} failed."

    return JSONResponse(
        status_code=201,
        content=ApiResponse(
            success=fail_count == 0,
            message=message,
            data={
                "results": results,
                "start_date": resolved_date.isoformat(),
                "expiry": expiry_date.isoformat(),
                "ritm": body.ritm,
            },
            warning=warning,
        ).model_dump(mode="json"),
    )


@app.delete(
    "/api/exceptions/{pc_name}",
    response_model=ApiResponse,
    summary="Revoke a USB access exception",
    responses={
        200: {"description": "Exception revoked successfully"},
        404: {"description": "Computer not found in BigFix"},
        502: {"description": "BigFix API error"},
    },
)
async def revoke_exception(pc_name: str, request: Request) -> JSONResponse:
    """
    Deploy a BigFix action that immediately revokes USB storage access.

    Requires role: admin only.
    """
    _require_role(request, ROLE_ADMIN)

    api_key = request.headers.get("X-API-Key", "")
    if not _check_rate_limit(api_key, is_write=True):
        return JSONResponse(status_code=429, content={"success": False, "message": "Rate limit exceeded."})

    bigfix: BigFixClient = request.app.state.bigfix

    if not await bigfix.computer_exists(pc_name):
        return JSONResponse(
            status_code=404,
            content={
                "success": False,
                "message": f"Computer '{pc_name}' was not found in BigFix.",
            },
        )

    action_id = await bigfix.revoke_exception_action(pc_name)

    return JSONResponse(
        status_code=200,
        content=ApiResponse(
            success=True,
            message=(
                "Exception revoked.  USB access will be blocked on next BigFix "
                "baseline run (up to 4 hours)."
            ),
            data={"action_id": action_id, "pc_name": pc_name},
        ).model_dump(mode="json"),
    )


# ---------------------------------------------------------------------------
# Audit log endpoint
# ---------------------------------------------------------------------------

_AUDIT_LINE_RE = re.compile(
    r"^\[(?P<timestamp>[^\]]+)\]\s+ACTION=(?P<action>\S+)\s+USER=(?P<user>\S+)(?:\s+(?P<detail>.*))?$"
)


@app.get(
    "/api/audit",
    response_model=ApiResponse,
    summary="Query audit log entries",
    responses={
        200: {"description": "Audit entries retrieved"},
    },
)
async def query_audit(
    request: Request,
    action: Optional[str] = Query(None, description="Filter by action type (e.g. block, unblock)"),
    from_date: Optional[str] = Query(None, description="Start date (YYYY-MM-DD)"),
    to_date: Optional[str] = Query(None, description="End date (YYYY-MM-DD)"),
    limit: int = Query(100, ge=1, le=1000, description="Max entries to return"),
) -> JSONResponse:
    """
    Query the local USBGuard audit log.

    The audit log is a flat text file at %ProgramData%\\USBGuard\\audit.log.
    This endpoint parses it and returns structured entries.

    Requires role: readonly, approver, or admin.
    """
    _require_role(request, ROLE_READONLY, ROLE_APPROVER, ROLE_ADMIN)

    api_key = request.headers.get("X-API-Key", "")
    if not _check_rate_limit(api_key, is_write=False):
        return JSONResponse(status_code=429, content={"success": False, "message": "Rate limit exceeded."})

    audit_path = os.path.join(os.environ.get("ProgramData", "C:\\ProgramData"), "USBGuard", "audit.log")

    if not os.path.exists(audit_path):
        return JSONResponse(
            status_code=200,
            content=ApiResponse(
                success=True,
                message="No audit log found.",
                data={"entries": [], "total": 0},
            ).model_dump(mode="json"),
        )

    entries: List[dict] = []
    from_dt = None
    to_dt = None

    if from_date:
        try:
            from_dt = datetime.strptime(from_date, "%Y-%m-%d")
        except ValueError:
            pass
    if to_date:
        try:
            to_dt = datetime.strptime(to_date, "%Y-%m-%d").replace(hour=23, minute=59, second=59)
        except ValueError:
            pass

    try:
        with open(audit_path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                m = _AUDIT_LINE_RE.match(line)
                if not m:
                    continue

                entry = {
                    "timestamp": m.group("timestamp"),
                    "action": m.group("action"),
                    "user": m.group("user"),
                    "detail": (m.group("detail") or "").strip(),
                }

                # Apply filters
                if action and entry["action"].lower() != action.lower():
                    continue
                if from_dt or to_dt:
                    try:
                        entry_dt = datetime.strptime(entry["timestamp"], "%Y-%m-%d %H:%M:%S")
                        if from_dt and entry_dt < from_dt:
                            continue
                        if to_dt and entry_dt > to_dt:
                            continue
                    except ValueError:
                        pass

                entries.append(entry)

    except OSError:
        return JSONResponse(
            status_code=200,
            content=ApiResponse(
                success=True,
                message="Could not read audit log.",
                data={"entries": [], "total": 0},
            ).model_dump(mode="json"),
        )

    # Return most recent entries first, up to limit
    entries = entries[-limit:]
    entries.reverse()

    return JSONResponse(
        status_code=200,
        content=ApiResponse(
            success=True,
            message=f"Retrieved {len(entries)} audit entries.",
            data={"entries": entries, "total": len(entries)},
        ).model_dump(mode="json"),
    )


# ---------------------------------------------------------------------------
# Fleet compliance endpoint
# ---------------------------------------------------------------------------

@app.get(
    "/api/fleet/compliance",
    response_model=ApiResponse,
    summary="Fleet-wide compliance summary",
    responses={200: {"description": "Compliance summary retrieved"}},
)
async def fleet_compliance(request: Request) -> JSONResponse:
    """
    Query BigFix Analysis Properties to return a fleet-wide compliance summary.

    Returns counts of compliant, non-compliant, and unknown endpoints.
    Requires role: readonly, approver, or admin.
    """
    _require_role(request, ROLE_READONLY, ROLE_APPROVER, ROLE_ADMIN)

    api_key = request.headers.get("X-API-Key", "")
    if not _check_rate_limit(api_key, is_write=False):
        return JSONResponse(status_code=429, content={"success": False, "message": "Rate limit exceeded."})

    bigfix: BigFixClient = request.app.state.bigfix

    try:
        # Query BigFix for the count of computers where USBSTOR Start=4
        compliant_count = await _count_by_relevance(
            bigfix,
            'number of bes computers whose (exists values "Start" of keys '
            '"HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Services\\USBSTOR" '
            'of registry of it whose (it as integer = 4))',
        )
        total_count = await _count_by_relevance(
            bigfix,
            "number of bes computers",
        )

        non_compliant = max(0, total_count - compliant_count)

        return JSONResponse(
            status_code=200,
            content=ApiResponse(
                success=True,
                message="Fleet compliance summary retrieved.",
                data={
                    "total": total_count,
                    "compliant": compliant_count,
                    "non_compliant": non_compliant,
                    "compliance_rate": round(compliant_count / max(total_count, 1) * 100, 1),
                },
            ).model_dump(mode="json"),
        )
    except Exception as exc:
        return JSONResponse(
            status_code=502,
            content=ApiResponse(
                success=False,
                message=f"Could not query BigFix fleet data: {exc}",
            ).model_dump(mode="json"),
        )


async def _count_by_relevance(bigfix: BigFixClient, relevance: str) -> int:
    """Execute a BigFix relevance query that returns a single integer."""
    import urllib.parse
    from xml.etree import ElementTree as ET

    encoded = urllib.parse.quote(relevance, safe="")
    url = f"{bigfix._base_url}/api/query?relevance={encoded}"
    try:
        response = await bigfix._http.get(url)
        response.raise_for_status()
        root = ET.fromstring(response.text)
        answer = root.find(".//Answer")
        if answer is not None and answer.text:
            return int(answer.text.strip())
    except Exception:
        pass
    return 0


# ---------------------------------------------------------------------------
# Device inventory endpoint
# ---------------------------------------------------------------------------

@app.get(
    "/api/inventory/{pc_name}",
    response_model=ApiResponse,
    summary="Get USB device inventory for a PC",
    responses={
        200: {"description": "Device inventory retrieved"},
        404: {"description": "Computer not found in BigFix"},
    },
)
async def device_inventory(pc_name: str, request: Request) -> JSONResponse:
    """
    Query the USB device inventory and USBGuard layer status for a given PC
    via BigFix relevance.

    Requires role: readonly, approver, or admin.
    """
    _require_role(request, ROLE_READONLY, ROLE_APPROVER, ROLE_ADMIN)

    api_key = request.headers.get("X-API-Key", "")
    if not _check_rate_limit(api_key, is_write=False):
        return JSONResponse(status_code=429, content={"success": False, "message": "Rate limit exceeded."})

    bigfix: BigFixClient = request.app.state.bigfix

    if not await bigfix.computer_exists(pc_name):
        return JSONResponse(
            status_code=404,
            content={"success": False, "message": f"Computer '{pc_name}' not found in BigFix."},
        )

    # Query layer status
    layers = {}
    layer_keys = {
        "L1_USBSTOR": ("HKEY_LOCAL_MACHINE\\\\SYSTEM\\\\CurrentControlSet\\\\Services\\\\USBSTOR", "Start"),
        "L2_WriteProtect": ("HKEY_LOCAL_MACHINE\\\\SYSTEM\\\\CurrentControlSet\\\\Control\\\\StorageDevicePolicies", "WriteProtect"),
        "L7_WpdFilesystemDriver": ("HKEY_LOCAL_MACHINE\\\\SYSTEM\\\\CurrentControlSet\\\\Services\\\\WpdFilesystemDriver", "Start"),
    }

    for label, (key_path, value_name) in layer_keys.items():
        raw = await bigfix._query_registry_value(pc_name, value_name)
        layers[label] = raw

    # Get exception status
    exception_status = await bigfix.get_exception_status(pc_name)

    return JSONResponse(
        status_code=200,
        content=ApiResponse(
            success=True,
            message="Device inventory retrieved.",
            data={
                "pc_name": pc_name,
                "layers": layers,
                "exception": exception_status.model_dump(mode="json"),
            },
        ).model_dump(mode="json"),
    )
