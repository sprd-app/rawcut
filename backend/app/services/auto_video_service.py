"""One-tap auto-video service.

Queries today's clips, computes trim heuristics, creates an auto project,
and kicks off a cinematic render. Smart-chronological order for V1.
"""

from __future__ import annotations

import asyncio
import json
import logging
import subprocess
import uuid
from collections import Counter
from datetime import UTC, datetime, timedelta
from typing import Any

import aiosqlite

from app.config import settings
from app.services.blob_storage import get_blob_url

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Korean title generation
# ---------------------------------------------------------------------------

CONTENT_TYPE_LABELS: dict[str, str] = {
    "talking_head": "인터뷰",
    "outdoor_walk": "야외",
    "product_demo": "제품",
    "screen_recording": "스크린",
    "whiteboard": "화이트보드",
    "b_roll_generic": "일상",
}


def generate_title(clips: list[dict[str, Any]], local_date: datetime) -> str:
    """Generate a Korean title from clip content types and local date."""
    date_str = f"{local_date.month}월 {local_date.day}일"

    types = [c.get("content_type") for c in clips if c.get("content_type")]
    if not types:
        return f"{date_str} · 영상"

    counter = Counter(types)
    top_types = [t for t, _ in counter.most_common(3)]
    labels = [CONTENT_TYPE_LABELS.get(t, t) for t in top_types]

    if len(labels) == 1:
        return f"{date_str} · {labels[0]}"
    return f"{date_str} · {' & '.join(labels[:2])}"


# ---------------------------------------------------------------------------
# Trim heuristics (smart-chronological V1)
# ---------------------------------------------------------------------------

_DEFAULT_TRIM = 5.0


def compute_trims(clips: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Compute trim_start/trim_end for each clip based on duration.

    Returns clips with updated trim_start, trim_end fields.
    """
    # First pass: compute initial trims
    for clip in clips:
        dur = clip.get("duration")
        if dur is None:
            clip["trim_start"] = 0.0
            clip["trim_end"] = _DEFAULT_TRIM
            continue

        content_type = clip.get("content_type")

        if dur <= 5.0:
            clip["trim_start"] = 0.0
            clip["trim_end"] = None  # full clip
        elif dur <= 15.0:
            clip["trim_start"] = 0.0
            clip["trim_end"] = 5.0
        elif dur <= 60.0:
            clip["trim_start"] = 0.0
            clip["trim_end"] = 8.0
        else:
            clip["trim_start"] = 0.0
            clip["trim_end"] = 10.0

        # Exception: talking_head <= 30s keeps full duration
        if content_type == "talking_head" and dur <= 30.0:
            clip["trim_start"] = 0.0
            clip["trim_end"] = None

    # Second pass: enforce 180s advisory limit
    total = sum(_clip_duration(c) for c in clips)
    if total > 180.0:
        for clip in clips:
            if clip.get("content_type") == "talking_head" and clip.get("trim_end") is None:
                dur = clip.get("duration", _DEFAULT_TRIM)
                if dur > 10.0:
                    clip["trim_end"] = 10.0

    return clips


def _clip_duration(clip: dict[str, Any]) -> float:
    """Effective duration of a clip after trimming."""
    if clip.get("trim_end") is None:
        return clip.get("duration") or _DEFAULT_TRIM
    return clip["trim_end"] - clip.get("trim_start", 0.0)


# ---------------------------------------------------------------------------
# Estimated render time
# ---------------------------------------------------------------------------


def estimate_render_time(clip_count: int, total_duration: float) -> int:
    """Estimate render time in seconds."""
    return int(30 + (15 * clip_count) + (total_duration * 0.3))


# ---------------------------------------------------------------------------
# ffprobe for missing durations
# ---------------------------------------------------------------------------


async def _probe_duration_from_url(blob_name: str) -> float | None:
    """Probe video duration from blob URL using ffprobe (no full download)."""
    try:
        url = await get_blob_url(blob_name)
        proc = await asyncio.create_subprocess_exec(
            "ffprobe", "-v", "quiet",
            "-print_format", "json",
            "-show_format", url,
            stdout=asyncio.subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=15.0)
        data = json.loads(stdout.decode())
        return float(data["format"]["duration"])
    except Exception:
        logger.warning("ffprobe failed for blob %s", blob_name)
        return None


# ---------------------------------------------------------------------------
# Main orchestration
# ---------------------------------------------------------------------------


async def create_auto_video(
    user_id: str,
    timezone_offset: int,
    preset: str = "warm_film",
    aspect_ratio: str = "2.0",
) -> dict[str, Any]:
    """Create a one-tap auto-video from today's clips.

    Args:
        user_id: Authenticated user ID.
        timezone_offset: Seconds from GMT (e.g., KST = +32400).
        preset: Cinematic preset name.
        aspect_ratio: Output aspect ratio.

    Returns:
        Dict with project_id, render_id, title, clip_count,
        estimated_seconds, is_existing, preset, aspect_ratio.

    Raises:
        ValueError: If fewer than 3 clips are available.
    """
    db_path = settings.sqlite_path

    # Compute local midnight in UTC
    now_utc = datetime.now(UTC)
    local_now = now_utc + timedelta(seconds=timezone_offset)
    local_midnight = local_now.replace(hour=0, minute=0, second=0, microsecond=0)
    utc_midnight = local_midnight - timedelta(seconds=timezone_offset)
    utc_midnight_str = utc_midnight.strftime("%Y-%m-%dT%H:%M:%S")

    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row

        # Check for active render on existing auto project today
        cursor = await db.execute(
            """
            SELECT p.id, r.id as render_id, r.status, r.preset, r.aspect_ratio,
                   r.progress, r.output_blob, r.error, r.created_at as render_created,
                   p.title, r.completed_at
            FROM projects p
            LEFT JOIN renders r ON r.project_id = p.id
            WHERE p.user_id = ? AND p.type = 'auto'
              AND p.created_at >= ?
            ORDER BY p.created_at DESC, r.created_at DESC
            LIMIT 1
            """,
            (user_id, utc_midnight_str),
        )
        existing = await cursor.fetchone()
        if existing:
            row = dict(existing)
            render_status = row.get("status")
            # Block only during active render
            if render_status in ("queued", "processing"):
                return {
                    "project_id": row["id"],
                    "render_id": row["render_id"],
                    "title": row["title"],
                    "clip_count": 0,
                    "estimated_seconds": 0,
                    "is_existing": True,
                    "preset": row.get("preset", preset),
                    "aspect_ratio": row.get("aspect_ratio", aspect_ratio),
                }

        # Query today's tagged video clips
        cursor = await db.execute(
            """
            SELECT id, blob_name, content_type, quality_score, energy_level,
                   emotion, duration, media_type
            FROM media_assets
            WHERE user_id = ?
              AND created_at >= ?
              AND sync_status = 'complete'
              AND tagged_at IS NOT NULL
              AND media_type = 'video'
            ORDER BY created_at ASC
            """,
            (user_id, utc_midnight_str),
        )
        clips = [dict(r) for r in await cursor.fetchall()]

        # Check minimum clip count with differentiated errors
        if len(clips) < 3:
            # Check if there are untagged clips
            cursor = await db.execute(
                """
                SELECT COUNT(*) as cnt FROM media_assets
                WHERE user_id = ? AND created_at >= ?
                  AND sync_status = 'complete'
                  AND tagged_at IS NULL
                  AND media_type = 'video'
                """,
                (user_id, utc_midnight_str),
            )
            untagged_row = await cursor.fetchone()
            untagged_count = dict(untagged_row)["cnt"] if untagged_row else 0

            if len(clips) + untagged_count >= 3:
                raise ValueError(
                    f"TAGGING_PENDING:{len(clips)}:{untagged_count}"
                )
            raise ValueError(
                f"NOT_ENOUGH_CLIPS:{len(clips)}"
            )

    # Fill missing durations via ffprobe on blob URL
    for clip in clips:
        if clip.get("duration") is None:
            dur = await _probe_duration_from_url(clip["blob_name"])
            clip["duration"] = dur
            # Cache in DB
            if dur is not None:
                async with aiosqlite.connect(db_path) as db:
                    await db.execute(
                        "UPDATE media_assets SET duration = ? WHERE id = ?",
                        (dur, clip["id"]),
                    )
                    await db.commit()

    # Compute trims
    clips = compute_trims(clips)

    # Generate title
    title = generate_title(clips, local_now)

    # Compute totals
    total_duration = sum(_clip_duration(c) for c in clips)
    estimated_seconds = estimate_render_time(len(clips), total_duration)

    # Create project + clips + render in a transaction
    project_id = uuid.uuid4().hex
    render_id = uuid.uuid4().hex
    now_str = datetime.now(UTC).isoformat()

    async with aiosqlite.connect(db_path) as db:
        try:
            await db.execute(
                """INSERT INTO projects (id, user_id, title, description, created_at, updated_at, type)
                   VALUES (?, ?, ?, '', ?, ?, 'auto')""",
                (project_id, user_id, title, now_str, now_str),
            )

            for i, clip in enumerate(clips):
                await db.execute(
                    """INSERT INTO project_clips
                       (project_id, asset_id, position, trim_start, trim_end, role)
                       VALUES (?, ?, ?, ?, ?, 'auto')""",
                    (project_id, clip["id"], i, clip.get("trim_start", 0.0), clip.get("trim_end")),
                )

            # Check for active render on any project before creating
            cursor = await db.execute(
                """SELECT COUNT(*) as cnt FROM renders
                   WHERE project_id = ? AND status IN ('queued', 'processing')""",
                (project_id,),
            )
            active = await cursor.fetchone()
            # New project, so active count should be 0

            await db.execute(
                """INSERT INTO renders
                   (id, project_id, user_id, status, preset, aspect_ratio, progress, created_at)
                   VALUES (?, ?, ?, 'queued', ?, ?, 0.0, ?)""",
                (render_id, project_id, user_id, preset, aspect_ratio, now_str),
            )

            await db.commit()
        except Exception:
            await db.rollback()
            raise

    return {
        "project_id": project_id,
        "render_id": render_id,
        "title": title,
        "clip_count": len(clips),
        "estimated_seconds": estimated_seconds,
        "is_existing": False,
        "preset": preset,
        "aspect_ratio": aspect_ratio,
    }
