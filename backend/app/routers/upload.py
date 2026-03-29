"""Zero-copy streaming upload endpoint."""

from __future__ import annotations

import asyncio
import uuid
from typing import AsyncIterator

from fastapi import APIRouter, HTTPException, Request, status

from app.services import blob_storage

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


@router.post("/stream")
async def stream_upload(request: Request) -> dict[str, str | int]:
    """Stream an uploaded file directly to Azure Blob Storage.

    Uses ``request.stream()`` so the full file is never buffered in
    application memory.  Each chunk is staged as a separate block and then
    committed as a single blob.

    Concurrency is limited to **one active upload per user**.

    Headers:
        - ``Content-Type``: MIME type of the uploaded file.
        - ``X-Filename``: (optional) Original filename hint.

    Returns:
        Blob metadata including ``blob_name`` and ``size``.
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

    return result
