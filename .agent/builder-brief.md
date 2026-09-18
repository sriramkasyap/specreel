# Specreel — Builder Brief for Cursor Agent

## Mission
Build a fully functional native macOS screen recorder app called "Specreel" from scratch. The TRD is at `docs/Specreel-TRD.md`. Read it first — it contains all architecture, module contracts, acceptance criteria, and process rules.

## Source Material
- **Plan:** `docs/screen-recorder-build-plan.md` (the original plan doc)
- **TRD:** `docs/Specreel-TRD.md` (the authoritative technical requirements — the builder's bible)
- **Decision log:** `.agent/decision-log.md`

## Build Approach: Milestone-by-Milestone (M0→M7)

Build in order. Each milestone has an acceptance test in the TRD §3. DO NOT advance past a milestone until its acceptance test passes. Several fail silently (noted in the TRD) — enforce the acceptance test, not a subjective "looks done."

### M0 — Skeleton
- Xcode project with SwiftUI MenuBarExtra + WindowGroup
- LSUIElement = false, applicationShouldTerminateAfterLastWindowClosed = false
- App Sandbox OFF, hardened runtime ON
- Camera + mic usage strings in Info.plist
- Popover shell + empty main window, both inert
- **Setup stable signing identity** before moving to M1 (see Trap 1)
- *Accept:* app launches with Dock icon + main window, status item click opens popover, closing main window leaves app running

### M1 — Screen to file
- SCShareableContent → pick display → SCStream → .screen output → AVAssetWriter → H.264 MP4
- No audio, webcam, or region yet
- *Accept:* 10s recording plays in QuickTime at correct res, smooth motion, correct duration
- *Must also test:* 10s recording of a STATIC screen (checks .status == .complete handling)

### M2 — Source selection
- Display / window / region support
- Region via SCStreamConfiguration.sourceRect
- *Accept:* window capture follows window if moved; region on secondary display captures exactly those pixels
- Coordinate conversion utility must handle NSScreen vs SCStreamConfiguration vs pixels

### M3 — Audio
- capturesAudio = true, captureMicrophone = true, microphoneCaptureDeviceID from picker
- AudioMixer: format conversion → gain → sum → clamp, one AAC track
- *Accept:* music + narration audible and in sync at 5-minute mark

### M4 — Webcam PiP
- AVCaptureSession + device picker + live preview
- Latch pattern + Compositor (CIContext/Metal-backed)
- PiP geometry: corner (4 choices), size (% of frame, default 20%), corner radius, circular mask, border
- *Accept:* round PiP, correctly positioned, no frame drops at 1080p30
- *Long test:* ≥5 min continuous recording to check thermal/throttle

### M5 — Post-recording flow
- Stop → floating panel with thumbnail, pre-filled title, description
- Save writes folder structure; Esc/Cancel discards
- *Accept:* folder has all 3 files, meta.json validates, thumbnail is real frame from ~10% in

### M6 — Gallery
- Main window grid, inline AVPlayerView playback, editable title/description
- Search, sort, delete (Trash), reveal in Finder, copy path
- *Accept:* editing description updates meta.json only (never folder name); menu-bar recording appears in open gallery without relaunch

### M7 — Polish
- Config persistence to UserDefaults
- Status item: recording state + timer, click-to-stop
- Global hotkey (KeyboardShortcuts SPM package)
- Pause/resume via PTS subtraction (NOT stop/restart writer)
- Floating control pill with NSWindow.sharingType = .none
- Countdown before start
- *Accept:* quit/relaunch/click Record uses previous config; pause/resume produces gapless file

## Critical Rules

1. **Never advance a milestone without its acceptance test passing.** Several fail silently.
2. **Set up stable signing identity before M1.** Use signing identity SHA `F0E68E2139D99E40A51186407C21E70CC3E43060` ("Apple Development: sriramkasyap.m.s@gmail.com (X93VLP8U9X)"). Set it in Xcode project settings > Signing & Capabilities.
3. **AVAssetWriter pause via PTS subtraction**, not stop/restart.
4. **Guard every screen sample:** check SCStreamFrameInfo.status == .complete AND CMSampleBufferGetImageBuffer != nil before use.
5. **Set NSWindow.sharingType = .none** on control pill, webcam preview, countdown overlay, and any panel.
6. **Test multi-monitor** for M2 coordinate conversion — test on a non-main display at non-2x scale.
7. **Use Conventional Commits** (feat:, fix:, test:, docs:) on branches named m0-skeleton through m7-polish.
8. **Keep main protected** — work on feature branches, PR before merge.
9. **Use parallel subagents** where helpful for multi-file work.
10. **Include unit tests** per TRD §7: AudioMixer, coordinate conversion, meta.json validation, RecordingStore tests.

## On-Disk Model
- Recordings at ~/Movies/Specreel/<timestamp>-<id>/
- Each folder: recording.mp4, thumbnail.jpg, meta.json
- meta.json schema in TRD §1.4

## Codec & Performance Defaults
- Codec: H.264 High
- Resolution cap: 1440p default, native-res toggle
- Frame rate: 30fps default
- Webcam: H.264 passthrough (burned into composite)
- System audio gain: -6dB relative to mic default
- Skip raw webcam alongside composite

## Git
Already initialized on main branch. Create feature branches per milestone.