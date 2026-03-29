"""Pydantic models for media assets."""

from datetime import datetime
from enum import StrEnum
from uuid import UUID, uuid4

from pydantic import BaseModel, Field


class MediaType(StrEnum):
    """Supported media types."""

    VIDEO = "video"
    AUDIO = "audio"
    IMAGE = "image"


class SyncStatus(StrEnum):
    """Upload / sync lifecycle states."""

    PENDING = "pending"
    UPLOADING = "uploading"
    COMPLETE = "complete"
    FAILED = "failed"


class MediaAsset(BaseModel):
    """A single media file tracked by rawcut."""

    id: UUID = Field(default_factory=uuid4)
    blob_name: str
    file_size: int = Field(ge=0)
    media_type: MediaType
    sync_status: SyncStatus = SyncStatus.PENDING
    created_at: datetime = Field(default_factory=datetime.utcnow)
    tags: list[str] = Field(default_factory=list)


class MediaAssetCreate(BaseModel):
    """Payload accepted when registering a new asset."""

    blob_name: str
    file_size: int = Field(ge=0)
    media_type: MediaType
    tags: list[str] = Field(default_factory=list)


class MediaAssetResponse(BaseModel):
    """API response for a media asset."""

    id: UUID
    blob_name: str
    file_size: int
    media_type: MediaType
    sync_status: SyncStatus
    created_at: datetime
    tags: list[str]
