"""Azure Blob Storage wrapper for media uploads."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import AsyncIterator

from azure.storage.blob import (
    BlobSasPermissions,
    BlobServiceClient,
    StandardBlobTier,
    generate_blob_sas,
)
from azure.storage.blob.aio import BlobServiceClient as AsyncBlobServiceClient

from app.config import settings


def _sync_service_client() -> BlobServiceClient:
    """Create a synchronous BlobServiceClient (used for SAS generation)."""
    return BlobServiceClient.from_connection_string(settings.AZURE_STORAGE_CONNECTION_STRING)


def _async_service_client() -> AsyncBlobServiceClient:
    """Create an async BlobServiceClient for streaming operations."""
    return AsyncBlobServiceClient.from_connection_string(settings.AZURE_STORAGE_CONNECTION_STRING)


def generate_sas_token(blob_name: str, expiry_hours: int = 1) -> str:
    """Generate a read-only SAS token for a blob.

    Args:
        blob_name: Name of the blob in the container.
        expiry_hours: How many hours until the token expires.

    Returns:
        The SAS query string (without leading ``?``).
    """
    client = _sync_service_client()
    account_name = client.account_name
    account_key = client.credential.account_key  # type: ignore[union-attr]

    return generate_blob_sas(
        account_name=account_name,
        container_name=settings.AZURE_STORAGE_CONTAINER,
        blob_name=blob_name,
        account_key=account_key,
        permission=BlobSasPermissions(read=True),
        expiry=datetime.now(UTC) + timedelta(hours=expiry_hours),
    )


async def upload_stream(
    blob_name: str,
    data_stream: AsyncIterator[bytes],
    content_type: str = "application/octet-stream",
) -> dict[str, str | int]:
    """Stream upload via stage_block / put_block_list (zero-copy).

    Reads chunks from *data_stream*, stages each as a block, then commits
    the block list.  This avoids buffering the entire file in memory.

    Args:
        blob_name: Destination blob name.
        data_stream: Async iterator yielding bytes chunks.
        content_type: MIME type for the blob.

    Returns:
        Dict with ``blob_name``, ``size``, and ``etag``.
    """
    async with _async_service_client() as service:
        container = service.get_container_client(settings.AZURE_STORAGE_CONTAINER)
        blob = container.get_blob_client(blob_name)

        block_ids: list[str] = []
        total_size = 0
        block_index = 0

        async for chunk in data_stream:
            if not chunk:
                continue
            block_id = f"{block_index:06d}"
            await blob.stage_block(block_id=block_id, data=chunk, length=len(chunk))
            block_ids.append(block_id)
            total_size += len(chunk)
            block_index += 1

        await blob.commit_block_list(block_ids)

        # Set content type after commit
        await blob.set_http_headers(content_settings={"content_type": content_type})

        return {"blob_name": blob_name, "size": total_size, "etag": ""}


async def get_blob_url(blob_name: str) -> str:
    """Return a full SAS URL for a blob.

    Args:
        blob_name: Name of the blob.

    Returns:
        HTTPS URL with embedded SAS token.
    """
    client = _sync_service_client()
    sas = generate_sas_token(blob_name)
    return (
        f"https://{client.account_name}.blob.core.windows.net/"
        f"{settings.AZURE_STORAGE_CONTAINER}/{blob_name}?{sas}"
    )


async def list_blobs(prefix: str = "") -> list[dict[str, str | int]]:
    """List blobs in the container, optionally filtered by prefix.

    Args:
        prefix: Only return blobs whose name starts with this string.

    Returns:
        List of dicts with ``name`` and ``size``.
    """
    results: list[dict[str, str | int]] = []
    async with _async_service_client() as service:
        container = service.get_container_client(settings.AZURE_STORAGE_CONTAINER)
        async for blob in container.list_blobs(name_starts_with=prefix):
            results.append({"name": blob.name, "size": blob.size})
    return results


async def move_to_cool_tier(blob_name: str) -> None:
    """Move a blob to the Cool access tier to reduce storage costs.

    Args:
        blob_name: Name of the blob to re-tier.
    """
    async with _async_service_client() as service:
        container = service.get_container_client(settings.AZURE_STORAGE_CONTAINER)
        blob = container.get_blob_client(blob_name)
        await blob.set_standard_blob_tier(StandardBlobTier.COOL)
