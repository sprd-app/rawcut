"""Rawcut backend -- FastAPI application entry point."""

import asyncio
import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.middleware.auth import AppleAuthMiddleware
from app.models.database import init_db
from app.routers import (
    auth,
    auto_video,
    chat,
    chunked_upload,
    health,
    projects,
    renders,
    search,
    sessions,
    storage,
    sync_health,
    tagging,
    upload,
)

logger = logging.getLogger(__name__)


async def _cool_tier_scheduler() -> None:
    """Move blobs older than 30 days to Cool tier every 6 hours."""
    while True:
        await asyncio.sleep(6 * 3600)  # 6 hours
        try:
            from datetime import UTC, datetime, timedelta

            import aiosqlite

            from app.config import settings
            from app.services.blob_storage import move_to_cool_tier

            cutoff = (datetime.now(UTC) - timedelta(days=30)).isoformat()
            async with aiosqlite.connect(settings.sqlite_path) as db:
                db.row_factory = aiosqlite.Row
                cursor = await db.execute(
                    """
                    SELECT blob_name FROM media_assets
                    WHERE sync_status = 'complete'
                      AND created_at < ?
                      AND (storage_tier IS NULL OR storage_tier = 'Hot')
                    """,
                    (cutoff,),
                )
                rows = await cursor.fetchall()

            moved = 0
            for row in rows:
                blob_name = dict(row)["blob_name"]
                try:
                    await move_to_cool_tier(blob_name)
                    async with aiosqlite.connect(settings.sqlite_path) as db:
                        await db.execute(
                            "UPDATE media_assets SET storage_tier = 'Cool' WHERE blob_name = ?",
                            (blob_name,),
                        )
                        await db.commit()
                    moved += 1
                except Exception:
                    logger.exception("Failed to move %s to Cool tier", blob_name)
            if moved:
                logger.info("Cool tier scheduler: moved %d blobs", moved)
        except Exception:
            logger.exception("Cool tier scheduler error")


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    """Run startup / shutdown tasks."""
    await init_db()
    cool_task = asyncio.create_task(_cool_tier_scheduler())
    yield
    cool_task.cancel()


app = FastAPI(
    title="Rawcut API",
    version="0.1.0",
    lifespan=lifespan,
)

# ---------------------------------------------------------------------------
# Middleware (outermost first)
# ---------------------------------------------------------------------------
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # tighten for production
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
app.add_middleware(AppleAuthMiddleware)

# ---------------------------------------------------------------------------
# Routers
# ---------------------------------------------------------------------------
# Infrastructure
app.include_router(health.router)
app.include_router(auth.router)
app.include_router(sync_health.router)
# Media pipeline
app.include_router(upload.router)
app.include_router(chunked_upload.router)
app.include_router(storage.router)
app.include_router(tagging.router)
app.include_router(search.router)
# Projects & editing
app.include_router(projects.router)
app.include_router(renders.router)
app.include_router(chat.router)
app.include_router(auto_video.router)
app.include_router(sessions.router)
