# Local Loom — Decision Log

## Phase 1 — TRD (Claude Code PM/Tech Lead)

| Decision | Rationale | Source |
|----------|-----------|--------|
| H.264 High default codec | Universal playback, no browser surprises | TRD §2 |
| Skip raw webcam alongside composite | YAGNI — no current use case for re-compositing later | TRD §2 |
| Default 1440p capture with native-res toggle | Sweet spot for screen recording — 5K is overkill for text | TRD §2 |
| 30fps default | Correct for almost all screen content | TRD §2 |
| API currency verified: SCStream capabilities stable through macOS 26 | Web search confirmed captureMicrophone/microphoneCaptureDeviceID unchanged | Phase 1 |

## Bootstrap Adaptation (Swift vs pnpm monorepo)

| Practice | Adapted? | How |
|----------|----------|-----|
| Protected main, PR-before-merge | Yes | Same practice, no monorepo tooling needed |
| Per-milestone branches | Yes | m0-skeleton through m7-polish |
| Conventional Commits | Yes | feat:/fix:/test:/docs: as usual |
| Acceptance gates before merge | Yes | Manual per-milestone tests per TRD §3 |
| Decision log | Yes | This file |
| pnpm/Turborepo layout | No | Single Xcode target, no workspace boundaries |
| 95% coverage gate | Partial | Coverage enforced on testable modules (AudioMixer, CoordinateConversion, RecordingMeta, RecordingStore) but not on SCK/camera paths that need real hardware |

## Phase 2 — Builder (Cursor Agent)

| Decision | Rationale |
|----------|-----------|
| Used xcodegen (project.yml) instead of raw .xcodeproj | Cleaner spec-driven project config; xcodegen was available |
| Converted RecordingEngine from `actor` to `@Observable final class` with NSLock | Swift 6 Observation cannot compose with actor isolation; views use @Environment which needs @Observable |
| RecordingStore changed from ObservableObject to @Observable | Consistent @Environment pattern across all views |
| GalleryView rewritten against RecordingEntry API | Builder wrote gallery against speculative API; actual RecordingEntry uses .meta.title, .videoURL, .thumbnailURL |
| Test files rewritten against actual API | Builder wrote tests against design-time spec that diverged from implementation |
| Thumbnail generation made best-effort (non-fatal on failure) | Enables save to succeed with test/placeholder video data |
| Product name changed from "Local Loom" (with space) to "LocalLoom" | Space in product name broke TEST_HOST path resolution; "Local Loom" display name preserved via Info.plist CFBundleDisplayName |

## Phase 3 — QA Gate (Claude Code)

| Iteration | Verdict | Fixes Applied |
|-----------|---------|---------------|
| 1 | GATE:FAIL | Tests did not compile (API mismatch between test spec and implementation) |
| 2 | GATE:PASS | All 14 tests rewritten to match actual APIs and passing |

## Phase 4 — Operator Doc

Written to `docs/OPERATOR.md` covering install, permissions, signing, recordings backup, troubleshooting.