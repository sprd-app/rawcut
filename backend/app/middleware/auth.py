"""Apple ID token verification middleware."""

from __future__ import annotations

import time
from typing import Any

import httpx
from fastapi import HTTPException, Request, status
from jose import JWTError, jwt
from starlette.middleware.base import BaseHTTPMiddleware, RequestResponseEndpoint
from starlette.responses import Response

from app.config import settings

# Apple's public key endpoint
APPLE_KEYS_URL = "https://appleid.apple.com/auth/keys"
APPLE_ISSUER = "https://appleid.apple.com"

# Cached JWKS to avoid fetching on every request
_jwks_cache: dict[str, Any] = {"keys": [], "fetched_at": 0.0}
_CACHE_TTL_SECONDS = 3600  # re-fetch every hour


async def _get_apple_public_keys() -> list[dict[str, Any]]:
    """Fetch and cache Apple's public JWKS keys."""
    now = time.monotonic()
    if _jwks_cache["keys"] and (now - _jwks_cache["fetched_at"]) < _CACHE_TTL_SECONDS:
        return _jwks_cache["keys"]  # type: ignore[return-value]

    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.get(APPLE_KEYS_URL)
        resp.raise_for_status()
        jwks = resp.json()

    _jwks_cache["keys"] = jwks.get("keys", [])
    _jwks_cache["fetched_at"] = now
    return _jwks_cache["keys"]  # type: ignore[return-value]


def _find_matching_key(keys: list[dict[str, Any]], kid: str) -> dict[str, Any]:
    """Find the JWK that matches the key-id in the token header."""
    for key in keys:
        if key.get("kid") == kid:
            return key
    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="No matching Apple public key for kid",
    )


async def verify_apple_token(token: str) -> dict[str, Any]:
    """Verify an Apple Sign-In identity token and return its claims.

    Raises HTTPException on any validation failure.
    """
    try:
        unverified_header = jwt.get_unverified_header(token)
    except JWTError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=f"Invalid token header: {exc}",
        ) from exc

    kid = unverified_header.get("kid", "")
    keys = await _get_apple_public_keys()
    key = _find_matching_key(keys, kid)

    try:
        claims: dict[str, Any] = jwt.decode(
            token,
            key,
            algorithms=["RS256"],
            issuer=APPLE_ISSUER,
            options={"verify_aud": False},  # audience varies per client
        )
    except JWTError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=f"Token verification failed: {exc}",
        ) from exc

    return claims


# Paths that skip authentication
_PUBLIC_PATHS: set[str] = {"/health", "/docs", "/openapi.json", "/redoc"}


class AppleAuthMiddleware(BaseHTTPMiddleware):
    """Starlette middleware that enforces Apple ID token auth.

    Attaches ``request.state.user_id`` for downstream handlers.
    """

    async def dispatch(
        self, request: Request, call_next: RequestResponseEndpoint
    ) -> Response:
        """Verify the Bearer token on non-public routes."""
        if request.method == "OPTIONS" or request.url.path in _PUBLIC_PATHS:
            return await call_next(request)

        auth_header = request.headers.get("Authorization", "")
        if not auth_header.startswith("Bearer "):
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Missing Bearer token",
            )

        token = auth_header.removeprefix("Bearer ").strip()
        claims = await verify_apple_token(token)

        # Apple's subject claim is the stable user identifier
        request.state.user_id = claims.get("sub", "")
        return await call_next(request)
