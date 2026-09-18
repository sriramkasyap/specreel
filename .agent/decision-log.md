# Local Loom — Decision Log

## 2026-09-17 22:45 — Stop never reached Save

| Confidence | Decision | Where | Reasoning | Spec link |
|---|---|---|---|---|
| Medium | Salvage the temp mp4 if pipeline prep times out instead of waiting forever | `RecordingEngine.salvageTimedOutRecording` | Save panel only appears after `engine.stop()` returns; a hung pipeline must not block that | unlinked |
| High | Bound stop with OnceGate, not TaskGroup | `RecordingEngine.swift` | TaskGroup still joins hung `stopCapture` / `finishWriting` children, so the 8s timeout never unblocked Stop | unlinked |
| High | Fire-and-forget `SCStream.stopCapture` | `teardownCaptureOnly` | That call has been observed never to return; `isStopping` already drops further samples | unlinked |

## 2026-09-17 18:56 — Stop hangs with Start recording spinner

| Confidence | Decision | Where | Reasoning | Spec link |
|---|---|---|---|---|
| Medium | Bound `SCStream.stopCapture` at 2.5s and `finishWriting` at 8s | `RecordingEngine.swift` | Either can wait forever; idle was already published so the UI showed Start+spinner | unlinked |
| High | Don't publish `.idle` until stop fully finishes | `performStop` | Idle + `isBusy` is exactly the Start recording loader the user saw | unlinked |
| High | Single-flight `stop()` so pill and window share one finalize | `RecordingEngine.swift` | Two Stop taps raced finalize after idle was delayed | unlinked |

## 2026-09-17 14:36 — Rebuild main window to match layout mock

| Confidence | Decision | Where | Reasoning | Spec link |
|---|---|---|---|---|
| Low | Keep system appearance instead of forcing the mock's light chrome | `MainWindow.swift` | User's screenshot is Dark Mode; matching structure and column spec is the miss, not painting the window light | unlinked |
| Medium | Size `HSplitView` with `GeometryReader` instead of `NavigationStack` | `MainWindow.swift` | NavigationStack proposed a short height so the three columns sat in a band with empty chrome above and below | linked |
| High | Hide the 320pt inspector until a clip is selected (or New Recording is open) | `MainWindow.swift` | Mock sticky: inspector collapses when nothing is selected | linked |
| High | Sidebar is Library (All/Recent) + Source (Screen/Window/Region); New Recording lives in the toolbar | `LibrarySidebar.swift` | Read directly from the gallery frame and yellow spec notes at 115% zoom | linked |

## 2026-09-17 13:12 — Refactor UI to layout reference

| Confidence | Decision | Where | Reasoning | Spec link |
|---|---|---|---|---|
| Low | Sidebar uses smart filters (All / Recents / Camera) instead of user folders | `LibrarySidebar.swift` | Artifact gallery sidebar looks folder-like, but `RecordingStore` has no folder model and the yellow notes were unreadable at 26% zoom | unlinked |
| Low | New Recording canvas previews via `SCScreenshotManager` snapshot, not a live SCStream | `CapturePreviewCanvas.swift` | Avoids a second capture stream fighting the recorder; still shows source + circular webcam PiP | unlinked |
| Medium | Three-column `HSplitView` (sidebar \| gallery/canvas \| inspector) instead of config\|gallery | `MainWindow.swift` | Matches the artifact's library chrome; keeps hard column mins so controls don't clip | partially linked |
| Medium | Region overlay confirms from a bottom toolbar, not mouse-up | `RegionSelector.swift` | Artifact shows handles + Cancel/Confirm; auto-confirm on release made the toolbar unreachable | partially linked |
| High | One `RecordingSessionController` for popover and main-window Record | `RecordingSessionController.swift` | Countdown, pill, and post-save panel must stay identical whichever surface starts the take | linked |

## 2026-09-17 12:52 — Fix AVAssetWriter finishWriting crash on Stop

| Confidence | Decision | Where | Reasoning | Spec link |
|---|---|---|---|---|
| High | Call `cancelWriting` instead of `finishWriting` when no `startSession` (status `.writing` / 1) | `finalizeWriter` | Apple throws NSInternalInconsistencyException if you finish without a session — common on static screens (Trap 2) | linked |
| High | Set `isStopping` + pipeline barrier before finalize | `stop()` | Prevents late sample appends racing `finishWriting` | unlinked |
| Medium | Route stream-death through `stop()` | `handleStreamStopped` | Avoids double-finalize races with user Stop | partially linked |

## 2026-09-17 12:45 — Fix OPERATOR build/open paths

| Confidence | Decision | Where | Reasoning | Spec link |
|---|---|---|---|---|
| High | Document Debug + `SYMROOT=./build` as the default CLI path; Release only when `-configuration Release` | `docs/OPERATOR.md`, `scripts/dev.sh` | Plain `xcodebuild build` never created `build/Release/` — it used DerivedData/Debug | linked |

## 2026-09-17 12:40 — Fix app freeze on Record

| Confidence | Decision | Where | Reasoning | Spec link |
|---|---|---|---|---|
| High | Process SCStream samples on a serial `pipelineQueue` with no per-frame `Task` | `RecordingEngine.swift` | Unbounded Tasks per frame raced the writer and starved the UI within ~2–4s | unlinked |
| High | Publish `phase` / `elapsed` only via `MainActor` | `RecordingEngine.swift` | `@Observable` updates off the main thread hang SwiftUI (pill + menu bar) | unlinked |
| High | Skip CIContext compositor when webcam is off | `processScreenSample` | Default path was Metal-rendering every frame for no reason | unlinked |
| Medium | Coalesce pending screen frames while draining | `enqueueScreenSample` | Keeps realtime capture from queuing a multi-second backlog under load | unlinked |

## 2026-09-17 12:30 — Stop Screen Recording re-prompt on Recordings open

| Confidence | Decision | Where | Reasoning | Spec link |
|---|---|---|---|---|
| High | Preflight with `CGPreflightScreenCaptureAccess` and skip `SCShareableContent` on window appear when denied | `ScreenCaptureAccess.swift`, `RecordingConfigView.swift` | Opening Recordings called SCK every time, which re-triggered the system TCC sheet | linked |
| High | Only call `CGRequestScreenCaptureAccess` from Grant / Record / region-select | Capture + Engine | System prompt must be user-initiated, never a side effect of browsing the gallery | linked |
| Medium | Surface stale-grant quit/relaunch hint in the banner | `RecordingConfigView.swift` | Common when Settings shows LocalLoom on but this DerivedData build isn't the granted binary | partially linked |

## 2026-09-17 12:28 — Fix broken Recordings window layout

| Confidence | Decision | Where | Reasoning | Spec link |
|---|---|---|---|---|
| Medium | Replace `NavigationSplitView` with `HSplitView` + `NavigationStack` for main window | `MainWindow.swift` | Sidebar column was clipping GroupBox/segmented controls into unreadable fragments; HSplitView keeps a hard min width (320) | partially linked |
| Medium | Map raw TCC denial strings to an actionable Screen Recording banner + Settings deep-link | `RecordingConfigView.swift` | Screenshot showed truncated "The user declined TCCs for…" with no recovery path | partially linked |
| High | Stack gain/size sliders as label-above-control instead of `LabeledContent` | `RecordingConfigView.swift` | Horizontal `LabeledContent` was the main clip culprit in narrow columns | unlinked |
| High | Shorten resolution segment labels to "1440p" / "Native" | `RecordingConfigView.swift` | "1440p cap" + long caption overflowed the Quality GroupBox | unlinked |

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