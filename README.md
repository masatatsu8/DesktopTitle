English | [日本語](README-ja.md)

# DesktopTitle

macOS menu bar app that displays desktop (Space) names when switching between desktops.

## Features

- Custom name overlay shown when switching desktops, with a configurable initial delay and display duration
- Customizable overlay appearance: font family / size, position (X/Y), unified or per-desktop text & background colors, optional space-index display
- **Per-display profiles**: each display configuration (e.g. laptop alone, laptop + external) gets its own settings; multi-display configurations can either inherit from the built-in display profile or use independent settings
- Launch at login (via `SMAppService`)
- Optional overlay for fullscreen Spaces
- Lightweight menu bar app (`LSUIElement`)

## Requirements

- macOS 15.0 (Sequoia) or later

## Install

1. Download the latest `DesktopTitle-vX.Y.Z.zip` from the [Releases page](../../releases).
2. Unzip and move `DesktopTitle.app` to `/Applications`.
3. **Important — remove the quarantine attribute before launching.** The release binary is **not signed with an Apple Developer ID** (the project does not own one), so macOS Gatekeeper will refuse to open it. Run this once in Terminal:

   ```bash
   xattr -dr com.apple.quarantine /Applications/DesktopTitle.app
   ```

   After this you can launch the app normally from Finder, Spotlight, or the Dock.

   <details><summary>Why this command is needed</summary>

   Files downloaded by a browser are tagged with the `com.apple.quarantine` extended attribute. Gatekeeper consults that attribute and refuses to launch third-party apps that are not signed with a Developer ID Application certificate or notarized by Apple. Because this project does not have a Developer ID, the Release workflow builds with `CODE_SIGNING_ALLOWED=NO` and the resulting `.app` only carries an ad-hoc signature. Removing the quarantine attribute tells Gatekeeper to skip the signature check for this app, after which it launches normally.

   </details>

## Usage

The app lives entirely in the menu bar.

1. Launch `DesktopTitle.app`. A menu bar icon appears.
2. Click the icon and choose **Settings…** to open the configuration window.
3. **Desktops** tab — give each desktop (Space) a name. In multi-display setups the screen name is shown alongside each desktop, and desktops shared across configurations are labelled `(shared)`.
4. **Display** tab — adjust font, size, position, colors, display duration, delay, and the space-index toggle.
5. **General** tab — toggle **Launch at login** and **Show for fullscreen apps**, manage the active per-display profile, or **Reset Current Profile to Defaults**.
6. Switch desktops to see the overlay.

### Per-display profiles

Settings (overlay appearance, desktop names) are stored per **display configuration**, not globally. When you connect or disconnect a monitor the app picks the matching profile automatically. For multi-display configurations:

- **Inherit** (default when a single-display base profile already exists) — the multi-display configuration mirrors the built-in display's profile. Changes propagate both ways.
- **Independent** — the multi-display configuration owns its own settings. Useful when you want a different layout when external monitors are attached.

You can switch between modes from the **General** tab.

## Building

### Prerequisites

- Xcode 16.0 or later
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (regenerates the Xcode project from `project.yml`)

### Build steps

1. Generate the Xcode project:
   ```bash
   xcodegen generate
   ```

2. Build from the command line:
   ```bash
   xcodebuild -project DesktopTitle.xcodeproj -scheme DesktopTitle -configuration Debug -derivedDataPath ./build build
   ```

3. Run the app:
   ```bash
   open ./build/Build/Products/Debug/DesktopTitle.app
   ```

Or open `DesktopTitle.xcodeproj` in Xcode and build from there.

## Project structure

```
DesktopTitle/
├── App/
│   ├── DesktopTitleApp.swift     # SwiftUI app entry point
│   └── AppDelegate.swift         # NSApplicationDelegate, lifecycle
├── Core/
│   ├── CGSPrivate.h              # Private CoreGraphics Space APIs
│   ├── SpaceIdentifier.swift     # Stable Space ID resolution
│   ├── SpaceMonitor.swift        # Active-Space change observer
│   ├── DisplayConfiguration.swift# Display topology + profile ID
│   └── DebugLog.swift            # Conditional file/console logging
├── Models/
│   ├── SpaceConfig.swift         # Per-Space (name, color) config
│   └── AppSettings.swift         # Per-display profiles + global settings
├── UI/
│   ├── MenuBarController.swift   # Menu bar item + Settings window
│   ├── OverlayWindow.swift       # Borderless transparent NSWindow
│   ├── OverlayView.swift         # Overlay SwiftUI view
│   └── SettingsView.swift        # Settings window UI (3 tabs)
└── DesktopTitle-Bridging-Header.h
```

## Releasing

Releases are produced by the [Release workflow](.github/workflows/release.yml) on every `v*` tag push. The tag must point at a commit that already contains the version bump, otherwise the published `.app` will not match the release name.

```bash
# 1. Bump CFBundleShortVersionString in project.yml, then regenerate the project
xcodegen generate

# 2. Commit the version bump and push it to the default branch
git add project.yml DesktopTitle.xcodeproj
git commit -m "Bump version to 1.2.3"
git push

# 3. Create an annotated tag at that commit and push it
git tag -a v1.2.3 -m "v1.2.3"
git push origin v1.2.3
```

The workflow runs `xcodebuild -configuration Release`, packages `DesktopTitle.app` with `ditto`, and publishes it as `DesktopTitle-vX.Y.Z.zip` on a new GitHub Release with auto-generated notes.

The build is unsigned (no Apple Developer ID); end users must follow the [Install](#install) steps to bypass Gatekeeper on first launch.

## License

MIT License
