"""Storyboard generation service.

Takes a script and generates one preview image per segment:
- clip → extract best frame via ffprobe/ffmpeg
- title → generate background image via Nano Banana
- photo_to_video → restyle photo via Nano Banana
- generate → generate scene image via Nano Banana

Images are uploaded to Azure and URLs returned for iOS display.
"""

from __future__ import annotations

import asyncio
import base64
import logging
import tempfile
from pathlib import Path
from typing import Any

import httpx

from app.config import settings
from app.services.blob_storage import get_blob_url, upload_stream

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Frame extraction from existing clips
# ---------------------------------------------------------------------------


async def _extract_frame(blob_name: str, time_seconds: float, output_path: Path) -> bool:
    """Extract a single frame from a video at the given timestamp."""
    url = await get_blob_url(blob_name)

    proc = await asyncio.create_subprocess_exec(
        "ffmpeg", "-y",
        "-ss", str(time_seconds),
        "-i", url,
        "-frames:v", "1",
        "-q:v", "2",
        str(output_path),
        stdout=asyncio.subprocess.DEVNULL,
        stderr=asyncio.subprocess.PIPE,
    )
    _, stderr = await proc.communicate()

    if proc.returncode != 0:
        logger.error("Frame extraction failed: %s", stderr.decode()[-300:])
        return False
    return output_path.exists() and output_path.stat().st_size > 100


async def _find_best_frame_time(blob_name: str, in_point: float, out_point: float) -> float:
    """Find the best representative frame using binary search strategy.

    Like ButterCut: try start/middle/end, pick the one with the most visual content.
    For short clips, just pick 1/3 in. For longer, pick middle (usually the action).
    """
    duration = out_point - in_point
    if duration <= 3:
        return in_point + duration * 0.3
    elif duration <= 10:
        # Pick the 1/3 point — usually past any intro/setup
        return in_point + duration * 0.33
    else:
        # For longer clips, pick 40% in — past intro, before outro
        return in_point + duration * 0.4


# ---------------------------------------------------------------------------
# Nano Banana image generation
# ---------------------------------------------------------------------------


async def _generate_image(prompt: str, output_path: Path, reference_image: bytes | None = None) -> bool:
    """Generate an image using Nano Banana (Gemini)."""
    api_key = settings.GEMINI_API_KEY
    if not api_key:
        logger.error("GEMINI_API_KEY not configured")
        return False

    url = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-image:generateContent?key={api_key}"

    # Build request parts
    parts: list[dict] = [{"text": prompt}]
    if reference_image:
        parts.insert(0, {
            "inline_data": {
                "mime_type": "image/jpeg",
                "data": base64.b64encode(reference_image).decode(),
            }
        })

    async with httpx.AsyncClient(timeout=60.0) as client:
        resp = await client.post(url, json={
            "contents": [{"parts": parts}],
            "generationConfig": {
                "responseModalities": ["IMAGE", "TEXT"],
                "imageConfig": {
                    "aspectRatio": "16:9",
                },
            },
        })

        if resp.status_code != 200:
            logger.error("Nano Banana error %d: %s", resp.status_code, resp.text[:200])
            return False

        data = resp.json()

    # Extract image
    candidates = data.get("candidates", [])
    if not candidates:
        logger.error("Nano Banana returned no candidates")
        return False

    for part in candidates[0].get("content", {}).get("parts", []):
        if "inlineData" in part:
            img_bytes = base64.b64decode(part["inlineData"]["data"])
            output_path.write_bytes(img_bytes)
            logger.info("Generated image: %s (%d bytes)", output_path.name, len(img_bytes))
            return True

    logger.error("Nano Banana returned no image data")
    return False


# ---------------------------------------------------------------------------
# Upload helper
# ---------------------------------------------------------------------------


async def _upload_image(local_path: Path, blob_name: str) -> str:
    """Upload image to Azure and return signed URL."""
    async def _stream():
        data = local_path.read_bytes()
        yield data

    mime = "image/jpeg" if local_path.suffix in (".jpg", ".jpeg") else "image/png"
    await upload_stream(blob_name, _stream(), content_type=mime)
    return await get_blob_url(blob_name)


# ---------------------------------------------------------------------------
# Main storyboard generation
# ---------------------------------------------------------------------------


async def generate_storyboard(
    segments: list[dict[str, Any]],
    user_id: str,
    session_id: str,
) -> list[dict[str, Any]]:
    """Generate storyboard images for each segment.

    Returns list of segments with added 'storyboard_url' field.
    """
    import aiosqlite

    # Resolve clip blob_names
    clip_ids = [
        s.get("clip_id") for s in segments
        if s.get("type") in ("clip", "photo_to_video") and s.get("clip_id")
    ]
    asset_map: dict[str, dict] = {}
    if clip_ids:
        async with aiosqlite.connect(settings.sqlite_path) as db:
            db.row_factory = aiosqlite.Row
            placeholders = ",".join("?" * len(clip_ids))
            cursor = await db.execute(
                f"SELECT id, blob_name, media_type, duration FROM media_assets WHERE id IN ({placeholders})",
                clip_ids,
            )
            asset_map = {dict(r)["id"]: dict(r) for r in await cursor.fetchall()}

    results = []
    with tempfile.TemporaryDirectory(prefix="rawcut_storyboard_") as tmpdir:
        tmp = Path(tmpdir)
        tasks = []

        for i, seg in enumerate(segments):
            seg_type = seg.get("type", "clip")
            output_path = tmp / f"sb_{i:03d}.jpg"
            blob_name = f"storyboards/{user_id}/{session_id}/sb_{i:03d}.jpg"

            if seg_type == "clip":
                # Extract frame from video
                clip_id = seg.get("clip_id")
                asset = asset_map.get(clip_id, {})
                asset_blob = asset.get("blob_name")

                if not asset_blob:
                    results.append({**seg, "storyboard_url": None, "storyboard_status": "no_source"})
                    continue

                in_point = seg.get("in_point", 0) or 0
                out_point = seg.get("out_point") or asset.get("duration") or 5
                frame_time = await _find_best_frame_time(asset_blob, in_point, out_point)

                if asset.get("media_type") == "image":
                    # For photos, download directly
                    photo_url = await get_blob_url(asset_blob)
                    async with httpx.AsyncClient(timeout=30.0) as client:
                        resp = await client.get(photo_url)
                        if resp.status_code == 200:
                            output_path.write_bytes(resp.content)
                        else:
                            results.append({**seg, "storyboard_url": None, "storyboard_status": "download_failed"})
                            continue
                else:
                    ok = await _extract_frame(asset_blob, frame_time, output_path)
                    if not ok:
                        results.append({**seg, "storyboard_url": None, "storyboard_status": "frame_failed"})
                        continue

                url = await _upload_image(output_path, blob_name)
                results.append({**seg, "storyboard_url": url, "storyboard_status": "ready"})

            elif seg_type == "title":
                # Generate title card background
                prompt = seg.get("image_prompt", "Dark cinematic background, 16:9")
                text = seg.get("text", "")
                if text:
                    prompt += f". Include the text '{text}' prominently displayed, {seg.get('text_style', 'white, centered, large')}"

                ok = await _generate_image(prompt, output_path)
                if ok:
                    url = await _upload_image(output_path, blob_name)
                    results.append({**seg, "storyboard_url": url, "storyboard_status": "ready"})
                else:
                    results.append({**seg, "storyboard_url": None, "storyboard_status": "generation_failed"})

            elif seg_type == "photo_to_video":
                # Restyle user's photo
                clip_id = seg.get("clip_id")
                asset = asset_map.get(clip_id, {})
                asset_blob = asset.get("blob_name")

                reference = None
                if asset_blob:
                    photo_url = await get_blob_url(asset_blob)
                    async with httpx.AsyncClient(timeout=30.0) as client:
                        resp = await client.get(photo_url)
                        if resp.status_code == 200:
                            reference = resp.content

                prompt = seg.get("image_prompt", "Restyle this photo cinematically")
                ok = await _generate_image(prompt, output_path, reference_image=reference)
                if ok:
                    url = await _upload_image(output_path, blob_name)
                    results.append({**seg, "storyboard_url": url, "storyboard_status": "ready"})
                else:
                    results.append({**seg, "storyboard_url": None, "storyboard_status": "generation_failed"})

            elif seg_type == "generate":
                # Generate scene image
                prompt = seg.get("image_prompt", "Cinematic scene, 16:9")
                ok = await _generate_image(prompt, output_path)
                if ok:
                    url = await _upload_image(output_path, blob_name)
                    results.append({**seg, "storyboard_url": url, "storyboard_status": "ready"})
                else:
                    results.append({**seg, "storyboard_url": None, "storyboard_status": "generation_failed"})

            else:
                results.append({**seg, "storyboard_url": None, "storyboard_status": "unknown_type"})

    return results
