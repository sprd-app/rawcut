"""Auto-tagging API endpoints."""

from __future__ import annotations

import json
import logging
from datetime import datetime

import aiosqlite
from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Request, status
from pydantic import BaseModel

from app.models.database import get_db
from app.services.auto_tagger import AssetTags, analyze_asset, analyze_batch
from app.services.blob_storage import get_blob_url

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/assets", tags=["tagging"])


# ---------------------------------------------------------------------------
# Response models
# ---------------------------------------------------------------------------


class TagResponse(BaseModel):
    """Tags for a single asset."""

    asset_id: str
    content_type: str | None = None
    quality_score: float | None = None
    energy_level: float | None = None
    emotion: str | None = None
    description: str | None = None
    tagged_at: str | None = None


class BatchTagResponse(BaseModel):
    """Response for batch tagging request."""

    message: str
    queued_count: int


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


async def _save_tags(db: aiosqlite.Connection, asset_id: str, tags: AssetTags) -> None:
    """Persist tags to the media_assets table."""
    await db.execute(
        """
        UPDATE media_assets
        SET content_type = ?,
            quality_score = ?,
            energy_level = ?,
            emotion = ?,
            description = ?,
            tagged_at = ?
        WHERE id = ?
        """,
        (
            tags.content_type.value,
            tags.quality_score,
            tags.energy_level,
            tags.emotion.value,
            tags.description,
            datetime.utcnow().isoformat(),
            asset_id,
        ),
    )
    await db.commit()


async def _tag_single_asset(asset_id: str, blob_name: str) -> None:
    """Run tagging for a single asset (used as background task)."""
    from app.config import settings as _settings
    try:
        blob_url = await get_blob_url(blob_name)
        tags = await analyze_asset(blob_name, blob_url)
        if tags:
            async with aiosqlite.connect(_settings.sqlite_path) as db:
                await _save_tags(db, asset_id, tags)
            logger.info("Tagged asset %s: %s", asset_id, tags.content_type)
        else:
            logger.warning("Tagging returned no result for asset %s", asset_id)
    except Exception:
        logger.exception("Failed to tag asset %s", asset_id)


async def _tag_batch(user_id: str) -> None:
    """Tag all untagged assets for a user (background task)."""
    from app.config import settings as _settings
    try:
        async with aiosqlite.connect(_settings.sqlite_path) as db:
            db.row_factory = aiosqlite.Row
            async with db.execute(
                """
                SELECT id, blob_name FROM media_assets
                WHERE user_id = ?
                  AND tagged_at IS NULL
                  AND sync_status = 'complete'
                ORDER BY created_at DESC
                """,
                (user_id,),
            ) as cursor:
                rows = await cursor.fetchall()

        if not rows:
            logger.info("No untagged assets for user %s", user_id)
            return

        assets = []
        for row in rows:
            blob_url = await get_blob_url(row["blob_name"])
            assets.append({
                "id": row["id"],
                "blob_name": row["blob_name"],
                "blob_url": blob_url,
            })

        results = await analyze_batch(assets)

        async with aiosqlite.connect(_settings.sqlite_path) as db:
            for asset_id, tags in results.items():
                if tags:
                    await _save_tags(db, asset_id, tags)

        tagged = sum(1 for t in results.values() if t is not None)
        logger.info("Batch tagging complete for user %s: %d/%d tagged", user_id, tagged, len(rows))

    except Exception:
        logger.exception("Batch tagging failed for user %s", user_id)


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


@router.post("/{asset_id}/tag", response_model=TagResponse)
async def tag_asset(
    asset_id: str,
    request: Request,
    background_tasks: BackgroundTasks,
    db: aiosqlite.Connection = Depends(get_db),
) -> TagResponse:
    """Trigger auto-tagging for a single asset.

    Queues the tagging as a background task and returns immediately.
    """
    user_id: str = getattr(request.state, "user_id", "anonymous")

    async with db.execute(
        "SELECT id, blob_name, tagged_at FROM media_assets WHERE id = ? AND user_id = ?",
        (asset_id, user_id),
    ) as cursor:
        row = await cursor.fetchone()

    if not row:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Asset not found")

    background_tasks.add_task(_tag_single_asset, asset_id, row["blob_name"])

    return TagResponse(
        asset_id=asset_id,
        tagged_at=row["tagged_at"],
    )


@router.post("/tag-batch", response_model=BatchTagResponse)
async def tag_batch(
    request: Request,
    background_tasks: BackgroundTasks,
    db: aiosqlite.Connection = Depends(get_db),
) -> BatchTagResponse:
    """Trigger auto-tagging for all untagged assets (background).

    Queues a batch tagging job and returns the count of assets queued.
    """
    user_id: str = getattr(request.state, "user_id", "anonymous")

    async with db.execute(
        """
        SELECT COUNT(*) AS cnt FROM media_assets
        WHERE user_id = ?
          AND tagged_at IS NULL
          AND sync_status = 'complete'
        """,
        (user_id,),
    ) as cursor:
        row = await cursor.fetchone()

    count = row[0] if row else 0

    if count > 0:
        background_tasks.add_task(_tag_batch, user_id)

    return BatchTagResponse(
        message="Batch tagging queued" if count > 0 else "No untagged assets found",
        queued_count=count,
    )


@router.get("/{asset_id}/tags", response_model=TagResponse)
async def get_asset_tags(
    asset_id: str,
    request: Request,
    db: aiosqlite.Connection = Depends(get_db),
) -> TagResponse:
    """Get tags for an asset."""
    user_id: str = getattr(request.state, "user_id", "anonymous")

    async with db.execute(
        """
        SELECT id, content_type, quality_score, energy_level,
               emotion, description, tagged_at
        FROM media_assets
        WHERE id = ? AND user_id = ?
        """,
        (asset_id, user_id),
    ) as cursor:
        row = await cursor.fetchone()

    if not row:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Asset not found")

    return TagResponse(
        asset_id=row[0],
        content_type=row[1],
        quality_score=row[2],
        energy_level=row[3],
        emotion=row[4],
        description=row[5],
        tagged_at=row[6],
    )
