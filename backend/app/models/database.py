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
    tagged_at     TEXT DEFAULT NULL,
    duration      REAL DEFAULT NULL,
    transcript    TEXT DEFAULT NULL,
    content_hash  TEXT DEFAULT NULL
);

CREATE TABLE IF NOT EXISTS projects (
    id          TEXT PRIMARY KEY,
    user_id     TEXT NOT NULL,
    title       TEXT NOT NULL DEFAULT 'Untitled',
    description TEXT NOT NULL DEFAULT '',
    created_at  TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at  TEXT NOT NULL DEFAULT (datetime('now')),
    type        TEXT NOT NULL DEFAULT 'manual'
                    CHECK(type IN ('manual', 'auto'))
);

CREATE INDEX IF NOT EXISTS idx_media_assets_user ON media_assets(user_id);
CREATE INDEX IF NOT EXISTS idx_media_assets_user_tagged ON media_assets(user_id, tagged_at);
CREATE INDEX IF NOT EXISTS idx_media_assets_content_type ON media_assets(content_type);
CREATE INDEX IF NOT EXISTS idx_media_assets_emotion ON media_assets(emotion);
CREATE INDEX IF NOT EXISTS idx_media_assets_sync_status ON media_assets(user_id, sync_status);
CREATE INDEX IF NOT EXISTS idx_projects_user ON projects(user_id);

CREATE TABLE IF NOT EXISTS project_clips (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id  TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    asset_id    TEXT NOT NULL REFERENCES media_assets(id),
    position    INTEGER NOT NULL DEFAULT 0,
    trim_start  REAL DEFAULT 0.0,
    trim_end    REAL DEFAULT NULL,
    role        TEXT DEFAULT 'auto'
                CHECK(role IN ('a_roll', 'b_roll', 'auto'))
);

CREATE TABLE IF NOT EXISTS renders (
    id           TEXT PRIMARY KEY,
    project_id   TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    user_id      TEXT NOT NULL,
    status       TEXT NOT NULL DEFAULT 'queued'
                 CHECK(status IN ('queued', 'processing', 'complete', 'failed')),
    preset       TEXT NOT NULL DEFAULT 'warm_film'
                 CHECK(preset IN ('warm_film', 'cool_minimal', 'natural_vivid')),
    aspect_ratio TEXT NOT NULL DEFAULT '2.0'
                 CHECK(aspect_ratio IN ('16:9', '2.0', '2.39')),
    progress     REAL NOT NULL DEFAULT 0.0,
    segments_json TEXT DEFAULT NULL,
    output_blob  TEXT DEFAULT NULL,
    thumbnail_blob TEXT DEFAULT NULL,
    error        TEXT DEFAULT NULL,
    created_at   TEXT NOT NULL DEFAULT (datetime('now')),
    completed_at TEXT DEFAULT NULL
);

CREATE INDEX IF NOT EXISTS idx_project_clips_project ON project_clips(project_id);
CREATE INDEX IF NOT EXISTS idx_renders_project ON renders(project_id);
CREATE INDEX IF NOT EXISTS idx_renders_user ON renders(user_id);

CREATE TABLE IF NOT EXISTS chat_sessions (
    id          TEXT PRIMARY KEY,
    user_id     TEXT NOT NULL,
    title       TEXT NOT NULL DEFAULT 'Untitled',
    messages    TEXT NOT NULL DEFAULT '[]',
    current_script TEXT DEFAULT NULL,
    project_id  TEXT DEFAULT NULL REFERENCES projects(id) ON DELETE SET NULL,
    created_at  TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_chat_sessions_user ON chat_sessions(user_id);
"""


async def init_db() -> None:
    """Create tables if they do not exist.

    Also runs lightweight migrations for columns added after initial schema.
    Retries on database lock errors (common on Azure File Share).
    """
    import os
    import time

    # Remove stale lock files on Azure File Share
    db_path = settings.sqlite_path
    for suffix in ("-wal", "-shm", "-journal"):
        lock_file = db_path + suffix
        try:
            os.remove(lock_file)
        except OSError:
            pass

    _migrations = [
        "ALTER TABLE media_assets ADD COLUMN duration REAL DEFAULT NULL",
        "ALTER TABLE projects ADD COLUMN type TEXT NOT NULL DEFAULT 'manual'",
        "ALTER TABLE renders ADD COLUMN segments_json TEXT DEFAULT NULL",
        "ALTER TABLE media_assets ADD COLUMN transcript TEXT DEFAULT NULL",
        "ALTER TABLE renders ADD COLUMN thumbnail_blob TEXT DEFAULT NULL",
        "ALTER TABLE media_assets ADD COLUMN content_hash TEXT DEFAULT NULL",
        "ALTER TABLE media_assets ADD COLUMN storage_tier TEXT DEFAULT NULL",
    ]

    _migration_indexes = [
        "CREATE INDEX IF NOT EXISTS idx_projects_user_type "
        "ON projects(user_id, type, created_at)",
        "CREATE INDEX IF NOT EXISTS idx_media_assets_content_hash "
        "ON media_assets(content_hash)",
    ]

    for attempt in range(5):
        try:
            async with aiosqlite.connect(db_path, timeout=10) as db:
                await db.execute("PRAGMA journal_mode=DELETE")
                await db.execute("PRAGMA busy_timeout=5000")

                # Create tables
                for statement in _SCHEMA.split(";"):
                    stmt = statement.strip()
                    if stmt:
                        await db.execute(stmt)
                await db.commit()

                # Run migrations (idempotent — column-already-exists is expected)
                for stmt in _migrations:
                    try:
                        await db.execute(stmt)
                        await db.commit()
                    except Exception:
                        pass

                # Create indexes that depend on migrated columns
                for stmt in _migration_indexes:
                    try:
                        await db.execute(stmt)
                        await db.commit()
                    except Exception:
                        pass

            break  # success
        except Exception:
            if attempt < 4:
                import asyncio
                await asyncio.sleep(2)
            else:
                raise


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
