# TODOS

## Design: Matching Algorithm for option_generator.py
**Priority:** HIGH — blocks Phase 2 implementation
**What:** Design the clip-to-segment matching algorithm: scoring weights for GPT-4o tags (content type, quality, energy, emotion), threshold for valid matches, fallback logic when no clips match a segment, and how cinematic presets (Warm Film, Cool Minimal, Natural Vivid) modify the scoring.
**Why:** This is the taste engine — the core product differentiation. Bad matching produces bad edit options, and the whole swipe UX falls apart. The outside voice in the eng review flagged this as the biggest blind spot.
**Context:** GPT-4o Vision tags each clip with content type, quality (0-1), energy (0-1), and emotion. Claude parses the script into segments with mood, energy, shot_types, and keywords. The matching engine scores clips against segments and picks the top N for each of 3 options. No formula exists yet.
**Depends on:** GPT-4o Vision tag taxonomy (Phase 2 Track B) — need to know what tags look like before designing weights.

## Prototype: FFmpeg Cinematic Quality Validation
**Priority:** HIGH — gates entire rendering architecture (Day 1)
**What:** Download 2-3 cinematic LUTs (Kodak 2383, Fuji 3513 style .cube files). Record 2-3 short clips on iPhone (talking head, outdoor walk, screen recording). Run FFmpeg with `lut3d` filter + crossfade transitions + audio mixing. Evaluate output: does it pass the "YouTube-proud" bar?
**Why:** If FFmpeg with LUTs can't produce cinematic quality, the rendering architecture needs to change (DaVinci Resolve headless, MLT, or a different approach). This is the #1 risk in the project.
**Context:** Use 16-bit precision for LUT application to avoid banding. Test command: `ffmpeg -i input.mp4 -vf "lut3d=kodak2383.cube" -c:v libx264 -b:v 10M output.mp4`. Compare side-by-side with a manually graded version from CapCut.
**Depends on:** Nothing. Can run on local machine with FFmpeg 7.1.1 already installed.

## Visual Mockups: Generate AI Design Mockups
**Priority:** MEDIUM — improves design quality but not a blocker
**What:** Run /design-consultation or /design-shotgun to generate visual mockups for all key screens (Media Hub, Swipe Review, Script Input, Render Status, Onboarding). Use the gstack designer binary with the DESIGN.md tokens as constraints.
**Why:** DESIGN.md defines the system in tokens (colors, fonts, spacing) but there's no visual reference. Mockups catch issues that text descriptions miss: does the teal accent work on pure black? Is the segment numeral watermark readable? Does the swipe card feel heavy enough?
**Context:** The gstack designer (`$D`) is installed but requires a verified OpenAI org. Once verified, mockups take ~40s each to generate. The /office-hours wireframe at /tmp/gstack-sketch-rawcut.html serves as a rough starting point.
**Depends on:** OpenAI org verification at https://platform.openai.com/settings/organization/general

## Extract Shared DB Helpers
**Priority:** P2
**What:** Extract `_verify_project_ownership` and `_row_to_dict` from `projects.py` and `renders.py` into `app/helpers/db.py`. Both functions are duplicated identically; `auto_video_service.py` will need them too, making it a 3x duplication.
**Why:** DRY violation flagged in CEO review. Adding auto-video makes the duplication worse.
**Effort:** S (human: ~30 min / CC: ~5 min)
**Depends on:** Nothing

## Render Job Recovery on Container Restart
**Priority:** P2
**What:** Add a startup check in `init_db()`: any render with `status='processing'` and `created_at` older than 10 minutes should be marked `status='failed'` with `error='Container restarted during render.'`
**Why:** If Azure Container Apps recycles the container mid-render, the render job stays in 'processing' forever with no recovery. Auto-video increases render frequency, making this more likely. Flagged by outside voice in CEO review.
**Effort:** S (human: ~1 hour / CC: ~10 min)
**Depends on:** Nothing

## Calibrate Render Time Estimates
**Priority:** P3 (after first 10 renders)
**What:** Log actual render times (start/end) and compare against the formula `30 + (15 * clip_count) + (total_duration * 0.3)`. Adjust constants based on real data from 10+ renders.
**Why:** The estimate formula is uncalibrated. Wildly wrong estimates create worse UX than no estimate. Need real data to tune.
**Effort:** S (human: ~30 min / CC: ~5 min)
**Depends on:** Auto-video shipped + real usage data

## App Store Positioning: Media Cloud, Not Video Editor
**Priority:** P2 — before TestFlight public launch
**What:** Define App Store listing (title, subtitle, keywords, screenshots, description) that positions rawcut as a personal media cloud for creators, not a video editor.
**Why:** If positioned as video editor, competing with CapCut (2B downloads). As media cloud, competing with iCloud alternatives (much smaller, less saturated field). The CEO review reframed rawcut's strategy: media cloud IS the product, editing is the hook.
**Context:** Key competitors in media cloud space: Google Photos (free tier shrinking), iCloud (expensive for heavy shooters), Amazon Photos (Prime only). rawcut's angle: affordable, auto-tagging, creator-focused. Editing is the future differentiator but not the launch positioning.
**Effort:** S (human: ~1 day / CC: ~2 hours)
**Depends on:** V1 cloud features finalized (auto-tag, search, timeline, cost dashboard)
