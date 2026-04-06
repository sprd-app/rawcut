"""Resumable chunked upload for large files (especially video).

Protocol:
1. POST /api/upload/chunked/init  → returns upload_id
2. PUT  /api/upload/chunked/{upload_id}/{chunk_index}  → uploads one chunk
3. POST /api/upload/chunked/{upload_id}/commit  → commits all chunks as a blob

The client can resume by re-uploading only the missing chunks.
Each chunk is staged as an Azure Block Blob block.
"""

from __future__ import annotations

import asyncio
import hashlib
import logging
import time
import uuid
from datetime import UTC

import aiosqlite
from fastapi import APIRouter, BackgroundTasks, HTTPException, Request, status
from pydantic import BaseModel

from app.config import settings
from app.services import blob_storage
from app.services.auto_tagger import analyze_asset
from app.services.blob_storage import get_blob_url

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/upload/chunked", tags=["chunked-upload"])

# In-memory tracking of active chunked uploads (per-process).
# For multi-process deployments, replace with Redis or DB.
_active_uploads: dict[str, dict] = {}


class InitUploadRequest(BaseModel):
    filename: str
    file_size: int
    media_type: str  # "video", "image"
    content_type: str = "application/octet-stream"
    chunk_size: int = 5_242_880  # 5 MB default
    local_identifier: str | None = None
    content_hash: str | None = None


class InitUploadResponse(BaseModel):
    upload_id: str
    blob_name: str
    chunk_size: int
    total_chunks: int


class ChunkUploadResponse(BaseModel):
    chunk_index: int
    received: bool


class CommitResponse(BaseModel):
    blob_name: str
    size: int
    asset_id: str


class UploadStatusResponse(BaseModel):
    upload_id: str
    blob_name: str
    total_chunks: int
    received_chunks: list[int]
    is_complete: bool


# ---------------------------------------------------------------------------
# Init
# ---------------------------------------------------------------------------


@router.post("/init", response_model=InitUploadResponse)
async def init_chunked_upload(
    body: InitUploadRequest,
    request: Request,
) -> dict:
    """Initialize a resumable chunked upload session."""
    user_id: str = getattr(request.state, "user_id", "anonymous")

    # Deduplicate: check if a file with same content hash already exists
    if body.content_hash:
        async with aiosqlite.connect(settings.sqlite_path) as db:
            db.row_factory = aiosqlite.Row
            cursor = await db.execute(
                "SELECT blob_name FROM media_assets"
                " WHERE user_id = ? AND content_hash = ?"
                " AND sync_status = 'complete' LIMIT 1",
                (user_id, body.content_hash),
            )
            existing = await cursor.fetchone()
            if existing:
                # Return existing blob — client can skip all chunks
                return {
                    "upload_id": "dedup",
                    "blob_name": dict(existing)["blob_name"],
                    "chunk_size": body.chunk_size,
                    "total_chunks": 0,
                }

    extension = body.filename.rsplit(".", maxsplit=1)[-1] if "." in body.filename else "bin"
    blob_name = f"{user_id}/{uuid.uuid4().hex}.{extension}"
    upload_id = uuid.uuid4().hex
    total_chunks = max(1, -(-body.file_size // body.chunk_size))  # ceil division

    _active_uploads[upload_id] = {
        "user_id": user_id,
        "blob_name": blob_name,
        "content_type": body.content_type,
        "media_type": body.media_type,
        "file_size": body.file_size,
        "chunk_size": body.chunk_size,
        "total_chunks": total_chunks,
        "received_chunks": set(),
        "total_received_bytes": 0,
        "created_at": time.time(),
        "local_identifier": body.local_identifier,
        "content_hash": body.content_hash,
        "hasher": hashlib.sha256(),
    }

    return {
        "upload_id": upload_id,
        "blob_name": blob_name,
        "chunk_size": body.chunk_size,
        "total_chunks": total_chunks,
    }


# ---------------------------------------------------------------------------
# Upload chunk
# ---------------------------------------------------------------------------


@router.put("/{upload_id}/{chunk_index}", response_model=ChunkUploadResponse)
async def upload_chunk(
    upload_id: str,
    chunk_index: int,
    request: Request,
) -> dict:
    """Upload a single chunk. Can be retried safely (idempotent per block_id)."""
    session = _active_uploads.get(upload_id)
    if not session:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Upload session not found",
        )

    user_id: str = getattr(request.state, "user_id", "anonymous")
    if session["user_id"] != user_id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Access denied")

    if chunk_index >= session["total_chunks"]:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Chunk index out of range",
        )

    # Read chunk body
    body = await request.body()
    if not body:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Empty chunk body")

    # Stage as Azure Block Blob block
    blob_name = session["blob_name"]
    block_id = f"{chunk_index:06d}"

    try:
        await blob_storage.stage_block(blob_name, block_id, body)
    except Exception as exc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Failed to stage block: {exc}",
        ) from exc

    is_new_chunk = chunk_index not in session["received_chunks"]
    session["received_chunks"].add(chunk_index)
    if is_new_chunk:
        session["total_received_bytes"] += len(body)
        # Feed into running hash — only on first receipt of each chunk.
        # Chunks must arrive in order for correct hash (iOS sends sequentially).
        session["hasher"].update(body)

    return {"chunk_index": chunk_index, "received": True}


# ---------------------------------------------------------------------------
# Status (for resumption)
# ---------------------------------------------------------------------------


@router.get("/{upload_id}/status", response_model=UploadStatusResponse)
async def get_upload_status(
    upload_id: str,
    request: Request,
) -> dict:
    """Get current upload status — which chunks have been received."""
    session = _active_uploads.get(upload_id)
    if not session:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Upload session not found",
        )

    return {
        "upload_id": upload_id,
        "blob_name": session["blob_name"],
        "total_chunks": session["total_chunks"],
        "received_chunks": sorted(session["received_chunks"]),
        "is_complete": len(session["received_chunks"]) == session["total_chunks"],
    }


# ---------------------------------------------------------------------------
# Commit
# ---------------------------------------------------------------------------


async def _tag_asset_background(asset_id: str, blob_name: str) -> None:
    """Run auto-tagger for a chunked upload asset."""
    try:
        blob_url = await get_blob_url(blob_name)
        tags = await analyze_asset(blob_name, blob_url)
        if tags is None:
            return
        import json
        from datetime import datetime
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
                    datetime.now(UTC).isoformat(),
                    asset_id,
                ),
            )
            await db.commit()
        logger.info("Auto-tagged chunked asset %s", asset_id)
    except Exception:
        logger.exception("Auto-tagging failed for chunked asset %s", asset_id)


async def _populate_duration_background(asset_id: str, blob_name: str) -> None:
    """Extract video duration via ffprobe."""
    try:
        import json as _json
        import subprocess as _sp

        blob_url = await get_blob_url(blob_name)
        proc = await asyncio.create_subprocess_exec(
            "ffprobe", "-v", "quiet",
            "-print_format", "json",
            "-show_format", blob_url,
            stdout=asyncio.subprocess.PIPE,
            stderr=_sp.DEVNULL,
        )
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=30.0)
        data = _json.loads(stdout.decode())
        duration = float(data["format"]["duration"])

        async with aiosqlite.connect(settings.sqlite_path) as db:
            await db.execute(
                "UPDATE media_assets SET duration = ? WHERE id = ?",
                (duration, asset_id),
            )
            await db.commit()
        logger.info("Duration for chunked asset %s: %.1fs", asset_id, duration)
    except Exception:
        logger.exception("Failed to get duration for chunked asset %s", asset_id)


@router.post("/{upload_id}/commit", response_model=CommitResponse)
async def commit_chunked_upload(
    upload_id: str,
    request: Request,
    background_tasks: BackgroundTasks,
) -> dict:
    """Commit all uploaded chunks as a single blob."""
    session = _active_uploads.get(upload_id)
    if not session:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Upload session not found",
        )

    user_id: str = getattr(request.state, "user_id", "anonymous")
    if session["user_id"] != user_id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Access denied")

    # Verify all chunks are present
    if len(session["received_chunks"]) != session["total_chunks"]:
        missing = set(range(session["total_chunks"])) - session["received_chunks"]
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Missing chunks: {sorted(missing)}",
        )

    blob_name = session["blob_name"]
    block_ids = [f"{i:06d}" for i in range(session["total_chunks"])]

    # Verify content hash before committing
    server_hash = session["hasher"].hexdigest()
    client_hash = session.get("content_hash")
    if client_hash and server_hash != client_hash:
        logger.error(
            "Chunked upload hash mismatch for %s: client=%s server=%s",
            blob_name, client_hash, server_hash,
        )
        del _active_uploads[upload_id]
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"Content hash mismatch: expected {client_hash}, got {server_hash}",
        )

    content_hash = client_hash or server_hash

    try:
        await blob_storage.commit_block_list(blob_name, block_ids, session["content_type"])
    except Exception as exc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Failed to commit blob: {exc}",
        ) from exc

    # Register asset in DB
    asset_id = str(uuid.uuid4())
    try:
        async with aiosqlite.connect(settings.sqlite_path) as db:
            await db.execute(
                """
                INSERT OR IGNORE INTO media_assets
                    (id, user_id, blob_name, file_size, media_type, sync_status, content_hash)
                VALUES (?, ?, ?, ?, ?, 'complete', ?)
                """,
                (asset_id, user_id, blob_name, session["total_received_bytes"],
                 session["media_type"], content_hash),
            )
            await db.commit()
    except Exception:
        logger.exception("Failed to register chunked asset %s in DB", asset_id)

    # Background tasks
    background_tasks.add_task(_tag_asset_background, asset_id, blob_name)
    if session["media_type"] == "video":
        background_tasks.add_task(_populate_duration_background, asset_id, blob_name)

    # Cleanup
    del _active_uploads[upload_id]

    return {
        "blob_name": blob_name,
        "size": session["total_received_bytes"],
        "asset_id": asset_id,
    }
