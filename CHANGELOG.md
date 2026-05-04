# Changelog

All notable changes to DesktopTitle are documented in this file.

## 1.0.3 - 2026-05-04

### Fixed

- Made the fullscreen overlay toggle default to off and ignore older profile defaults.
- Improved fullscreen Space detection by checking the CoreGraphics Space type directly.
- Stopped fullscreen Spaces from being saved as desktop title entries.

## 1.0.2 - 2026-05-04

### Fixed

- Prevented duplicate DesktopTitle login items from being created on app launch.
- Preserved desktop title and color settings after Spaces are reordered, added, or removed.
- Forced settings writes to disk so updated desktop configuration is reflected after restart.

## 1.0.1 - 2026-05-04

### Changed

- Updated the app version display and bundle short version to 1.0.1 during local validation.

## 1.0.0 - 2026-05-04

### Added

- Initial release of DesktopTitle.
- Menu bar app for naming macOS desktops and showing desktop names as overlays when switching Spaces.
- Per-display-configuration settings, including multi-display inheritance or independent profiles.
- Customizable overlay timing, position, font, colors, desktop numbers, and fullscreen behavior.
