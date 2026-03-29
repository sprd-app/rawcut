"""Zero-copy streaming upload endpoint."""

from __future__ import annotations

import asyncio
import logging
import uuid
from typing import AsyncIterator

import aiosqlite
from fastapi import APIRouter, BackgroundTasks, HTTPException, Request, status

from app.config import settings
from app.services import blob_storage
from app.services.auto_tagger import analyze_asset
from app.services.blob_storage import get_blob_url

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/upload", tags=["upload"])

# Per-user concurrency gate: only one active upload at a time
_user_locks: dict[str, asyncio.Lock] = {}


def _get_user_lock(user_id: str) -> asyncio.Lock:
    """Return (or create) the upload lock for a given user."""
    if user_id not in _user_locks:
        _user_locks[user_id] = asyncio.Lock()
    return _user_locks[user_id]


async def _request_body_chunks(request: Request) -> AsyncIterator[bytes]:
    """Yield raw body chunks from the incoming request stream."""
    async for chunk in request.stream():
        yield chunk


def _media_type_from_content_type(content_type: str) -> str:
    """Derive a media_type string from a MIME type."""
    ct = content_type.lower()
    if ct.startswith("video/"):
        return "video"
    if ct.startswith("audio/"):
        return "audio"
    return "image"


async def _tag_asset_background(asset_id: str, blob_name: str) -> None:
    """Run auto-tagger for a single asset and persist the results."""
    try:
        blob_url = await get_blob_url(blob_name)
        tags = await analyze_asset(blob_name, blob_url)
        if tags is None:
            return
        import json
        from datetime import datetime, timezone
        async with aiosqlite.connect(settings.sqlite_path) as db:
            await db.execute(
                """
                UPDATE media_assets
                SET content_type = ?,
                    quality_score = ?,
                    energy_level = ?,
                    emotion = ?,
                    description = ?,
                    tags = ?,
                    tagged_at = ?
                WHERE id = ?
                """,
                (
                    tags.content_type.value if tags.content_type else None,
                    tags.quality_score,
                    tags.energy_level,
                    tags.emotion.value if tags.emotion else None,
                    tags.description,
                    json.dumps(tags.tags),
                    datetime.now(timezone.utc).isoformat(),
                    asset_id,
                ),
            )
            await db.commit()
        logger.info("Auto-tagged asset %s", asset_id)
    except Exception:
        logger.exception("Auto-tagging failed for asset %s", asset_id)


@router.post("/stream")
async def stream_upload(
    request: Request,
    background_tasks: BackgroundTasks,
) -> dict[str, str | int]:
    """Stream an uploaded file directly to Azure Blob Storage.

    Uses ``request.stream()`` so the full file is never buffered in
    application memory.  Each chunk is staged as a separate block and then
    committed as a single blob.

    Concurrency is limited to **one active upload per user**.

    Headers:
        - ``Content-Type``: MIME type of the uploaded file.
        - ``X-Filename``: (optional) Original filename hint.

    Returns:
        Blob metadata including ``blob_name``, ``size``, and ``asset_id``.
    """
    user_id: str = getattr(request.state, "user_id", "anonymous")

    lock = _get_user_lock(user_id)
    if lock.locked():
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="An upload is already in progress for this user",
        )

    content_type = request.headers.get("content-type", "application/octet-stream")
    filename_hint = request.headers.get("x-filename", "upload")
    extension = filename_hint.rsplit(".", maxsplit=1)[-1] if "." in filename_hint else "bin"
    blob_name = f"{user_id}/{uuid.uuid4().hex}.{extension}"
    media_type = _media_type_from_content_type(content_type)

    async with lock:
        try:
            result = await blob_storage.upload_stream(
                blob_name=blob_name,
                data_stream=_request_body_chunks(request),
                content_type=content_type,
            )
        except Exception as exc:
            raise HTTPException(
                status_code=status.HTTP_502_BAD_GATEWAY,
                detail=f"Blob upload failed: {exc}",
            ) from exc

    # Register asset in DB
    asset_id = str(uuid.uuid4())
    try:
        async with aiosqlite.connect(settings.sqlite_path) as db:
            await db.execute(
                """
                INSERT OR IGNORE INTO media_assets
                    (id, user_id, blob_name, file_size, media_type, sync_status)
                VALUES (?, ?, ?, ?, ?, 'complete')
                """,
                (asset_id, user_id, blob_name, result.get("size", 0), media_type),
            )
            await db.commit()
    except Exception:
        logger.exception("Failed to register asset %s in DB", asset_id)

    # Trigger auto-tagging in background
    background_tasks.add_task(_tag_asset_background, asset_id, blob_name)

    return {**result, "asset_id": asset_id}
