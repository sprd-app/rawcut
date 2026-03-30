"""FFmpeg-based cinematic render pipeline.

Applies color grading (LUT), letterboxing, film grain, and crossfade
transitions to produce a cinematic MP4 from project clips.
"""

from __future__ import annotations

import asyncio
import json
import logging
import subprocess
import tempfile
import uuid
from datetime import UTC, datetime
from enum import StrEnum
from pathlib import Path

import aiosqlite
import httpx

from app.config import settings
from app.services.blob_storage import get_blob_url, upload_stream

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Preset definitions
# ---------------------------------------------------------------------------

_LUT_DIR = Path(__file__).resolve().parent.parent.parent / "luts"


class Preset(StrEnum):
    WARM_FILM = "warm_film"
    COOL_MINIMAL = "cool_minimal"
    NATURAL_VIVID = "natural_vivid"


class AspectRatio(StrEnum):
    STANDARD = "16:9"
    STREAMING = "2.0"
    CINEMATIC = "2.39"


def _letterbox_filter(ratio: AspectRatio) -> str:
    """Return the FFmpeg crop filter for the given aspect ratio.

    Rounds height to even number (libx264 requirement).
    """
    if ratio == AspectRatio.STANDARD:
        return ""  # no crop needed for 16:9
    return f"crop=iw:2*trunc(iw/{ratio.value}/2):0:(ih-2*trunc(iw/{ratio.value}/2))/2"


def _preset_filters(preset: Preset, ratio: AspectRatio) -> str:
    """Build the full -vf filter chain for a preset."""
    filters: list[str] = []

    # iPhone correction (always applied first)
    iphone_fix = "eq=saturation=0.85:contrast=1.05:brightness=-0.02,unsharp=3:3:-0.3"

    if preset == Preset.WARM_FILM:
        lut_path = _LUT_DIR / "kodak_2383.cube"
        if lut_path.exists():
            filters.append(f"lut3d={lut_path}:interp=trilinear")
        filters.append(iphone_fix)
        filters.append("eq=saturation=0.9:contrast=1.05:brightness=-0.02")
        filters.append("noise=alls=8:allf=t+u")
        filters.append("vignette=PI/4")

    elif preset == Preset.COOL_MINIMAL:
        lut_path = _LUT_DIR / "fuji_3510.cube"
        if lut_path.exists():
            filters.append(f"lut3d={lut_path}:interp=trilinear")
        filters.append(iphone_fix)
        filters.append("eq=saturation=0.6:contrast=1.15:brightness=-0.05")
        filters.append("colorbalance=bs=0.05:bm=0.03")
        filters.append("noise=alls=5:allf=t")

    elif preset == Preset.NATURAL_VIVID:
        filters.append("curves=vintage")
        filters.append(iphone_fix)
        filters.append("eq=saturation=1.2:contrast=1.02")
        filters.append("unsharp=3:3:0.5")
        filters.append("noise=alls=3:allf=t")

    # Letterbox
    lb = _letterbox_filter(ratio)
    if lb:
        filters.append(lb)

    # Normalize to 1920x1080 and yuv420p for consistent crossfade concat
    filters.append("scale=1920:1080:force_original_aspect_ratio=decrease")
    filters.append("pad=1920:1080:(ow-iw)/2:(oh-ih)/2")
    filters.append("format=yuv420p")

    return ",".join(filters)


# ---------------------------------------------------------------------------
# Download helpers
# ---------------------------------------------------------------------------


async def _download_blob(blob_name: str, dest: Path) -> None:
    """Download a blob from Azure storage to a local file."""
    url = await get_blob_url(blob_name)
    async with httpx.AsyncClient(timeout=300.0) as client:
        async with client.stream("GET", url) as resp:
            resp.raise_for_status()
            with open(dest, "wb") as f:
                async for chunk in resp.aiter_bytes(chunk_size=1024 * 256):
                    f.write(chunk)


# ---------------------------------------------------------------------------
# FFmpeg operations
# ---------------------------------------------------------------------------


async def _run_ffmpeg(cmd: list[str]) -> None:
    """Run an FFmpeg command asynchronously and raise on failure."""
    logger.info("ffmpeg: %s", " ".join(cmd))
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=subprocess.DEVNULL,
        stderr=asyncio.subprocess.PIPE,
    )
    _, stderr = await proc.communicate()
    if proc.returncode != 0:
        err = stderr.decode(errors="replace")
        logger.error("ffmpeg failed: %s", err)
        raise RuntimeError(f"ffmpeg exited with code {proc.returncode}: {err[-1000:]}")


async def _apply_preset(
    input_path: Path,
    output_path: Path,
    preset: Preset,
    ratio: AspectRatio,
) -> None:
    """Apply cinematic preset filters to a single clip."""
    vf = _preset_filters(preset, ratio)

    cmd = [
        "ffmpeg", "-y",
        "-i", str(input_path),
        "-vf", vf,
        "-c:v", "libx264", "-preset", "slow", "-crf", "18", "-tune", "grain",
        "-pix_fmt", "yuv420p",
        "-c:a", "aac", "-b:a", "192k",
        str(output_path),
    ]
    await _run_ffmpeg(cmd)


async def _get_duration(path: Path) -> float:
    """Get video duration in seconds using ffprobe."""
    proc = await asyncio.create_subprocess_exec(
        "ffprobe", "-v", "quiet",
        "-print_format", "json",
        "-show_format", str(path),
        stdout=asyncio.subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    stdout, _ = await proc.communicate()
    data = json.loads(stdout.decode())
    return float(data["format"]["duration"])


async def _has_audio_stream(path: Path) -> bool:
    """Check if a video file has an audio stream."""
    try:
        proc = await asyncio.create_subprocess_exec(
            "ffprobe", "-v", "quiet",
            "-select_streams", "a",
            "-show_entries", "stream=codec_type",
            "-print_format", "json", str(path),
            stdout=asyncio.subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        stdout, _ = await proc.communicate()
        data = json.loads(stdout.decode())
        return len(data.get("streams", [])) > 0
    except Exception:
        return True  # Assume audio exists on failure (safer)


async def _ensure_audio(path: Path, output_dir: Path) -> Path:
    """Return the clip path, adding a silent audio track if none exists."""
    if await _has_audio_stream(path):
        return path

    duration = await _get_duration(path)
    output = output_dir / f"audio_{path.name}"
    cmd = [
        "ffmpeg", "-y",
        "-i", str(path),
        "-f", "lavfi", "-i", f"anullsrc=r=44100:cl=stereo",
        "-t", str(duration),
        "-c:v", "copy", "-c:a", "aac",
        str(output),
    ]
    await _run_ffmpeg(cmd)
    logger.info("Added silent audio track to %s (%.1fs)", path.name, duration)
    return output


async def _add_fade(clip: Path, output: Path, fade_in: float, fade_out: float) -> None:
    """Add fade-in and/or fade-out to a single clip."""
    duration = await _get_duration(clip)
    filters = []

    if fade_in > 0:
        filters.append(f"fade=t=in:st=0:d={fade_in}")
    if fade_out > 0:
        start = max(0, duration - fade_out)
        filters.append(f"fade=t=out:st={start:.2f}:d={fade_out}")

    afilters = []
    if fade_in > 0:
        afilters.append(f"afade=t=in:st=0:d={fade_in}")
    if fade_out > 0:
        start = max(0, duration - fade_out)
        afilters.append(f"afade=t=out:st={start:.2f}:d={fade_out}")

    cmd = ["ffmpeg", "-y", "-i", str(clip)]
    if filters:
        cmd.extend(["-vf", ",".join(filters)])
    if afilters:
        cmd.extend(["-af", ",".join(afilters)])
    cmd.extend([
        "-c:v", "libx264", "-preset", "fast", "-crf", "18",
        "-pix_fmt", "yuv420p",
        "-c:a", "aac", "-b:a", "192k",
        str(output),
    ])
    await _run_ffmpeg(cmd)


async def _concatenate_with_crossfade(
    clips: list[Path],
    output: Path,
    fade_duration: float = 0.5,
) -> None:
    """Concatenate clips with fade-in/out transitions.

    Each clip gets a fade-out at its end and fade-in at its start
    (except first clip = fade from black, last clip = fade to black).
    Uses concat demuxer for reliable N-clip joining.
    """
    if len(clips) == 1:
        # Single clip: just fade in from black and fade out to black
        await _add_fade(clips[0], output, fade_in=1.0, fade_out=1.0)
        return

    # Add fades to each clip
    faded_clips: list[Path] = []
    for i, clip in enumerate(clips):
        faded = clip.parent / f"faded_{i:03d}.mp4"
        is_first = (i == 0)
        is_last = (i == len(clips) - 1)

        # First clip: 1s fade from black + 0.5s fade out
        # Last clip: 0.5s fade in + 1s fade to black
        # Middle clips: 0.5s fade in + 0.5s fade out
        fin = 1.0 if is_first else fade_duration
        fout = 1.0 if is_last else fade_duration
        await _add_fade(clip, faded, fin, fout)
        faded_clips.append(faded)

    # Concat
    concat_list = output.parent / "concat_list.txt"
    with open(concat_list, "w") as f:
        for clip in faded_clips:
            f.write(f"file '{clip}'\n")

    cmd = [
        "ffmpeg", "-y",
        "-f", "concat", "-safe", "0",
        "-i", str(concat_list),
        "-c:v", "libx264", "-preset", "slow", "-crf", "18",
        "-pix_fmt", "yuv420p",
        "-c:a", "aac", "-b:a", "192k",
        str(output),
    ]
    await _run_ffmpeg(cmd)


# ---------------------------------------------------------------------------
# Upload helper
# ---------------------------------------------------------------------------


async def _upload_file(local_path: Path, blob_name: str) -> None:
    """Upload a local file to Azure Blob Storage."""
    async def _file_stream():
        with open(local_path, "rb") as f:
            while True:
                chunk = f.read(1024 * 256)
                if not chunk:
                    break
                yield chunk

    await upload_stream(blob_name, _file_stream(), content_type="video/mp4")


# ---------------------------------------------------------------------------
# Main render pipeline
# ---------------------------------------------------------------------------


async def _update_render_status(
    db_path: str,
    render_id: str,
    *,
    status: str | None = None,
    progress: float | None = None,
    output_blob: str | None = None,
    error: str | None = None,
    completed_at: str | None = None,
) -> None:
    """Update render record in the database."""
    updates: list[str] = []
    values: list[str | float] = []

    if status is not None:
        updates.append("status = ?")
        values.append(status)
    if progress is not None:
        updates.append("progress = ?")
        values.append(progress)
    if output_blob is not None:
        updates.append("output_blob = ?")
        values.append(output_blob)
    if error is not None:
        updates.append("error = ?")
        values.append(error)
    if completed_at is not None:
        updates.append("completed_at = ?")
        values.append(completed_at)

    if not updates:
        return

    values.append(render_id)
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            f"UPDATE renders SET {', '.join(updates)} WHERE id = ?",
            tuple(values),
        )
        await db.commit()


async def render_project(
    render_id: str,
    project_id: str,
    user_id: str,
    preset: str,
    aspect_ratio: str,
) -> None:
    """Execute the full render pipeline as a background task.

    1. Fetch clips from DB
    2. Download source videos from Azure
    3. Apply preset filters to each clip
    4. Concatenate with crossfade transitions
    5. Upload result to Azure
    6. Update render status
    """
    db_path = settings.sqlite_path
    preset_enum = Preset(preset)
    ratio_enum = AspectRatio(aspect_ratio)

    try:
        await _update_render_status(db_path, render_id, status="processing", progress=0.0)

        # 1. Fetch clips
        async with aiosqlite.connect(db_path) as db:
            db.row_factory = aiosqlite.Row
            cursor = await db.execute(
                """
                SELECT pc.asset_id, pc.position, pc.trim_start, pc.trim_end,
                       ma.blob_name, ma.media_type
                FROM project_clips pc
                JOIN media_assets ma ON pc.asset_id = ma.id
                WHERE pc.project_id = ?
                ORDER BY pc.position
                """,
                (project_id,),
            )
            clips = [dict(r) for r in await cursor.fetchall()]

        if not clips:
            await _update_render_status(
                db_path, render_id, status="failed", error="No clips in project",
            )
            return

        # Only process video clips
        video_clips = [c for c in clips if c["media_type"] == "video"]
        if not video_clips:
            await _update_render_status(
                db_path, render_id, status="failed", error="No video clips in project",
            )
            return

        total_steps = len(video_clips) * 2 + 1  # download + process + concat
        step = 0

        with tempfile.TemporaryDirectory(prefix="rawcut_render_") as tmpdir:
            tmp = Path(tmpdir)

            # 2. Download source clips
            source_paths: list[Path] = []
            for clip in video_clips:
                blob_name = clip["blob_name"]
                ext = blob_name.rsplit(".", 1)[-1] if "." in blob_name else "mp4"
                local_path = tmp / f"source_{clip['position']:03d}.{ext}"

                logger.info("Downloading clip %s -> %s", blob_name, local_path)
                await _download_blob(blob_name, local_path)
                source_paths.append(local_path)

                step += 1
                await _update_render_status(
                    db_path, render_id, progress=step / total_steps,
                )

            # 3. Apply preset to each clip
            processed_paths: list[Path] = []
            for i, source in enumerate(source_paths):
                output = tmp / f"processed_{i:03d}.mp4"

                # Handle trimming
                clip_data = video_clips[i]
                trim_input = source
                if clip_data["trim_start"] > 0 or clip_data["trim_end"] is not None:
                    trimmed = tmp / f"trimmed_{i:03d}.mp4"
                    trim_cmd = ["ffmpeg", "-y"]
                    # Place -ss before -i for fast input seeking
                    if clip_data["trim_start"] > 0:
                        trim_cmd.extend(["-ss", str(clip_data["trim_start"])])
                    trim_cmd.extend(["-i", str(source)])
                    if clip_data["trim_end"] is not None:
                        duration = clip_data["trim_end"] - clip_data["trim_start"]
                        trim_cmd.extend(["-t", str(duration)])
                    # Re-encode to avoid keyframe alignment issues
                    trim_cmd.extend([
                        "-c:v", "libx264", "-preset", "fast", "-crf", "18",
                        "-c:a", "aac", "-b:a", "192k",
                        "-pix_fmt", "yuv420p",
                        str(trimmed),
                    ])
                    await _run_ffmpeg(trim_cmd)
                    trim_input = trimmed

                logger.info("Applying preset %s to clip %d", preset, i)
                await _apply_preset(trim_input, output, preset_enum, ratio_enum)
                processed_paths.append(output)

                step += 1
                await _update_render_status(
                    db_path, render_id, progress=step / total_steps,
                )

            # 4. Ensure all clips have audio (fix for screen recordings / timelapses)
            audio_ready_paths: list[Path] = []
            for p in processed_paths:
                audio_ready_paths.append(await _ensure_audio(p, tmp))

            # 5. Concatenate with crossfade
            final_output = tmp / "final.mp4"
            logger.info("Concatenating %d clips with crossfade", len(audio_ready_paths))
            await _concatenate_with_crossfade(audio_ready_paths, final_output)

            step += 1
            await _update_render_status(
                db_path, render_id, progress=step / total_steps,
            )

            # 5. Upload to Azure
            output_blob = f"renders/{user_id}/{render_id}.mp4"
            logger.info("Uploading render result to %s", output_blob)
            await _upload_file(final_output, output_blob)

        # 6. Mark complete
        await _update_render_status(
            db_path, render_id,
            status="complete",
            progress=1.0,
            output_blob=output_blob,
            completed_at=datetime.now(UTC).isoformat(),
        )
        logger.info("Render %s complete", render_id)

    except Exception as exc:
        logger.exception("Render %s failed", render_id)
        await _update_render_status(
            db_path, render_id,
            status="failed",
            error=str(exc)[:500],
        )
