"""Chat session persistence endpoints."""

from __future__ import annotations

import json
import logging
import uuid
from typing import Any

import aiosqlite
from fastapi import APIRouter, HTTPException, Request, status
from pydantic import BaseModel, Field

from app.config import settings

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/sessions", tags=["sessions"])


class SessionCreate(BaseModel):
    title: str = "Untitled"


class SessionUpdate(BaseModel):
    title: str | None = None
    messages: list[dict[str, Any]] | None = None
    current_script: dict[str, Any] | None = None
    project_id: str | None = None


class SessionResponse(BaseModel):
    id: str
    title: str
    messages: list[dict[str, Any]]
    current_script: dict[str, Any] | None
    project_id: str | None
    created_at: str
    updated_at: str


class SessionListItem(BaseModel):
    id: str
    title: str
    message_count: int
    has_script: bool
    project_id: str | None
    created_at: str
    updated_at: str


@router.post("", response_model=SessionResponse, status_code=201)
async def create_session(body: SessionCreate, request: Request) -> dict[str, Any]:
    user_id: str = getattr(request.state, "user_id", "anonymous")
    session_id = str(uuid.uuid4())

    async with aiosqlite.connect(settings.sqlite_path) as db:
        await db.execute(
            "INSERT INTO chat_sessions (id, user_id, title) VALUES (?, ?, ?)",
            (session_id, user_id, body.title),
        )
        await db.commit()

        db.row_factory = aiosqlite.Row
        cursor = await db.execute(
            "SELECT * FROM chat_sessions WHERE id = ?", (session_id,)
        )
        row = await cursor.fetchone()

    return _row_to_response(dict(row))


@router.get("", response_model=list[SessionListItem])
async def list_sessions(request: Request) -> list[dict[str, Any]]:
    user_id: str = getattr(request.state, "user_id", "anonymous")

    async with aiosqlite.connect(settings.sqlite_path) as db:
        db.row_factory = aiosqlite.Row
        cursor = await db.execute(
            """SELECT id, title, messages, current_script, project_id,
                      created_at, updated_at
               FROM chat_sessions
               WHERE user_id = ?
               ORDER BY updated_at DESC""",
            (user_id,),
        )
        rows = await cursor.fetchall()

    result = []
    for row in rows:
        r = dict(row)
        msgs = json.loads(r["messages"]) if r["messages"] else []
        result.append({
            "id": r["id"],
            "title": r["title"],
            "message_count": len(msgs),
            "has_script": r["current_script"] is not None,
            "project_id": r["project_id"],
            "created_at": r["created_at"],
            "updated_at": r["updated_at"],
        })
    return result


@router.get("/{session_id}", response_model=SessionResponse)
async def get_session(session_id: str, request: Request) -> dict[str, Any]:
    user_id: str = getattr(request.state, "user_id", "anonymous")

    async with aiosqlite.connect(settings.sqlite_path) as db:
        db.row_factory = aiosqlite.Row
        cursor = await db.execute(
            "SELECT * FROM chat_sessions WHERE id = ? AND user_id = ?",
            (session_id, user_id),
        )
        row = await cursor.fetchone()

    if not row:
        raise HTTPException(status_code=404, detail="Session not found")

    return _row_to_response(dict(row))


@router.put("/{session_id}", response_model=SessionResponse)
async def update_session(
    session_id: str, body: SessionUpdate, request: Request
) -> dict[str, Any]:
    user_id: str = getattr(request.state, "user_id", "anonymous")

    async with aiosqlite.connect(settings.sqlite_path) as db:
        db.row_factory = aiosqlite.Row
        cursor = await db.execute(
            "SELECT * FROM chat_sessions WHERE id = ? AND user_id = ?",
            (session_id, user_id),
        )
        row = await cursor.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Session not found")

        updates = []
        params = []

        if body.title is not None:
            updates.append("title = ?")
            params.append(body.title)
        if body.messages is not None:
            updates.append("messages = ?")
            params.append(json.dumps(body.messages))
        if body.current_script is not None:
            updates.append("current_script = ?")
            params.append(json.dumps(body.current_script))
        if body.project_id is not None:
            updates.append("project_id = ?")
            params.append(body.project_id)

        if updates:
            updates.append("updated_at = datetime('now')")
            params.extend([session_id, user_id])
            await db.execute(
                f"UPDATE chat_sessions SET {', '.join(updates)} WHERE id = ? AND user_id = ?",
                params,
            )
            await db.commit()

        cursor = await db.execute(
            "SELECT * FROM chat_sessions WHERE id = ?", (session_id,)
        )
        row = await cursor.fetchone()

    return _row_to_response(dict(row))


@router.delete("/{session_id}")
async def delete_session(session_id: str, request: Request) -> dict[str, str]:
    user_id: str = getattr(request.state, "user_id", "anonymous")

    async with aiosqlite.connect(settings.sqlite_path) as db:
        cursor = await db.execute(
            "DELETE FROM chat_sessions WHERE id = ? AND user_id = ?",
            (session_id, user_id),
        )
        await db.commit()
        if cursor.rowcount == 0:
            raise HTTPException(status_code=404, detail="Session not found")
    return {"status": "deleted"}


def _row_to_response(row: dict[str, Any]) -> dict[str, Any]:
    messages = json.loads(row["messages"]) if row["messages"] else []
    script = json.loads(row["current_script"]) if row["current_script"] else None
    return {
        "id": row["id"],
        "title": row["title"],
        "messages": messages,
        "current_script": script,
        "project_id": row["project_id"],
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
    }
