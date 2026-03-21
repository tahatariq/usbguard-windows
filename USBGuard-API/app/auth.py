"""
API key authentication middleware for the USBGuard API.

All routes are protected except health check, Swagger UI, ReDoc, and OpenAPI
schema paths.  Keys are validated against the list stored in
app.state.settings.api_keys using timing-safe comparison.
"""

import hmac
from typing import Callable

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.types import ASGIApp


# Paths that are exempt from API key authentication.
_PUBLIC_PREFIXES = ("/docs", "/openapi", "/redoc", "/api/health")


class ApiKeyMiddleware(BaseHTTPMiddleware):
    """
    Starlette middleware that enforces X-API-Key header authentication.

    Public paths (Swagger UI, ReDoc, OpenAPI JSON, health check) bypass the
    check so that interactive documentation and monitoring remain accessible
    without credentials.
    """

    def __init__(self, app: ASGIApp) -> None:
        super().__init__(app)

    async def dispatch(self, request: Request, call_next: Callable) -> Response:
        # Allow unauthenticated access to documentation and health endpoints.
        for prefix in _PUBLIC_PREFIXES:
            if request.url.path.startswith(prefix):
                return await call_next(request)

        api_key = request.headers.get("X-API-Key")

        if not api_key:
            return JSONResponse(
                status_code=401,
                content={"success": False, "message": "API key missing. Provide X-API-Key header."},
            )

        settings = request.app.state.settings

        # Resolve the role for the matched key.  Each key entry can be a plain
        # string (legacy, defaults to "admin" role) or a dict with "key" and
        # "role" fields.  Comparison is timing-safe to prevent key enumeration.
        matched_role = _match_api_key(api_key, settings.api_keys)
        if matched_role is None:
            return JSONResponse(
                status_code=403,
                content={"success": False, "message": "Invalid API key."},
            )

        # Attach resolved role to the request for downstream route handlers.
        request.state.role = matched_role
        return await call_next(request)


def _match_api_key(provided: str, api_keys: list) -> str | None:
    """
    Compare *provided* against every configured key using constant-time
    comparison.  Returns the role string on match, or ``None``.

    Each entry in *api_keys* is either:
    - a plain ``str`` (legacy format — treated as role ``"admin"``), or
    - a ``dict`` with ``"key"`` and ``"role"`` fields.
    """
    matched_role: str | None = None
    for entry in api_keys:
        if isinstance(entry, dict):
            candidate = entry.get("key", "")
            role = entry.get("role", "admin")
        else:
            candidate = str(entry)
            role = "admin"
        if hmac.compare_digest(provided, candidate):
            matched_role = role
            # Don't break — continue comparing all keys to keep timing constant.
    return matched_role
