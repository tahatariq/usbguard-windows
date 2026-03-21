"""
API key authentication middleware for the USBGuard API.

All routes are protected except Swagger UI, ReDoc, and OpenAPI schema paths.
Keys are validated against the list stored in app.state.settings.api_keys.
"""

import json
from typing import Callable

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.types import ASGIApp


# Paths that are exempt from API key authentication.
_PUBLIC_PREFIXES = ("/docs", "/openapi", "/redoc")


class ApiKeyMiddleware(BaseHTTPMiddleware):
    """
    Starlette middleware that enforces X-API-Key header authentication.

    Public paths (Swagger UI, ReDoc, OpenAPI JSON) bypass the check so that
    interactive documentation remains accessible without credentials.
    """

    def __init__(self, app: ASGIApp) -> None:
        super().__init__(app)

    async def dispatch(self, request: Request, call_next: Callable) -> Response:
        # Allow unauthenticated access to documentation endpoints.
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
        if api_key not in settings.api_keys:
            return JSONResponse(
                status_code=403,
                content={"success": False, "message": "Invalid API key."},
            )

        return await call_next(request)
