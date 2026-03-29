"""Health-check endpoint."""

from fastapi import APIRouter

router = APIRouter()


@router.get("/health")
async def health_check() -> dict[str, str]:
    """Return a simple health-check response."""
    return {"status": "ok"}
