"""LLM-powered vlog script generation.

The director LLM (Claude Opus) analyzes available clips and creates a structured
script. No FFmpeg filter chains — only natural language descriptions.
The script flows through 3 phases: script → storyboard → render.
"""

from __future__ import annotations

import json
import logging
from typing import Any

import httpx

from app.config import settings

logger = logging.getLogger(__name__)

SYSTEM_PROMPT = """You are a professional vlog editor. You arrange REAL footage into cohesive vlogs.

## YOUR JOB
1. First, ANALYZE the available clips. Write a brief "footage coverage" assessment:
   - What footage exists (types, moods, subjects)
   - What's strongest (best quality, most compelling)
   - What's missing or weak
   - How these clips could tell a story together
2. Then create your segment plan based on this analysis.
3. Only use AI generation for title cards or when the user explicitly asks.

Read each clip's description and transcript carefully. The transcript tells you what people are SAYING.

## OUTPUT FORMAT
Return a JSON object:
{
  "title": "vlog title",
  "message": "your response to user (1-2 sentences)",
  "action": "update" | "render" | "chat",
  "footage_coverage": "brief analysis of available footage — what exists, what's strong, what's missing",
  "bgm": {
    "prompt": "background music description — mood, tempo, genre (e.g., 'warm acoustic guitar, 100bpm, hopeful')",
    "volume": 0.15
  },
  "segments": [...]
}

BGM RULES:
- Always include a bgm object with a music prompt matching the vlog mood
- volume: 0.1-0.2 for vlogs with dialogue, 0.3-0.5 for montage/b-roll heavy
- Keep prompts short and mood-focused: "chill lo-fi beats, 85bpm" or "upbeat indie pop, 120bpm"

## ACTIONS
- "update": you created or changed the script
- "render": user approved ("looks good", "render", "go", "done")
- "chat": just talking, no changes. segments=[]

## SEGMENT TYPES

### type: "clip" — Use existing footage
{
  "type": "clip",
  "label": "Opening Shot",
  "clip_id": "uuid-from-available-clips",
  "in_point": 0.0,
  "out_point": 8.0,
  "duration": 8,
  "description": "What this segment shows and why it's here",
  "transition": "fade_from_black",
  "cinematography": "WS, outdoor, natural light, calm energy"
}
NOTE: Always include duration for ALL segment types. For clips, duration = out_point - in_point.

### type: "title" — Text overlay on background (Nano Banana generates image, Veo animates)
{
  "type": "title",
  "label": "Title Card",
  "description": "Bold channel title reveal against moody dark background",
  "cinematography": "Static, centered frame, dark ambient",
  "image_prompt": "Dark cinematic background with subtle bokeh, warm tones, 16:9. Include text 'DAILY VLOG' in white serif font, centered",
  "video_prompt": "Gentle bokeh lights drift slowly, subtle zoom in on the text",
  "text": "DAILY VLOG",
  "duration": 4,
  "transition": "dissolve"
}

### type: "photo_to_video" — Animate a user's photo
{
  "type": "photo_to_video",
  "label": "Seoul Night",
  "clip_id": "uuid-of-photo-asset",
  "image_prompt": "Restyle: same scene but at golden hour, warmer tones, cinematic grain",
  "video_prompt": "Gentle camera push in, clouds drift slowly",
  "duration": 4,
  "transition": "dissolve"
}

### type: "generate" — AI-generated scene (use sparingly, only when user asks)
{
  "type": "generate",
  "label": "Transition Shot",
  "description": "AI-generated atmospheric city scene for visual transition",
  "cinematography": "WS aerial, dusk lighting, cinematic",
  "image_prompt": "Cinematic aerial view of city at dusk, 85mm, shallow DOF, film grain, 16:9",
  "video_prompt": "Slow dolly forward, warm light shifts across buildings, atmospheric haze",
  "duration": 4,
  "transition": "dissolve"
}

IMPORTANT: Always include video_prompt for title/generate/photo_to_video segments.
It describes the motion and camera movement for the animated video.
Keep it short (1-2 sentences) and cinematic.

## RULES
1. READ clip descriptions carefully. Match clips to the right moments.
2. DON'T use all clips. Pick only the ones that fit.
3. DON'T invent fictional narratives with real clips. But you CAN generate AI scenes.
4. If clips don't match user's request, say so and suggest alternatives.
5. Keep vlogs 15-60 seconds unless user asks for longer.
6. Structure: intro → content → outro. Simple.
7. "cinematography" is a free-text description of the visual style for that segment.
8. Title cards: keep text short. The image_prompt describes the background visual.
9. For "clip" type: in_point and out_point are seconds within the source clip.
10. Transitions: "fade_from_black" | "fade" | "cut" | "dissolve"
REQUIRED for EVERY segment: "description", "cinematography", "duration". No exceptions.
11. If NO clips available: create a fully AI-generated vlog using "title" and "generate" segments.
    You can make a complete vlog with just AI — title cards, generated scenes, outro.
12. If SOME clips available but not enough: mix real clips + AI-generated scenes to fill gaps.
"""


async def generate_script(
    user_message: str,
    clips: list[dict[str, Any]],
    conversation_history: list[dict[str, str]] | None = None,
    current_script: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Generate or update a vlog script."""
    if clips:
        clips_context = json.dumps(clips, indent=2, default=str)
        user_content = f"AVAILABLE CLIPS ({len(clips)} clips):\n{clips_context}\n\n"
    else:
        user_content = "AVAILABLE CLIPS: None. User has no footage yet. Use 'title' and 'generate' segments to create a fully AI-generated vlog, or ask what kind of footage they'd like to shoot.\n\n"
    if current_script:
        user_content += f"CURRENT SCRIPT:\n{json.dumps(current_script, indent=2)}\n\n"
        user_content += f"USER FEEDBACK: {user_message}"
    else:
        user_content += f"USER INTENT: {user_message}"

    messages = []
    if conversation_history:
        messages.extend(conversation_history)
    messages.append({"role": "user", "content": user_content})

    api_key = settings.ANTHROPIC_API_KEY
    if not api_key:
        return await _generate_with_openai(messages)

    return await _generate_with_anthropic(messages)


async def _generate_with_anthropic(messages: list[dict[str, str]]) -> dict[str, Any]:
    async with httpx.AsyncClient(timeout=120.0) as client:
        resp = await client.post(
            "https://api.anthropic.com/v1/messages",
            headers={
                "x-api-key": settings.ANTHROPIC_API_KEY,
                "anthropic-version": "2023-06-01",
                "content-type": "application/json",
            },
            json={
                "model": "claude-opus-4-6",
                "max_tokens": 3000,
                "system": SYSTEM_PROMPT,
                "messages": messages,
            },
        )
        resp.raise_for_status()
        data = resp.json()
        text = data["content"][0]["text"]
        return _parse_script(text)


async def _generate_with_openai(messages: list[dict[str, str]]) -> dict[str, Any]:
    api_key = settings.OPENAI_API_KEY
    if not api_key:
        raise ValueError("No LLM API key configured")

    oai_messages = [{"role": "system", "content": SYSTEM_PROMPT}]
    for m in messages:
        oai_messages.append({"role": m["role"], "content": m["content"]})

    async with httpx.AsyncClient(timeout=120.0) as client:
        resp = await client.post(
            "https://api.openai.com/v1/chat/completions",
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
            json={
                "model": "gpt-4o",
                "messages": oai_messages,
                "max_tokens": 3000,
                "temperature": 0.7,
            },
        )
        resp.raise_for_status()
        data = resp.json()
        text = data["choices"][0]["message"]["content"]
        return _parse_script(text)


def _parse_script(text: str) -> dict[str, Any]:
    text = text.strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[1]
    if text.endswith("```"):
        text = text.rsplit("```", 1)[0]
    text = text.strip()

    try:
        script = json.loads(text)
    except json.JSONDecodeError as e:
        logger.error("Failed to parse script: %s\nRaw: %s", e, text[:500])
        raise ValueError(f"LLM returned invalid JSON: {e}") from e

    if "segments" not in script:
        raise ValueError("Script missing 'segments' field")

    # Ensure defaults
    for seg in script["segments"]:
        seg.setdefault("type", "clip")
        seg.setdefault("transition", "cut")
        if seg["type"] == "clip":
            seg.setdefault("in_point", 0.0)
            seg.setdefault("out_point", None)

    return script


def get_script_suggestions(clips: list[dict[str, Any]]) -> list[str]:
    """Quick suggestions based on available clips."""
    content_types = [c.get("content_type") for c in clips if c.get("content_type")]
    if not content_types:
        return ["Make a highlight reel"]

    type_labels = {
        "talking_head": "Interview", "outdoor_walk": "Outdoor",
        "product_demo": "Product Demo", "screen_recording": "Coding",
        "food": "Food", "travel": "Travel", "selfie": "Selfie",
        "portrait": "Portrait", "landscape": "Scenery",
        "pet": "Pet", "event": "Event", "workout": "Workout",
        "b_roll_generic": "Daily Life",
    }

    from collections import Counter
    counter = Counter(content_types)
    top = [t for t, _ in counter.most_common(3)]
    labels = [type_labels.get(t, t) for t in top]

    suggestions = []
    if len(labels) >= 2:
        suggestions.append(f"{labels[0]} + {labels[1]} vlog")
    suggestions.append("Full day highlight")
    suggestions.append("Quick 30-second recap")
    return suggestions
