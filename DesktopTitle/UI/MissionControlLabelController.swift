//
//  MissionControlLabelController.swift
//  DesktopTitle
//
//  Per-Space label windows that get captured into Mission Control's
//  thumbnail strip and active-Space preview. Each banner is pinned to
//  its Space via private CGS APIs and toggled between alpha=0 and
//  alpha=1 based on whether Mission Control is currently active.
//
//  Mission Control detection uses AXObserver on the Dock process. The
//  MC overlay is rendered by SkyLight directly and is NOT exposed via
//  CGWindowListCopyWindowInfo, NSWindow occlusion notifications, or
//  the public `com.apple.expose.*` distributed notifications — every
//  one of those was tried and discarded. AXObserver on Dock is the
//  same mechanism Yabai / SpaceJump-style utilities use, and it does
//  require Accessibility permission to be granted once.
//

import AppKit
import ApplicationServices
import SwiftUI

final class MissionControlLabelController {
    // Set true to keep banners permanently visible. Useful when validating
    // that pin / level / sharing-type / sizing all work end-to-end without
    // the MC-detection layer in the way.
    private static let debugAlwaysVisible = false

    private var windows: [UInt64: MissionControlLabelWindow] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var isMissionControlActive = false
    private var cgsMonitor: CGSEventMonitor?
    private var lastSpaceChangeAt: Date = .distantPast
    private var lastDeactivatedAt: Date = .distantPast
    private var mcDeactivationTimer: Timer?
    private var recentUnpaired1508s: [Date] = []

    static weak var shared: MissionControlLabelController?

    private let settings = AppSettings.shared
    private let spaceIdentifier = SpaceIdentifier.shared

    func start() {
        Self.shared = self
        rebuildWindows()

        workspaceObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.rebuildWindows()
            }
        )

        let monitor = CGSEventMonitor()
        monitor.start()
        cgsMonitor = monitor

        DebugLog.log("MissionControlLabel", "started", details: [
            "windowCount": "\(windows.count)",
            "debugAlwaysVisible": "\(Self.debugAlwaysVisible)"
        ])
    }

    fileprivate func handleCGSNotification(type: UInt32) {
        switch type {
        case 1401:
            // Active Space changed. 1508 + 1401 fires in the same millisecond
            // for both trackpad swipes AND in-MC navigation, so we cannot use
            // 1401 to trigger MC; we only record the timestamp so a deferred-
            // evaluated 1508 can detect "I'm just a Space-change side effect".
            lastSpaceChangeAt = Date()
        case 1508:
            // Defer 100ms. 1508 races with 1401 inside the same millisecond
            // when a Space switch happens; waiting lets the 1401 update
            // lastSpaceChangeAt regardless of callback order.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                let now = Date()
                let timeSinceSpaceChange = now.timeIntervalSince(self.lastSpaceChangeAt)
                if timeSinceSpaceChange < 0.3 {
                    DebugLog.log("MissionControlLabel", "1508 ignored (paired with 1401)", details: [
                        "deltaMs": "\(Int(timeSinceSpaceChange * 1000))"
                    ])
                    return
                }
                // 1507 fires AFTER the close-animation 1508s in CGS callback
                // order, but my deferred 100ms check on those 1508s runs even
                // later. Discard 1508s that arrive within 1s of an explicit
                // 1507 deactivation — they are part of the close animation,
                // not a fresh open.
                let timeSinceDeactivation = now.timeIntervalSince(self.lastDeactivatedAt)
                if timeSinceDeactivation < 1.0 {
                    DebugLog.log("MissionControlLabel", "1508 ignored (post-1507 close)", details: [
                        "deltaMs": "\(Int(timeSinceDeactivation * 1000))"
                    ])
                    return
                }
                // Single isolated 1508s fire spuriously (e.g., ~3 sec after a
                // trackpad swipe completes its animation). MC opens, by
                // contrast, fire multiple 1508s within ~500ms. Require 2+ in
                // the recent window before activating.
                self.recentUnpaired1508s.append(now)
                self.recentUnpaired1508s.removeAll { now.timeIntervalSince($0) > 0.5 }
                guard self.recentUnpaired1508s.count >= 2 else {
                    DebugLog.log("MissionControlLabel", "1508 buffered (need 2+)", details: [
                        "count": "\(self.recentUnpaired1508s.count)"
                    ])
                    return
                }
                self.recentUnpaired1508s.removeAll()
                self.activateMissionControl(reason: "1508-burst")
            }
        case 1507:
            // 1507 fires reliably when Mission Control fully closes. Use it as
            // the canonical deactivation signal.
            deactivateMissionControl(reason: "1507")
        default:
            break
        }
    }

    private func rearmSafetyTimer() {
        // Long safety net in case 1507 is missed for any reason. Without this,
        // a missed close would leave banners visible until app restart.
        mcDeactivationTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: false) { [weak self] _ in
            self?.deactivateMissionControl(reason: "safetyTimeout")
        }
        mcDeactivationTimer = timer
    }

    private func activateMissionControl(reason: String) {
        rearmSafetyTimer()
        if !isMissionControlActive {
            isMissionControlActive = true
            applyVisibility(reason: "mc activate (\(reason))")
        }
    }

    private func deactivateMissionControl(reason: String) {
        mcDeactivationTimer?.invalidate()
        mcDeactivationTimer = nil
        // Drop any pending 1508 burst tracking — the close animation
        // produces 1508s and we must not let them re-trigger activation.
        recentUnpaired1508s.removeAll()
        lastDeactivatedAt = Date()
        if isMissionControlActive {
            isMissionControlActive = false
            applyVisibility(reason: "mc deactivate (\(reason))")
        }
    }

    func stop() {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        cgsMonitor?.stop()
        cgsMonitor = nil

        for window in windows.values {
            window.close()
        }
        windows.removeAll()

        DebugLog.log("MissionControlLabel", "stopped")
    }

    func hideImmediately(reason: String) {
        guard !Self.debugAlwaysVisible else { return }
        for window in windows.values {
            window.alphaValue = 0
        }
        DebugLog.log("MissionControlLabel", "hideImmediately", details: ["reason": reason])
    }

    func refreshLabels() {
        rebuildWindows()
    }

    // MARK: - Window lifecycle

    private func rebuildWindows() {
        guard settings.showMissionControlLabels else {
            tearDownAllWindows(reason: "settingDisabled")
            return
        }

        let spaces = spaceIdentifier.getAllSpaces()
            .filter { settings.showForFullscreen || !$0.isFullscreen }

        let liveSpaceIDs = Set(spaces.map { $0.id })

        for spaceID in Array(windows.keys) where !liveSpaceIDs.contains(spaceID) {
            windows[spaceID]?.close()
            windows.removeValue(forKey: spaceID)
        }

        for space in spaces {
            if let existing = windows[space.id] {
                // CRITICAL: do NOT orderFront here. AppKit will force a Space
                // switch to the window's pinned Space, cycling the user
                // through every Space at every rebuild.
                existing.update(space: space)
            } else {
                let window = MissionControlLabelWindow(space: space)
                windows[space.id] = window
            }
        }

        applyVisibility(reason: "rebuildWindows")

        DebugLog.log("MissionControlLabel", "rebuilt windows", details: [
            "windowCount": "\(windows.count)",
            "spaces": DebugLog.describe(spaces: spaces)
        ])
    }

    private func tearDownAllWindows(reason: String) {
        guard !windows.isEmpty else { return }
        for window in windows.values {
            window.close()
        }
        windows.removeAll()
        DebugLog.log("MissionControlLabel", "tore down windows", details: ["reason": reason])
    }

    // MARK: - Visibility toggle

    /// Strategy:
    ///   - Mission Control NOT active: every banner is alpha=0.
    ///   - Mission Control active: every non-active-Space banner is alpha=1
    ///     so it appears in MC's thumbnail strip; the active-Space banner
    ///     stays at alpha=0 so it does not appear over the live preview
    ///     (mirrors SpaceJump's observed behavior — the highlighted Space's
    ///     thumbnail has no banner).
    private func applyVisibility(reason: String) {
        let activeSpaceID = spaceIdentifier.getActiveSpaceID()

        for (spaceID, window) in windows {
            let target: CGFloat
            if Self.debugAlwaysVisible {
                target = 1
            } else if !isMissionControlActive {
                target = 0
            } else if spaceID == activeSpaceID {
                target = 0
            } else {
                target = 1
            }
            window.alphaValue = target
        }

        DebugLog.log("MissionControlLabel", "applied visibility", details: [
            "reason": reason,
            "isMissionControlActive": "\(isMissionControlActive)",
            "activeSpaceID": "\(activeSpaceID)",
            "windowCount": "\(windows.count)"
        ])
    }
}

// MARK: - CGS notification monitor (diagnostic)

/// Registers callbacks for a wide range of private SkyLight notification
/// type IDs and logs everything that fires. The MC-related IDs are not
/// publicly documented, so this is exploratory: open MC, swipe Spaces,
/// etc., then look at the log to see which IDs fire when.
private final class CGSEventMonitor {
    private static let candidateTypeIDs: [UInt32] = [
        // Window / process foreground
        100, 101, 102, 103, 104, 105,
        // Space switching family
        1100, 1101, 1102, 1103, 1104, 1105, 1106, 1107, 1108, 1109, 1110,
        // Mission Control / Exposé family (Yabai uses values in this range)
        1200, 1201, 1202, 1203, 1204,
        1400, 1401, 1402, 1403, 1404, 1405, 1406, 1407, 1408,
        1409, 1410, 1411, 1412, 1413, 1414, 1415, 1416, 1417, 1418, 1419,
        // Space / display change family
        1500, 1501, 1502, 1503, 1504, 1505, 1506, 1507, 1508, 1509, 1510,
        // Dock / Launchpad
        1600, 1601, 1602, 1603, 1604, 1605, 1606,
    ]

    private var registered: [UInt32] = []

    func start() {
        for id in Self.candidateTypeIDs {
            let result = CGSRegisterNotifyProc(cgsNotifyCallback, id, nil)
            if result == .success {
                registered.append(id)
            }
        }
        DebugLog.log("CGSEvent", "started", details: [
            "registeredCount": "\(registered.count)",
            "totalAttempted": "\(Self.candidateTypeIDs.count)"
        ])
    }

    func stop() {
        for id in registered {
            _ = CGSRemoveNotifyProc(cgsNotifyCallback, id, nil)
        }
        registered.removeAll()
        DebugLog.log("CGSEvent", "stopped")
    }
}

private let cgsNotifyCallback: CGSNotifyProcPtr = { type, _, length, _ in
    DebugLog.log("CGSEvent", "fired", details: [
        "type": "\(type)",
        "length": "\(length)"
    ])
    DispatchQueue.main.async {
        MissionControlLabelController.shared?.handleCGSNotification(type: type)
    }
}

// MARK: - Per-Space label window

private final class MissionControlLabelWindow: NSWindow {
    private var pinnedSpaceID: UInt64

    init(space: SpaceInfo) {
        self.pinnedSpaceID = space.id

        let screen = NSScreen.screens.first { $0.displayUUIDString == space.displayID } ?? NSScreen.main
        let frame = screen.map { Self.bannerFrame(on: $0) }
            ?? NSRect(x: 0, y: 0, width: 1600, height: 480)

        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        configureWindow()
        installContent(for: space)

        // orderFrontRegardless ONLY at creation. The window has no prior Space
        // association so it joins the current Space's z-stack without forcing a
        // switch. After this, pinToAssignedSpace moves it to the target Space.
        // Subsequent updates MUST NOT orderFront — see update(space:).
        orderFrontRegardless()
        pinToAssignedSpace()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func close() {
        unpinFromSpaces()
        super.close()
    }

    private func configureWindow() {
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isExcludedFromWindowsMenu = true
        isReleasedWhenClosed = false
        alphaValue = 0
        level = .normal
        sharingType = .readOnly
        collectionBehavior = [.fullScreenAuxiliary]
    }

    func update(space: SpaceInfo) {
        pinnedSpaceID = space.id

        if let screen = NSScreen.screens.first(where: { $0.displayUUIDString == space.displayID }) ?? NSScreen.main {
            setFrame(Self.bannerFrame(on: screen), display: false)
        }

        installContent(for: space)
        // pinToAssignedSpace is idempotent and does NOT order the window front,
        // so it is safe to call from update without forcing a Space switch.
        pinToAssignedSpace()

        DebugLog.log("MissionControlLabel", "updated label window", details: [
            "space": DebugLog.describe(space: space),
            "window": DebugLog.describe(window: self)
        ])
    }

    private func installContent(for space: SpaceInfo) {
        let configManager = SpaceConfigManager.shared
        let settings = AppSettings.shared
        let spaceName = configManager.getDisplayName(for: space)

        let backgroundColor: Color
        let textColor: Color
        if settings.useUnifiedColors {
            backgroundColor = settings.backgroundColor
            textColor = settings.textColor
        } else {
            backgroundColor = configManager.getBackgroundColor(for: space) ?? settings.backgroundColor
            textColor = configManager.getTextColor(for: space) ?? settings.textColor
        }

        let hosting = NSHostingView(
            rootView: MissionControlLabelView(
                spaceName: spaceName,
                textColor: textColor,
                backgroundColor: backgroundColor,
                fontName: settings.fontName,
                size: frame.size
            )
        )
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }

    private func pinToAssignedSpace() {
        guard windowNumber > 0 else { return }

        let connection = CGSMainConnectionID()
        let windowIDs = [NSNumber(value: Int32(windowNumber))] as CFArray
        let targetSpaces = [NSNumber(value: pinnedSpaceID)] as CFArray

        CGSAddWindowsToSpaces(connection, windowIDs, targetSpaces)

        if let currentSpaces = CGSCopySpacesForWindows(connection, kCGSAllSpacesMask, windowIDs) {
            let extras = (currentSpaces as NSArray).compactMap { ($0 as? NSNumber)?.uint64Value }
                .filter { $0 != pinnedSpaceID }
            if !extras.isEmpty {
                CGSRemoveWindowsFromSpaces(
                    connection,
                    windowIDs,
                    extras.map { NSNumber(value: $0) } as CFArray
                )
            }
        }
    }

    private func unpinFromSpaces() {
        guard windowNumber > 0 else { return }

        let connection = CGSMainConnectionID()
        let windowIDs = [NSNumber(value: Int32(windowNumber))] as CFArray
        if let currentSpaces = CGSCopySpacesForWindows(connection, kCGSAllSpacesMask, windowIDs) {
            CGSRemoveWindowsFromSpaces(connection, windowIDs, currentSpaces)
        }
    }

    /// Centered, lower-third banner sized after SpaceJump's apparent layout
    /// (~88% screen width, ~41% screen height, bottom edge ~11% above screen bottom).
    private static func bannerFrame(on screen: NSScreen) -> NSRect {
        let screenFrame = screen.frame
        let width = screenFrame.width * 0.88
        let height = screenFrame.height * 0.41
        let x = screenFrame.minX + (screenFrame.width - width) / 2
        let y = screenFrame.minY + screenFrame.height * 0.11
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - Banner content

private struct MissionControlLabelView: View {
    let spaceName: String
    let textColor: Color
    let backgroundColor: Color
    let fontName: String
    let size: CGSize

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size.height * 0.12, style: .continuous)
                .fill(backgroundColor)

            Text(spaceName)
                .font(labelFont)
                .foregroundStyle(textColor)
                .lineLimit(1)
                .minimumScaleFactor(0.35)
                .padding(.horizontal, size.height * 0.18)
        }
        .frame(width: size.width, height: size.height)
    }

    private var labelFont: Font {
        let pt = size.height * 0.55
        if fontName.isEmpty {
            return .system(size: pt, weight: .heavy, design: .default)
        }
        return .custom(fontName, size: pt)
    }
}
