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

## License

MIT License
