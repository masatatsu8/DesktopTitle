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
    static weak var shared: AppDelegate?

    private var menuBarController: MenuBarController?
    private let missionControlLabelController = MissionControlLabelController()
    private var cancellables = Set<AnyCancellable>()
    private var overlayWindows: [String: OverlayWindow] = [:]
    private var overlayGenerations: [String: Int] = [:]

    private let spaceMonitor = SpaceMonitor.shared
    private let spaceConfigManager = SpaceConfigManager.shared
    private let settings = AppSettings.shared
    private let displayConfigurationMonitor = DisplayConfigurationMonitor.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        DebugLog.beginSession()

        // Setup menu bar
        menuBarController = MenuBarController()

        // Activate the current display profile before subscriptions begin.
        displayConfigurationMonitor.startMonitoring()
        applyDisplayConfiguration(displayConfigurationMonitor.currentConfiguration)

        // Start monitoring space changes
        spaceMonitor.startMonitoring()
        missionControlLabelController.start()

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
                self?.menuBarController?.updateCurrentSpace(space)
            }
            .store(in: &cancellables)

        displayConfigurationMonitor.$currentConfiguration
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] configuration in
                self?.applyDisplayConfiguration(configuration)
            }
            .store(in: &cancellables)

        // Debounce reactive label rebuilds. Each rebuild iterates all 11
        // banner windows and re-runs SwiftUI hosting + CGS pin operations,
        // which is expensive AND occasionally drags the user's active
        // Space when the burst is large (e.g. while scrubbing a color
        // picker in Settings). 120 ms catches sustained slider drags
        // without making single edits feel sluggish.
        spaceConfigManager.$configs
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.menuBarController?.updateCurrentSpace(self.spaceMonitor.currentSpace)
                self.missionControlLabelController.refreshLabels()
            }
            .store(in: &cancellables)

        settings.objectWillChange
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.menuBarController?.updateCurrentSpace(self.spaceMonitor.currentSpace)
                self.missionControlLabelController.refreshLabels()
            }
            .store(in: &cancellables)

        // Initial sync
        spaceConfigManager.syncWithCurrentSpaces()

        DebugLog.log(
            "AppDelegate",
            "DesktopTitle started",
            details: [
                "currentConfiguration": settings.currentProfileSummary,
                "initialCurrentSpace": DebugLog.describe(space: spaceMonitor.currentSpace),
                "logFile": DebugLog.filePath
            ]
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.shared = nil
        spaceConfigManager.syncWithCurrentSpaces()
        missionControlLabelController.stop()
        spaceMonitor.stopMonitoring()
        displayConfigurationMonitor.stopMonitoring()
        DebugLog.log("AppDelegate", "DesktopTitle terminated")
    }

    // MARK: - Space Change Handling

    private func handleSpaceChange(_ event: SpaceChangeEvent) {
        missionControlLabelController.hideImmediately(reason: "spaceChangeEvent")

        guard !event.changedSpaces.isEmpty else {
            DebugLog.log(
                "AppDelegate",
                "space change ignored because changedSpaces was empty",
                details: [
                    "trigger": event.trigger,
                    "allCurrentSpaces": DebugLog.describe(spacesByDisplay: event.allCurrentSpaces)
                ]
            )
            return
        }

        // Refresh ordering before resolving the display label.
        spaceConfigManager.syncWithCurrentSpaces()

        DebugLog.log(
            "AppDelegate",
            "handling space change event",
            details: [
                "trigger": event.trigger,
                "occurredAt": ISO8601DateFormatter().string(from: event.occurredAt),
                "changedSpaces": DebugLog.describe(spaces: event.changedSpaces),
                "allCurrentSpaces": DebugLog.describe(spacesByDisplay: event.allCurrentSpaces),
                "showForFullscreen": "\(settings.showForFullscreen)"
            ]
        )

        for space in event.changedSpaces {
            DebugLog.log(
                "AppDelegate",
                "processing changed space",
                details: [
                    "space": DebugLog.describe(space: space)
                ]
            )

            // Skip fullscreen spaces if setting is disabled
            if space.isFullscreen && !settings.showForFullscreen {
                DebugLog.log(
                    "AppDelegate",
                    "skipping fullscreen space because setting is disabled",
                    details: [
                        "space": DebugLog.describe(space: space)
                    ]
                )
                continue
            }

            let delayOverride = missionControlLabelController.desktopOverlayDelayOverrideForSpaceChange(
                defaultDelay: settings.displayDelay
            )
            if let delayOverride {
                DebugLog.log(
                    "AppDelegate",
                    "delaying overlay for Mission Control transition",
                    details: [
                        "space": DebugLog.describe(space: space),
                        "delay": String(format: "%.3f", delayOverride)
                    ]
                )
            }
            showOverlay(for: space, delayOverride: delayOverride)
        }
    }

    func showPreviewOverlay(for previewSpace: SpaceInfo? = nil) {
        guard let space = previewSpace ?? spaceMonitor.currentSpace else {
            DebugLog.log("AppDelegate", "preview overlay request ignored because there was no current space")
            return
        }

        DebugLog.log(
            "AppDelegate",
            "preview overlay requested",
            details: [
                "space": DebugLog.describe(space: space)
            ]
        )
        showOverlay(for: space, delayOverride: 0)
    }

    private func showOverlay(for space: SpaceInfo, delayOverride: Double? = nil) {
        guard settings.showForFullscreen || !space.isFullscreen else {
            DebugLog.log(
                "AppDelegate",
                "overlay skipped for fullscreen space because setting is disabled",
                details: [
                    "space": DebugLog.describe(space: space)
                ]
            )
            return
        }

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

        let nextGeneration = (overlayGenerations[space.displayID] ?? 0) + 1
        overlayGenerations[space.displayID] = nextGeneration

        // Apply display delay if set
        let delay = delayOverride ?? settings.displayDelay
        DebugLog.log(
            "AppDelegate",
            "overlay scheduled",
            details: [
                "space": DebugLog.describe(space: space),
                "spaceName": spaceName,
                "generation": "\(nextGeneration)",
                "delay": String(format: "%.3f", delay),
                "displayDuration": String(format: "%.3f", settings.displayDuration),
                "showIndex": "\(settings.showSpaceIndex)",
                "fontSize": String(format: "%.1f", settings.fontSize),
                "position": String(format: "(%.3f, %.3f)", settings.positionX, settings.positionY),
                "useUnifiedColors": "\(settings.useUnifiedColors)",
                "backgroundColor": DebugLog.describe(color: backgroundColor),
                "textColor": DebugLog.describe(color: textColor),
                "nsAppActive": "\(NSApp.isActive)"
            ]
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, spaceName, space, backgroundColor, textColor, nextGeneration] in
            guard let self = self else { return }

            // Check if this overlay is still current (not superseded by another)
            guard nextGeneration == self.overlayGenerations[space.displayID] else {
                DebugLog.log(
                    "AppDelegate",
                    "overlay became stale before display",
                    details: [
                        "space": DebugLog.describe(space: space),
                        "requestedGeneration": "\(nextGeneration)",
                        "currentGeneration": "\(self.overlayGenerations[space.displayID] ?? -1)"
                    ]
                )
                return
            }

            let targetScreen = NSScreen.screens.first { $0.displayUUIDString == space.displayID }
            DebugLog.log(
                "AppDelegate",
                "overlay delay elapsed; preparing window show",
                details: [
                    "space": DebugLog.describe(space: space),
                    "generation": "\(nextGeneration)",
                    "targetScreen": DebugLog.describe(screen: targetScreen)
                ]
            )

            // Close previous overlay window for this display (if any)
            if let oldWindow = self.overlayWindows[space.displayID] {
                oldWindow.hide(reason: "replacedByNewGeneration=\(nextGeneration)")
                self.overlayWindows.removeValue(forKey: space.displayID)
            }

            // Create a fresh window on the current space
            let window = OverlayWindow(displayID: space.displayID)
            self.overlayWindows[space.displayID] = window

            let overlayView = OverlayContentView(
                spaceName: spaceName,
                spaceIndex: space.index,
                displayID: space.displayID,
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
                // Only hide/destroy if this overlay is still the current one
                if self?.overlayGenerations[space.displayID] == generation {
                    DebugLog.log(
                        "AppDelegate",
                        "overlay completion requested hide",
                        details: [
                            "space": DebugLog.describe(space: space),
                            "generation": "\(generation)"
                        ]
                    )
                    self?.overlayWindows[space.displayID]?.hide(reason: "animationCompleted generation=\(generation)")
                    self?.overlayWindows.removeValue(forKey: space.displayID)
                } else {
                    DebugLog.log(
                        "AppDelegate",
                        "overlay completion skipped hide because generation advanced",
                        details: [
                            "space": DebugLog.describe(space: space),
                            "completionGeneration": "\(generation)",
                            "currentGeneration": "\(self?.overlayGenerations[space.displayID] ?? -1)"
                        ]
                    )
                }
            }

            window.show(content: overlayView, on: targetScreen)
        }
    }

    private func applyDisplayConfiguration(_ configuration: DisplayConfiguration) {
        DebugLog.log(
            "AppDelegate",
            "applying display configuration",
            details: [
                "configurationID": configuration.id,
                "summary": configuration.summary,
                "orderedDisplays": configuration.orderedDisplayIDs.joined(separator: ", ")
            ]
        )
        settings.applyDisplayConfiguration(configuration)
        spaceConfigManager.setActiveProfile(
            configuration.id,
            mode: settings.profileMode,
            baseProfileID: settings.baseProfileID,
            displayIDs: configuration.orderedDisplayIDs
        )

        let activeDisplayIDs = Set(configuration.orderedDisplayIDs)
        let staleDisplayIDs = overlayWindows.keys.filter { !activeDisplayIDs.contains($0) }
        for displayID in staleDisplayIDs {
            DebugLog.log(
                "AppDelegate",
                "removing stale overlay window for inactive display",
                details: [
                    "display": DebugLog.shortDisplayID(displayID)
                ]
            )
            overlayWindows[displayID]?.hide(reason: "displayConfigurationChanged")
            overlayWindows.removeValue(forKey: displayID)
            overlayGenerations.removeValue(forKey: displayID)
        }

        spaceMonitor.updateCurrentSpace()
        spaceConfigManager.syncWithCurrentSpaces()
        menuBarController?.updateCurrentSpace(spaceMonitor.currentSpace)
        missionControlLabelController.refreshLabels()
    }
}

// MARK: - Overlay Content View

/// Internal view for overlay display with completion callback
private struct OverlayContentView: View {
    let spaceName: String
    let spaceIndex: Int
    let displayID: String
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
            DebugLog.log(
                "OverlayView",
                "overlay content appeared",
                details: [
                    "spaceName": spaceName,
                    "spaceIndex": "\(spaceIndex)",
                    "display": DebugLog.shortDisplayID(displayID),
                    "generation": "\(generation)",
                    "displayDuration": String(format: "%.3f", displayDuration)
                ]
            )

            // Fade in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                opacity = 1
                scale = 1
            }

            // Schedule fade out
            let gen = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + displayDuration) {
                DebugLog.log(
                    "OverlayView",
                    "starting overlay fade out",
                    details: [
                        "spaceName": spaceName,
                        "spaceIndex": "\(spaceIndex)",
                        "display": DebugLog.shortDisplayID(displayID),
                        "generation": "\(gen)"
                    ]
                )
                withAnimation(.easeOut(duration: 0.3)) {
                    opacity = 0
                    scale = 0.9
                }

                // Hide window after animation
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    DebugLog.log(
                        "OverlayView",
                        "fade out completed; invoking overlay completion",
                        details: [
                            "display": DebugLog.shortDisplayID(displayID),
                            "generation": "\(gen)"
                        ]
                    )
                    onComplete(gen)
                }
            }
        }
        .onDisappear {
            DebugLog.log(
                "OverlayView",
                "overlay content disappeared",
                details: [
                    "display": DebugLog.shortDisplayID(displayID),
                    "generation": "\(generation)"
                ]
            )
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
