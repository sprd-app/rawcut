"""aiosqlite database setup and dependency."""

import aiosqlite

from app.config import settings

_SCHEMA = """
CREATE TABLE IF NOT EXISTS media_assets (
    id            TEXT PRIMARY KEY,
    user_id       TEXT NOT NULL,
    blob_name     TEXT NOT NULL,
    file_size     INTEGER NOT NULL DEFAULT 0,
    media_type    TEXT NOT NULL CHECK(media_type IN ('video', 'audio', 'image')),
    sync_status   TEXT NOT NULL DEFAULT 'pending'
                      CHECK(sync_status IN ('pending', 'uploading', 'complete', 'failed')),
    created_at    TEXT NOT NULL DEFAULT (datetime('now')),
    tags          TEXT NOT NULL DEFAULT '[]',
    content_type  TEXT DEFAULT NULL,
    quality_score REAL DEFAULT NULL,
    energy_level  REAL DEFAULT NULL,
    emotion       TEXT DEFAULT NULL,
    description   TEXT DEFAULT NULL,
    tagged_at     TEXT DEFAULT NULL
);

CREATE TABLE IF NOT EXISTS projects (
    id          TEXT PRIMARY KEY,
    user_id     TEXT NOT NULL,
    title       TEXT NOT NULL DEFAULT 'Untitled',
    description TEXT NOT NULL DEFAULT '',
    created_at  TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_media_assets_user ON media_assets(user_id);
CREATE INDEX IF NOT EXISTS idx_media_assets_user_tagged ON media_assets(user_id, tagged_at);
CREATE INDEX IF NOT EXISTS idx_media_assets_content_type ON media_assets(content_type);
CREATE INDEX IF NOT EXISTS idx_media_assets_emotion ON media_assets(emotion);
CREATE INDEX IF NOT EXISTS idx_media_assets_sync_status ON media_assets(user_id, sync_status);
CREATE INDEX IF NOT EXISTS idx_projects_user ON projects(user_id);
"""


async def init_db() -> None:
    """Create tables if they do not exist."""
    async with aiosqlite.connect(settings.sqlite_path) as db:
        await db.executescript(_SCHEMA)
        await db.commit()


async def get_db() -> aiosqlite.Connection:
    """Yield a database connection for use as a FastAPI dependency.

    The caller is responsible for closing it (handled by the generator
    wrapper below).
    """
    db = await aiosqlite.connect(settings.sqlite_path)
    db.row_factory = aiosqlite.Row
    try:
        yield db  # type: ignore[misc]
    finally:
        await db.close()
