"""Render job endpoints for the cinematic pipeline."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime
from typing import Any

import aiosqlite
from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Request, status
from pydantic import BaseModel, Field

from app.models.database import get_db
from app.services.render_service import render_project
from app.services.blob_storage import get_blob_url

router = APIRouter(prefix="/api", tags=["renders"])


# ---------------------------------------------------------------------------
# Request / response models
# ---------------------------------------------------------------------------


class RenderRequest(BaseModel):
    """Payload to start a render."""

    preset: str = Field(default="warm_film", pattern=r"^(warm_film|cool_minimal|natural_vivid)$")
    aspect_ratio: str = Field(default="2.0", pattern=r"^(16:9|2\.0|2\.39)$")


class RenderResponse(BaseModel):
    """API representation of a render job."""

    id: str
    project_id: str
    user_id: str
    status: str
    preset: str
    aspect_ratio: str
    progress: float
    output_blob: str | None
    error: str | None
    created_at: str
    completed_at: str | None


class DownloadResponse(BaseModel):
    """Download URL for a completed render."""

    url: str


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _row_to_dict(row: aiosqlite.Row) -> dict[str, Any]:
    return dict(row)


async def _verify_project_ownership(
    project_id: str, user_id: str, db: aiosqlite.Connection,
) -> None:
    cursor = await db.execute(
        "SELECT id FROM projects WHERE id = ? AND user_id = ?",
        (project_id, user_id),
    )
    if await cursor.fetchone() is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Project not found")


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@router.post(
    "/projects/{project_id}/render",
    response_model=RenderResponse,
    status_code=status.HTTP_201_CREATED,
)
async def start_render(
    project_id: str,
    body: RenderRequest,
    request: Request,
    background_tasks: BackgroundTasks,
    db: aiosqlite.Connection = Depends(get_db),
) -> dict[str, Any]:
    """Start a cinematic render for a project."""
    user_id: str = getattr(request.state, "user_id", "anonymous")
    await _verify_project_ownership(project_id, user_id, db)

    # Check project has clips
    cursor = await db.execute(
        "SELECT COUNT(*) as cnt FROM project_clips WHERE project_id = ?",
        (project_id,),
    )
    row = await cursor.fetchone()
    if row is None or dict(row)["cnt"] == 0:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Project has no clips. Add clips before rendering.",
        )

    render_id = uuid.uuid4().hex
    now = datetime.now(UTC).isoformat()

    await db.execute(
        """INSERT INTO renders (id, project_id, user_id, status, preset, aspect_ratio, progress, created_at)
           VALUES (?, ?, ?, 'queued', ?, ?, 0.0, ?)""",
        (render_id, project_id, user_id, body.preset, body.aspect_ratio, now),
    )
    await db.commit()

    # Launch background render
    background_tasks.add_task(
        render_project, render_id, project_id, user_id, body.preset, body.aspect_ratio,
    )

    return {
        "id": render_id,
        "project_id": project_id,
        "user_id": user_id,
        "status": "queued",
        "preset": body.preset,
        "aspect_ratio": body.aspect_ratio,
        "progress": 0.0,
        "output_blob": None,
        "error": None,
        "created_at": now,
        "completed_at": None,
    }


@router.get("/renders/{render_id}", response_model=RenderResponse)
async def get_render(
    render_id: str,
    request: Request,
    db: aiosqlite.Connection = Depends(get_db),
) -> dict[str, Any]:
    """Get render job status and progress."""
    user_id: str = getattr(request.state, "user_id", "anonymous")
    cursor = await db.execute(
        "SELECT * FROM renders WHERE id = ? AND user_id = ?",
        (render_id, user_id),
    )
    row = await cursor.fetchone()
    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Render not found")
    return _row_to_dict(row)


@router.get("/renders/{render_id}/download", response_model=DownloadResponse)
async def get_render_download(
    render_id: str,
    request: Request,
    db: aiosqlite.Connection = Depends(get_db),
) -> dict[str, str]:
    """Get a download URL for a completed render."""
    user_id: str = getattr(request.state, "user_id", "anonymous")
    cursor = await db.execute(
        "SELECT * FROM renders WHERE id = ? AND user_id = ?",
        (render_id, user_id),
    )
    row = await cursor.fetchone()
    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Render not found")

    render = _row_to_dict(row)
    if render["status"] != "complete" or not render["output_blob"]:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Render is not complete yet",
        )

    url = await get_blob_url(render["output_blob"])
    return {"url": url}


@router.get("/projects/{project_id}/renders", response_model=list[RenderResponse])
async def list_project_renders(
    project_id: str,
    request: Request,
    db: aiosqlite.Connection = Depends(get_db),
) -> list[dict[str, Any]]:
    """List all renders for a project."""
    user_id: str = getattr(request.state, "user_id", "anonymous")
    await _verify_project_ownership(project_id, user_id, db)

    cursor = await db.execute(
        "SELECT * FROM renders WHERE project_id = ? AND user_id = ? ORDER BY created_at DESC",
        (project_id, user_id),
    )
    rows = await cursor.fetchall()
    return [_row_to_dict(r) for r in rows]
