//
//  AppDelegate.swift
//  DesktopTitle
//
//  Application delegate for AppKit integration
//

import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBarController: MenuBarController?
    private var cancellables = Set<AnyCancellable>()
    private var overlayWindows: [String: OverlayWindow] = [:]
    private var overlayGenerations: [String: Int] = [:]

    private let spaceMonitor = SpaceMonitor.shared
    private let spaceConfigManager = SpaceConfigManager.shared
    private let settings = AppSettings.shared
    private let displayConfigurationMonitor = DisplayConfigurationMonitor.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup menu bar
        menuBarController = MenuBarController()

        // Activate the current display profile before subscriptions begin.
        displayConfigurationMonitor.startMonitoring()
        applyDisplayConfiguration(displayConfigurationMonitor.currentConfiguration)

        // Start monitoring space changes
        spaceMonitor.startMonitoring()

        // Subscribe to space changes
        spaceMonitor.$spaceChangeEvent
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] event in
                self?.handleSpaceChange(event)
            }
            .store(in: &cancellables)

        // Subscribe to current space updates for menu bar
        spaceMonitor.$currentSpace
            .receive(on: RunLoop.main)
            .sink { [weak self] space in
                guard let self = self else { return }
                // Keep desktop indices fresh even when macOS auto-reorders Spaces.
                self.spaceConfigManager.syncWithCurrentSpaces()
                self.menuBarController?.updateCurrentSpace(space)
            }
            .store(in: &cancellables)

        displayConfigurationMonitor.$currentConfiguration
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] configuration in
                self?.applyDisplayConfiguration(configuration)
            }
            .store(in: &cancellables)

        // Initial sync
        spaceConfigManager.syncWithCurrentSpaces()

        print("[AppDelegate] DesktopTitle started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        spaceMonitor.stopMonitoring()
        displayConfigurationMonitor.stopMonitoring()
        print("[AppDelegate] DesktopTitle terminated")
    }

    // MARK: - Space Change Handling

    private func handleSpaceChange(_ event: SpaceChangeEvent) {
        guard !event.changedSpaces.isEmpty else {
            print("[AppDelegate] handleSpaceChange: changedSpaces is empty")
            return
        }

        // Refresh ordering before resolving the display label.
        spaceConfigManager.syncWithCurrentSpaces()

        for space in event.changedSpaces {
            print("[AppDelegate] handleSpaceChange: space \(space.index), isFullscreen: \(space.isFullscreen), display: \(space.displayID)")

            // Skip fullscreen spaces if setting is disabled
            if space.isFullscreen && !settings.showForFullscreen {
                print("[AppDelegate] Skipping fullscreen space")
                continue
            }

            showOverlay(for: space)
        }
    }

    private func showOverlay(for space: SpaceInfo) {
        let spaceName = spaceConfigManager.getDisplayName(for: space)

        // Determine colors based on unified/per-desktop setting
        let backgroundColor: Color
        let textColor: Color

        if settings.useUnifiedColors {
            backgroundColor = settings.backgroundColor
            textColor = settings.textColor
        } else {
            backgroundColor = spaceConfigManager.getBackgroundColor(for: space) ?? settings.backgroundColor
            textColor = spaceConfigManager.getTextColor(for: space) ?? settings.textColor
        }

        print("[AppDelegate] showOverlay: name=\(spaceName), index=\(space.index), useUnified=\(settings.useUnifiedColors), delay=\(settings.displayDelay)")

        let nextGeneration = (overlayGenerations[space.displayID] ?? 0) + 1
        overlayGenerations[space.displayID] = nextGeneration

        // Apply display delay if set
        let delay = settings.displayDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, spaceName, space, backgroundColor, textColor, nextGeneration] in
            guard let self = self else { return }

            // Check if this overlay is still current (not superseded by another)
            guard nextGeneration == self.overlayGenerations[space.displayID] else {
                print("[AppDelegate] Skipping stale overlay for space \(space.index)")
                return
            }

            print("[AppDelegate] Showing overlay now for space \(space.index)")

            let overlayView = OverlayContentView(
                spaceName: spaceName,
                spaceIndex: space.index,
                showIndex: self.settings.showSpaceIndex,
                fontSize: self.settings.fontSize,
                displayDuration: self.settings.displayDuration,
                positionX: self.settings.positionX,
                positionY: self.settings.positionY,
                backgroundColor: backgroundColor,
                textColor: textColor,
                fontName: self.settings.fontName,
                generation: nextGeneration
            ) { [weak self] generation in
                // Only hide if this overlay is still the current one
                if self?.overlayGenerations[space.displayID] == generation {
                    self?.overlayWindows[space.displayID]?.hide()
                }
            }

            let targetScreen = NSScreen.screens.first { $0.displayUUIDString == space.displayID }
            self.overlayWindow(for: space.displayID).show(content: overlayView, on: targetScreen)
        }
    }

    private func overlayWindow(for displayID: String) -> OverlayWindow {
        if let existing = overlayWindows[displayID] {
            return existing
        }

        let window = OverlayWindow()
        overlayWindows[displayID] = window
        return window
    }

    private func applyDisplayConfiguration(_ configuration: DisplayConfiguration) {
        settings.applyDisplayConfiguration(configuration)
        spaceConfigManager.setActiveProfile(configuration.id)

        let activeDisplayIDs = Set(configuration.orderedDisplayIDs)
        let staleDisplayIDs = overlayWindows.keys.filter { !activeDisplayIDs.contains($0) }
        for displayID in staleDisplayIDs {
            overlayWindows[displayID]?.hide()
            overlayWindows.removeValue(forKey: displayID)
            overlayGenerations.removeValue(forKey: displayID)
        }

        spaceMonitor.updateCurrentSpace()
        spaceConfigManager.syncWithCurrentSpaces()
        menuBarController?.updateCurrentSpace(spaceMonitor.currentSpace)
    }
}

// MARK: - Overlay Content View

/// Internal view for overlay display with completion callback
private struct OverlayContentView: View {
    let spaceName: String
    let spaceIndex: Int
    let showIndex: Bool
    let fontSize: CGFloat
    let displayDuration: Double
    let positionX: Double
    let positionY: Double
    let backgroundColor: Color
    let textColor: Color
    let fontName: String
    let generation: Int
    let onComplete: (Int) -> Void

    @State private var opacity: Double = 0
    @State private var scale: Double = 0.8

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Content at custom position
                VStack(spacing: 8) {
                    Text(spaceName)
                        .font(customFont(size: fontSize))
                        .foregroundStyle(textColor)

                    if showIndex {
                        Text("Desktop \(spaceIndex)")
                            .font(customFont(size: fontSize * 0.4))
                            .foregroundStyle(textColor.opacity(0.7))
                    }


                }
                .padding(.horizontal, 40)
                .padding(.vertical, 24)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(backgroundColor)
                        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
                }
                .scaleEffect(scale)
                .opacity(opacity)
                .position(
                    x: geometry.size.width * positionX,
                    y: geometry.size.height * positionY
                )
            }
        }
        .onAppear {
            // Fade in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                opacity = 1
                scale = 1
            }

            // Schedule fade out
            let gen = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + displayDuration) {
                withAnimation(.easeOut(duration: 0.3)) {
                    opacity = 0
                    scale = 0.9
                }

                // Hide window after animation
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    onComplete(gen)
                }
            }
        }
    }

    private func customFont(size: CGFloat) -> Font {
        if fontName.isEmpty {
            return .system(size: size, weight: .medium, design: .rounded)
        } else {
            return .custom(fontName, size: size)
        }
    }
}
