# Local Loom — Build Plan

A personal macOS screen recorder. Records display / window / region, optional burned-in webcam PiP, mic + system audio mixed to one track, writes a self-contained folder to disk with a metadata sidecar. No server, no upload, no accounts.

---

## 1. Stack decision

**Native Swift + SwiftUI, menu bar app. macOS 15 minimum.**

Electron was the other option and it loses on every axis here. System audio capture, window enumeration, and region cropping all route through ScreenCaptureKit, which means an Electron build needs a native helper binary anyway — so you'd be writing the hard 80% in Swift regardless, plus an IPC layer, plus a 150MB bundle. There's no cross-platform payoff to buy with that cost, since the target is two Macs you own.

The macOS 15 floor is what makes the audio tractable. Before 15, mic capture came from `AVCaptureSession` on a different clock than ScreenCaptureKit's system audio, and aligning them meant host-time ring buffers and drift correction. From 15 onward ScreenCaptureKit captures the mic itself (`SCStreamConfiguration.captureMicrophone` + `microphoneCaptureDeviceID`), delivering it on the same stream clock as system audio and screen frames. Same clock domain turns the mixing job from "resample two drifting sources" into "sum two buffers." Both your machines are well past 15, so this costs nothing.

> **Note on API currency:** the API surface below is accurate as of macOS 15's ScreenCaptureKit. Apple has shipped at least one major release since, so agents should verify exact symbol names against current documentation before building — particularly anything in the `SCRecordingOutput` / microphone-capture area, which was new at the time and is the most likely to have been renamed or supplemented.

### Answers locked in

| Question | Answer | Consequence |
|---|---|---|
| Webcam | Burned in as PiP | Real-time compositing; needs its own render stage |
| System audio | Yes, mixed with mic | Single AAC track; mix before encode |
| Stack | Swift/SwiftUI native | See above |

---

## 2. Architecture

Two producers feed one compositor, which feeds one writer.

```
SCStream ──┬── .screen   CMSampleBuffer (BGRA/IOSurface) ──┐
           ├── .audio    system audio PCM ──────┐          │
           └── .microphone  mic PCM ────────────┤          │
                                                ▼          ▼
AVCaptureSession ── webcam CMSampleBuffer ──► [latest   [Compositor]
                    (stored in latched slot)   frame]    CIContext, Metal-backed
                                                │          │
                                                ▼          ▼
                                          [Audio mixer]  CVPixelBuffer
                                          AVAudioConverter    │
                                          → sum → 48k stereo  │
                                                │          │
                                                ▼          ▼
                                        AVAssetWriterInput (aac)
                                        AVAssetWriterInput (h264)
                                                    │
                                                    ▼
                                            recording.mp4
```

The screen stream is the clock master. Its first frame's PTS is what you pass to `startSession(atSourceTime:)`, and every other buffer's timestamps are already in that domain (which is the whole point of pulling mic through SCK rather than AVCapture).

The webcam is *not* a clock source. It's a latch: the delegate writes each incoming frame into a lock-protected slot, and the compositor reads whatever is currently there when a screen frame arrives. Webcam frame rate becomes irrelevant — if the camera runs at 30 and the screen at 60, some webcam frames get composited twice, and nobody notices. Do not try to synchronize them; that way lies pain for zero visible gain.

---

## 3. Modules

**`MenuBarController`** — the fast path, not the only path. Clicking the status item opens a popover with one primary action: a Record button wired to the last-used configuration, with source, camera, and mic controls in a disclosure below it. Persist the full config to `UserDefaults` on every start so the common case is icon click, Record, done. Opening the disclosure should be for changing something, not for confirming what you already chose last time. A "Recordings…" item at the bottom opens the main window.

The status item icon carries recording state: idle glyph, red glyph plus elapsed timer while recording, paused glyph while paused. Clicking it during a recording stops immediately rather than reopening the popover — mirroring Loom, where the stop affordance is always one click from anywhere.

**`MainWindow`** — a regular app window with a Dock icon, hosting two things: the gallery and a full-size version of the recording setup (larger camera preview, live mic meter, PiP position picker). Closing it leaves the app alive in the menu bar, which means setting `applicationShouldTerminateAfterLastWindowClosed` to false — miss that and closing the gallery kills your recorder.

`LSUIElement` stays **false**. The alternative is accessory mode with `NSApp.setActivationPolicy` flipping to `.regular` whenever the window opens, which keeps the Dock clean but is a reliable source of windows opening behind other apps, missing app menus, and broken Cmd-Tab. If the permanent Dock icon bothers you later, add it as a "Hide Dock icon" preference in M7 and accept the edge cases then, with the app already working.

**`RecordingConfigView`** — one component, two hosts. The popover and the main window render the same configuration state at different sizes; build it once with a compact/expanded mode rather than twice. Two copies of device-picker logic will drift within a week, and the bug it produces — popover and window disagreeing about which mic is selected — is miserable to track down.

**`PostRecordingPanel`** — its own floating window, centered, appearing on stop regardless of whether the main window is open. Thumbnail, title field pre-filled from source app and time, description field, Save and Discard. Do not attach this as a sheet on the main window; recordings started from the menu bar with the window closed have nothing to attach to.

**`CaptureSourcePicker`** — wraps `SCShareableContent` to enumerate displays, windows, and running applications. Filters out windows with zero size, the app's own windows, and system UI (menu bar owner, Dock, Window Server) unless explicitly requested. Refreshes on every open; the window list goes stale fast.

**`RegionSelector`** — borderless transparent `NSWindow` at `.screenSaver` level spanning every screen, crosshair cursor, drag to draw, live dimension readout, ESC cancels, Enter confirms. Produces a `CGRect` plus the `SCDisplay` it landed on.

**`RecordingEngine`** — owns the `SCStream`, the `AVCaptureSession`, the compositor, the mixer, and the `AVAssetWriter`. Exposes `start(config:)`, `pause()`, `resume()`, `stop() async throws -> URL`. This is the only stateful component and it should be a single actor to avoid the concurrency mess that otherwise emerges from three delegate queues writing shared state.

**`Compositor`** — `CIContext` backed by Metal. Takes screen pixel buffer + latched webcam buffer, returns composited buffer from a `CVPixelBufferPool`. PiP geometry: corner (4 choices), size as % of frame width (default 20%), corner radius, optional circular mask, optional border. Center-crop the webcam to square before the circular mask or it comes out as a squashed oval.

**`AudioMixer`** — converts system audio and mic to a common format (48kHz, stereo, float32) via `AVAudioConverter`, applies per-source gain, sums, clamps, hands to the AAC writer input. Needs independent gain on each source: system audio is routinely 15dB hotter than a podcast mic and will bury your voice at 1:1.

**`RecordingStore`** — writes and reads the on-disk library. Folder scan, no database.

**`GalleryView`** — the main window's primary surface. Grid of thumbnail cards showing title, date, and duration, newest first. Click to play inline in an `AVPlayerView`. Title and description are editable in place from the detail pane, not just at save time — the first pass at a description written 10 seconds after recording is usually worse than the one written later. Search filters across title and description. Per-item actions: Reveal in Finder, Copy Path, Delete. Sort by date or duration.

**`HotKeyManager`** — global start/stop shortcut. Use the `KeyboardShortcuts` SPM package or Carbon `RegisterEventHotKey`. Both work without Accessibility permission; `NSEvent.addGlobalMonitorForEvents` requires it, so avoid that route.

---

## 4. On-disk layout

One folder per recording, fully self-contained:

```
~/Movies/LocalLoom/
  2026-09-15-143022-a3f9c1/
    recording.mp4
    thumbnail.jpg
    meta.json
```

```json
{
  "id": "a3f9c1",
  "title": "Auth flow walkthrough",
  "description": "Covers the token refresh edge case at 2:40",
  "createdAt": "2026-09-15T14:30:22Z",
  "duration": 384.2,
  "width": 1920,
  "height": 1080,
  "fps": 30,
  "fileSize": 112340992,
  "source": { "type": "window", "app": "Safari", "title": "localhost:3000" },
  "hasWebcam": true,
  "hasMic": true,
  "hasSystemAudio": true
}
```

Folder-per-recording with a sidecar rather than a central database, specifically because of where you said this is going. A self-contained directory is an `rclone copy` away from R2 with no export step, no schema migration, and no divergence when the MacBook and the Mac Mini both have recordings the other doesn't. Filename-as-timestamp keeps them sorted without reading anything. At personal scale a directory scan on launch is instant — revisit only if you cross a few thousand recordings, which you won't.

---

## 5. Milestones

Each has an acceptance test. Don't let an agent move on without it passing — several of these fail silently in ways that only surface three milestones later.

### M0 — Skeleton
Xcode project, SwiftUI `MenuBarExtra` + `WindowGroup`, `LSUIElement = false`, `applicationShouldTerminateAfterLastWindowClosed = false`, `App Sandbox` **off** (it fights ScreenCaptureKit and buys nothing for a local personal tool), hardened runtime on, camera + mic usage strings in Info.plist. Popover shell and empty main window, both inert.

*Accept:* app launches with a Dock icon and the main window. Status item click opens the popover. Closing the main window leaves the app running in the menu bar, and the popover's "Recordings…" item brings it back.

### M1 — Screen to file, nothing else
`SCShareableContent` → pick display → `SCStream` → `.screen` output → `AVAssetWriter` → H.264 MP4. No audio, no webcam, no region.

*Accept:* a 10-second recording plays in QuickTime at the right resolution with smooth motion and correct duration.

### M2 — Source selection
Display / window / region. Region via `SCStreamConfiguration.sourceRect`.

*Accept:* recording a specific window captures only that window and follows it if moved. Region selection drawn over a secondary display produces a file containing exactly the selected pixels — verify on a multi-monitor setup, this is where coordinate bugs surface.

### M3 — Audio
`capturesAudio = true`, `captureMicrophone = true`, `microphoneCaptureDeviceID` from the picker. Both PCM streams into `AudioMixer`, one AAC track out.

*Accept:* a recording with music playing and you talking has both audible and in sync with the video at the 5-minute mark, not just at the start. Drift only shows up over time.

### M4 — Webcam PiP
`AVCaptureSession` with device picker and live preview. Latch + compositor. Corner and size configurable.

*Accept:* PiP is round, not oval; positioned correctly; no frame drops at 1080p30 with the camera on. Check `AVAssetWriterInput.isReadyForMoreMediaData` returning false — if you're hitting that, the compositor is too slow and needs the Metal path.

### M5 — Post-recording flow
Stop → standalone floating panel with thumbnail, title (pre-filled from source app + time), description. Save writes the folder. Esc/Cancel offers discard.

*Accept:* saved folder contains all three files, `meta.json` validates, thumbnail is a real frame from ~10% in rather than a black first frame. The panel appears correctly for a recording started from the menu bar with the main window closed.

### M6 — Gallery
Main window grid, inline playback, editable title and description, search, sort, delete, reveal, copy path. Full-size recording setup alongside it.

*Accept:* editing a description updates `meta.json` and not the folder name. Delete moves to Trash, never `unlink`. A recording saved from the menu bar appears in an already-open gallery without requiring a relaunch — the store needs to notify, not just scan at launch.

### M7 — Polish
Config persistence to `UserDefaults`, status item recording state and timer, click-to-stop, global hotkey, pause/resume, floating recording control pill, countdown before start.

*Accept:* quit the app, relaunch, click the status item, hit Record — the previous source, camera, and mic are already selected and recording starts without opening the disclosure. The control pill does not appear in the recording. Pause/resume produces a file with no gap and correct duration.

---

## 6. Traps

Ordered by how much time they cost when missed.

**Code signing resets your screen recording permission.** Ad-hoc signed builds get their TCC grant invalidated whenever the binary hash changes, meaning every single rebuild re-prompts for Screen Recording, and the prompt requires quitting the app. Set up a stable signing identity — Developer ID if you have one, a consistent self-signed cert if not — before M1, not after. This single item will otherwise eat an afternoon and poison the whole development loop.

**ScreenCaptureKit only delivers frames when pixels change.** An idle screen produces no buffers. Check `SCStreamFrameInfo.status` on every sample and discard anything that isn't `.complete` — `.idle` and `.blank` buffers contain garbage or nothing. The resulting file is legitimately variable-frame-rate, which QuickTime and browsers handle correctly, but some editors do not. If you need CFR, run a watchdog that re-appends the last good frame after ~1s of silence.

**Coordinate systems disagree.** `NSScreen` uses bottom-left origin with the main display as reference; `SCStreamConfiguration.sourceRect` uses top-left origin relative to the captured display; both are in points while the output is in pixels. Region selection crosses all three. Write the conversion once, test it on a non-main display with a non-2x scale factor, and never touch it again.

**`AVAssetWriter` has no pause.** Implement it by accumulating paused duration and subtracting it from every subsequent buffer's PTS before appending. Agents routinely try to stop and restart the writer instead, which produces two files or a corrupt one.

**Exclude your own windows from capture.** Set `NSWindow.sharingType = .none` on the control pill, the webcam preview, and any panel. Cleaner than maintaining an exclusion list in the `SCContentFilter`, and it survives new windows being added later.

**Audio levels need independent gain.** Covered above, but it bears repeating because it's invisible until you play back a recording where system audio buried your narration. Default to roughly -6dB on system audio relative to mic and expose both sliders.

**`.complete` status ≠ non-nil pixel buffer.** Guard both. `CMSampleBufferGetImageBuffer` returns nil more often than you'd expect during display mode changes.

**Sleep, display disconnect, and resolution change kill the stream.** Handle `SCStreamDelegate.stream(_:didStopWithError:)` by finalizing the writer and saving what you have rather than losing the recording. A 40-minute walkthrough lost to a monitor unplug is the kind of thing that makes you stop using the tool.

---

## 7. Decisions left to you

None of these block starting; M1 through M3 are identical either way.

**Codec.** H.264 High is the safe default for anything you'll share — universal playback, no surprises. HEVC cuts file size roughly 40% at equal quality and every Apple device handles it, but browsers are inconsistent. Given that R2 sharing is the eventual destination and you don't know yet what's consuming these, H.264 is the lower-regret choice. Revisit once you know.

**Raw webcam alongside the composite.** You picked burned-in, which is right for a Loom clone. The optional addition is also writing the untouched webcam to `webcam.mp4` in the same folder, costing a little disk and a second writer input. It buys you the ability to re-composite later if a PiP ends up covering something important. Worth it only if you expect to care about that; skip it otherwise.

**Resolution cap.** Capturing a 5K display at native resolution produces enormous files for content that is mostly static text. Downscaling to 1440p via `SCStreamConfiguration.width/height` is usually invisible for screen content and cuts size dramatically. Suggest defaulting to 1440p with a native-resolution toggle.

**Frame rate.** 30fps is right for almost all screen recording. 60 only matters if you're demoing animation, and it doubles the file for content where nothing moves.
