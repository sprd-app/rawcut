"""Chat-based vlog script generation endpoint."""

from __future__ import annotations

import logging
from typing import Any

import aiosqlite
from fastapi import APIRouter, HTTPException, Request, status
from pydantic import BaseModel, Field

from app.config import settings
from app.services.script_service import generate_script, get_script_suggestions

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/chat", tags=["chat"])


class ChatMessage(BaseModel):
    """A single chat message."""

    role: str = Field(pattern=r"^(user|assistant)$")
    content: str


class ChatRequest(BaseModel):
    """Request body for chat endpoint."""

    message: str = Field(min_length=1, max_length=2000)
    timezone_offset: int = 0
    history: list[ChatMessage] = []
    current_script: dict[str, Any] | None = None


class ChatResponse(BaseModel):
    """Response from chat endpoint."""

    script: dict[str, Any]
    suggestions: list[str] = []
    clip_count: int = 0


class SuggestionsResponse(BaseModel):
    """Quick suggestions based on available clips."""

    suggestions: list[str]
    clip_count: int


@router.post("", response_model=ChatResponse)
async def chat(body: ChatRequest, request: Request) -> dict[str, Any]:
    """Generate or update a vlog script via chat.

    Send a user message (intent or feedback) and get back a script.
    Include history and current_script for iterative refinement.
    """
    user_id: str = getattr(request.state, "user_id", "anonymous")

    # Get available clips
    clips = await _get_tagged_clips(user_id, body.timezone_offset)

    if not clips:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="No tagged clips available. Upload and sync footage first.",
        )

    # Convert history to list of dicts
    history = [{"role": m.role, "content": m.content} for m in body.history]

    try:
        script = await generate_script(
            user_message=body.message,
            clips=clips,
            conversation_history=history if history else None,
            current_script=body.current_script,
        )
    except ValueError as e:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=str(e),
        ) from e

    return {
        "script": script,
        "suggestions": [],
        "clip_count": len(clips),
    }


@router.get("/suggestions", response_model=SuggestionsResponse)
async def suggestions(request: Request, timezone_offset: int = 0) -> dict[str, Any]:
    """Get quick one-tap suggestions based on available clips."""
    user_id: str = getattr(request.state, "user_id", "anonymous")
    clips = await _get_tagged_clips(user_id, timezone_offset)

    return {
        "suggestions": get_script_suggestions(clips),
        "clip_count": len(clips),
    }


async def _get_tagged_clips(user_id: str, timezone_offset: int) -> list[dict[str, Any]]:
    """Query today's tagged video clips."""
    from datetime import UTC, datetime, timedelta

    now_utc = datetime.now(UTC)
    local_now = now_utc + timedelta(seconds=timezone_offset)
    local_midnight = local_now.replace(hour=0, minute=0, second=0, microsecond=0)
    utc_midnight = local_midnight - timedelta(seconds=timezone_offset)
    utc_midnight_str = utc_midnight.strftime("%Y-%m-%d %H:%M:%S")

    async with aiosqlite.connect(settings.sqlite_path) as db:
        db.row_factory = aiosqlite.Row
        cursor = await db.execute(
            """
            SELECT id, blob_name, content_type, quality_score, energy_level,
                   emotion, duration, description, media_type
            FROM media_assets
            WHERE user_id = ?
              AND created_at >= ?
              AND sync_status = 'complete'
              AND tagged_at IS NOT NULL
            ORDER BY created_at ASC
            """,
            (user_id, utc_midnight_str),
        )
        return [dict(r) for r in await cursor.fetchall()]
