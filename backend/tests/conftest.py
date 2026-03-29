"""Shared test fixtures for rawcut backend tests."""

import asyncio
import uuid
from datetime import UTC, datetime

import aiosqlite
import pytest


@pytest.fixture
def db(tmp_path, monkeypatch):
    """Provide a fresh test database for each test (sync fixture)."""
    db_path = str(tmp_path / "test.db")
    monkeypatch.setattr("app.config.settings.DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")

    # Initialize schema synchronously
    async def _init():
        async with aiosqlite.connect(db_path) as conn:
            from app.models.database import _SCHEMA
            await conn.executescript(_SCHEMA)
            await conn.commit()

    asyncio.get_event_loop().run_until_complete(_init())
    return db_path


@pytest.fixture
def sample_clips(db):
    """Insert sample tagged video clips into the test DB (sync fixture)."""
    user_id = "test-user"
    now = datetime.now(UTC)
    clips = []

    clip_data = [
        ("talking_head", 0.8, 0.5, "focused", 25.0),
        ("outdoor_walk", 0.7, 0.6, "calm", 12.0),
        ("product_demo", 0.9, 0.4, "excited", 45.0),
        ("screen_recording", 0.6, 0.3, "neutral", 120.0),
        ("b_roll_generic", 0.5, 0.7, "happy", 3.0),
    ]

    async def _insert():
        async with aiosqlite.connect(db) as conn:
            for content_type, quality, energy, emotion, duration in clip_data:
                asset_id = uuid.uuid4().hex
                blob_name = f"{user_id}/{uuid.uuid4().hex}.mp4"
                created_at = now.isoformat()

                await conn.execute(
                    """INSERT INTO media_assets
                       (id, user_id, blob_name, file_size, media_type, sync_status,
                        created_at, content_type, quality_score, energy_level, emotion,
                        tagged_at, duration)
                       VALUES (?, ?, ?, 1000, 'video', 'complete', ?, ?, ?, ?, ?, ?, ?)""",
                    (asset_id, user_id, blob_name, created_at, content_type,
                     quality, energy, emotion, now.isoformat(), duration),
                )
                clips.append({
                    "id": asset_id,
                    "blob_name": blob_name,
                    "content_type": content_type,
                    "quality_score": quality,
                    "energy_level": energy,
                    "emotion": emotion,
                    "duration": duration,
                })
            await conn.commit()

    asyncio.get_event_loop().run_until_complete(_insert())
    return {"user_id": user_id, "clips": clips, "db_path": db}
