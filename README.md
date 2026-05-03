# DesktopTitle

macOS menu bar app that displays desktop (Space) names when switching between desktops.

## Features

- Displays custom names for each desktop when switching
- Customizable overlay appearance:
  - Font size and font family
  - Text and background colors (unified or per-desktop)
  - Display position (X/Y)
  - Display duration and delay
- Works across all Spaces including fullscreen apps
- Lightweight menu bar app

## Requirements

- macOS 15.0 (Sequoia) or later

## Install

1. Download the latest `DesktopTitle-vX.Y.Z.zip` from the [Releases page](../../releases).
2. Unzip and move `DesktopTitle.app` to `/Applications`.
3. Because the app is **not signed with an Apple Developer ID**, macOS 15 (Sequoia) Gatekeeper blocks it on first launch. Allow it as follows:
   1. Double-click `DesktopTitle.app`. macOS will refuse to open it and show a warning dialog. Dismiss the dialog.
   2. Open **System Settings → Privacy & Security**.
   3. Scroll down to the message about `DesktopTitle.app` being blocked, and click **Open Anyway**. Authenticate with Touch ID or your password when prompted.
   4. Double-click `DesktopTitle.app` again and click **Open** in the confirmation dialog. You only need to do this once.

   <details><summary>Advanced: bypass via Terminal (only if you have verified the download yourself)</summary>

   ```bash
   xattr -dr com.apple.quarantine /Applications/DesktopTitle.app
   ```

   </details>

## Building

### Prerequisites

- Xcode 16.0 or later
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (for generating Xcode project)

### Build Steps

1. Generate Xcode project:
   ```bash
   xcodegen generate
   ```

2. Build from command line:
   ```bash
   xcodebuild -project DesktopTitle.xcodeproj -scheme DesktopTitle -configuration Debug -derivedDataPath ./build build
   ```

3. Run the app:
   ```bash
   open ./build/Build/Products/Debug/DesktopTitle.app
   ```

Or open `DesktopTitle.xcodeproj` in Xcode and build from there.

## Usage

1. Launch the app - it will appear in the menu bar
2. Click the menu bar icon and select "Settings..." to configure
3. Set custom names for each desktop in the "Desktops" tab
4. Adjust display settings in the "Display" tab
5. Switch desktops to see the overlay

## Project Structure

```
DesktopTitle/
├── App/
│   ├── DesktopTitleApp.swift    # App entry point
│   └── AppDelegate.swift        # Main app delegate
├── Core/
│   ├── CGSPrivate.h             # Private API declarations
│   ├── SpaceIdentifier.swift    # Space detection
│   └── SpaceMonitor.swift       # Space change monitoring
├── Models/
│   ├── SpaceConfig.swift        # Per-desktop configuration
│   └── AppSettings.swift        # Global app settings
└── UI/
    ├── MenuBarController.swift  # Menu bar management
    ├── OverlayWindow.swift      # Overlay window
    ├── OverlayView.swift        # Overlay view
    └── SettingsView.swift       # Settings window
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
