# rawcut

Personal media cloud for creators. iOS app + Azure cloud backend.

## What this is

rawcut syncs your iPhone photos/videos to Azure Blob Storage (replacing iCloud for media), auto-tags them with GPT-5.4 Vision, and lets you search your footage with natural language. Future: AI-powered cinematic vlog editing via swipe-to-select.

## Architecture

```
iPhone (Swift/SwiftUI, iOS 17+)
  ├── Media Hub: background sync to Azure Blob
  ├── Auto-tagging: GPT-5.4 Vision (background)
  ├── Search: natural language over tags
  └── Auth: Sign in with Apple

Cloud (Azure)
  ├── FastAPI on Container Apps
  ├── Azure Blob Storage (Hot + Cool tiers)
  ├── SQLite (aiosqlite) for metadata
  └── GPT-5.4 Vision API for clip analysis
```

## Project structure

- `ios/` - Xcode project (Swift 6, SwiftUI, iOS 17+)
- `backend/` - Python FastAPI backend
- `infra/` - Azure Bicep IaC
- `prototypes/` - Quality validation scripts
- `DESIGN.md` - Design system (colors, typography, spacing, motion)
- `TODOS.md` - Tracked work items

## Commands

### Backend
```bash
cd backend && python -m uvicorn app.main:app --reload
```

### Tests
```bash
cd backend && python -m pytest tests/
```

## Key decisions

- Upload: URLSession background upload -> backend proxy -> Azure Blob (not direct SAS)
- DB: SQLite via aiosqlite (single tenant)
- Clip analysis: GPT-5.4 Vision only (no CLIP/GPU VM for V1)
- Auth: Sign in with Apple (Phase 0)
- Render workers: HTTP callback to API (not shared DB)
- UI language: Korean first, English V2
- Strategic position: media cloud is the product, editing is the hook
