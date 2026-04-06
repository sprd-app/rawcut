# rawcut Design System

## Color Palette

| Token | Value | Usage |
|-------|-------|-------|
| `background` | #000000 | Pure black. OLED-friendly. Main app background |
| `surface` | #1C1C1E | Cards, modals, elevated containers (Apple secondarySystemBackground) |
| `surfaceElevated` | #2C2C2E | Active/selected elements, input fields (Apple tertiarySystemBackground) |
| `accent` | #5BBFB6 | Clean teal. Primary actions, interactive states only |
| `accentDim` | #4DA69C | Teal at 85%. Secondary accent uses |
| `textPrimary` | #FFFFFF | Headlines, primary labels (pure white) |
| `textSecondary` | #8E8E93 | Body text, descriptions (Apple systemGray) |
| `textTertiary` | #48484A | Placeholders, hints, metadata (Apple systemGray3) |
| `success` | #5BBFB6 | Same as accent. Sync complete, render done |
| `error` | #FF453A | Upload failed, render failed (Apple systemRed dark) |
| `warning` | #FF9F0A | Sync paused, low storage (Apple systemOrange dark) |

## Typography (SF Pro)

| Level | Font | Size | Weight | Design | Usage |
|-------|------|------|--------|--------|-------|
| `display` | SF Pro | 32pt | Semibold | Default | Hero moments, brand |
| `displayMedium` | SF Pro | 26pt | Semibold | Default | Sub-hero text |
| `titleLarge` | SF Pro | 28pt | Medium | Default | Screen titles |
| `titleMedium` | SF Pro | 20pt | Medium | Default | Section headers |
| `body` | SF Pro Text | 15pt | Regular | Default | Body text, descriptions |
| `caption` | SF Pro Text | 12pt | Regular | Default | Metadata, timestamps, badges |
| `tabBar` | SF Pro Text | 10pt | Medium | Default | Tab bar labels |
| `stat` | SF Pro | 24pt | Medium | Monospaced | Numbers, stats, cost display |

No rounded fonts — clean, restrained aesthetic. Dynamic Type: All text scales with user's accessibility settings. Minimum touch target remains 44pt.

## Spacing (8pt grid)

| Token | Value | Usage |
|-------|-------|-------|
| `xs` | 4pt | Tight gaps (badge margins, inline spacing) |
| `sm` | 8pt | Component internal padding |
| `md` | 12pt | Card padding, list item spacing |
| `lg` | 16pt | Screen margins, section spacing |
| `xl` | 24pt | Major section gaps |
| `xxl` | 32pt | Screen-level separators |

Grid: 3-column thumbnail grid with 2pt gap. Card corner radius: 10pt. Tab bar height: 49pt (iOS standard).

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
Full-bleed preview video occupying top 60% of card. Cinematic preset badge (e.g., "Warm Film") as pill in top-left corner with `accent` background. Description and metadata below video. Card has subtle shadow (0, 4, 12, rgba(0,0,0,0.3)) and 10pt corner radius.

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
