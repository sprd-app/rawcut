"""Storage management — media download, tier transitions, usage stats."""

from __future__ import annotations

import logging
from datetime import UTC, datetime, timedelta

import aiosqlite
from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Request, status
from pydantic import BaseModel

from app.config import settings
from app.models.database import get_db
from app.services.blob_storage import get_blob_url, move_to_cool_tier

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/storage", tags=["storage"])


# ---------------------------------------------------------------------------
# Response models
# ---------------------------------------------------------------------------


class DownloadURLResponse(BaseModel):
    """Signed download URL for a media asset."""

    url: str


class StorageUsageResponse(BaseModel):
    """Storage usage statistics for a user."""

    total_assets: int
    total_bytes: int
    video_bytes: int
    photo_bytes: int
    synced_count: int
    estimated_monthly_cost_usd: float
    icloud_200gb_monthly_usd: float = 2.99


class OptimizeResponse(BaseModel):
    """Response for storage optimization request."""

    status: str
    threshold_days: int


# ---------------------------------------------------------------------------
# Media download
# ---------------------------------------------------------------------------


@router.get("/media/{blob_name:path}/download", response_model=DownloadURLResponse)
async def get_media_download(
    blob_name: str,
    request: Request,
) -> dict[str, str]:
    """Get a signed download URL for an uploaded media asset.

    Verifies the requesting user owns the blob (blob_name starts with user_id/).
    """
    user_id: str = getattr(request.state, "user_id", "anonymous")

    if not blob_name.startswith(f"{user_id}/"):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Access denied",
        )

    url = await get_blob_url(blob_name)
    return {"url": url}


# ---------------------------------------------------------------------------
# Tier optimization
# ---------------------------------------------------------------------------


async def _transition_old_blobs_to_cool(user_id: str, days: int) -> int:
    """Move blobs older than `days` days to Azure Cool tier."""
    cutoff = (datetime.now(UTC) - timedelta(days=days)).isoformat()
    moved = 0

    async with aiosqlite.connect(settings.sqlite_path) as db:
        db.row_factory = aiosqlite.Row
        cursor = await db.execute(
            """
            SELECT id, blob_name FROM media_assets
            WHERE user_id = ?
              AND sync_status = 'complete'
              AND created_at < ?
            """,
            (user_id, cutoff),
        )
        rows = await cursor.fetchall()

    for row in rows:
        blob_name = dict(row)["blob_name"]
        try:
            await move_to_cool_tier(blob_name)
            moved += 1
            logger.info("Moved %s to Cool tier", blob_name)
        except Exception:
            logger.exception("Failed to move %s to Cool tier", blob_name)

    return moved


@router.post("/optimize", response_model=OptimizeResponse)
async def optimize_storage(
    request: Request,
    background_tasks: BackgroundTasks,
    days: int = 30,
) -> dict[str, str | int]:
    """Move blobs older than N days to Azure Cool tier to save costs."""
    user_id: str = getattr(request.state, "user_id", "anonymous")
    background_tasks.add_task(_transition_old_blobs_to_cool, user_id, days)
    return {"status": "optimization started", "threshold_days": days}


# ---------------------------------------------------------------------------
# Usage stats
# ---------------------------------------------------------------------------


@router.get("/usage", response_model=StorageUsageResponse)
async def storage_usage(
    request: Request,
    db: aiosqlite.Connection = Depends(get_db),
) -> dict[str, int | float]:
    """Get storage usage stats for the current user."""
    user_id: str = getattr(request.state, "user_id", "anonymous")

    cursor = await db.execute(
        """
        SELECT
            COUNT(*) as total_assets,
            COALESCE(SUM(file_size), 0) as total_bytes,
            COALESCE(SUM(CASE WHEN media_type = 'video' THEN file_size ELSE 0 END), 0) as video_bytes,
            COALESCE(SUM(CASE WHEN media_type = 'image' THEN file_size ELSE 0 END), 0) as photo_bytes,
            COUNT(CASE WHEN sync_status = 'complete' THEN 1 END) as synced_count
        FROM media_assets
        WHERE user_id = ?
        """,
        (user_id,),
    )
    row = await cursor.fetchone()
    stats = dict(row) if row else {}

    total_gb = stats.get("total_bytes", 0) / (1024 ** 3)
    stats["estimated_monthly_cost_usd"] = round(total_gb * 0.0184, 2)
    stats["icloud_200gb_monthly_usd"] = 2.99

    return stats
