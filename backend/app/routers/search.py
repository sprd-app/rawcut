"""Search API endpoint."""

from __future__ import annotations

from fastapi import APIRouter, Query, Request

from app.models.asset import MediaAssetResponse
from app.services.search_service import search_assets

router = APIRouter(prefix="/api", tags=["search"])


@router.get("/search", response_model=list[MediaAssetResponse])
async def search(
    request: Request,
    q: str = Query(..., min_length=1, max_length=500, description="Natural language search query"),
    limit: int = Query(50, ge=1, le=200, description="Maximum results to return"),
) -> list[MediaAssetResponse]:
    """Search across all user's tagged assets using natural language.

    Supports queries like:
    - "talking head clips from last week"
    - "excited outdoor footage"
    - "high energy b-roll"
    - "screen recording tuesday"

    Returns matching assets with tags and relevance ranking.
    """
    user_id: str = getattr(request.state, "user_id", "anonymous")
    return await search_assets(query=q, user_id=user_id, limit=limit)
