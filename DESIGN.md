# rawcut Design System

## Color Palette

| Token | Value | Usage |
|-------|-------|-------|
| `background` | #000000 | Pure black. OLED-friendly. Main app background |
| `surface` | #1A1A1A | Cards, modals, elevated containers |
| `surfaceElevated` | #222222 | Active/selected elements, input fields |
| `accent` | #4ECDC4 | Teal. Primary actions, selected states, sync indicators |
| `accentDim` | #3AA89F | Teal at 80%. Secondary accent uses |
| `textPrimary` | #FFFFFF | Headlines, primary labels |
| `textSecondary` | #888888 | Body text, descriptions |
| `textTertiary` | #555555 | Placeholders, hints, metadata |
| `success` | #4ECDC4 | Same as accent. Sync complete, render done |
| `error` | #FF4444 | Upload failed, render failed |
| `warning` | #FFB347 | Sync paused, low storage |

## Typography (SF Pro)

| Level | Font | Size | Weight | Tracking | Usage |
|-------|------|------|--------|----------|-------|
| `titleLarge` | SF Pro Display | 28pt | Semibold | -0.5 | Screen titles |
| `titleMedium` | SF Pro Display | 20pt | Semibold | -0.3 | Section headers |
| `body` | SF Pro Text | 15pt | Regular | 0 | Body text, descriptions |
| `caption` | SF Pro Text | 12pt | Regular | 0 | Metadata, timestamps, badges |
| `tabBar` | SF Pro Text | 10pt | Medium | 0 | Tab bar labels |
| `segmentNumber` | SF Pro Display | 64pt | Ultralight | -1.0 | Background segment numerals |

Dynamic Type: All text scales with user's accessibility settings. Minimum touch target remains 44pt.

## Spacing (8pt grid)

| Token | Value | Usage |
|-------|-------|-------|
| `xs` | 4pt | Tight gaps (badge margins, inline spacing) |
| `sm` | 8pt | Component internal padding |
| `md` | 12pt | Card padding, list item spacing |
| `lg` | 16pt | Screen margins, section spacing |
| `xl` | 24pt | Major section gaps |
| `xxl` | 32pt | Screen-level separators |

Grid: 3-column thumbnail grid with 2pt gap. Card corner radius: 12pt. Tab bar height: 49pt (iOS standard).

## Motion

| Animation | Spec | When |
|-----------|------|------|
| `swipeSelect` | `.spring(response: 0.35, dampingFraction: 0.8)` | Card flies off-screen on swipe right |
| `swipeCycle` | `.spring(response: 0.3, dampingFraction: 0.85)` | Card slides left, next slides in |
| `cardAppear` | `.easeOut(duration: 0.25)` | Card enters view |
| `shimmer` | Linear gradient sweep, 1.5s cycle | Loading placeholders |
| `syncPulse` | `.easeInOut(duration: 1.0).repeatForever()` | Upload indicator |
| `progressRing` | `.easeInOut(duration: 0.5)` | Render progress updates |

Haptics:
- `.impact(.medium)` on swipe select (right)
- `.impact(.light)` on swipe cycle (left)
- `.impact(.soft)` on regenerate (up/down)
- `.notification(.success)` on render complete

Reduced Motion: When `UIAccessibility.isReduceMotionEnabled`, replace spring animations with `.easeOut(duration: 0.2)` and disable shimmer/pulse loops.

## Component Patterns

### Segment Cards (Script Input)
Full-width cards on `surface` background. Large, light segment number (64pt, `textTertiary`) as background watermark. Title in `titleMedium`. Description in `body`. NO colored left-border.

### Option Cards (Swipe Review)
Full-bleed preview video occupying top 60% of card. Cinematic preset badge (e.g., "Warm Film") as pill in top-left corner with `accent` background. Description and metadata below video. Card has subtle shadow (0, 4, 12, rgba(0,0,0,0.3)) and 16pt corner radius.

### Thumbnails (Media Hub)
Square aspect ratio, 2pt gap grid. Sync indicator: 8pt circle in bottom-right corner. Video duration badge: bottom-right, semi-transparent black pill.

### Tab Bar
Standard iOS tab bar, `surface` background. Active tab: `accent` color. Inactive: `textTertiary`. Center "Create" tab: slightly larger icon, `accent` background circle.

### Empty States
Always include: (1) a relevant illustration or icon at 64pt, (2) a warm headline, (3) a one-line description, (4) a primary action button in `accent`. Never just "No items found."

## Accessibility

- All interactive elements: 44pt minimum touch target
- VoiceOver labels for all swipe gestures ("Swipe right to select this edit option")
- Color contrast: all text/background pairs meet WCAG AA (4.5:1 for body, 3:1 for large text)
- Dynamic Type support: all text scales. Layout adapts. No truncation without disclosure.

## Navigation Structure

```
Tab Bar (persistent, surface background)
├── Library         ← Media Hub, default tab
├── + Create        ← Vlog Editor (multi-step navigation stack)
├── Projects        ← Past vlogs list
└── Settings        ← Account, sync, storage
```

Create flow is a NavigationStack within the tab:
Select footage → Script → Music → Wait → Swipe Review → Render → Done
