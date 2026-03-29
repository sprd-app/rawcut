"""Sync health monitoring service."""

from __future__ import annotations

import logging
from datetime import datetime

import aiosqlite
from pydantic import BaseModel, Field

from app.config import settings

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------

_FAILURE_RATE_ALERT_THRESHOLD = 0.05  # 5%


class SyncHealth(BaseModel):
    """Sync health metrics for a user."""

    total_assets: int = 0
    synced_count: int = 0
    failed_count: int = 0
    pending_count: int = 0
    uploading_count: int = 0
    success_rate: float = Field(ge=0.0, le=1.0, default=1.0)
    sync_lag_seconds: float | None = None
    alert: str | None = None


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


async def get_sync_health(user_id: str) -> SyncHealth:
    """Calculate sync health metrics for a user.

    Tracks:
    - Total assets, counts per sync status
    - Success rate (synced / total attempted)
    - Sync lag (seconds since oldest pending asset)
    - Alert if failure rate exceeds threshold for recent uploads

    Args:
        user_id: The user to check.

    Returns:
        SyncHealth with current metrics.
    """
    async with aiosqlite.connect(settings.sqlite_path) as db:
        db.row_factory = aiosqlite.Row

        # Counts by status
        sql_counts = """
            SELECT
                COUNT(*) AS total,
                SUM(CASE WHEN sync_status = 'complete' THEN 1 ELSE 0 END) AS synced,
                SUM(CASE WHEN sync_status = 'failed' THEN 1 ELSE 0 END) AS failed,
                SUM(CASE WHEN sync_status = 'pending' THEN 1 ELSE 0 END) AS pending,
                SUM(CASE WHEN sync_status = 'uploading' THEN 1 ELSE 0 END) AS uploading
            FROM media_assets
            WHERE user_id = ?
        """
        async with db.execute(sql_counts, (user_id,)) as cursor:
            row = await cursor.fetchone()

        if row is None or row["total"] == 0:
            return SyncHealth()

        total = row["total"]
        synced = row["synced"]
        failed = row["failed"]
        pending = row["pending"]
        uploading = row["uploading"]

        # Success rate: synced / (synced + failed), ignoring pending/uploading
        attempted = synced + failed
        success_rate = (synced / attempted) if attempted > 0 else 1.0

        # Sync lag: time since oldest pending asset
        sync_lag: float | None = None
        sql_oldest_pending = """
            SELECT MIN(created_at) AS oldest
            FROM media_assets
            WHERE user_id = ? AND sync_status IN ('pending', 'uploading')
        """
        async with db.execute(sql_oldest_pending, (user_id,)) as cursor:
            lag_row = await cursor.fetchone()

        if lag_row and lag_row["oldest"]:
            oldest_dt = datetime.fromisoformat(lag_row["oldest"])
            sync_lag = (datetime.utcnow() - oldest_dt).total_seconds()

        # Alert: check failure rate for recent uploads (last 100)
        alert: str | None = None
        sql_recent = """
            SELECT
                COUNT(*) AS total,
                SUM(CASE WHEN sync_status = 'failed' THEN 1 ELSE 0 END) AS failed
            FROM (
                SELECT sync_status FROM media_assets
                WHERE user_id = ?
                ORDER BY created_at DESC
                LIMIT 100
            )
        """
        async with db.execute(sql_recent, (user_id,)) as cursor:
            recent_row = await cursor.fetchone()

        if recent_row and recent_row["total"] > 0:
            recent_failure_rate = recent_row["failed"] / recent_row["total"]
            if recent_failure_rate > _FAILURE_RATE_ALERT_THRESHOLD:
                alert = (
                    f"High failure rate: {recent_failure_rate:.1%} of recent "
                    f"{recent_row['total']} uploads failed "
                    f"(threshold: {_FAILURE_RATE_ALERT_THRESHOLD:.0%})"
                )

        return SyncHealth(
            total_assets=total,
            synced_count=synced,
            failed_count=failed,
            pending_count=pending,
            uploading_count=uploading,
            success_rate=round(success_rate, 4),
            sync_lag_seconds=round(sync_lag, 1) if sync_lag is not None else None,
            alert=alert,
        )
