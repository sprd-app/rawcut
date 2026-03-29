"""One-tap auto-video endpoint."""

from __future__ import annotations

import logging
from typing import Any

from fastapi import APIRouter, BackgroundTasks, HTTPException, Request, status
from pydantic import BaseModel, Field

from app.services.auto_video_service import create_auto_video
from app.services.render_service import render_project

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["auto-video"])


class AutoVideoRequest(BaseModel):
    """Request body for one-tap auto-video."""

    timezone_offset: int = Field(
        ...,
        description="Seconds from GMT (e.g., KST = +32400). iOS: TimeZone.current.secondsFromGMT()",
    )
    preset: str = Field(default="warm_film", pattern=r"^(warm_film|cool_minimal|natural_vivid)$")
    aspect_ratio: str = Field(default="2.0", pattern=r"^(16:9|2\.0|2\.39)$")


class AutoVideoResponse(BaseModel):
    """Response for auto-video creation."""

    project_id: str
    render_id: str
    title: str
    clip_count: int
    estimated_seconds: int
    is_existing: bool
    preset: str
    aspect_ratio: str


@router.post(
    "/auto-video",
    response_model=AutoVideoResponse,
    status_code=status.HTTP_201_CREATED,
)
async def auto_video(
    body: AutoVideoRequest,
    request: Request,
    background_tasks: BackgroundTasks,
) -> dict[str, Any]:
    """Create a one-tap auto-video from today's clips.

    Queries today's tagged video clips, computes smart trims,
    creates an auto project, and starts a cinematic render.
    """
    user_id: str = getattr(request.state, "user_id", "anonymous")

    try:
        result = await create_auto_video(
            user_id=user_id,
            timezone_offset=body.timezone_offset,
            preset=body.preset,
            aspect_ratio=body.aspect_ratio,
        )
    except ValueError as exc:
        msg = str(exc)
        if msg.startswith("TAGGING_PENDING:"):
            parts = msg.split(":")
            tagged = int(parts[1])
            pending = int(parts[2])
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"태깅이 완료될 때까지 잠시 기다려주세요. ({tagged}개 완료, {pending}개 대기 중)",
            ) from exc
        if msg.startswith("NOT_ENOUGH_CLIPS:"):
            count = int(msg.split(":")[1])
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"촬영을 더 해주세요. 최소 3개의 동영상이 필요합니다. (현재 {count}개)",
            ) from exc
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="서버 오류. 다시 시도해주세요.",
        ) from exc

    # If existing active render, return with 200 (not 201)
    if result["is_existing"]:
        return result  # FastAPI will use 201 but the is_existing flag tells iOS

    # Start render in background
    background_tasks.add_task(
        render_project,
        result["render_id"],
        result["project_id"],
        user_id,
        body.preset,
        body.aspect_ratio,
    )

    logger.info(
        "Auto-video created: project=%s render=%s clips=%d est=%ds",
        result["project_id"],
        result["render_id"],
        result["clip_count"],
        result["estimated_seconds"],
    )

    return result
