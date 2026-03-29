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
