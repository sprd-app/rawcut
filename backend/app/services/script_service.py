"""LLM-powered vlog script generation service.

Takes user intent + available clips and generates a cinematic vlog script
using Claude API. Supports iterative refinement via conversation history.
"""

from __future__ import annotations

import json
import logging
from typing import Any

import httpx

from app.config import settings

logger = logging.getLogger(__name__)

SYSTEM_PROMPT = """You are a cinematic vlog editor AI. Given a user's intent and available video clips with metadata, generate or update a vlog script.

Output a JSON object with:
- "title": short title for the vlog (English)
- "total_duration_estimate": in seconds
- "segments": array of segments, each with:
  - "label": section name (e.g., "Cold Open", "Morning Standup", "Deep Work", "Closing")
  - "clip_id": which clip to use (from available clips)
  - "trim_start": seconds from start to begin
  - "trim_end": seconds from start to end (null = use to end)
  - "duration": effective duration of this segment
  - "reason": 1 sentence explaining why this clip fits here
  - "transition": "fade_from_black" | "fade" | "cut" | "dissolve"

Rules:
- Documentary structure: cold open → intro → main sections → closing
- Cold open: visually striking moment, 3-5 seconds
- Talking head clips: preserve speech, 8-15 seconds
- B-roll clips: short visual breaks, 3-5 seconds
- Screen recordings: short excerpts only, 5-8 seconds
- Total video: 60-120 seconds
- Match clips to the user's narrative arc
- Not every clip needs to be used — pick the best ones
- When user gives feedback, modify the script accordingly
- Output ONLY valid JSON, no markdown, no explanation"""


async def generate_script(
    user_message: str,
    clips: list[dict[str, Any]],
    conversation_history: list[dict[str, str]] | None = None,
    current_script: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Generate or update a vlog script using LLM.

    Args:
        user_message: User's intent or feedback.
        clips: Available tagged clips with metadata.
        conversation_history: Prior messages in the session.
        current_script: Current script to modify (for feedback loop).

    Returns:
        Parsed script dict with title, segments, etc.
    """
    # Build context
    clips_context = json.dumps(clips, indent=2, default=str)

    user_content = f"AVAILABLE CLIPS:\n{clips_context}\n\n"
    if current_script:
        user_content += f"CURRENT SCRIPT:\n{json.dumps(current_script, indent=2)}\n\n"
        user_content += f"USER FEEDBACK: {user_message}"
    else:
        user_content += f"USER INTENT: {user_message}"

    # Build messages
    messages = []
    if conversation_history:
        messages.extend(conversation_history)
    messages.append({"role": "user", "content": user_content})

    # Call LLM
    api_key = settings.ANTHROPIC_API_KEY
    if not api_key:
        # Fallback to OpenAI if Anthropic key not available
        return await _generate_with_openai(messages, user_content)

    return await _generate_with_anthropic(messages)


async def _generate_with_anthropic(messages: list[dict[str, str]]) -> dict[str, Any]:
    """Call Anthropic Claude API."""
    async with httpx.AsyncClient(timeout=30.0) as client:
        resp = await client.post(
            "https://api.anthropic.com/v1/messages",
            headers={
                "x-api-key": settings.ANTHROPIC_API_KEY,
                "anthropic-version": "2023-06-01",
                "content-type": "application/json",
            },
            json={
                "model": "claude-sonnet-4-20250514",
                "max_tokens": 2000,
                "system": SYSTEM_PROMPT,
                "messages": messages,
            },
        )
        resp.raise_for_status()
        data = resp.json()
        text = data["content"][0]["text"]
        return _parse_script(text)


async def _generate_with_openai(
    messages: list[dict[str, str]], user_content: str
) -> dict[str, Any]:
    """Fallback: call OpenAI API."""
    api_key = settings.OPENAI_API_KEY
    if not api_key:
        raise ValueError("No LLM API key configured (ANTHROPIC_API_KEY or OPENAI_API_KEY)")

    oai_messages = [{"role": "system", "content": SYSTEM_PROMPT}]
    for m in messages:
        oai_messages.append({"role": m["role"], "content": m["content"]})

    async with httpx.AsyncClient(timeout=30.0) as client:
        resp = await client.post(
            "https://api.openai.com/v1/chat/completions",
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
            json={
                "model": "gpt-4o",
                "messages": oai_messages,
                "max_tokens": 2000,
                "temperature": 0.7,
            },
        )
        resp.raise_for_status()
        data = resp.json()
        text = data["choices"][0]["message"]["content"]
        return _parse_script(text)


def _parse_script(text: str) -> dict[str, Any]:
    """Parse LLM response into script dict."""
    # Strip markdown code fences if present
    text = text.strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[1]
    if text.endswith("```"):
        text = text.rsplit("```", 1)[0]
    text = text.strip()

    try:
        script = json.loads(text)
    except json.JSONDecodeError as e:
        logger.error("Failed to parse LLM script: %s\nRaw: %s", e, text[:500])
        raise ValueError(f"LLM returned invalid JSON: {e}") from e

    # Validate required fields
    if "segments" not in script:
        raise ValueError("Script missing 'segments' field")

    return script


def get_script_suggestions(clips: list[dict[str, Any]]) -> list[str]:
    """Generate quick suggestions based on available clip tags.

    Returns 2-3 one-tap suggestions like "Meeting + Coding" based on
    the content types present in today's clips.
    """
    content_types = [c.get("content_type") for c in clips if c.get("content_type")]
    if not content_types:
        return ["Make a highlight reel"]

    type_labels = {
        "talking_head": "Interview",
        "outdoor_walk": "Outdoor",
        "product_demo": "Product Demo",
        "screen_recording": "Coding",
        "whiteboard": "Planning",
        "b_roll_generic": "Daily Life",
    }

    from collections import Counter
    counter = Counter(content_types)
    top = [t for t, _ in counter.most_common(3)]
    labels = [type_labels.get(t, t) for t in top]

    suggestions = []
    if len(labels) >= 2:
        suggestions.append(f"{labels[0]} + {labels[1]} vlog")
    if len(labels) >= 1:
        suggestions.append(f"Full day highlight")
    suggestions.append("Quick 30-second recap")

    return suggestions
