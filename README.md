<div align="center">

<img src="Specreel/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png" width="128" height="128" alt="Specreel icon">

# Specreel

**A native, local-first screen recorder for macOS.**

[![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-0F7355?style=flat-square)](#-requirements)
[![Swift](https://img.shields.io/badge/Swift-5-E3292E?style=flat-square&logo=swift&logoColor=white)](#-requirements)
[![License: GPL v3](https://img.shields.io/badge/license-GPL--3.0-0F7355?style=flat-square)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-68%20passing-E3292E?style=flat-square)](#-contributing)

</div>

Specreel records a display, a single window, or a region you drag out, with an optional round webcam bubble burned into the video and your microphone plus system audio mixed onto one track. Every recording lands in its own folder on disk as a plain MP4, a thumbnail, and a small JSON sidecar. No server, no upload, no account.

Think of it as a local-first Loom alternative for people who just want the file.

## ✨ Features

| | |
|---|---|
| 🖥️ **Three capture modes** | Full display, a single window (follows it if it moves), or a dragged region. |
| 🟢 **Webcam picture-in-picture** | Circular or rounded-rectangle bubble, pick the corner and size, composited in real time via Core Image / Metal. |
| 🎙️ **Mic + system audio, one track** | Both come from ScreenCaptureKit on the same clock — no drift correction — each with its own gain (system audio defaults to −6 dB so your voice isn't buried). |
| ⏸️ **Pause / resume** | No gaps or frozen frames in the output. |
| ⏱️ **3-second countdown** | Cancellable, plus a floating control pill showing elapsed time. |
| 🎛️ **Menu bar first** | Start from the popover; while recording, clicking the menu bar icon stops immediately. |
| 🗂️ **Library window** | A gallery of past recordings — inspect, edit title/description, double-click to open, or share straight to AirDrop/Mail/Messages via the system share sheet. |
| 📐 **Resolution cap** | 1440p (default) or native pixels, 30 fps by default. |
| 📁 **Portable storage** | Each recording is a self-contained folder — back up with `rsync`, `rclone`, Time Machine, anything. |

## 📋 Requirements

| | Minimum |
|---|---|
| macOS | 15.0 (Sequoia), required for ScreenCaptureKit microphone capture |
| Xcode | 16.0 |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | 2.x (`brew install xcodegen`) |

## 📦 Installation

### Option 1: Download a release

Grab the latest `Specreel-vX.Y.Z.zip` from [Releases](../../releases), unzip it, and drag `Specreel.app` to `/Applications`.

It's signed ad-hoc, not notarized, so **macOS will call it an app from an unidentified developer** the first time you open it. Right-click (Control-click) `Specreel.app` → **Open** → **Open** again on the dialog. You only need to do this once.

### Option 2: Build from source

```bash
git clone <this-repo-url> specreel
cd specreel
./scripts/dev.sh run
```

That generates the Xcode project, builds a Debug app into `./build/Debug/Specreel.app`, and launches it.

To install it like a normal app, build Release and copy it to `/Applications`:

```bash
./scripts/dev.sh release
cp -R build/Release/Specreel.app /Applications/
```

Prefer Xcode? `./scripts/dev.sh open`, pick the **Specreel** scheme, and press ⌘R.

### Code signing

Out of the box the project signs **ad-hoc** ("Sign to Run Locally"), so it builds without an Apple Developer account.

The catch: macOS ties the Screen Recording permission to the binary's signature, and an ad-hoc signature changes on every build. You'll be asked to re-grant Screen Recording after each rebuild. To avoid that, sign with a stable certificate (a free Apple Development certificate from Xcode → Settings → Accounts works):

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig
security find-identity -v -p codesigning   # copy your certificate's SHA-1
# edit Config/Local.xcconfig: set CODE_SIGN_IDENTITY and DEVELOPMENT_TEAM
./scripts/dev.sh run
```

`Config/Local.xcconfig` is gitignored, so your identity never ends up in a commit.

### Permissions

macOS asks for these the first time each is needed:

| Permission | Needed for | Where to manage it |
|---|---|---|
| Screen Recording | Capturing anything | System Settings → Privacy & Security → Screen & System Audio Recording |
| Microphone | Narration | System Settings → Privacy & Security → Microphone |
| Camera | Webcam bubble (optional) | System Settings → Privacy & Security → Camera |

The app runs **outside the App Sandbox** with the hardened runtime on. ScreenCaptureKit window/region capture and writing to `~/Movies` are simpler that way. It makes no network connections.

If a permission gets stuck, reset it and relaunch:

```bash
tccutil reset ScreenCapture dev.yagna.specreel
tccutil reset Microphone dev.yagna.specreel
tccutil reset Camera dev.yagna.specreel
```

## 🚀 Usage

1. **Open the popover.** Click the record-circle icon in the menu bar.
2. **Choose what to capture.** Display, Window, or Region (for Region, click **Select Region…** and drag). Toggle the webcam, mic, and system audio, and pick devices if you have more than one.
3. **Record.** Press **Record** (or Return). A 3-second countdown runs; press Cancel to back out.
4. **While recording,** the floating pill shows the elapsed time with pause/resume and stop. Clicking the menu bar icon also stops the recording.
5. **Save.** A *Save recording* panel appears with an editable title and optional description. Choose **Save**, **Save & Open**, or **Discard**. Closing the panel discards.
6. **Browse.** Open **Recordings** from the popover (or the Dock icon) for the library: gallery on the left, preview in the middle, and an inspector for editing metadata, revealing in Finder, copying the path, or trashing.

Your capture settings are remembered between launches.

### Where recordings go

```
~/Movies/Specreel/
  2026-09-15-143022-a3f9c1/
    recording.mp4     # H.264 video + AAC audio
    thumbnail.jpg     # frame from ~10% in
    meta.json         # title, description, duration, source, which inputs were on
```

The folder name is `<yyyy-MM-dd-HHmmss>-<id>`, so folders sort chronologically. Specreel never renames them; editing the title only rewrites `meta.json`. You can move, back up, or delete folders freely, and the library rescans on launch.

## 🛠️ Troubleshooting

- **Black or empty video:** Screen Recording permission is missing or was invalidated by a rebuild (see [Code signing](#code-signing)). Re-grant it and relaunch.
- **Recording stops by itself:** ScreenCaptureKit ends the stream if the display sleeps, the monitor is unplugged, or the captured window closes. Specreel finalizes and keeps whatever was captured up to that point.
- **Logs:** Engine diagnostics go to the unified log. Stream them with:
  ```bash
  log stream --predicate 'subsystem == "dev.yagna.specreel"' --level info
  ```

## ⚙️ How it works

```
SCStream ──┬── .screen      frames ───────────────┐
           ├── .audio       system PCM ──┐        │
           └── .microphone  mic PCM ─────┤        │
                                         ▼        ▼
AVCaptureSession ── webcam ──► [latch]  [AudioMixer]  [Compositor (CIContext/Metal)]
                                  └──────────┼──────────────┘
                                             ▼
                          AVAssetWriter (H.264 + AAC) → recording.mp4
```

- The **screen stream is the master clock.** The webcam is a latch: the compositor grabs whatever camera frame is newest when a screen frame arrives, so the camera never drives timing.
- **Audio** from system and mic shares ScreenCaptureKit's clock. `AudioMixer` converts both to 48 kHz stereo float, applies per-source gain, and sums them into one track.
- **Pause** is done by subtracting the accumulated paused duration from presentation timestamps, so the file has no gap.
- ScreenCaptureKit sends **idle frames** (no new pixels) with `.idle` status; only `.complete` frames are written.
- `RecordingEngine` owns all pipeline state on a single serial queue; the UI observes it through Swift Observation.

## 🗺️ Project layout

```
Specreel/
  App/              App entry point and delegate
  Capture/          Source picker, region selector, permission preflight
  Engine/           RecordingEngine, Compositor, AudioMixer, config, coordinate math
  Storage/          RecordingStore (folder-per-recording) and meta.json model
  UI/               Menu bar, main window, gallery, save panel, shared views, theme
SpecreelTests/            Unit tests (mixer, coordinates, metadata, store)
SpecreelIntegrationTests/ Writer finalization and pipeline teardown tests
Config/                   Signing xcconfigs
project.yml               XcodeGen spec, the source of truth for the Xcode project
scripts/dev.sh            build | run | release | test | open
```

The one third-party dependency is [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) (MIT), pulled in by Swift Package Manager.

## 🚢 Releasing

Pushing a `v*` tag triggers [`.github/workflows/release.yml`](.github/workflows/release.yml), which builds a Release configuration on a macOS GitHub Actions runner, zips `Specreel.app`, and publishes it to [Releases](../../releases). No secrets are involved — it signs ad-hoc, the same as a local build with no Apple Developer account.

1. Bump `MARKETING_VERSION` in `project.yml` (and `CURRENT_PROJECT_VERSION` if you want a distinct build number).
2. Commit it: `git commit -am "chore: bump version to X.Y.Z"`.
3. Tag and push:
   ```bash
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```
4. Watch the run under the repo's **Actions** tab. When it finishes, the zip is on the **Releases** page.

### Removing the Gatekeeper warning

Ad-hoc signing means people see an "unidentified developer" prompt on first launch (harmless — see [Installation](#-installation)). To remove it entirely:

1. Enroll in the [Apple Developer Program](https://developer.apple.com/programs/) ($99/year) and create a **Developer ID Application** certificate (Xcode → Settings → Accounts, or [developer.apple.com](https://developer.apple.com/account/resources/certificates/list)).
2. Export it as a `.p12`, base64-encode it, and add it as a repo secret (`Settings → Secrets and variables → Actions`) along with an [app-specific password](https://support.apple.com/en-us/102654) or API key for `notarytool`.
3. Update the workflow to import the certificate, sign with `CODE_SIGN_IDENTITY: "Developer ID Application: <name> (<team>)"`, and add a step that runs `xcrun notarytool submit --wait` on the zip before publishing it.

This repo doesn't do that yet — see [Known gaps](#known-gaps--good-first-issues).

## 🤝 Contributing

Contributions are welcome: bug reports, fixes, and features.

1. **Fork and branch** off `main`.
2. **Edit `project.yml`, not the `.xcodeproj`.** The Xcode project is generated. After adding files or changing settings, run `xcodegen generate` (every `dev.sh` command does this for you) and commit the regenerated `Specreel.xcodeproj` alongside `project.yml`.
3. **Run the tests** before opening a PR:
   ```bash
   ./scripts/dev.sh test
   ```
   Add a test for any logic change, especially in `Engine/` and `Storage/`. For anything that touches capture, also run a real recording, including a **static screen** (no pixels changing) and a **pause/resume**, since those paths fail silently.
4. **Keep your signing identity out of commits.** Put it in `Config/Local.xcconfig` only.
5. **Commit messages** follow [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix(engine):`, `docs:` …).
6. **Open a pull request** that says what changed, why, and how you tested it. Screenshots help for UI changes.

The project uses Swift strict concurrency (`SWIFT_STRICT_CONCURRENCY = complete`). Please don't add new concurrency warnings.

### Known gaps / good first issues

- A global start/stop hotkey is stubbed in `Capture/HotKeyManager.swift` but not wired into the app or given a settings UI.
- Releases are ad-hoc signed, not notarized (see [Releasing](#-releasing)) — wiring up a Developer ID cert + `notarytool` in CI would remove the Gatekeeper warning.

## 📄 License

[GNU General Public License v3.0](LICENSE). You may use, modify, and redistribute Specreel, but distributed modified versions must also be released under GPL-3.0 with source.
