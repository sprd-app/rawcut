"""Sync health API endpoint."""

from __future__ import annotations

from fastapi import APIRouter, Request

from app.services.sync_health import SyncHealth, get_sync_health

router = APIRouter(prefix="/api/sync", tags=["sync"])


@router.get("/health", response_model=SyncHealth)
async def sync_health(request: Request) -> SyncHealth:
    """Returns sync health metrics for the authenticated user.

    Includes: total/synced/failed/pending counts, success rate,
    sync lag, and alerts for high failure rates.
    """
    user_id: str = getattr(request.state, "user_id", "anonymous")
    return await get_sync_health(user_id)
