"""Natural language search over tagged media assets."""

from __future__ import annotations

import logging
import re
from datetime import datetime, timedelta

import aiosqlite

from app.config import settings
from app.models.asset import MediaAssetResponse, MediaType, SyncStatus

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Keyword mappings for structured query parsing
# ---------------------------------------------------------------------------

_CONTENT_TYPE_KEYWORDS: dict[str, str] = {
    "talking head": "talking_head",
    "talking": "talking_head",
    "facecam": "talking_head",
    "screen recording": "screen_recording",
    "screencast": "screen_recording",
    "screen": "screen_recording",
    "whiteboard": "whiteboard",
    "outdoor": "outdoor_walk",
    "walk": "outdoor_walk",
    "outside": "outdoor_walk",
    "product demo": "product_demo",
    "demo": "product_demo",
    "meeting": "meeting",
    "b-roll": "b_roll_generic",
    "b roll": "b_roll_generic",
    "broll": "b_roll_generic",
}

_EMOTION_KEYWORDS: dict[str, str] = {
    "neutral": "neutral",
    "calm": "neutral",
    "excited": "excited",
    "energetic": "excited",
    "hype": "excited",
    "focused": "focused",
    "concentrating": "focused",
    "reflective": "reflective",
    "thoughtful": "reflective",
    "casual": "casual",
    "relaxed": "casual",
    "chill": "casual",
}

_ENERGY_KEYWORDS: dict[str, str] = {
    "high energy": "high",
    "energetic": "high",
    "intense": "high",
    "fast": "high",
    "low energy": "low",
    "slow": "low",
    "quiet": "low",
    "mellow": "low",
}

# Date reference patterns
_DATE_PATTERNS: dict[str, int] = {
    "today": 0,
    "yesterday": 1,
    "last week": 7,
    "this week": 7,
    "last month": 30,
    "this month": 30,
}

_DAY_NAMES: dict[str, int] = {
    "monday": 0,
    "tuesday": 1,
    "wednesday": 2,
    "thursday": 3,
    "friday": 4,
    "saturday": 5,
    "sunday": 6,
}


# ---------------------------------------------------------------------------
# Query parsing
# ---------------------------------------------------------------------------


class _ParsedQuery:
    """Structured representation of a natural language search query."""

    def __init__(self) -> None:
        self.content_types: list[str] = []
        self.emotions: list[str] = []
        self.energy_level: str | None = None  # "high" or "low"
        self.date_from: datetime | None = None
        self.date_to: datetime | None = None
        self.free_text: str = ""


def _parse_query(query: str) -> _ParsedQuery:
    """Parse a natural language query into structured search terms."""
    parsed = _ParsedQuery()
    q_lower = query.lower().strip()
    remaining = q_lower

    # Match content types
    for keyword, content_type in sorted(_CONTENT_TYPE_KEYWORDS.items(), key=lambda x: -len(x[0])):
        if keyword in q_lower:
            if content_type not in parsed.content_types:
                parsed.content_types.append(content_type)
            remaining = remaining.replace(keyword, "")

    # Match emotions
    for keyword, emotion in _EMOTION_KEYWORDS.items():
        if keyword in q_lower:
            if emotion not in parsed.emotions:
                parsed.emotions.append(emotion)
            remaining = remaining.replace(keyword, "")

    # Match energy level
    for keyword, level in sorted(_ENERGY_KEYWORDS.items(), key=lambda x: -len(x[0])):
        if keyword in q_lower:
            parsed.energy_level = level
            remaining = remaining.replace(keyword, "")
            break

    # Match date references
    now = datetime.utcnow()
    for pattern, days_back in sorted(_DATE_PATTERNS.items(), key=lambda x: -len(x[0])):
        if pattern in q_lower:
            parsed.date_from = now - timedelta(days=days_back)
            parsed.date_to = now
            remaining = remaining.replace(pattern, "")
            break

    # Match day names (e.g., "tuesday")
    if parsed.date_from is None:
        for day_name, weekday in _DAY_NAMES.items():
            if day_name in q_lower:
                days_since = (now.weekday() - weekday) % 7
                if days_since == 0:
                    days_since = 7  # last occurrence
                target = now - timedelta(days=days_since)
                parsed.date_from = target.replace(hour=0, minute=0, second=0)
                parsed.date_to = target.replace(hour=23, minute=59, second=59)
                remaining = remaining.replace(day_name, "")
                break

    # Remaining text is free-text search
    parsed.free_text = re.sub(r"\s+", " ", remaining).strip()

    return parsed


# ---------------------------------------------------------------------------
# Search execution
# ---------------------------------------------------------------------------


async def search_assets(
    query: str,
    user_id: str,
    limit: int = 50,
) -> list[MediaAssetResponse]:
    """Search tagged assets using natural language.

    Parses the query for content types, emotions, energy, date references,
    and free text. Matches against asset tags and metadata in SQLite.
    Results are ranked: exact tag match > partial description > date match.

    Args:
        query: Natural language search query.
        user_id: ID of the user whose assets to search.
        limit: Maximum number of results.

    Returns:
        Sorted list of matching MediaAssetResponse objects.
    """
    parsed = _parse_query(query)

    # Build SQL query with scoring
    conditions: list[str] = ["user_id = ?"]
    params: list[str | float] = [user_id]

    # Only search tagged assets
    conditions.append("tagged_at IS NOT NULL")

    # Build CASE-based relevance score
    score_parts: list[str] = []

    if parsed.content_types:
        placeholders = ",".join("?" for _ in parsed.content_types)
        score_parts.append(f"(CASE WHEN content_type IN ({placeholders}) THEN 10 ELSE 0 END)")
        params.extend(parsed.content_types)

    if parsed.emotions:
        placeholders = ",".join("?" for _ in parsed.emotions)
        score_parts.append(f"(CASE WHEN emotion IN ({placeholders}) THEN 8 ELSE 0 END)")
        params.extend(parsed.emotions)

    if parsed.energy_level == "high":
        score_parts.append("(CASE WHEN energy_level >= 0.6 THEN 6 ELSE 0 END)")
    elif parsed.energy_level == "low":
        score_parts.append("(CASE WHEN energy_level <= 0.4 THEN 6 ELSE 0 END)")

    if parsed.date_from and parsed.date_to:
        score_parts.append(
            "(CASE WHEN created_at BETWEEN ? AND ? THEN 4 ELSE 0 END)"
        )
        params.append(parsed.date_from.isoformat())
        params.append(parsed.date_to.isoformat())

    if parsed.free_text:
        score_parts.append("(CASE WHEN description LIKE ? THEN 5 ELSE 0 END)")
        params.append(f"%{parsed.free_text}%")
        # Also search in the legacy tags JSON column
        score_parts.append("(CASE WHEN tags LIKE ? THEN 3 ELSE 0 END)")
        params.append(f"%{parsed.free_text}%")

    # If no structured terms matched, do a broad text search
    if not score_parts:
        score_parts.append("(CASE WHEN description LIKE ? THEN 5 ELSE 0 END)")
        params.append(f"%{query}%")
        score_parts.append("(CASE WHEN tags LIKE ? THEN 3 ELSE 0 END)")
        params.append(f"%{query}%")
        score_parts.append("(CASE WHEN content_type LIKE ? THEN 2 ELSE 0 END)")
        params.append(f"%{query}%")

    score_expr = " + ".join(score_parts) if score_parts else "0"

    sql = f"""
        SELECT
            id, user_id, blob_name, file_size, media_type, sync_status,
            created_at, tags, content_type, quality_score, energy_level,
            emotion, description, tagged_at,
            ({score_expr}) AS relevance
        FROM media_assets
        WHERE {' AND '.join(conditions)}
          AND ({score_expr}) > 0
        ORDER BY relevance DESC, created_at DESC
        LIMIT ?
    """
    params.append(limit)

    results: list[MediaAssetResponse] = []

    async with aiosqlite.connect(settings.sqlite_path) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute(sql, params) as cursor:
            async for row in cursor:
                import json
                tags_raw = row["tags"]
                try:
                    tags_list = json.loads(tags_raw) if tags_raw else []
                except (json.JSONDecodeError, TypeError):
                    tags_list = []

                results.append(MediaAssetResponse(
                    id=row["id"],
                    blob_name=row["blob_name"],
                    file_size=row["file_size"],
                    media_type=MediaType(row["media_type"]),
                    sync_status=SyncStatus(row["sync_status"]),
                    created_at=datetime.fromisoformat(row["created_at"]),
                    tags=tags_list,
                    content_type=row["content_type"],
                    quality_score=row["quality_score"],
                    energy_level=row["energy_level"],
                    emotion=row["emotion"],
                    description=row["description"],
                    tagged_at=row["tagged_at"],
                ))

    return results
