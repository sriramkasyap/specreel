# Specreel — Operator Guide

## Overview

Specreel is a native macOS screen recorder (Loom replacement). Records display/window/region with optional burned-in webcam PiP, mic + system audio mixed to one track, and writes a self-contained folder to disk with a metadata sidecar. No server, no upload, no accounts.

---

## Prerequisites

| Requirement | Minimum |
|-------------|---------|
| macOS | **15.0** or later |
| Xcode | 16.0+ (for building from source) |
| Signing | Apple Developer ID (free or paid) or stable self-signed cert |

Both your MacBook and Mac Mini are well past macOS 15 — no OS upgrade needed.

---

## Installation

### Option 1: Build & Run from Source (current setup)

Plain `xcodebuild build` defaults to **Debug** and writes into Xcode’s DerivedData — it does **not** create `build/Release/`. Use one of these:

**A. Easiest — open in Xcode and Run**

```bash
cd /Users/sriramkasyapmeduri/Works/SK/mac-screen-recorder
xcodegen generate -s project.yml
open Specreel.xcodeproj
```

Then select the `Specreel` scheme and Product → Run (⌘R).

**B. CLI with a local `build/` folder**

```bash
cd /Users/sriramkasyapmeduri/Works/SK/mac-screen-recorder
xcodegen generate -s project.yml
xcodebuild build \
  -project Specreel.xcodeproj \
  -scheme Specreel \
  -configuration Debug \
  -destination 'platform=macOS' \
  SYMROOT="$(pwd)/build"
open build/Debug/Specreel.app
```

For a Release build (creates `build/Release/`):

```bash
xcodebuild build \
  -project Specreel.xcodeproj \
  -scheme Specreel \
  -configuration Release \
  -destination 'platform=macOS' \
  SYMROOT="$(pwd)/build"
open build/Release/Specreel.app
```

**C. Helper script**

```bash
./scripts/dev.sh run    # generate + Debug build into ./build + open the app
```

### Option 2: Run the pre-built app

If you have a pre-built `Specreel.app`, move it to `/Applications/` or run directly:

```bash
open /Applications/Specreel.app
```

First launch will prompt for permissions (see below).

### Moving to another Mac

Copy the app bundle to the other Mac via AirDrop, USB, or `scp`. Prefer a **Release** build from Option 1B. See the Signing section below for Developer ID vs development signing.

---

## Code Signing

A **stable signing identity** was set up during the build. The project uses:

- **Identity:** `Apple Development: sriramkasyap.m.s@gmail.com (X93VLP8U9X)`
- **Team:** `X93VLP8U9X`
- **Style:** Manual (set in `project.yml`)

### What this means for you

- **On your Mac:** the current identity works as-is for development builds. Just run `xcodebuild build` or open in Xcode and hit Run.
- **On another Mac you own (same Apple ID):** signing may work if the other Mac is logged into the same Apple Developer account. If not, use a **self-signed cert**:
  ```bash
  security create-keychain -p temp specreel.keychain
  security add-certificates -k specreel.keychain
  security codesign -s - --force Specreel.app
  ```
- **For distribution to other people:** you need a **Developer ID** certificate from your Apple Developer account ($99/year). Then:
  ```bash
  codesign --force --deep --options runtime --sign "Developer ID: Your Name (TEAMID)" Specreel.app
  ```
- **Critical:** ad-hoc signed builds lose Screen Recording permission on every binary hash change (every rebuild). The manual Developer ID setup above prevents this pain.

---

## Permissions (Required)

The app needs three TCC (Transparency, Consent, and Control) permissions. macOS prompts for each on first use:

| Permission | Why | How to grant |
|-----------|-----|--------------|
| **Screen Recording** | Capture display / window / region content | System Settings → Privacy & Security → Screen Recording → enable Specreel |
| **Microphone** | Record narration via built-in or external mic | System Settings → Privacy & Security → Microphone → enable Specreel |
| **Camera** | Optional webcam PiP overlay | System Settings → Privacy & Security → Camera → enable Specreel |

### Rebuild re-prompt gotcha

Every time the binary changes (rebuild, re-sign), macOS may invalidate the Screen Recording grant. You'll see the permission prompt again. This is **normal** — just re-grant it. The project's stable signing identity minimizes this but doesn't eliminate it entirely during development.

### If permissions stop working

```bash
# Reset TCC for Specreel (requires SIP-disabled or full disk access)
tccutil reset ScreenCapture dev.yagna.specreel
tccutil reset Microphone dev.yagna.specreel
tccutil reset Camera dev.yagna.specreel
```

Or manually: System Settings → Privacy & Security → remove Specreel from each list, then re-launch and re-grant.

---

## Usage

### Recording

1. Click the **record circle icon** in the menu bar (top right).
2. Click **Record** — a 3-second countdown appears, then recording starts.
3. A floating **control pill** shows elapsed time — click to stop, or click pause/resume.
4. Click the menu bar icon at any time to **stop** immediately (mirrors Loom's click-to-stop).

### Source Selection

Open the menu bar popover, click the **Options** disclosure. Choose:
- **Display** — capture an entire screen
- **Window** — capture a specific app window (follows it if moved)
- **Region** — drag a selection rectangle over any area

Toggle **webcam** and **mic** as needed.

### After Recording

A **Save Recording** panel floats in the center of your screen:
- **Title** — pre-filled from the source app + date; editable
- **Description** — optional notes
- **Save** — writes the recording folder to `~/Movies/Specreel/`
- **Discard** (or Escape) — deletes the temp file

### Gallery

Click "Recordings…" in the menu bar popover to open the Gallery:
- Grid view, newest first
- Click a thumbnail to play inline with `AVPlayer`
- Edit title and description in the detail pane
- Search by title or description
- Sort by date or duration
- Right-click for: Reveal in Finder, Copy Path, Move to Trash

### Hotkey

A global start/stop shortcut is registered via the `KeyboardShortcuts` SPM package. Check the app settings to configure or change it.

---

## Recordings Storage

| Item | Location |
|------|----------|
| Video files | `~/Movies/Specreel/` |
| Folder format | `<timestamp>-<id>/` |
| Files per folder | `recording.mp4`, `thumbnail.jpg`, `meta.json` |

### Folder format example

```
~/Movies/Specreel/
  2026-09-15-143022-a3f9c1/
    recording.mp4
    thumbnail.jpg
    meta.json
```

### Backup (rclone to R2)

Each folder is fully self-contained. To back up:

```bash
# Install rclone first: brew install rclone
# Configure rclone for R2 (Cloudflare)
rclone config

# Sync recordings to R2
rclone copy ~/Movies/Specreel/ r2:my-bucket/specreel-backups/
```

The folder-per-recording format means `rclone copy` will incrementally sync new recordings without any export step.

To restore a recording from backup:
```bash
rclone copy r2:my-bucket/specreel-backups/2026-09-15-143022-a3f9c1/ ~/Movies/Specreel/2026-09-15-143022-a3f9c1/
```

---

## Changing / Rebuilding

### If you modify source code

```bash
cd /Users/sriramkasyapmeduri/Works/SK/mac-screen-recorder
xcodegen generate -s project.yml   # Only needed if project.yml changed
xcodebuild build \
  -project Specreel.xcodeproj \
  -scheme Specreel \
  -configuration Debug \
  -destination 'platform=macOS' \
  SYMROOT="$(pwd)/build"
open build/Debug/Specreel.app
```

Or `./scripts/dev.sh run`, or Cmd+R in Xcode.

### If you add new Swift files

Add the file path to `project.yml` under `sources`, then re-run `xcodegen generate -s project.yml`.

### If you need to clean everything

```bash
xcodebuild clean -project Specreel.xcodeproj -scheme Specreel
rm -rf ~/Library/Developer/Xcode/DerivedData/Specreel-*
```

---

## Troubleshooting

### "No frames captured" / Black video

- Ensure **Screen Recording** permission is granted (check System Settings).
- The app only records when pixels change. A completely static screen produces no frames (expected — the MP4 will have no video track for that segment).
- After rebuilding, re-check Screen Recording permission (see rebuild gotcha above).

### Recording starts but stops immediately

- Check the console for `SCStreamDelegate.stream(_:didStopWithError:)` messages.
- Common causes: display sleep, monitor unplugged, resolution change.
- The app saves whatever was captured before the stop rather than losing it.

### Audio out of sync with video

- Ensure system audio + mic are both routed through ScreenCaptureKit (macOS 15+).
- If you see drift at 5+ minutes, the AudioMixer format conversion may need tuning.

### PiP webcam looks oval not round

- The webcam is center-cropped to square before the circular mask. If it's oval, the center-crop step is being skipped. Check `Compositor.swift` for the center-crop logic.

### App doesn't appear in the Dock

- Set `LSUIElement = false` in `Info.plist` (it's already set in the current build).

### "AVAssetWriter not ready for more media data"

- The compositor is too slow. Move fully onto the Metal-backed `CIContext` path. Check `Compositor.swift` for `CIContext(options: [.workingColorSpace: ...])`.

### Can't find new recordings in an already-open gallery

- The gallery updates live via the `RecordingStore.libraryDidChange` publisher. If live updates aren't working, close and reopen the gallery window (or relaunch the app for an immediate scan).

### rclone backup fails

- Ensure `rclone` is installed (`brew install rclone`).
- Check R2 bucket permissions and endpoint configuration.

---

## Xcode / OS Prerequisites Detail

| Component | Version |
|-----------|---------|
| macOS | 15.0+ (Apple's `SCStreamConfiguration.captureMicrophone` shipped in 15) |
| Xcode | 16.0+ (for Swift 6 concurrency / Observation support) |
| Swift | 5.9+ (the project uses `@Observable` macro, Swift Testing) |
| xcodegen | Installed via Homebrew (`brew install xcodegen`) |

To verify:
```bash
swift --version
xcodebuild -version
xcodegen --version
```

---

## Architecture Quick Reference

```
SCStream ──┬── .screen  CMSampleBuffer ──────────────┐
           ├── .audio   system PCM ────────┐         │
           └── .microphone  mic PCM ───────┤          │
                                           ▼          ▼
AVCaptureSession ── webcam frame ──► [latch]   [Compositor: CIContext/Metal]
                                           │            │
                                           ▼            ▼
                                     [AudioMixer]   CVPixelBuffer
                                     → 48k/stereo/f32   │
                                           │            │
                                           ▼            ▼
                                  AVAssetWriterInput(aac / h264)
                                               │
                                               ▼
                                        recording.mp4
```

Single-actor `RecordingEngine` owns all pipeline state. Screen clock is master; webcam is a latch-only (no synchronization).