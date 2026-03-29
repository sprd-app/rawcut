# Cinematic Render Pipeline

Technical strategy for transforming raw iPhone footage into documentary-style founder vlogs.

## Terminology

- **A-roll**: Main footage. Talking head, interviews, core content where the subject speaks to camera.
- **B-roll**: Supporting footage layered over A-roll. Office scenes, product shots, outdoor walks, timelapses. This is what makes a vlog feel like a documentary.
- **LUT (Look-Up Table)**: A `.cube` file that remaps colors. Applying a Kodak 2383 LUT to iPhone footage makes it look like it was shot on film.
- **Letterboxing**: Black bars top and bottom. Cropping to a wider aspect ratio (2.0:1 or 2.39:1) signals "cinema" to the viewer.
- **Ken Burns**: Slow pan/zoom over a still photo to create motion from a static image.

## Architecture

```
User selects clips in app
  → GPT-5.4 Vision tags classify A-roll vs B-roll
  → Claude parses script into segments (mood, energy, shot types)
  → Matching algorithm scores clips against segments
  → FFmpeg render pipeline assembles final video:
      1. Color grade (LUT)
      2. Letterbox
      3. Film grain
      4. Ken Burns on photos
      5. Transitions between clips
      6. Audio mix (original + BGM + narration)
  → Output: cinematic MP4
```

## Layer 1: FFmpeg Post-Processing (Cost: $0)

The foundation. Runs server-side on Azure Container Apps. No GPU needed.

### Color Grading with LUTs

```bash
# Kodak 2383 — warm skin tones, cool shadows (classic cinema)
ffmpeg -i input.mp4 \
  -vf "lut3d=kodak2383.cube:interp=trilinear" \
  -c:v libx264 -b:v 10M -pix_fmt yuv420p10le -c:a copy output.mp4
```

16-bit precision (`yuv420p10le`) prevents color banding. Always use `interp=trilinear`.

**iPhone-specific adjustments** (iPhone over-sharpens and slightly overexposes):
```bash
# Fix iPhone's video look: lower midtones, slight desaturation, reduce sharpness
-vf "eq=saturation=0.85:contrast=1.05:brightness=-0.02,unsharp=3:3:-0.3"
```

### Three Cinematic Presets

Matching DESIGN.md's preset names:

**Warm Film** (Kodak-inspired, founder interview style):
```bash
-vf "lut3d=kodak2383.cube:interp=trilinear,\
     eq=saturation=0.9:contrast=1.05:brightness=-0.02,\
     noise=alls=8:allf=t+u,\
     vignette=PI/4"
```

**Cool Minimal** (desaturated, tech/startup feel):
```bash
-vf "lut3d=fuji3510.cube:interp=trilinear,\
     eq=saturation=0.6:contrast=1.15:brightness=-0.05,\
     colorbalance=bs=0.05:bm=0.03,\
     noise=alls=5:allf=t"
```

**Natural Vivid** (enhanced reality, outdoor/product):
```bash
-vf "curves=vintage,\
     eq=saturation=1.2:contrast=1.02,\
     unsharp=3:3:0.5,\
     noise=alls=3:allf=t"
```

### Letterboxing

```bash
# 2.0:1 — streaming standard (Netflix). Default for rawcut.
-vf "crop=iw:iw/2.0:0:(ih-iw/2.0)/2"

# 2.39:1 — full cinematic scope. Premium preset.
-vf "crop=iw:iw/2.39:0:(ih-iw/2.39)/2"
```

Use 2.0:1 as default. It says "cinematic" without heavy bars that hurt mobile engagement. Offer 2.39:1 as opt-in.

### Film Grain

```bash
# Synthetic grain (simple, good enough for V1)
-vf "noise=alls=8:allf=t+u"

# Real grain overlay (better quality, requires grain scan file)
ffmpeg -i input.mp4 -i grain_16mm.mp4 \
  -filter_complex "[1]format=rgba,colorchannelmixer=aa=0.20[grain];[0][grain]overlay" \
  -c:v libx264 -tune grain output.mp4
```

`-tune grain` preserves grain detail during encoding. 16mm grain = documentary look. 35mm = polished cinema.

### Ken Burns on Photos

```bash
# Slow zoom-in over 5 seconds (pre-upscale to 8000px for smooth result)
ffmpeg -loop 1 -framerate 30 -i photo.jpg -t 5 \
  -vf "scale=8000:-1,\
       zoompan=z='min(zoom+0.0015,1.3)':d=150:s=1920x1080:fps=30:\
       x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)'" \
  -c:v libx264 -pix_fmt yuv420p output.mp4
```

Best practices:
- Alternate directions between consecutive photos (zoom in → pan left → zoom out)
- Slow and purposeful. Fast = amateur.
- Pre-upscale source image to at least 2x output resolution
- `scale=8000:-1` gives zoom headroom without pixelation

### Camera Drift on Static Shots

```bash
# Subtle breathing motion — mimics handheld without shake
-vf "scale=8000:-1,\
     zoompan=z='1.05+0.02*sin(in/60)':\
     x='iw/2-(iw/zoom/2)+15*sin(in/45)':\
     y='ih/2-(ih/zoom/2)+10*cos(in/55)':\
     d=300:s=1920x1080:fps=30"
```

### Transitions

```bash
# Crossfade (1s dissolve between two clips)
ffmpeg -i clip1.mp4 -i clip2.mp4 \
  -filter_complex "[0:v][1:v]xfade=transition=fade:duration=1:offset=4,format=yuv420p[v];\
                   [0:a][1:a]acrossfade=d=1[a]" \
  -map "[v]" -map "[a]" output.mp4
```

Available: `fade`, `dissolve`, `fadeblack`, `fadewhite`, `wipeleft`, `circleopen`, `smoothleft`, and 30+ more.

### Slow Motion

```bash
# 2x slow-mo with motion-compensated interpolation
ffmpeg -i input.mp4 \
  -vf "setpts=2*PTS,minterpolate=mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1:fps=60" \
  -an output.mp4
```

Note: `minterpolate` is single-threaded and slow. For production, use RIFE (Layer 3).

### Audio Mixing

```bash
# Original audio + BGM (ducked to 15%) + narration
ffmpeg -i interview.mp4 -i bgm.mp3 -i narration.mp3 \
  -filter_complex "\
    [0:a]volume=1.0[speech];\
    [1:a]volume=0.15[bgm];\
    [2:a]volume=0.9[narr];\
    [speech][bgm][narr]amix=inputs=3:duration=longest" \
  -c:v copy -c:a aac output.mp4
```

### Full Pipeline (Single Command)

```bash
ffmpeg -i input.mp4 \
  -vf "lut3d=kodak2383.cube:interp=trilinear,\
       eq=saturation=0.9:contrast=1.05:brightness=-0.02,\
       noise=alls=8:allf=t+u,\
       crop=iw:iw/2.0:0:(ih-iw/2.0)/2,\
       vignette=PI/4" \
  -c:v libx264 -preset slow -crf 18 -tune grain \
  -pix_fmt yuv420p10le \
  -c:a aac -b:a 192k \
  output.mp4
```

### Free LUT Sources

| Source | LUTs | License |
|--------|------|---------|
| GitHub `imnz730/LUTs` | Kodak 2383 D55.cube | Free |
| Juan Melara (via jonnyelwyn.co.uk) | Kodak 2383, 2393, Fuji 3510 | Free |
| FreshLUTs.com | Various film emulations | CC0 (commercial OK) |
| IWLTBAP Aspen | Kodak Ektar/Vision inspired | Free |
| PremiumBeat | 180+ cinematic LUTs | Free |

## Layer 2: AI Audio ($2–3 per video)

### Background Music — MiniMax Music 2.5

Official API via fal.ai. Generates cinematic instrumental tracks.

```python
import httpx

async def generate_bgm(style: str = "cinematic documentary") -> str:
    resp = await httpx.post(
        "https://queue.fal.run/fal-ai/minimax-music",
        headers={"Authorization": f"Key {FAL_API_KEY}"},
        json={
            "prompt": f"{style}, emotional piano with strings, instrumental",
            "duration": 60,
        },
    )
    return resp.json()["audio_url"]
```

**Cost:** ~$0.035/track. **Why not Suno:** No official API, cookie-based auth, account ban risk. **Why not Udio:** Platform unstable (downloads disabled since Oct 2025, songs disappearing, 2.4/5 Trustpilot).

### English Narration — ElevenLabs

```python
from elevenlabs.client import ElevenLabs

client = ElevenLabs(api_key="...")

audio = client.text_to_speech.convert(
    text="In the summer of 2024, everything changed...",
    voice_id="JBFqnCBsd6RMkjVDRZzb",  # "Josh" — documentary narrator
    model_id="eleven_multilingual_v2",
    output_format="mp3_44100_128",
    voice_settings={
        "stability": 0.7,        # higher = more consistent
        "similarity_boost": 0.8,  # higher = closer to original voice
    },
)

with open("narration.mp3", "wb") as f:
    for chunk in audio:
        f.write(chunk)
```

**Recommended voices:** Josh (documentary/motivational), David (British storyteller), Bill L. Oxley (audiobook).

**Cost:** ~$0.12 per 1,000 characters. A 10-minute narration (~15,000 chars) = ~$1.80.

**v3 (Alpha):** Supports emotional control via audio tags for tone variation.

### Beat-Synced Editing — librosa

```python
import librosa

y, sr = librosa.load("bgm.mp3")
tempo, beat_frames = librosa.beat.beat_track(y=y, sr=sr)
beat_times = librosa.frames_to_time(beat_frames, sr=sr)

# Onset detection (more granular than beats)
onset_frames = librosa.onset.onset_detect(y=y, sr=sr)
onset_times = librosa.frames_to_time(onset_frames, sr=sr)

# Pacing rules:
# - Interview sections: ignore beats, cut on speech pauses
# - Montage sections: cut every 1-2 beats
# - Normal B-roll: cut every 2-4 beats
```

## Layer 3: AI Enhancement (Optional, $5–15 per video)

### B-Roll Generation — Runway Gen-4.5

When the user doesn't have enough B-roll footage, generate it from photos.

```python
from runwayml import RunwayML

client = RunwayML(api_key="...")
task = client.image_to_video.create(
    model="gen4.5",
    prompt_image="https://blob.../office_photo.jpg",
    prompt_text="slow cinematic dolly forward, shallow depth of field, warm lighting",
    ratio="16:9",
    duration=5,
)
result = task.wait_for_task_output(timeout=600)
# result.output_url → 5-second cinematic B-roll clip
```

**Cost:** ~$0.05–0.12/second. A 5-second clip = ~$0.50. Use sparingly — 2-3 AI clips per video max.

**Alternatives:**
| Service | Strength | Cost | Max Duration |
|---------|----------|------|-------------|
| Runway Gen-4.5 | Best API, most stable | ~$0.08/sec | 60s |
| Kling 2.6 | Longest duration, audio included | ~$0.10/sec | 3 min |
| Google Veo 3.1 | 4K quality, transparent pricing | $0.15–0.40/sec | 8s (chainable) |
| Pika 2.5 | Cheapest | ~$0.03/gen | 5s |

### Video Upscaling — Topaz via fal.ai

Upscale iPhone 1080p to 4K with genuine detail enhancement.

```python
resp = await httpx.post(
    "https://queue.fal.run/fal-ai/topaz/upscale/video",
    headers={"Authorization": f"Key {FAL_API_KEY}"},
    json={"video_url": blob_url, "model": "proteus", "scale": 2},
)
```

**Cost:** $0.01/sec (720p), $0.02/sec (1080p), $0.08/sec (4K+).

### AI Slow Motion — RIFE

Open-source frame interpolation. Much better than FFmpeg's `minterpolate`.

- 30fps → 120fps interpolation → play at 24fps = 5x slow-mo
- **Flowframes** wraps RIFE with audio preservation for server-side use
- TensorRT acceleration doubles speed on NVIDIA GPUs

### 2.5D Parallax (Future)

Convert still photos to 3D-feeling video using depth estimation:

```
Photo → Depth Anything V2 (depth map) → Layer separation → Inpaint gaps → Virtual camera render → Video clip
```

Much more impressive than Ken Burns but requires GPU. Premium feature candidate.

## Documentary Editing Patterns

### Pacing Data

| Style | Average Shot Length | Use Case |
|-------|-------------------|----------|
| Documentary (award-winning) | ~15 seconds | Interviews, reflection |
| Modern narrative | 4–6 seconds | General storytelling |
| Action / montage | 2–3 seconds | Energy, progression |
| **Rule of thumb** | 3–5 seconds | Something visual must change |

### Structure Template

```
1. COLD OPEN (3-5s)
   → Best visual, slow-mo, fade from black
   → High quality_score, high energy_level clip

2. INTRO + NARRATION (15-20s)
   → B-roll montage + English narration
   → Ken Burns on photos, crossfade transitions
   → outdoor_walk, b_roll_generic clips

3. INTERVIEW / A-ROLL (main content)
   → Pattern: talking_head(8-12s) → B-roll insert(3-5s) → repeat
   → Original audio + low BGM (15% volume)
   → Cut on speech pauses, not mid-sentence

4. MONTAGE (10-15s)
   → Beat-synced rapid cuts
   → Cut every 1-2 beats
   → energy_level > 0.5 clips
   → BGM volume rises

5. CLOSING (5-10s)
   → Slow-mo + fade to black
   → emotion: "reflective" clips
   → BGM fade out + title card
```

### Clip Selection from Tags

GPT-5.4 Vision tags map directly to editorial roles:

| Tag | Role | Typical Duration |
|-----|------|-----------------|
| `talking_head` | A-roll | 8–15s per segment |
| `outdoor_walk` | B-roll (establishing) | 3–5s |
| `b_roll_generic` | B-roll (illustration) | 3–5s |
| `product_demo` | B-roll (show, don't tell) | 4–6s |
| `screen_recording` | B-roll (tech context) | 3–8s |
| `whiteboard` | B-roll (planning/strategy) | 4–6s |

Quality filter: only use clips with `quality_score > 0.5`.

Energy curve: alternate between high and low `energy_level` clips for rhythm.

## Cost Summary

| Tier | What You Get | Cost per 1-min Video |
|------|-------------|---------------------|
| **Free** | FFmpeg: LUT + letterbox + grain + Ken Burns + transitions | $0 |
| **Standard** | + ElevenLabs narration + MiniMax BGM + beat sync | ~$2–3 |
| **Premium** | + Runway B-roll (3 clips) + Topaz upscale | ~$8–10 |
| **Full** | + RIFE slow-mo + 2.5D parallax | ~$12–15 |

## Fallback: DaVinci Resolve Headless

If FFmpeg quality doesn't pass the "YouTube-proud" bar:

```bash
# Launch headless (no GUI)
/opt/resolve/bin/resolve -nogui &

# Python scripting API
python3 render_script.py
```

Requires DaVinci Resolve installed on server + GPU. Studio version needed for noise reduction and HDR. Use only if FFmpeg proves insufficient.

## Dependencies

```
# Backend (add to pyproject.toml)
librosa          # beat detection
elevenlabs       # English narration TTS

# System (already installed)
ffmpeg 7.1.1     # core rendering engine

# Optional
runwayml         # AI B-roll generation
flowframes       # RIFE slow-motion wrapper
```

## API Status (as of March 2026)

| Service | Official API | Status |
|---------|-------------|--------|
| Runway (Gen-4.5) | Yes (PyPI SDK) | Active, stable |
| Kling 2.6 | Yes (klingai.com + fal.ai) | Active |
| Google Veo 3.1 | Yes (Gemini API) | Active |
| Pika 2.5 | Yes (via fal.ai) | Active |
| ElevenLabs | Yes (REST + Python SDK) | Active, best TTS |
| MiniMax Music 2.5 | Yes (via fal.ai) | Active, best value BGM |
| Topaz Video AI | Yes (fal.ai + direct) | Active |
| Suno | No official API | Third-party only, ban risk |
| Udio | No official API | Unstable platform, avoid |
| OpenAI Sora | Shutdown March 24, 2026 | Dead. Do not use. |

## Validation Checklist

Before building the full pipeline, validate FFmpeg quality (TODOS.md item):

1. Download Kodak 2383 .cube from GitHub `imnz730/LUTs`
2. Record 3 test clips on iPhone: talking head, outdoor walk, screen recording
3. Run the "Full Pipeline" command above
4. Compare side-by-side with a manually graded version from CapCut
5. Does it pass the "would I put this on YouTube?" bar?

If yes → build on FFmpeg. If no → evaluate DaVinci Resolve headless.
