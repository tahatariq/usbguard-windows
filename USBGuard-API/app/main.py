"""
USBGuard API — FastAPI application entry point.

Routes:
    GET    /api/exceptions/{pc_name}  — Query current exception status
    POST   /api/exceptions            — Create a new USB access exception
    DELETE /api/exceptions/{pc_name}  — Revoke an existing exception
"""

import os
from contextlib import asynccontextmanager
from datetime import date, timedelta
from typing import Any

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse

from app.auth import ApiKeyMiddleware
from app.bigfix import BigFixClient
from app.config import load_settings
from app.date_parser import resolve_start_date
from app.models import ApiResponse, CreateExceptionRequest


# ---------------------------------------------------------------------------
# Lifespan — load config and build BigFix client at startup
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Load configuration and initialise the BigFix client on startup."""
    settings = load_settings()
    app.state.settings = settings
    app.state.bigfix = BigFixClient(
        server=settings.bigfix_server,
        port=settings.bigfix_port,
        username=settings.bigfix_username,
        password=settings.bigfix_password,
    )
    yield
    # Nothing to clean up — httpx uses per-request clients.


# ---------------------------------------------------------------------------
# Application factory
# ---------------------------------------------------------------------------

app = FastAPI(
    title="USBGuard API",
    description=(
        "Manages USB access exceptions on Windows endpoints via IBM BigFix. "
        "All endpoints require an X-API-Key header."
    ),
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(ApiKeyMiddleware)


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
                f"HTTP {exc.response.status_code} from {exc.request.url}. "
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
# Routes
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

    Queries the BigFix relevance API to read registry values written by the
    grant action.  If the computer is not enrolled in BigFix a 404 is returned.
    """
    bigfix: BigFixClient = request.app.state.bigfix

    if not bigfix.computer_exists(pc_name):
        return JSONResponse(
            status_code=404,
            content={
                "success": False,
                "message": f"Computer '{pc_name}' was not found in BigFix.",
            },
        )

    status = bigfix.get_exception_status(pc_name)

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

    The start date is parsed flexibly; if it is in the past or unparseable
    today's date is used and a warning is included in the response.
    """
    bigfix: BigFixClient = request.app.state.bigfix

    resolved_date, warning = resolve_start_date(body.start_date)

    if not bigfix.computer_exists(body.pc_name):
        return JSONResponse(
            status_code=422,
            content={
                "success": False,
                "message": (
                    f"Computer '{body.pc_name}' was not found in BigFix. "
                    "Verify the name and try again."
                ),
            },
        )

    action_id = bigfix.create_exception_action(
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
            f"Exception scheduled. BigFix will activate USB access on "
            f"{resolved_date.isoformat()} and the PC will be unblocked the next "
            f"time it checks in on or after that date (even if currently offline)."
        )
    else:
        message = "Exception created. USB access will be active on next BigFix agent check-in."

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

    The BigFix agent must be running and connected for the action to execute.
    USB will be re-blocked on the next agent check-in (typically within minutes
    if the machine is online).
    """
    bigfix: BigFixClient = request.app.state.bigfix

    if not bigfix.computer_exists(pc_name):
        return JSONResponse(
            status_code=404,
            content={
                "success": False,
                "message": f"Computer '{pc_name}' was not found in BigFix.",
            },
        )

    action_id = bigfix.revoke_exception_action(pc_name)

    return JSONResponse(
        status_code=200,
        content=ApiResponse(
            success=True,
            message=(
                "Exception revoked. USB access will be blocked on next BigFix "
                "baseline run (up to 4 hours)."
            ),
            data={"action_id": action_id, "pc_name": pc_name},
        ).model_dump(mode="json"),
    )
