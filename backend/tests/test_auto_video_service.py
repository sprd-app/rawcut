"""Tests for auto_video_service — trim heuristics, title generation, time estimation."""

from datetime import datetime

import pytest

from app.services.auto_video_service import (
    compute_trims,
    estimate_render_time,
    generate_title,
)


# ---------------------------------------------------------------------------
# generate_title
# ---------------------------------------------------------------------------


class TestGenerateTitle:
    def test_multiple_types(self):
        clips = [
            {"content_type": "talking_head"},
            {"content_type": "outdoor_walk"},
            {"content_type": "talking_head"},
        ]
        title = generate_title(clips, datetime(2026, 3, 29))
        assert "3월 29일" in title
        assert "인터뷰" in title

    def test_single_type(self):
        clips = [
            {"content_type": "b_roll_generic"},
            {"content_type": "b_roll_generic"},
            {"content_type": "b_roll_generic"},
        ]
        title = generate_title(clips, datetime(2026, 3, 29))
        assert title == "3월 29일 · 일상"

    def test_unknown_type(self):
        clips = [{"content_type": "something_new"}]
        title = generate_title(clips, datetime(2026, 1, 15))
        assert "1월 15일" in title
        assert "something_new" in title

    def test_all_null_content_type(self):
        clips = [{"content_type": None}, {"content_type": None}]
        title = generate_title(clips, datetime(2026, 12, 1))
        assert title == "12월 1일 · 영상"

    def test_empty_clips(self):
        title = generate_title([], datetime(2026, 6, 5))
        assert title == "6월 5일 · 영상"

    def test_mixed_null_and_real(self):
        clips = [
            {"content_type": None},
            {"content_type": "outdoor_walk"},
            {"content_type": None},
        ]
        title = generate_title(clips, datetime(2026, 3, 29))
        assert "야외" in title


# ---------------------------------------------------------------------------
# compute_trims
# ---------------------------------------------------------------------------


class TestComputeTrims:
    def test_short_clip_no_trim(self):
        clips = [{"duration": 3.0, "content_type": "b_roll_generic"}]
        result = compute_trims(clips)
        assert result[0]["trim_start"] == 0.0
        assert result[0]["trim_end"] is None

    def test_5s_boundary_no_trim(self):
        clips = [{"duration": 5.0, "content_type": "b_roll_generic"}]
        result = compute_trims(clips)
        assert result[0]["trim_end"] is None

    def test_medium_clip_trim_to_5s(self):
        clips = [{"duration": 10.0, "content_type": "b_roll_generic"}]
        result = compute_trims(clips)
        assert result[0]["trim_end"] == 5.0

    def test_15s_boundary_trim_to_5s(self):
        clips = [{"duration": 15.0, "content_type": "b_roll_generic"}]
        result = compute_trims(clips)
        assert result[0]["trim_end"] == 5.0

    def test_long_clip_trim_to_8s(self):
        clips = [{"duration": 30.0, "content_type": "b_roll_generic"}]
        result = compute_trims(clips)
        assert result[0]["trim_end"] == 8.0

    def test_60s_boundary_trim_to_8s(self):
        clips = [{"duration": 60.0, "content_type": "b_roll_generic"}]
        result = compute_trims(clips)
        assert result[0]["trim_end"] == 8.0

    def test_very_long_clip_trim_to_10s(self):
        clips = [{"duration": 120.0, "content_type": "outdoor_walk"}]
        result = compute_trims(clips)
        assert result[0]["trim_end"] == 10.0

    def test_talking_head_under_30s_full_duration(self):
        clips = [{"duration": 25.0, "content_type": "talking_head"}]
        result = compute_trims(clips)
        assert result[0]["trim_end"] is None  # full duration

    def test_talking_head_exactly_30s_full_duration(self):
        clips = [{"duration": 30.0, "content_type": "talking_head"}]
        result = compute_trims(clips)
        assert result[0]["trim_end"] is None

    def test_talking_head_over_30s_trimmed(self):
        clips = [{"duration": 45.0, "content_type": "talking_head"}]
        result = compute_trims(clips)
        assert result[0]["trim_end"] == 8.0

    def test_null_duration_default_5s(self):
        clips = [{"duration": None, "content_type": "outdoor_walk"}]
        result = compute_trims(clips)
        assert result[0]["trim_end"] == 5.0

    def test_180s_advisory_limit_reduces_talking_heads(self):
        clips = [
            {"duration": 25.0, "content_type": "talking_head"},  # 25s full
            {"duration": 25.0, "content_type": "talking_head"},  # 25s full
            {"duration": 25.0, "content_type": "talking_head"},  # 25s full
            {"duration": 25.0, "content_type": "talking_head"},  # 25s full
            {"duration": 25.0, "content_type": "talking_head"},  # 25s full
            {"duration": 25.0, "content_type": "talking_head"},  # 25s full
            {"duration": 25.0, "content_type": "talking_head"},  # 25s full
            {"duration": 25.0, "content_type": "talking_head"},  # 25s full = 200s > 180s
        ]
        result = compute_trims(clips)
        # After enforcement, talking heads > 10s should be trimmed to 10s
        for clip in result:
            assert clip["trim_end"] == 10.0

    def test_under_180s_no_reduction(self):
        clips = [
            {"duration": 20.0, "content_type": "talking_head"},
            {"duration": 20.0, "content_type": "talking_head"},
            {"duration": 20.0, "content_type": "talking_head"},
        ]
        result = compute_trims(clips)
        # Total 60s < 180s, no reduction
        for clip in result:
            assert clip["trim_end"] is None


# ---------------------------------------------------------------------------
# estimate_render_time
# ---------------------------------------------------------------------------


class TestEstimateRenderTime:
    def test_basic_formula(self):
        # 30 + 15*5 + 60*0.3 = 30 + 75 + 18 = 123
        assert estimate_render_time(5, 60.0) == 123

    def test_single_clip(self):
        # 30 + 15*1 + 10*0.3 = 30 + 15 + 3 = 48
        assert estimate_render_time(1, 10.0) == 48

    def test_many_clips(self):
        result = estimate_render_time(20, 300.0)
        assert result == int(30 + 15 * 20 + 300.0 * 0.3)
