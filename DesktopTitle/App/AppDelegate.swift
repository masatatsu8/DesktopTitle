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
    private var overlayWindow: OverlayWindow?
    private var cancellables = Set<AnyCancellable>()
    private var currentOverlayGeneration: Int = 0  // Track overlay generation to prevent race conditions

    private let spaceMonitor = SpaceMonitor.shared
    private let spaceConfigManager = SpaceConfigManager.shared
    private let settings = AppSettings.shared
    private let imageCache = DesktopImageCache.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup menu bar
        menuBarController = MenuBarController()

        // Setup overlay window
        overlayWindow = OverlayWindow()

        // Start monitoring space changes
        spaceMonitor.startMonitoring()

        // Initialize image cache (triggers permission check)
        print("[AppDelegate] ImageCache hasPermission: \(imageCache.hasPermission)")

        // Subscribe to space changes
        spaceMonitor.$spaceChangedAt
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.handleSpaceChange()
            }
            .store(in: &cancellables)

        // Subscribe to current space updates for menu bar
        spaceMonitor.$currentSpace
            .receive(on: RunLoop.main)
            .sink { [weak self] space in
                self?.menuBarController?.updateCurrentSpace(space)
            }
            .store(in: &cancellables)

        // Initial sync
        spaceConfigManager.syncWithCurrentSpaces()

        print("[AppDelegate] DesktopTitle started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        spaceMonitor.stopMonitoring()
        print("[AppDelegate] DesktopTitle terminated")
    }

    // MARK: - Space Change Handling

    private func handleSpaceChange() {
        guard let currentSpace = spaceMonitor.currentSpace else {
            print("[AppDelegate] handleSpaceChange: currentSpace is nil")
            return
        }

        print("[AppDelegate] handleSpaceChange: space \(currentSpace.index), isFullscreen: \(currentSpace.isFullscreen)")

        // Skip fullscreen spaces if setting is disabled
        if currentSpace.isFullscreen && !settings.showForFullscreen {
            print("[AppDelegate] Skipping fullscreen space")
            return
        }

        showOverlay(for: currentSpace)
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

        // Increment generation to invalidate any pending hide operations
        currentOverlayGeneration += 1
        let thisGeneration = currentOverlayGeneration

        // Apply display delay if set
        let delay = settings.displayDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, spaceName, space, backgroundColor, textColor, thisGeneration] in
            guard let self = self else { return }

            // Check if this overlay is still current (not superseded by another)
            guard thisGeneration == self.currentOverlayGeneration else {
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
                generation: thisGeneration
            ) { [weak self] generation in
                // Only hide if this overlay is still the current one
                if self?.currentOverlayGeneration == generation {
                    self?.overlayWindow?.hide()
                }
            }

            let targetScreen = NSScreen.screens.first { $0.displayUUIDString == space.displayID }
            self.overlayWindow?.show(content: overlayView, on: targetScreen)
        }
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
