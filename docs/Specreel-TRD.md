# Specreel — Technical Requirements Document

Status: ready for build. Source: `docs/screen-recorder-build-plan.md`. This document translates that plan into module contracts, locked decisions, acceptance criteria, and process rules a builder (human or agent) can execute against without further judgment calls. No implementation code below — contracts and prose only.

API currency note: verified Sep 2026 against WWDC 2024 `SCRecordingOutput`, `SCStreamConfiguration.captureMicrophone`/`microphoneCaptureDeviceID`, and `SCStreamOutputType` (`.screen`/`.audio`/`.microphone`). All stable through macOS 26; no deprecations found. The plan's API names are current — build against them as written.

---

## 1. Architecture & Module Contracts

### 1.1 Data-flow shape

Two producers → one compositor/mixer stage → one writer. The screen stream is the only clock source; nothing else is allowed to drive timing.

```
SCStream ──┬── .screen  CMSampleBuffer ─────────────┐
           ├── .audio   system PCM ─────┐           │
           └── .microphone  mic PCM ────┤           │
                                        ▼           ▼
AVCaptureSession ── webcam frame ──► [latch]   [Compositor: CIContext/Metal]
                                        │             │
                                        ▼             ▼
                                  [AudioMixer]   CVPixelBuffer
                                  AVAudioConverter    │
                                  → 48k/stereo/f32    │
                                        │             │
                                        ▼             ▼
                              AVAssetWriterInput(aac)  AVAssetWriterInput(h264)
                                        └──────┬───────┘
                                               ▼
                                        recording.mp4
```

### 1.2 Concurrency model

- **Screen clock master.** The first `.screen` buffer's PTS is the value passed to `startSession(atSourceTime:)`. Every other timestamp (mic, system audio) is already in that domain because both route through `SCStream`, not `AVCaptureSession`. Do not build a second clock domain or a resampling/drift-correction path — that problem only exists pre-macOS 15 and this plan explicitly floors at 15.
- **Webcam latch, not a clock source.** The `AVCaptureSession` delegate writes each incoming frame into a lock-protected slot (single `NSLock` or `OSAllocatedUnfairLock` around a `CVPixelBuffer?`). The compositor reads whatever is currently latched when a screen frame arrives — no queue, no timestamp matching, no wait. Frame-rate mismatch between camera and screen is expected and invisible; do not add synchronization logic here.
- **Single-actor `RecordingEngine`.** Three separate delegate queues (`SCStream` output, `AVCaptureSession` output, `AVAssetWriter` readiness) all touch state that must stay consistent (current PTS offset, pause state, writer inputs). Model `RecordingEngine` as a Swift `actor` owning all of it, with delegate callbacks hopping into the actor via `Task { await ... }` rather than mutating shared state directly from arbitrary queues. This is the single concurrency primitive in the app — do not introduce additional actors, combine pipelines, or reactive frameworks for this.

### 1.3 Module contracts

Each module below is specified as: **owns / inputs / outputs / does not own**.

**`MenuBarController`**
- Owns: status item, popover, persisted "last config" read/write to `UserDefaults`.
- Input: user clicks (status item, Record button, disclosure toggle).
- Output: calls into `RecordingEngine.start(config:)` / `.stop()`; updates its own icon glyph from `RecordingEngine` state (idle / recording+timer / paused).
- Does not own: recording state itself (that's `RecordingEngine`'s), device enumeration (that's `CaptureSourcePicker`).

**`MainWindow`**
- Owns: window lifecycle only. Must set `applicationShouldTerminateAfterLastWindowClosed = false`.
- Hosts: `GalleryView` + expanded `RecordingConfigView`.
- Does not own: any recording state — it's a view onto the same state `MenuBarController` reads.

**`RecordingConfigView`**
- Input: `RecordingConfig` (source, camera, mic, PiP settings) as a shared observable model.
- Output: mutations to that same model, consumed identically by popover (compact) and main window (expanded) hosts.
- Contract: exactly one implementation, parameterized by a display-mode enum (`compact` / `expanded`). Two implementations is an explicit anti-goal per the plan — it produces state divergence bugs between popover and window.

**`PostRecordingPanel`**
- Owns: its own floating `NSWindow`, independent of `MainWindow`'s existence.
- Input: `RecordingEngine.stop()` result (`URL` to temp file + captured metadata: duration, dimensions, fps, source description).
- Output: on Save, calls `RecordingStore.save(...)`; on Discard/Esc, deletes the temp file.
- Contract: must never be a sheet/child of `MainWindow`. Must appear even if `MainWindow` was never opened.

**`CaptureSourcePicker`**
- Owns: nothing persistent. Wraps `SCShareableContent` enumeration.
- Output: filtered list of displays/windows/apps (excludes zero-size windows, the app's own windows, system UI chrome) on every open — no caching across opens.

**`RegionSelector`**
- Input: none (user-driven drag).
- Output: `(CGRect, SCDisplay)` pair, in the coordinate space documented in §4 below.
- Owns: a transient borderless `NSWindow` at `.screenSaver` level spanning all screens; torn down on confirm/cancel.

**`RecordingEngine`** (actor)
- Owns: `SCStream`, `AVCaptureSession`, `Compositor`, `AudioMixer`, `AVAssetWriter`, pause-duration accumulator.
- API surface: `start(config: RecordingConfig) async throws`, `pause() async`, `resume() async`, `stop() async throws -> RecordingResult`.
- Output: `RecordingResult` (file URL + duration + dimensions + fps + source description) handed to `PostRecordingPanel`.
- Does not own: UI state, persistence format (that's `RecordingStore`).

**`Compositor`**
- Input: screen `CVPixelBuffer` + latched webcam `CVPixelBuffer?` (nil when webcam off).
- Output: composited `CVPixelBuffer` drawn from a `CVPixelBufferPool` (pool avoids per-frame allocation).
- Config: PiP corner (4-way), size (% of frame width, default 20%), corner radius, circular-mask toggle, border toggle.
- Contract: webcam must be center-cropped to square *before* circular masking, or the mask produces an oval.

**`AudioMixer`**
- Input: system-audio PCM, mic PCM (both already on the screen clock via SCK).
- Processing: `AVAudioConverter` to common format (48kHz, stereo, float32) per source → independent gain per source → sum → clamp.
- Output: single PCM buffer per tick to the AAC `AVAssetWriterInput`.
- Contract: gain is per-source and independently settable; system audio defaults to −6dB relative to mic (see §2).

**`RecordingStore`**
- Owns: read/write of the on-disk folder-per-recording library (§1.4). No database — folder scan only.
- Output: must notify observers (not just serve a launch-time scan) so `GalleryView` updates live when a recording is saved from the menu bar with the gallery already open.

**`GalleryView`**
- Input: `RecordingStore` listing.
- Output: none external — in-place edits to title/description write through to `meta.json` via `RecordingStore`, never to the folder name. Delete routes through Trash, never `unlink`.

**`HotKeyManager`**
- Owns: global start/stop shortcut registration via the `KeyboardShortcuts` SPM package (preferred) or Carbon `RegisterEventHotKey`.
- Contract: must not use `NSEvent.addGlobalMonitorForEvents` — it requires Accessibility permission, which neither of the preferred options needs.

### 1.4 On-disk model

Folder-per-recording, self-contained, no database:

```
~/Movies/Specreel/
  2026-09-15-143022-a3f9c1/
    recording.mp4
    thumbnail.jpg
    meta.json
```

`meta.json` schema (from the plan, treat as the contract `RecordingStore` validates against):

```json
{
  "id": "a3f9c1",
  "title": "string",
  "description": "string",
  "createdAt": "ISO8601",
  "duration": 0.0,
  "width": 0,
  "height": 0,
  "fps": 0,
  "fileSize": 0,
  "source": { "type": "display|window|region", "app": "string?", "title": "string?" },
  "hasWebcam": false,
  "hasMic": false,
  "hasSystemAudio": false
}
```

Rationale carried forward from the plan: folder-per-recording is an `rclone copy` away from remote storage with no export step and no schema migration, and filename-as-timestamp keeps the library sorted without reading file contents. A directory scan is instant at personal scale; do not add a database or index file preemptively.

---

## 2. Decision Recommendations (unblock the builder)

These are locked so the builder never stalls waiting for a call. Each is revisitable later without architectural cost — M1 through M3 are identical regardless.

| Decision | Recommendation | Why |
|---|---|---|
| **Codec** | H.264 High, default | Universal playback, no browser surprises. HEVC saves ~40% size but browser support is inconsistent, and the destination (eventual R2 share) is unknown enough that the lower-regret choice wins. Revisit once a consuming surface is known. |
| **Raw webcam alongside composite** | Skip | A second `webcam.mp4` writer input costs disk and complexity to buy "re-composite later if PiP covers something important" — a hypothetical need with no current use case. Straightforward YAGNI; add only if a real recording is ruined by bad PiP placement. |
| **Resolution cap** | Default 1440p via `SCStreamConfiguration.width/height`, native-resolution toggle exposed in settings | Native 5K capture produces enormous files for mostly-static screen content with no visible quality gain. 1440p is the size/quality sweet spot for screen recording specifically (not video-of-the-world). |
| **Frame rate** | 30fps default | Correct for almost all screen-recording content. 60fps only matters for animation demos and doubles file size for static content. No UI needed at M0–M6; consider a 60fps toggle only if a real recording session needs it. |
| **Webcam encoding** | H.264 passthrough (part of the single composited H.264 stream, no separate webcam codec decision) | Webcam is burned into the composite before encode — there is no independent webcam codec choice once "raw webcam alongside" is skipped. |

---

## 3. Milestone Acceptance Criteria (M0–M7)

Each milestone's acceptance test is a hard gate — do not start the next milestone until the current one's test passes. Several of these fail in ways that are silent at the milestone where they're introduced and only surface two or three milestones later; those are flagged explicitly.

### M0 — Skeleton
**Build:** Xcode project, `MenuBarExtra` + `WindowGroup`, `LSUIElement = false`, `applicationShouldTerminateAfterLastWindowClosed = false`, App Sandbox **off**, hardened runtime **on**, camera + mic usage strings in Info.plist. Inert popover shell and empty main window.

**Accept:** app launches with Dock icon and main window visible. Status item click opens popover. Closing main window leaves app running in menu bar; popover's "Recordings…" reopens it.

**Fails silently if skipped:** stable code-signing identity is not itself an M0 deliverable, but per the Traps list it must be in place *before* M1 starts, or every subsequent rebuild re-triggers the Screen Recording TCC prompt. Treat "set up a stable signing identity" as a hard M0 exit requirement even though it produces no visible M0 behavior change.

### M1 — Screen to file, nothing else
**Build:** `SCShareableContent` → pick display → `SCStream` → `.screen` output → `AVAssetWriter` → H.264 MP4. No audio, webcam, or region.

**Accept:** 10-second recording plays in QuickTime at correct resolution, smooth motion, correct duration.

**Fails silently:** frame-drop/`.status` handling bugs introduced here (accepting `.idle`/`.blank` buffers) won't visibly break a 10-second test clip of a moving cursor — they surface later as corrupt or frozen frames on a genuinely idle screen. Explicitly test a 10-second recording of a *static* screen at M1, not just a moving one, or this trap goes undetected until M3+.

### M2 — Source selection
**Build:** display / window / region. Region via `SCStreamConfiguration.sourceRect`.

**Accept:** recording a specific window captures only that window and follows it if moved. Region selection on a secondary display produces a file containing exactly the selected pixels — must be verified on a real multi-monitor, non-2x-scale setup.

**Fails silently:** coordinate-conversion bugs (§4 of Traps) look correct on a single main display at 2x scale and only misalign on secondary displays or 1x/non-standard scale factors. The acceptance test as written forces this, but only if a real multi-monitor rig is used — do not accept a single-display test as satisfying M2.

### M3 — Audio
**Build:** `capturesAudio = true`, `captureMicrophone = true`, `microphoneCaptureDeviceID` from picker. Both PCM streams into `AudioMixer`, one AAC track out.

**Accept:** recording with music playing + narration has both audible and **in sync at the 5-minute mark**, not just at the start.

**Fails silently:** drift bugs are invisible in a 10-second smoke test. The 5-minute mark requirement in the acceptance criterion is load-bearing — a builder or agent that tests only the first few seconds will pass a broken implementation.

### M4 — Webcam PiP
**Build:** `AVCaptureSession` with device picker + live preview. Latch + compositor. Configurable corner/size.

**Accept:** PiP is round (not oval), correctly positioned, no frame drops at 1080p30 with camera on. Explicitly check `AVAssetWriterInput.isReadyForMoreMediaData` — if it returns false, the compositor is too slow and must move fully onto the Metal path.

**Fails silently:** a compositor that's borderline-too-slow may pass a short manual smoke test but drop frames on longer recordings under thermal throttling. Include a ≥5-minute continuous recording in the M4 test pass, not just a short clip.

### M5 — Post-recording flow
**Build:** stop → floating panel (thumbnail, pre-filled title, description). Save writes the folder; Esc/Cancel discards.

**Accept:** saved folder contains all three files; `meta.json` validates against the schema in §1.4; thumbnail is a real frame from ~10% into the recording (not a black first frame). Panel appears correctly for a recording started from the menu bar with the main window closed.

**Fails silently:** a black-frame thumbnail bug is easy to miss visually in a file browser at small icon size — check the actual pixel content, not just that a JPEG exists.

### M6 — Gallery
**Build:** main window grid, inline playback, editable title/description, search, sort, delete/reveal/copy-path. Full-size recording setup alongside.

**Accept:** editing description updates `meta.json`, never the folder name. Delete moves to Trash, never `unlink`. A recording saved from the menu bar appears in an already-open gallery without relaunch (store must notify, not just scan at launch).

**Fails silently:** the "no relaunch needed" requirement is the one most likely to be skipped by an implementation that only wires a launch-time scan — it will look complete in every manual test that happens to relaunch the app between recording and checking the gallery.

### M7 — Polish
**Build:** config persistence to `UserDefaults`, status-item recording state + timer, click-to-stop, global hotkey, pause/resume, floating control pill, countdown before start.

**Accept:** quit, relaunch, click status item, hit Record — previous source/camera/mic are already selected, recording starts without opening the disclosure. Control pill does not appear in the recording itself. Pause/resume produces a file with no gap and correct duration.

**Fails silently:** "control pill does not appear in the recording" depends on `NSWindow.sharingType = .none` being set on every new floating window added during M7 polish, including ones not explicitly named in the plan (e.g. the countdown overlay). Audit every new `NSWindow` introduced in M7 for `sharingType`, not just the ones the plan calls out by name.

---

## 4. Traps List

Ordered by cost-when-missed, per the plan, with the mechanism spelled out so a builder can write a specific guard rather than a vague awareness.

**1. Code-signing resets Screen Recording TCC permission.**
Ad-hoc signed builds invalidate their TCC grant on every hash change (i.e. every rebuild), forcing a re-prompt that requires quitting the app to clear. **Action: establish a stable signing identity (Developer ID, or a consistent self-signed cert) before M1 begins — not after the first rebuild pain is felt.** This is the single highest-cost trap in the plan; treat it as an M0 exit gate (see M0 acceptance above).

**2. Idle frames never arrive; non-`.complete` frames contain garbage.**
SCK only delivers buffers when pixels change — an idle screen produces nothing. Separately, `SCStreamFrameInfo.status` can be `.idle` or `.blank`, and those buffers must be discarded, not appended. **Action: check `.status == .complete` on every sample before use.** The resulting file is legitimately variable-frame-rate (fine for QuickTime/browsers, not for all editors); if CFR is ever required, add a watchdog that re-appends the last good frame after ~1s of silence — do not build this speculatively now.

**3. Coordinate systems disagree across three frames of reference.**
`NSScreen` is bottom-left origin, main-display-relative, in points. `SCStreamConfiguration.sourceRect` is top-left origin, captured-display-relative, in points. Output pixels are yet another space, scaled by the display's backing scale factor. Region selection crosses all three. **Action: write the conversion once, as a single tested utility, and validate it specifically on a non-main display at a non-2x scale factor** (this is exactly what M2's acceptance test requires — don't let a single-display test substitute for it).

**4. `AVAssetWriter` has no native pause.**
There is no pause API. Stopping and restarting the writer produces either two files or a corrupt one. **Action: implement pause by accumulating elapsed paused duration and subtracting it from every subsequent buffer's PTS before appending** — this is the only correct approach; do not attempt stop/restart.

**5. `.complete` status does not guarantee a non-nil pixel buffer.**
`CMSampleBufferGetImageBuffer` can return nil even on a `.complete`-status sample, especially across display-mode changes. **Action: guard both `.status == .complete` and a non-nil image buffer before compositing or writing** — checking only one is insufficient.

**6. Stream death on sleep/disconnect must finalize, not lose, the recording.**
Sleep, display disconnect, and resolution change all kill the `SCStream`. **Action: implement `SCStreamDelegate.stream(_:didStopWithError:)` to finalize the `AVAssetWriter` and save whatever was captured, rather than leaving a corrupt or unfinalized file.** Untested finalization-on-error is the most expensive trap to discover in production, since it's discovered by losing a real, long recording.

**7. System audio needs independent gain relative to mic, or the mic gets buried.**
System audio runs roughly 15dB hotter than a typical podcast mic. **Action: apply independent per-source gain in `AudioMixer` (§1.3), default system audio to −6dB relative to mic, and expose both as user-adjustable sliders** — do not ship a fixed 1:1 mix.

**8. Own-window capture leakage.**
Without exclusion, the app's own control pill, webcam preview, or panels can appear inside the recording. **Action: set `NSWindow.sharingType = .none` on every such window** rather than maintaining an exclusion list in `SCContentFilter` — the per-window flag survives new windows added later (see M7 acceptance note above); a filter-based exclusion list does not.

---

## 5. Code / File Layout

Proposed Xcode project structure, with Xcode groups mapped 1:1 to the modules in §1.3 so navigation matches the architecture doc:

```
Specreel/
  Specreel.xcodeproj
  Specreel/
    App/
      SpecreelApp.swift          — @main, MenuBarExtra + WindowGroup wiring
      AppDelegate.swift           — applicationShouldTerminateAfterLastWindowClosed, etc.
    Engine/
      RecordingEngine.swift       — actor; start/pause/resume/stop
      Compositor.swift
      AudioMixer.swift
      RecordingConfig.swift       — shared observable model
    Capture/
      CaptureSourcePicker.swift
      RegionSelector.swift
      HotKeyManager.swift
    Storage/
      RecordingStore.swift
      RecordingMeta.swift         — Codable meta.json model
    UI/
      MenuBar/
        MenuBarController.swift
      MainWindow/
        MainWindow.swift
      Shared/
        RecordingConfigView.swift — compact/expanded modes
      PostRecording/
        PostRecordingPanel.swift
      Gallery/
        GalleryView.swift
  SpecreelTests/
    AudioMixerTests.swift
    CoordinateConversionTests.swift
    MetaJSONValidationTests.swift
    RecordingStoreTests.swift
  SpecreelIntegrationTests/
    WriterFinalizationTests.swift
    PipelineTeardownTests.swift
```

### Adapting bootstrap discipline to native Swift

The standing bootstrap protocol (`~/.claude/skills/bootstrap-monorepo/SKILL.md`) assumes a pnpm/Turborepo web monorepo. Specreel is a single native Xcode target with no workspace boundaries to enforce, so most of that tooling has no analogue here. What translates and what doesn't:

| Practice | Translates? | How |
|---|---|---|
| Protected `main`, PR-before-merge | **Yes** | Same as web: `main` requires a PR, no direct pushes. |
| One branch per milestone | **Yes** | `m0-skeleton`, `m1-screen-capture`, … `m7-polish`, matching §6 below. |
| Conventional Commits (`feat:`, `fix:`, `test:`) | **Yes** | No tooling difference; applies identically to Swift commits. |
| Acceptance gates before merge | **Yes** | The M0–M7 acceptance criteria in §3 stand in for CI-enforced test gates. |
| Decision log for unprompted choices | **Yes** | Same `.agent/decision-log.md` convention; applies to any judgment call a builder makes that wasn't explicitly specified here. |
| pnpm workspace / `apps/` + `packages/` layout | **No** | No monorepo — one Xcode target, no package boundaries to manage. |
| Turborepo task graph / caching | **No** | Xcode's own build system handles incremental builds; no task orchestration layer needed for a single target. |
| lint-staged / JS pre-commit hooks | **No** | Swift has no equivalent hook chain in this project; use `swift-format` or SwiftLint directly in Xcode build phases if desired, not as a pnpm-driven pre-commit step. |
| 95% coverage gate (JS default) | **Partial** | Coverage gates make sense for the testable modules (§7's unit/integration list) but not for the two modules that structurally can't run headless (ScreenCaptureKit, AVCaptureSession) — see §7 for the split. |

---

## 6. Git / Branch Strategy

- **Protected `main`.** No direct pushes; all work lands via PR.
- **One branch per milestone**, named `m0-skeleton` through `m7-polish`, matching §3. A milestone's branch does not merge until its acceptance criterion (§3) passes.
- **Conventional Commits** throughout: `feat:` for new capability, `fix:` for bug fixes, `test:` for test-only changes, `refactor:` for non-behavioral cleanup. Commit at the granularity of one logical change per commit, not one commit per milestone.
- **PR-before-merge**, tests green first. For milestones with no automatable test (M0, M2 region/multi-monitor, M4 visual PiP check — see §7), the PR description must state how the manual acceptance criterion was verified (e.g. "tested on 2-display, non-2x-scale rig per M2 acceptance").
- **Code-signing identity setup happens before M1's branch opens**, per Trap #1 — this is infrastructure, not milestone work, so it isn't itself a milestone branch; do it against `main` directly (or a `chore/signing-setup` branch) before M1 starts.

---

## 7. Testing Strategy

Split strictly by what can run headless (CI-able) versus what structurally requires real hardware/display/camera and must be manually verified per the M0–M7 acceptance criteria in §3.

### Unit tests (headless, CI-able)

- **`AudioMixer`** — gain application, format conversion math, summing/clamping logic, given synthetic PCM buffers. No real audio device needed.
- **Coordinate conversion** (§4, Trap 3) — the single conversion utility tested against known input/output pairs across the three coordinate spaces, at both 1x and 2x scale, main and non-main display. This is a pure function; test it exhaustively since it's the trap with the least visible failure signal.
- **`meta.json` validation** — `RecordingMeta`'s `Codable` round-trip and schema validation against the structure in §1.4, including malformed/partial JSON handling.
- **`RecordingStore`** — folder scan, save/delete/notify logic against a temp directory fixture. No real `~/Movies/Specreel` needed; inject the root path.

### Integration tests (headless, CI-able, but exercise real system frameworks without a display/camera)

- **`AVAssetWriter` finalization** — the pause/resume PTS-subtraction logic (Trap 4) and the stream-death finalization path (Trap 6), driven by synthetic `CMSampleBuffer`s fed directly into the writer, not via a live `SCStream`. This validates the trickiest logic in the plan without needing a real capture session.
- **Pipeline teardown** — `RecordingEngine` actor's state transitions (start → pause → resume → stop, and start → simulated stream error → finalize) using injected fake producers, verifying no deadlock and correct final `RecordingResult`.

### Cannot be headless — manual verification against §3 acceptance criteria

- **ScreenCaptureKit paths** (M1–M3: screen capture, source selection, region, system/mic audio via SCK) — requires a real display and, for M2's multi-monitor requirement, a real multi-monitor rig at non-default scale factor. No simulator or CI runner substitutes for this.
- **`AVCaptureSession` / webcam** (M4) — requires a real camera device.
- **Full recording pipeline under real conditions** (M3's 5-minute drift check, M4's 5-minute thermal/frame-drop check, M6/M7's live-notification and pause/resume gap checks) — these are explicitly time-durational or hardware-durational and cannot be simulated meaningfully; run them as manual pre-merge verification per milestone, documented in the PR per the Git strategy above.

---

## 8. Open Items

Per the plan, none of the following block starting work — M1 through M3 are identical regardless of how these resolve, and §2 above gives the default to build against. Revisit each only when a concrete need arises:

- Codec: revisit H.264→HEVC once a consuming/sharing surface is known.
- Raw webcam alongside composite: revisit only if a real PiP placement ruins a real recording.
- Resolution/frame-rate defaults: revisit only if a specific recording use case (e.g. animation demo) needs 60fps or native resolution as a *default* rather than an opt-in toggle.
