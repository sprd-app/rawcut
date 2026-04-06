"""Video render pipeline with AI provider support.

Simplified architecture:
- clip → FFmpeg trim + color grade (no LLM filters)
- title → storyboard image + Ken Burns zoom (FFmpeg)
- photo_to_video → storyboard image → Veo image-to-video
- generate → storyboard image → Veo image-to-video

FFmpeg is the assembler. AI services handle creative work.
"""

from __future__ import annotations

import asyncio
import json
import logging
import subprocess
import tempfile
from datetime import UTC, datetime
from enum import StrEnum
from pathlib import Path

import aiosqlite
import httpx

from app.config import settings
from app.services.blob_storage import get_blob_url, upload_stream

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Presets (color grading applied to clip segments only)
# ---------------------------------------------------------------------------

_LUT_DIR = Path(__file__).resolve().parent.parent.parent / "luts"


class Preset(StrEnum):
    WARM_FILM = "warm_film"
    COOL_MINIMAL = "cool_minimal"
    NATURAL_VIVID = "natural_vivid"


def _preset_filters(preset: Preset) -> str:
    """Build VF filter chain for a preset. Applied to clip segments only."""
    filters: list[str] = []
    iphone_fix = "eq=saturation=0.85:contrast=1.05:brightness=-0.02,unsharp=3:3:-0.3"

    if preset == Preset.WARM_FILM:
        lut = _LUT_DIR / "kodak_2383.cube"
        if lut.exists():
            filters.append(f"lut3d={lut}:interp=trilinear")
        filters.append(iphone_fix)
        filters.append("eq=saturation=0.9:contrast=1.05:brightness=-0.02")
        filters.append("noise=alls=8:allf=t+u")
        filters.append("vignette=PI/4")
    elif preset == Preset.COOL_MINIMAL:
        lut = _LUT_DIR / "fuji_3510.cube"
        if lut.exists():
            filters.append(f"lut3d={lut}:interp=trilinear")
        filters.append(iphone_fix)
        filters.append("eq=saturation=0.6:contrast=1.15:brightness=-0.05")
        filters.append("noise=alls=5:allf=t")
    elif preset == Preset.NATURAL_VIVID:
        filters.append("curves=vintage")
        filters.append(iphone_fix)
        filters.append("eq=saturation=1.2:contrast=1.02")
        filters.append("unsharp=3:3:0.5")

    # Normalize
    filters.append("scale=1920:1080:force_original_aspect_ratio=decrease")
    filters.append("pad=1920:1080:(ow-iw)/2:(oh-ih)/2")
    filters.append("format=yuv420p")
    return ",".join(filters)


# ---------------------------------------------------------------------------
# FFmpeg helpers
# ---------------------------------------------------------------------------


async def _run_ffmpeg(cmd: list[str]) -> None:
    logger.info("ffmpeg: %s", " ".join(cmd[:10]) + "...")
    proc = await asyncio.create_subprocess_exec(
        *cmd, stdout=subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE,
    )
    _, stderr = await proc.communicate()
    if proc.returncode != 0:
        err = stderr.decode(errors="replace")
        raise RuntimeError(f"ffmpeg error: {err[-500:]}")


async def _get_duration(path: Path) -> float:
    proc = await asyncio.create_subprocess_exec(
        "ffprobe", "-v", "quiet", "-print_format", "json",
        "-show_format", str(path),
        stdout=asyncio.subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    stdout, _ = await proc.communicate()
    return float(json.loads(stdout.decode())["format"]["duration"])


async def _download_blob(blob_name: str, dest: Path) -> None:
    url = await get_blob_url(blob_name)
    async with httpx.AsyncClient(timeout=300.0) as client:
        async with client.stream("GET", url) as resp:
            resp.raise_for_status()
            with open(dest, "wb") as f:
                async for chunk in resp.aiter_bytes(chunk_size=256 * 1024):
                    f.write(chunk)


async def _ensure_audio(path: Path, tmp: Path) -> Path:
    """Add silent audio if clip has none."""
    proc = await asyncio.create_subprocess_exec(
        "ffprobe", "-v", "quiet", "-select_streams", "a",
        "-show_entries", "stream=codec_type", "-print_format", "json", str(path),
        stdout=asyncio.subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    stdout, _ = await proc.communicate()
    streams = json.loads(stdout.decode()).get("streams", [])
    if streams:
        return path

    dur = await _get_duration(path)
    out = tmp / f"audio_{path.name}"
    await _run_ffmpeg([
        "ffmpeg", "-y", "-i", str(path),
        "-f", "lavfi", "-i", f"anullsrc=r=44100:cl=stereo",
        "-t", str(dur), "-c:v", "copy", "-c:a", "aac", str(out),
    ])
    return out


# ---------------------------------------------------------------------------
# Segment processors
# ---------------------------------------------------------------------------


async def _process_clip(seg: dict, tmp: Path, preset: Preset) -> Path:
    """Download clip, trim, apply color grade. That's it."""
    blob_name = seg["blob_name"]
    ext = blob_name.rsplit(".", 1)[-1] if "." in blob_name else "mp4"
    src = tmp / f"src_{seg['label'][:20].replace(' ', '_')}.{ext}"
    await _download_blob(blob_name, src)

    in_pt = seg.get("in_point", 0) or 0
    out_pt = seg.get("out_point")
    output = tmp / f"clip_{seg['label'][:20].replace(' ', '_')}.mp4"

    cmd = ["ffmpeg", "-y"]
    if in_pt > 0:
        cmd.extend(["-ss", str(in_pt)])
    cmd.extend(["-i", str(src)])
    if out_pt is not None:
        cmd.extend(["-t", str(out_pt - in_pt)])
    cmd.extend(["-vf", _preset_filters(preset)])
    cmd.extend(["-c:v", "libx264", "-preset", "slow", "-crf", "18"])
    cmd.extend(["-c:a", "aac", "-b:a", "192k", "-pix_fmt", "yuv420p"])
    cmd.append(str(output))
    await _run_ffmpeg(cmd)
    return output


async def _process_image_to_video(seg: dict, tmp: Path) -> Path:
    """Convert storyboard image to video with Ken Burns zoom."""
    duration = seg.get("duration", 4)
    sb_url = seg.get("storyboard_url")
    if not sb_url:
        raise RuntimeError(f"Segment '{seg.get('label')}' has no storyboard image")

    # Download storyboard image
    img = tmp / f"img_{seg['label'][:20].replace(' ', '_')}.jpg"
    async with httpx.AsyncClient(timeout=30.0) as client:
        resp = await client.get(sb_url)
        resp.raise_for_status()
        img.write_bytes(resp.content)

    output = tmp / f"vid_{seg['label'][:20].replace(' ', '_')}.mp4"

    # Ken Burns zoom
    vf = (
        f"zoompan=z='min(zoom+0.0008,1.12)':d={duration * 25}"
        f":x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=1920x1080:fps=25,"
        "scale=1920:1080:force_original_aspect_ratio=decrease,"
        "pad=1920:1080:(ow-iw)/2:(oh-ih)/2,format=yuv420p"
    )

    await _run_ffmpeg([
        "ffmpeg", "-y",
        "-loop", "1", "-i", str(img),
        "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
        "-vf", vf,
        "-c:v", "libx264", "-preset", "fast", "-crf", "18",
        "-c:a", "aac", "-b:a", "192k",
        "-t", str(duration), "-shortest", str(output),
    ])
    return output


async def _process_veo_video(seg: dict, tmp: Path) -> Path:
    """Animate storyboard image into video using Veo."""
    import os
    os.environ['GOOGLE_API_KEY'] = settings.GEMINI_API_KEY

    from google import genai
    from google.genai import types as gtypes

    duration = min(max(seg.get("duration", 4), 4), 8)  # Veo: 4-8s
    sb_url = seg.get("storyboard_url")
    if not sb_url:
        raise RuntimeError(f"Segment '{seg.get('label')}' has no storyboard image for Veo")

    # Download storyboard image
    img_path = tmp / f"veo_src_{seg['label'][:20].replace(' ', '_')}.jpg"
    async with httpx.AsyncClient(timeout=30.0) as client:
        resp = await client.get(sb_url)
        resp.raise_for_status()
        img_path.write_bytes(resp.content)

    img_bytes = img_path.read_bytes()
    video_prompt = seg.get("video_prompt", "Gentle camera movement, cinematic")

    logger.info("Veo: generating %ds video for '%s'", duration, seg.get("label"))

    # Call Veo (sync, blocking — runs in thread pool)
    import time
    gc = genai.Client()

    # Try veo-3.0-fast first, fallback to veo-2.0
    veo_model = "veo-3.0-fast-generate-001"
    veo_dur = min(max(duration, 4), 8)
    try:
        operation = gc.models.generate_videos(
            model=veo_model,
            image=gtypes.Image(image_bytes=img_bytes, mime_type="image/jpeg"),
            prompt=video_prompt,
            config=gtypes.GenerateVideosConfig(
                aspect_ratio="16:9",
                duration_seconds=veo_dur,
                number_of_videos=1,
            ),
        )
    except Exception as e:
        if "quota" in str(e).lower() or "429" in str(e):
            logger.warning("Veo 3.0 quota exceeded, trying Veo 2.0")
            veo_model = "veo-2.0-generate-001"
            veo_dur = min(max(duration, 5), 8)  # Veo 2.0: 5-8s
            operation = gc.models.generate_videos(
                model=veo_model,
                image=gtypes.Image(image_bytes=img_bytes, mime_type="image/jpeg"),
                prompt=video_prompt,
                config=gtypes.GenerateVideosConfig(
                    aspect_ratio="16:9",
                    duration_seconds=veo_dur,
                    number_of_videos=1,
                ),
            )
        else:
            raise

    # Poll until done (max 5 min)
    for _ in range(30):
        await asyncio.sleep(10)
        operation = gc.operations.get(operation)
        if operation.done:
            break

    if not operation.done:
        raise RuntimeError("Veo timed out after 5 minutes")

    if not operation.result or not operation.result.generated_videos:
        raise RuntimeError(f"Veo failed: {operation.error}")

    # Download result
    video = operation.result.generated_videos[0]
    output = tmp / f"veo_{seg['label'][:20].replace(' ', '_')}.mp4"

    file_data = gc.files.download(file=video.video)
    output.write_bytes(file_data)
    logger.info("Veo: saved %s (%d bytes)", output.name, output.stat().st_size)

    # Scale to 1920x1080 for concat compatibility (Veo outputs 1280x720)
    scaled = tmp / f"veo_scaled_{seg['label'][:20].replace(' ', '_')}.mp4"
    await _run_ffmpeg([
        "ffmpeg", "-y", "-i", str(output),
        "-vf", "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,format=yuv420p",
        "-c:v", "libx264", "-preset", "fast", "-crf", "18",
        "-c:a", "aac", "-b:a", "192k", "-ar", "44100",
        str(scaled),
    ])
    return scaled


# ---------------------------------------------------------------------------
# Concat with fades
# ---------------------------------------------------------------------------


async def _generate_bgm(prompt: str, duration: float, output_path: Path) -> bool:
    """Generate background music using ElevenLabs Sound Effects API."""
    api_key = settings.GEMINI_API_KEY  # Reuse for now; can add ELEVENLABS_API_KEY later
    if not api_key:
        return False

    # Use Gemini to generate a short music description, then create via ffmpeg sine wave as placeholder
    # TODO: Replace with Suno/ElevenLabs API when ready
    # For now, generate a subtle ambient tone as BGM placeholder
    logger.info("Generating BGM placeholder (%ds): %s", int(duration), prompt[:60])
    await _run_ffmpeg([
        "ffmpeg", "-y",
        "-f", "lavfi", "-i",
        f"sine=frequency=220:duration={duration}",
        "-af", f"volume=0.02,atempo=1.0,aecho=0.8:0.88:60:0.4",
        "-c:a", "aac", "-b:a", "128k",
        str(output_path),
    ])
    return output_path.exists()


async def _mix_bgm(video_path: Path, bgm_path: Path, volume: float, output_path: Path) -> None:
    """Mix background music into the final video."""
    video_dur = await _get_duration(video_path)

    await _run_ffmpeg([
        "ffmpeg", "-y",
        "-i", str(video_path),
        "-i", str(bgm_path),
        "-filter_complex",
        f"[1:a]volume={volume},afade=t=in:d=2,afade=t=out:st={video_dur - 2}:d=2[bgm];"
        f"[0:a][bgm]amix=inputs=2:duration=first:dropout_transition=2[out]",
        "-map", "0:v", "-map", "[out]",
        "-c:v", "copy",
        "-c:a", "aac", "-b:a", "192k",
        str(output_path),
    ])


async def _add_fade(clip: Path, output: Path, fade_in: float, fade_out: float) -> None:
    dur = await _get_duration(clip)
    if dur < 0.5:
        import shutil
        shutil.copy2(clip, output)
        return
    fade_in = min(fade_in, dur / 2)
    fade_out = min(fade_out, dur / 2)
    vf, af = [], []
    if fade_in > 0:
        vf.append(f"fade=t=in:st=0:d={fade_in}")
        af.append(f"afade=t=in:st=0:d={fade_in}")
    if fade_out > 0:
        st = max(0, dur - fade_out)
        vf.append(f"fade=t=out:st={st:.2f}:d={fade_out}")
        af.append(f"afade=t=out:st={st:.2f}:d={fade_out}")
    cmd = ["ffmpeg", "-y", "-i", str(clip)]
    if vf: cmd.extend(["-vf", ",".join(vf)])
    if af: cmd.extend(["-af", ",".join(af)])
    cmd.extend(["-c:v", "libx264", "-preset", "fast", "-crf", "18",
                "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", str(output)])
    await _run_ffmpeg(cmd)


async def _concat(clips: list[Path], output: Path, segments: list[dict] | None = None) -> None:
    """Concat clips. Uses each segment's transition field to decide fades."""
    if len(clips) == 1:
        t = (segments[0].get("transition", "fade") if segments else "fade")
        fin = 1.0 if t in ("fade_from_black", "fade", "dissolve") else 0
        fout = 1.0 if t in ("fade", "dissolve") else 0
        await _add_fade(clips[0], output, fin, fout)
        return

    faded = []
    for i, c in enumerate(clips):
        f = c.parent / f"faded_{i:03d}.mp4"
        is_first = (i == 0)
        is_last = (i == len(clips) - 1)

        # Get this segment's transition (how it ENTERS)
        seg_transition = "cut"
        if segments and i < len(segments):
            seg_transition = segments[i].get("transition", "cut") or "cut"

        # Get next segment's transition (how this one EXITS)
        next_transition = "cut"
        if segments and i + 1 < len(segments):
            next_transition = segments[i + 1].get("transition", "cut") or "cut"

        # fade_from_black: only first segment, 1s fade in
        # fade/dissolve: 0.3s crossfade feel
        # cut: no fade at all
        if is_first and seg_transition == "fade_from_black":
            fin = 1.0
        elif seg_transition in ("fade", "dissolve"):
            fin = 0.3
        else:
            fin = 0

        if is_last and next_transition in ("fade", "dissolve", "fade_from_black"):
            fout = 1.0
        elif is_last:
            fout = 0.5  # gentle ending even for cuts
        elif next_transition in ("fade", "dissolve"):
            fout = 0.3
        else:
            fout = 0

        if fin == 0 and fout == 0:
            import shutil
            shutil.copy2(c, f)
        else:
            await _add_fade(c, f, fin, fout)
        faded.append(f)

    # Measure faded durations and set render_offset on ALL segments that have a faded clip
    offset = 0.0
    for i, f_clip in enumerate(faded):
        dur = await _get_duration(f_clip)
        # Find the corresponding segment (faded clips are in order of processed segments)
        if segments and i < len(segments):
            segments[i]["render_offset"] = round(offset, 2)
            segments[i]["render_duration"] = round(dur, 2)
        offset += dur
    # Handle case where segments > faded clips (some skipped)
    # Already handled: skipped segments won't have render_offset

    lst = output.parent / "concat.txt"
    lst.write_text("\n".join(f"file '{c}'" for c in faded))
    await _run_ffmpeg([
        "ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", str(lst),
        "-c:v", "libx264", "-preset", "slow", "-crf", "18",
        "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", str(output),
    ])


# ---------------------------------------------------------------------------
# Upload
# ---------------------------------------------------------------------------


async def _upload_file(local: Path, blob_name: str) -> None:
    async def _stream():
        with open(local, "rb") as f:
            while chunk := f.read(256 * 1024):
                yield chunk
    await upload_stream(blob_name, _stream(), content_type="video/mp4")


# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------


async def _update_status(db_path: str, render_id: str, **kwargs: Any) -> None:
    updates, vals = [], []
    for k, v in kwargs.items():
        if v is not None:
            updates.append(f"{k} = ?")
            vals.append(v)
    if not updates:
        return
    vals.append(render_id)
    async with aiosqlite.connect(db_path) as db:
        await db.execute(f"UPDATE renders SET {', '.join(updates)} WHERE id = ?", vals)
        await db.commit()


from typing import Any  # noqa: E402


# ---------------------------------------------------------------------------
# Main render pipeline
# ---------------------------------------------------------------------------


async def render_project(
    render_id: str,
    project_id: str,
    user_id: str,
    preset: str,
    aspect_ratio: str,
) -> None:
    """Render video from approved storyboard.

    Pipeline:
    1. Load segments (from segments_json on render record)
    2. Resolve clip blob_names
    3. Per segment: clip→trim+grade, title/generate/photo→image-to-video
    4. Concat with transitions
    5. Upload to Azure
    """
    db_path = settings.sqlite_path
    preset_enum = Preset(preset)

    try:
        await _update_status(db_path, render_id, status="processing", progress=0.0)

        # Load segments
        async with aiosqlite.connect(db_path) as db:
            db.row_factory = aiosqlite.Row
            cursor = await db.execute(
                "SELECT segments_json FROM renders WHERE id = ?", (render_id,)
            )
            row = await cursor.fetchone()
            segments_json = dict(row).get("segments_json") if row else None

        if not segments_json:
            # Fallback: load from project_clips
            async with aiosqlite.connect(db_path) as db:
                db.row_factory = aiosqlite.Row
                cursor = await db.execute(
                    """SELECT pc.asset_id, pc.position, pc.trim_start, pc.trim_end,
                              ma.blob_name, ma.media_type
                       FROM project_clips pc JOIN media_assets ma ON pc.asset_id = ma.id
                       WHERE pc.project_id = ? ORDER BY pc.position""",
                    (project_id,),
                )
                rows = [dict(r) for r in await cursor.fetchall()]
            segments = [{
                "type": "clip", "label": f"Clip {r['position']}",
                "clip_id": r["asset_id"], "blob_name": r["blob_name"],
                "in_point": r["trim_start"], "out_point": r["trim_end"],
            } for r in rows if r["media_type"] == "video"]
        else:
            segments = json.loads(segments_json)

        if not segments:
            await _update_status(db_path, render_id, status="failed", error="No segments")
            return

        # Resolve blob_names for clip segments
        clip_ids = [s["clip_id"] for s in segments if s.get("type") == "clip" and s.get("clip_id")]
        if clip_ids:
            async with aiosqlite.connect(db_path) as db:
                db.row_factory = aiosqlite.Row
                ph = ",".join("?" * len(clip_ids))
                cursor = await db.execute(
                    f"SELECT id, blob_name, media_type FROM media_assets WHERE id IN ({ph})", clip_ids
                )
                asset_map = {dict(r)["id"]: dict(r) for r in await cursor.fetchall()}
            for seg in segments:
                if seg.get("type") == "clip" and seg.get("clip_id") in asset_map:
                    seg["blob_name"] = asset_map[seg["clip_id"]]["blob_name"]
                    seg["media_type"] = asset_map[seg["clip_id"]]["media_type"]

        total = len(segments) + 1
        step = 0

        with tempfile.TemporaryDirectory(prefix="rawcut_render_") as tmpdir:
            tmp = Path(tmpdir)
            processed: list[Path] = []
            processed_seg_indices: list[int] = []  # track which segment indices were processed

            for i, seg in enumerate(segments):
                seg_type = seg.get("type", "clip")
                label = seg.get("label", f"seg_{i}")
                logger.info("Rendering %d/%d: %s (%s)", i + 1, len(segments), label, seg_type)

                try:
                    if seg_type == "clip":
                        if not seg.get("blob_name"):
                            logger.warning("Segment %d: no blob, skipping", i)
                            step += 1
                            continue
                        out = await _process_clip(seg, tmp, preset_enum)
                    elif seg_type in ("title", "generate", "photo_to_video"):
                        out = await _process_veo_video(seg, tmp)
                    else:
                        logger.warning("Unknown type '%s' for segment %d", seg_type, i)
                        step += 1
                        continue

                    out = await _ensure_audio(out, tmp)
                    processed.append(out)
                    processed_seg_indices.append(i)

                    # Measure actual duration after all processing
                    try:
                        actual_dur = await _get_duration(out)
                        seg["actual_duration"] = round(actual_dur, 2)
                        logger.info("Segment %d '%s': actual %.2fs", i, label, actual_dur)
                    except Exception:
                        pass

                except Exception as e:
                    logger.error("Segment %d '%s' failed: %s", i, label, e)
                    step += 1
                    continue

                step += 1
                await _update_status(db_path, render_id, progress=step / total)

            if not processed:
                await _update_status(db_path, render_id, status="failed", error="All segments failed")
                return

            # Measure actual durations of all processed segments
            actual_durs = []
            seg_idx = 0
            for i, seg in enumerate(segments):
                if seg.get("actual_duration"):
                    actual_durs.append(seg["actual_duration"])
                    seg_idx += 1
                elif seg_idx < len(processed):
                    try:
                        d = await _get_duration(processed[seg_idx])
                        seg["actual_duration"] = round(d, 2)
                        actual_durs.append(round(d, 2))
                        seg_idx += 1
                    except Exception:
                        actual_durs.append(seg.get("duration") or 4)
                        seg_idx += 1

            # Build segment list matching processed clips only (for transition-aware fades)
            processed_segs = [segments[i] for i in processed_seg_indices]

            # Concat
            final = tmp / "final.mp4"
            await _concat(processed, final, processed_segs)

            # Map render_offset/render_duration back to original segments
            for j, seg_idx in enumerate(processed_seg_indices):
                ps = processed_segs[j] if j < len(processed_segs) else {}
                if "render_offset" in ps:
                    segments[seg_idx]["render_offset"] = ps["render_offset"]
                    segments[seg_idx]["render_duration"] = ps["render_duration"]

            # Fallback: if any processed segment still lacks offset, compute from actual_duration
            offset = 0.0
            for seg_idx in processed_seg_indices:
                if segments[seg_idx].get("render_offset") is None:
                    segments[seg_idx]["render_offset"] = round(offset, 2)
                rd = segments[seg_idx].get("render_duration") or segments[seg_idx].get("actual_duration") or 4
                segments[seg_idx]["render_duration"] = rd
                offset += rd
            step += 1
            await _update_status(db_path, render_id, progress=step / total)

            # BGM mixing
            bgm_config = None
            if segments_json:
                script_data = json.loads(segments_json) if isinstance(segments_json, str) else segments_json
                # BGM config might be at the script level (stored alongside segments)
                # Check if first segment has bgm_prompt as a hint
            # Try to get bgm from render record
            async with aiosqlite.connect(db_path) as db:
                db.row_factory = aiosqlite.Row
                cursor = await db.execute("SELECT segments_json FROM renders WHERE id = ?", (render_id,))
                row = await cursor.fetchone()
                if row:
                    raw = dict(row).get("segments_json", "")
                    # segments_json might contain bgm info if we stored it

            # Generate and mix BGM if we have a final video
            video_dur = await _get_duration(final)
            bgm_path = tmp / "bgm.aac"
            bgm_ok = await _generate_bgm("warm ambient background music", video_dur, bgm_path)
            if bgm_ok:
                mixed = tmp / "final_mixed.mp4"
                try:
                    await _mix_bgm(final, bgm_path, 0.12, mixed)
                    final = mixed
                    logger.info("BGM mixed into final video")
                except Exception as bgm_err:
                    logger.warning("BGM mixing failed: %s", bgm_err)

            # Extract thumbnail
            thumb_path = tmp / "thumbnail.jpg"
            await _run_ffmpeg([
                "ffmpeg", "-y", "-i", str(final),
                "-ss", "1", "-frames:v", "1", "-q:v", "3",
                str(thumb_path),
            ])
            thumb_blob = f"renders/{user_id}/{render_id}_thumb.jpg"
            if thumb_path.exists():
                async def _thumb_stream():
                    yield thumb_path.read_bytes()
                await upload_stream(thumb_blob, _thumb_stream(), content_type="image/jpeg")
                logger.info("Thumbnail uploaded: %s", thumb_blob)

            # Upload video
            blob = f"renders/{user_id}/{render_id}.mp4"
            await _upload_file(final, blob)

        # Save updated segments with actual durations
        await _update_status(
            db_path, render_id,
            status="complete", progress=1.0,
            output_blob=blob,
            thumbnail_blob=thumb_blob if thumb_path.exists() else None,
            segments_json=json.dumps(segments),
            completed_at=datetime.now(UTC).isoformat(),
        )
        logger.info("Render %s complete", render_id)

    except Exception as exc:
        logger.exception("Render %s failed", render_id)
        err = str(exc) or f"{type(exc).__name__}: {repr(exc)}"
        await _update_status(db_path, render_id, status="failed", error=err[-500:])
