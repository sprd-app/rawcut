"""GPT-5.4 Vision auto-tagging service for media assets."""

from __future__ import annotations

import asyncio
import base64
import logging
import subprocess
import tempfile
from enum import StrEnum
from pathlib import Path

from openai import AsyncOpenAI, APITimeoutError, RateLimitError
from pydantic import BaseModel, Field

from app.config import settings

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Cost tracking
# ---------------------------------------------------------------------------
BATCH_COST_CAP_USD = 5.00
# Approximate per-token pricing for GPT-5.4 Vision (March 2026)
_INPUT_COST_PER_TOKEN = 5e-6   # $5.00 / 1M input tokens
_OUTPUT_COST_PER_TOKEN = 15e-6  # $15.00 / 1M output tokens


class _CostTracker:
    """Accumulates estimated cost across a batch run."""

    def __init__(self, cap: float = BATCH_COST_CAP_USD) -> None:
        self.cap = cap
        self.total_input_tokens = 0
        self.total_output_tokens = 0

    @property
    def estimated_cost(self) -> float:
        return (
            self.total_input_tokens * _INPUT_COST_PER_TOKEN
            + self.total_output_tokens * _OUTPUT_COST_PER_TOKEN
        )

    def record(self, input_tokens: int, output_tokens: int) -> None:
        self.total_input_tokens += input_tokens
        self.total_output_tokens += output_tokens

    def would_exceed_cap(self, headroom: float = 0.50) -> bool:
        """Return True if the next call is likely to exceed the cap."""
        return self.estimated_cost + headroom >= self.cap


# Module-level tracker reset per batch
_batch_tracker = _CostTracker()


def reset_batch_tracker() -> _CostTracker:
    """Reset and return a fresh cost tracker for a new batch."""
    global _batch_tracker  # noqa: PLW0603
    _batch_tracker = _CostTracker()
    return _batch_tracker


# ---------------------------------------------------------------------------
# Pydantic models for structured tagging output
# ---------------------------------------------------------------------------


class ContentType(StrEnum):
    TALKING_HEAD = "talking_head"
    SCREEN_RECORDING = "screen_recording"
    WHITEBOARD = "whiteboard"
    OUTDOOR_WALK = "outdoor_walk"
    OUTDOOR_ACTIVITY = "outdoor_activity"
    PRODUCT_DEMO = "product_demo"
    MEETING = "meeting"
    FOOD = "food"
    TRAVEL = "travel"
    SELFIE = "selfie"
    PORTRAIT = "portrait"
    LANDSCAPE = "landscape"
    PET = "pet"
    EVENT = "event"
    WORKOUT = "workout"
    B_ROLL_GENERIC = "b_roll_generic"


class Emotion(StrEnum):
    NEUTRAL = "neutral"
    EXCITED = "excited"
    FOCUSED = "focused"
    REFLECTIVE = "reflective"
    CASUAL = "casual"
    HAPPY = "happy"
    SAD = "sad"
    INTENSE = "intense"
    PEACEFUL = "peaceful"


class AssetTags(BaseModel):
    """Structured tags returned by GPT-5.4 Vision analysis."""

    content_type: ContentType
    quality_score: float = Field(ge=0.0, le=1.0)
    energy_level: float = Field(ge=0.0, le=1.0)
    emotion: Emotion
    description: str = Field(max_length=500)
    tags: list[str] = Field(default_factory=list)
    transcript: str | None = None


# ---------------------------------------------------------------------------
# Keyframe extraction
# ---------------------------------------------------------------------------

_KEYFRAME_INTERVAL_SECONDS = 2


async def _extract_keyframes(blob_url: str) -> list[bytes]:
    """Download video from blob URL and extract keyframes using ffmpeg.

    Extracts 1 frame every 2 seconds as JPEG bytes.
    """
    frames: list[bytes] = []

    with tempfile.TemporaryDirectory() as tmpdir:
        output_pattern = str(Path(tmpdir) / "frame_%04d.jpg")

        cmd = [
            "ffmpeg",
            "-i", blob_url,
            "-vf", f"fps=1/{_KEYFRAME_INTERVAL_SECONDS}",
            "-q:v", "2",
            "-frames:v", "30",  # cap at 30 frames (60s of video)
            output_pattern,
            "-y",
            "-loglevel", "error",
        ]

        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
        )
        _, stderr = await proc.communicate()

        if proc.returncode != 0:
            logger.warning("ffmpeg keyframe extraction failed: %s", stderr.decode())
            return frames

        frame_dir = Path(tmpdir)
        for frame_path in sorted(frame_dir.glob("frame_*.jpg")):
            frames.append(frame_path.read_bytes())

    return frames


def _encode_image(image_bytes: bytes) -> str:
    """Base64-encode image bytes for the Vision API."""
    return base64.b64encode(image_bytes).decode("utf-8")


# ---------------------------------------------------------------------------
# GPT-5.4 Vision analysis
# ---------------------------------------------------------------------------

_SYSTEM_PROMPT = """You are a media asset tagger for a vlog editing tool. Your description is CRITICAL — the editing AI uses it to decide which clips to use and where.

Analyze the provided image(s) and return a JSON object with these fields:

- content_type: one of talking_head, screen_recording, whiteboard, outdoor_walk, outdoor_activity, product_demo, meeting, food, travel, selfie, portrait, landscape, pet, event, workout, b_roll_generic
- quality_score: 0.0 to 1.0 (sharpness, lighting, framing, stability)
- energy_level: 0.0 to 1.0 (motion, pacing, visual intensity)
- emotion: one of neutral, excited, focused, reflective, casual, happy, sad, intense, peaceful
- description: DETAILED description (max 500 chars). Include:
  - WHO: people visible (age, gender, count, what they're doing)
  - WHERE: location/setting (indoor/outdoor, specific place if recognizable)
  - WHAT: main action or subject
  - MOOD: visual mood, lighting, colors
  - NOTABLE: any text on screen, products, animals, food, landmarks
  Example: "Young man in his 20s talking to camera in a bright office, wearing a black hoodie, whiteboard with diagrams behind him, natural window light from left, energetic hand gestures, appears to be explaining a tech concept"

Return ONLY valid JSON, no markdown fences."""


async def _call_vision_api(
    frames: list[bytes],
    tracker: _CostTracker,
) -> AssetTags | None:
    """Send frames to GPT-5.4 Vision and parse structured output.

    Returns None if the call fails or response is malformed.
    """
    client = AsyncOpenAI(api_key=settings.OPENAI_API_KEY)

    # Build image content parts
    content: list[dict] = [{"type": "text", "text": "Analyze this media asset:"}]
    for frame in frames:
        content.append({
            "type": "image_url",
            "image_url": {
                "url": f"data:image/jpeg;base64,{_encode_image(frame)}",
                "detail": "low",
            },
        })

    max_retries = 3
    for attempt in range(max_retries):
        try:
            response = await client.chat.completions.create(
                model="gpt-5.4",
                messages=[
                    {"role": "system", "content": _SYSTEM_PROMPT},
                    {"role": "user", "content": content},
                ],
                max_tokens=300,
                temperature=0.2,
                response_format={"type": "json_object"},
                timeout=30.0,
            )

            # Track cost
            usage = response.usage
            if usage:
                tracker.record(usage.prompt_tokens, usage.completion_tokens)

            raw = response.choices[0].message.content
            if not raw:
                logger.warning("Empty response from GPT-5.4 Vision")
                return None

            return AssetTags.model_validate_json(raw)

        except RateLimitError:
            wait = 2 ** (attempt + 1)
            logger.warning("Rate limited by GPT-5.4 Vision, backing off %ds", wait)
            await asyncio.sleep(wait)

        except APITimeoutError:
            logger.warning("GPT-5.4 Vision timeout (attempt %d/%d)", attempt + 1, max_retries)
            if attempt == max_retries - 1:
                return None

        except (ValueError, KeyError) as exc:
            logger.error("Malformed response from GPT-5.4 Vision: %s", exc)
            return None

    return None


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


async def _transcribe_audio(blob_url: str) -> str | None:
    """Transcribe audio from a video using OpenAI Whisper API."""
    try:
        client = AsyncOpenAI(api_key=settings.OPENAI_API_KEY)
        if not settings.OPENAI_API_KEY:
            return None

        # Download audio via ffmpeg (extract to temp mp3)
        with tempfile.TemporaryDirectory() as tmpdir:
            audio_path = Path(tmpdir) / "audio.mp3"
            proc = await asyncio.create_subprocess_exec(
                "ffmpeg", "-i", blob_url,
                "-vn", "-acodec", "libmp3lame", "-q:a", "4",
                "-t", "120",  # max 2 min
                str(audio_path),
                "-y", "-loglevel", "error",
                stdout=subprocess.DEVNULL,
                stderr=asyncio.subprocess.PIPE,
            )
            _, stderr = await proc.communicate()
            if proc.returncode != 0 or not audio_path.exists():
                logger.warning("Audio extraction failed: %s", stderr.decode()[:200])
                return None

            if audio_path.stat().st_size < 1000:
                return None  # Too small, probably no audio

            # Call Whisper
            with open(audio_path, "rb") as f:
                result = await client.audio.transcriptions.create(
                    model="whisper-1",
                    file=f,
                    response_format="text",
                    language="en",
                )
            transcript = result.strip() if isinstance(result, str) else str(result).strip()
            if transcript:
                logger.info("Transcribed: %s", transcript[:100])
            return transcript if transcript else None

    except Exception as e:
        logger.warning("Transcription failed: %s", e)
        return None


async def analyze_asset(blob_name: str, blob_url: str) -> AssetTags | None:
    """Analyze a single media asset and return structured tags.

    For video: extracts keyframes and sends them to GPT-5.4 Vision.
    For images: sends the image directly.

    Returns None if analysis fails.
    """
    extension = blob_name.rsplit(".", maxsplit=1)[-1].lower() if "." in blob_name else ""
    video_extensions = {"mp4", "mov", "avi", "mkv", "webm", "m4v"}
    image_extensions = {"jpg", "jpeg", "png", "heic", "heif", "webp", "tiff"}

    if extension in video_extensions:
        frames = await _extract_keyframes(blob_url)
        if not frames:
            logger.warning("No keyframes extracted for %s, skipping", blob_name)
            return None
    elif extension in image_extensions:
        # For images, fetch the image bytes via the blob URL
        import httpx
        async with httpx.AsyncClient() as http_client:
            try:
                resp = await http_client.get(blob_url, timeout=30.0)
                resp.raise_for_status()
                frames = [resp.content]
            except httpx.HTTPError as exc:
                logger.error("Failed to download image %s: %s", blob_name, exc)
                return None
    else:
        logger.info("Unsupported extension '%s' for tagging, skipping %s", extension, blob_name)
        return None

    # Run vision analysis + audio transcription in parallel
    tags_task = _call_vision_api(frames, _batch_tracker)

    transcript = None
    video_extensions = {"mp4", "mov", "avi", "mkv", "webm", "m4v"}
    if extension in video_extensions:
        transcript = await _transcribe_audio(blob_url)

    tags = await tags_task
    if tags and transcript:
        tags.transcript = transcript
    return tags


async def analyze_batch(
    assets: list[dict],
) -> dict[str, AssetTags | None]:
    """Analyze a batch of assets with cost cap enforcement.

    Args:
        assets: List of dicts with 'id', 'blob_name', 'blob_url' keys.

    Returns:
        Dict mapping asset id -> AssetTags (or None on failure).
    """
    tracker = reset_batch_tracker()
    results: dict[str, AssetTags | None] = {}

    for asset in assets:
        if tracker.would_exceed_cap():
            logger.warning(
                "Batch cost cap approaching ($%.2f / $%.2f). Stopping.",
                tracker.estimated_cost,
                tracker.cap,
            )
            break

        tags = await analyze_asset(asset["blob_name"], asset["blob_url"])
        results[asset["id"]] = tags

    logger.info(
        "Batch complete: %d assets analyzed, estimated cost $%.4f",
        len(results),
        tracker.estimated_cost,
    )
    return results
