"""Chat-based vlog editor API.

Supports 3-phase workflow:
  Phase 0: Script (text) — POST /api/chat
  Phase 1: Storyboard (images) — POST /api/chat/storyboard
  Phase 2: Render (video) — POST /api/projects/{id}/render (existing)
"""

from __future__ import annotations

import logging
from typing import Any

import aiosqlite
from fastapi import APIRouter, BackgroundTasks, HTTPException, Request, status
from pydantic import BaseModel, Field

from app.config import settings
from app.services.script_service import generate_script, get_script_suggestions

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/chat", tags=["chat"])


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------


class ChatMessage(BaseModel):
    role: str = Field(pattern=r"^(user|assistant)$")
    content: str


class ChatRequest(BaseModel):
    message: str = Field(min_length=1, max_length=2000)
    timezone_offset: int = 0
    history: list[ChatMessage] = []
    current_script: dict[str, Any] | None = None


class ChatResponse(BaseModel):
    script: dict[str, Any]
    message: str = ""
    action: str = "update"
    clip_count: int = 0


class StoryboardRequest(BaseModel):
    segments: list[dict[str, Any]]
    session_id: str = ""


class StoryboardResponse(BaseModel):
    segments: list[dict[str, Any]]


class SuggestionsResponse(BaseModel):
    suggestions: list[str]
    clip_count: int


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


async def _get_tagged_clips(user_id: str, timezone_offset: int) -> list[dict[str, Any]]:
    from datetime import UTC, datetime, timedelta

    now_utc = datetime.now(UTC)
    local_now = now_utc + timedelta(seconds=timezone_offset)
    local_midnight = local_now.replace(hour=0, minute=0, second=0, microsecond=0)
    utc_midnight = local_midnight - timedelta(seconds=timezone_offset)
    utc_midnight_str = utc_midnight.strftime("%Y-%m-%d %H:%M:%S")

    async with aiosqlite.connect(settings.sqlite_path) as db:
        db.row_factory = aiosqlite.Row
        cursor = await db.execute(
            """SELECT id, blob_name, content_type, quality_score, energy_level,
                      emotion, duration, description, transcript, media_type
               FROM media_assets
               WHERE user_id = ? AND created_at >= ?
                 AND sync_status = 'complete' AND tagged_at IS NOT NULL
               ORDER BY created_at ASC""",
            (user_id, utc_midnight_str),
        )
        return [dict(r) for r in await cursor.fetchall()]


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@router.post("", response_model=ChatResponse)
async def chat(body: ChatRequest, request: Request) -> dict[str, Any]:
    """Phase 0: Generate or update a vlog script via chat."""
    user_id: str = getattr(request.state, "user_id", "anonymous")
    clips = await _get_tagged_clips(user_id, body.timezone_offset)

    history = [{"role": m.role, "content": m.content} for m in body.history]

    try:
        script = await generate_script(
            user_message=body.message,
            clips=clips,
            conversation_history=history if history else None,
            current_script=body.current_script,
        )
    except ValueError as e:
        raise HTTPException(status_code=500, detail=str(e)) from e

    return {
        "script": script,
        "message": script.get("message", ""),
        "action": script.get("action", "update"),
        "clip_count": len(clips),
    }


@router.post("/storyboard", response_model=StoryboardResponse)
async def create_storyboard(
    body: StoryboardRequest,
    request: Request,
    background_tasks: BackgroundTasks,
) -> dict[str, Any]:
    """Phase 1: Generate storyboard images for each segment."""
    from app.services.storyboard_service import generate_storyboard

    user_id: str = getattr(request.state, "user_id", "anonymous")
    session_id = body.session_id or "default"

    results = await generate_storyboard(body.segments, user_id, session_id)
    return {"segments": results}


@router.get("/suggestions", response_model=SuggestionsResponse)
async def suggestions(request: Request, timezone_offset: int = 0) -> dict[str, Any]:
    user_id: str = getattr(request.state, "user_id", "anonymous")
    clips = await _get_tagged_clips(user_id, timezone_offset)
    return {
        "suggestions": get_script_suggestions(clips),
        "clip_count": len(clips),
    }
