"""CRUD endpoints for vlog projects (Phase 2 stub)."""

from __future__ import annotations

import uuid
from datetime import datetime, UTC
from typing import Any

import aiosqlite
from fastapi import APIRouter, Depends, HTTPException, Request, status
from pydantic import BaseModel, Field

from app.models.database import get_db

router = APIRouter(prefix="/api/projects", tags=["projects"])


# ---------------------------------------------------------------------------
# Request / response models
# ---------------------------------------------------------------------------

class ProjectCreate(BaseModel):
    """Payload for creating a new project."""

    title: str = Field(min_length=1, max_length=200)
    description: str = ""


class ProjectUpdate(BaseModel):
    """Payload for updating an existing project."""

    title: str | None = Field(default=None, min_length=1, max_length=200)
    description: str | None = None


class ProjectResponse(BaseModel):
    """API representation of a project."""

    id: str
    user_id: str
    title: str
    description: str
    created_at: str
    updated_at: str
    type: str = "manual"


class ClipItem(BaseModel):
    """A single clip in a project.

    Accepts either ``asset_id`` (backend UUID) or ``blob_name`` (Azure blob
    path).  When ``blob_name`` is provided, the server resolves it to the
    corresponding ``asset_id``.
    """

    asset_id: str | None = None
    blob_name: str | None = None
    position: int = 0
    trim_start: float = 0.0
    trim_end: float | None = None
    role: str = "auto"


class ClipListRequest(BaseModel):
    """Payload for setting a project's clip list."""

    clips: list[ClipItem]


class ClipResponse(BaseModel):
    """API representation of a project clip with asset metadata."""

    asset_id: str
    position: int
    trim_start: float
    trim_end: float | None
    role: str
    blob_name: str | None = None
    media_type: str | None = None
    content_type: str | None = None
    quality_score: float | None = None
    energy_level: float | None = None


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _row_to_dict(row: aiosqlite.Row) -> dict[str, Any]:
    """Convert an aiosqlite Row to a plain dict."""
    return dict(row)


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@router.get("", response_model=list[ProjectResponse])
async def list_projects(
    request: Request,
    db: aiosqlite.Connection = Depends(get_db),
) -> list[dict[str, Any]]:
    """List all projects belonging to the authenticated user."""
    user_id: str = getattr(request.state, "user_id", "anonymous")
    cursor = await db.execute(
        "SELECT * FROM projects WHERE user_id = ? ORDER BY updated_at DESC",
        (user_id,),
    )
    rows = await cursor.fetchall()
    return [_row_to_dict(r) for r in rows]


@router.post("", response_model=ProjectResponse, status_code=status.HTTP_201_CREATED)
async def create_project(
    body: ProjectCreate,
    request: Request,
    db: aiosqlite.Connection = Depends(get_db),
) -> dict[str, Any]:
    """Create a new vlog project."""
    user_id: str = getattr(request.state, "user_id", "anonymous")
    project_id = uuid.uuid4().hex
    now = datetime.now(UTC).isoformat()

    await db.execute(
        "INSERT INTO projects (id, user_id, title, description, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (project_id, user_id, body.title, body.description, now, now),
    )
    await db.commit()

    return {
        "id": project_id,
        "user_id": user_id,
        "title": body.title,
        "description": body.description,
        "created_at": now,
        "updated_at": now,
    }


@router.get("/{project_id}", response_model=ProjectResponse)
async def get_project(
    project_id: str,
    request: Request,
    db: aiosqlite.Connection = Depends(get_db),
) -> dict[str, Any]:
    """Get a single project by ID."""
    user_id: str = getattr(request.state, "user_id", "anonymous")
    cursor = await db.execute(
        "SELECT * FROM projects WHERE id = ? AND user_id = ?",
        (project_id, user_id),
    )
    row = await cursor.fetchone()
    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Project not found")
    return _row_to_dict(row)


@router.patch("/{project_id}", response_model=ProjectResponse)
async def update_project(
    project_id: str,
    body: ProjectUpdate,
    request: Request,
    db: aiosqlite.Connection = Depends(get_db),
) -> dict[str, Any]:
    """Update a project's title or description."""
    user_id: str = getattr(request.state, "user_id", "anonymous")

    # Fetch existing
    cursor = await db.execute(
        "SELECT * FROM projects WHERE id = ? AND user_id = ?",
        (project_id, user_id),
    )
    row = await cursor.fetchone()
    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Project not found")

    existing = _row_to_dict(row)
    new_title = body.title if body.title is not None else existing["title"]
    new_desc = body.description if body.description is not None else existing["description"]
    now = datetime.now(UTC).isoformat()

    await db.execute(
        "UPDATE projects SET title = ?, description = ?, updated_at = ? WHERE id = ?",
        (new_title, new_desc, now, project_id),
    )
    await db.commit()

    existing.update(title=new_title, description=new_desc, updated_at=now)
    return existing


@router.delete("/{project_id}", status_code=status.HTTP_204_NO_CONTENT, response_model=None)
async def delete_project(
    project_id: str,
    request: Request,
    db: aiosqlite.Connection = Depends(get_db),
) -> None:
    """Delete a project."""
    user_id: str = getattr(request.state, "user_id", "anonymous")
    cursor = await db.execute(
        "DELETE FROM projects WHERE id = ? AND user_id = ?",
        (project_id, user_id),
    )
    await db.commit()
    if cursor.rowcount == 0:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Project not found")


# ---------------------------------------------------------------------------
# Clip association routes
# ---------------------------------------------------------------------------


async def _verify_project_ownership(
    project_id: str, user_id: str, db: aiosqlite.Connection,
) -> None:
    """Raise 404 if the project doesn't exist or doesn't belong to the user."""
    cursor = await db.execute(
        "SELECT id FROM projects WHERE id = ? AND user_id = ?",
        (project_id, user_id),
    )
    if await cursor.fetchone() is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Project not found")


@router.put("/{project_id}/clips", response_model=list[ClipResponse])
async def set_project_clips(
    project_id: str,
    body: ClipListRequest,
    request: Request,
    db: aiosqlite.Connection = Depends(get_db),
) -> list[dict[str, Any]]:
    """Replace a project's clip list (idempotent)."""
    user_id: str = getattr(request.state, "user_id", "anonymous")
    await _verify_project_ownership(project_id, user_id, db)

    # Clear existing clips
    await db.execute("DELETE FROM project_clips WHERE project_id = ?", (project_id,))

    # Insert new clips, resolving blob_name → asset_id when needed
    for clip in body.clips:
        asset_id = clip.asset_id
        if asset_id is None and clip.blob_name:
            cursor = await db.execute(
                "SELECT id FROM media_assets WHERE blob_name = ? AND user_id = ?",
                (clip.blob_name, user_id),
            )
            row = await cursor.fetchone()
            if row is None:
                raise HTTPException(
                    status_code=status.HTTP_404_NOT_FOUND,
                    detail=f"Asset not found for blob: {clip.blob_name}",
                )
            asset_id = dict(row)["id"]
        if asset_id is None:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Each clip must have either asset_id or blob_name",
            )
        await db.execute(
            "INSERT INTO project_clips (project_id, asset_id, position, trim_start, trim_end, role) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (project_id, asset_id, clip.position, clip.trim_start, clip.trim_end, clip.role),
        )

    # Update project timestamp
    now = datetime.now(UTC).isoformat()
    await db.execute(
        "UPDATE projects SET updated_at = ? WHERE id = ?", (now, project_id),
    )
    await db.commit()

    return await _fetch_clips(project_id, db)


@router.get("/{project_id}/clips", response_model=list[ClipResponse])
async def get_project_clips(
    project_id: str,
    request: Request,
    db: aiosqlite.Connection = Depends(get_db),
) -> list[dict[str, Any]]:
    """Get ordered clips for a project with asset metadata."""
    user_id: str = getattr(request.state, "user_id", "anonymous")
    await _verify_project_ownership(project_id, user_id, db)
    return await _fetch_clips(project_id, db)


async def _fetch_clips(
    project_id: str, db: aiosqlite.Connection,
) -> list[dict[str, Any]]:
    """Fetch clips joined with asset metadata, ordered by position."""
    cursor = await db.execute(
        """
        SELECT pc.asset_id, pc.position, pc.trim_start, pc.trim_end, pc.role,
               ma.blob_name, ma.media_type, ma.content_type,
               ma.quality_score, ma.energy_level
        FROM project_clips pc
        LEFT JOIN media_assets ma ON pc.asset_id = ma.id
        WHERE pc.project_id = ?
        ORDER BY pc.position
        """,
        (project_id,),
    )
    rows = await cursor.fetchall()
    return [dict(r) for r in rows]
