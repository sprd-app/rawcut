"""Integration tests for auto-video creation flow."""

import asyncio
import uuid
from datetime import UTC, datetime
from unittest.mock import AsyncMock, patch

import aiosqlite

from app.services.auto_video_service import create_auto_video


def _run(coro):
    """Run an async function in the current event loop."""
    loop = asyncio.get_event_loop()
    return loop.run_until_complete(coro)


def test_create_auto_video_happy_path(sample_clips):
    """Full flow: query clips, compute trims, create project, start render."""
    data = sample_clips
    tz_offset = 32400  # KST

    with patch("app.services.auto_video_service.get_blob_url", new_callable=AsyncMock):
        result = _run(create_auto_video(
            user_id=data["user_id"],
            timezone_offset=tz_offset,
        ))

    assert result["is_existing"] is False
    assert result["clip_count"] == 5
    assert result["project_id"]
    assert result["render_id"]
    assert result["title"]
    assert result["estimated_seconds"] > 0
    assert result["preset"] == "warm_film"
    assert result["aspect_ratio"] == "2.0"

    # Verify project was created with type='auto'
    async def _check():
        async with aiosqlite.connect(data["db_path"]) as db:
            db.row_factory = aiosqlite.Row
            cursor = await db.execute(
                "SELECT * FROM projects WHERE id = ?", (result["project_id"],),
            )
            project = dict(await cursor.fetchone())
            assert project["type"] == "auto"

            cursor = await db.execute(
                "SELECT COUNT(*) as cnt FROM project_clips WHERE project_id = ?",
                (result["project_id"],),
            )
            row = dict(await cursor.fetchone())
            assert row["cnt"] == 5

            cursor = await db.execute(
                "SELECT * FROM renders WHERE id = ?", (result["render_id"],),
            )
            render = dict(await cursor.fetchone())
            assert render["status"] == "queued"
            assert render["preset"] == "warm_film"

    _run(_check())


def test_not_enough_clips(db):
    """Should raise ValueError when fewer than 3 clips."""
    now = datetime.now(UTC).isoformat()

    async def _setup():
        async with aiosqlite.connect(db) as conn:
            for i in range(2):
                await conn.execute(
                    """INSERT INTO media_assets
                       (id, user_id, blob_name, file_size, media_type, sync_status,
                        created_at, content_type, tagged_at, duration)
                       VALUES (?, 'test-user', ?, 1000, 'video', 'complete', ?, 'outdoor_walk', ?, 10.0)""",
                    (uuid.uuid4().hex, f"test-user/{uuid.uuid4().hex}.mp4", now, now),
                )
            await conn.commit()

    _run(_setup())

    try:
        _run(create_auto_video(user_id="test-user", timezone_offset=32400))
        assert False, "Should have raised ValueError"
    except ValueError as exc:
        assert "NOT_ENOUGH_CLIPS" in str(exc)


def test_tagging_pending(db):
    """Should raise ValueError with TAGGING_PENDING when clips exist but aren't tagged."""
    now = datetime.now(UTC).isoformat()

    async def _setup():
        async with aiosqlite.connect(db) as conn:
            for i in range(2):
                await conn.execute(
                    """INSERT INTO media_assets
                       (id, user_id, blob_name, file_size, media_type, sync_status,
                        created_at, content_type, tagged_at, duration)
                       VALUES (?, 'test-user', ?, 1000, 'video', 'complete', ?, 'outdoor_walk', ?, 10.0)""",
                    (uuid.uuid4().hex, f"test-user/{uuid.uuid4().hex}.mp4", now, now),
                )
            for i in range(3):
                await conn.execute(
                    """INSERT INTO media_assets
                       (id, user_id, blob_name, file_size, media_type, sync_status,
                        created_at, duration)
                       VALUES (?, 'test-user', ?, 1000, 'video', 'complete', ?, 10.0)""",
                    (uuid.uuid4().hex, f"test-user/{uuid.uuid4().hex}.mp4", now),
                )
            await conn.commit()

    _run(_setup())

    try:
        _run(create_auto_video(user_id="test-user", timezone_offset=32400))
        assert False, "Should have raised ValueError"
    except ValueError as exc:
        assert "TAGGING_PENDING" in str(exc)


def test_duplicate_guard_active_render(sample_clips):
    """Should return existing project when an active render exists today."""
    data = sample_clips

    with patch("app.services.auto_video_service.get_blob_url", new_callable=AsyncMock):
        result1 = _run(create_auto_video(
            user_id=data["user_id"],
            timezone_offset=32400,
        ))
        assert result1["is_existing"] is False

        result2 = _run(create_auto_video(
            user_id=data["user_id"],
            timezone_offset=32400,
        ))
        assert result2["is_existing"] is True
        assert result2["project_id"] == result1["project_id"]


def test_duplicate_guard_completed_render_allows_new(sample_clips):
    """Should create new project when previous render is completed."""
    data = sample_clips

    with patch("app.services.auto_video_service.get_blob_url", new_callable=AsyncMock):
        result1 = _run(create_auto_video(
            user_id=data["user_id"],
            timezone_offset=32400,
        ))

    # Mark render as complete
    async def _complete():
        async with aiosqlite.connect(data["db_path"]) as db:
            await db.execute(
                "UPDATE renders SET status = 'complete' WHERE id = ?",
                (result1["render_id"],),
            )
            await db.commit()

    _run(_complete())

    with patch("app.services.auto_video_service.get_blob_url", new_callable=AsyncMock):
        result2 = _run(create_auto_video(
            user_id=data["user_id"],
            timezone_offset=32400,
        ))
        assert result2["is_existing"] is False
        assert result2["project_id"] != result1["project_id"]


def test_custom_preset_and_ratio(sample_clips):
    """Should use custom preset and aspect ratio."""
    data = sample_clips

    with patch("app.services.auto_video_service.get_blob_url", new_callable=AsyncMock):
        result = _run(create_auto_video(
            user_id=data["user_id"],
            timezone_offset=32400,
            preset="cool_minimal",
            aspect_ratio="2.39",
        ))

    assert result["preset"] == "cool_minimal"
    assert result["aspect_ratio"] == "2.39"
