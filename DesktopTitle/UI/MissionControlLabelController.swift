//
//  MissionControlLabelController.swift
//  DesktopTitle
//
//  Per-Space label windows pinned via private CGS APIs. While Mission
//  Control is active each pinned banner becomes visible (alpha=1) so it
//  appears inside its Space's MC live preview; the rest of the time
//  every banner is alpha=0 so the user never sees them on the desktop.
//
//  Detection uses two private SkyLight notification IDs observed on
//  macOS 26 (Tahoe / 26.3.1):
//
//    • 1508 — fires once on MC open, twice (same millisecond) on MC
//      close. We debounce within a 250 ms window, so each user toggle
//      yields one effective event.
//    • 1401 — active-Space change. Used both as the canonical Space
//      switch signal AND to suppress phantom 1508s.
//
//  The crucial gotcha: macOS occasionally emits a stray 1508 about 1.2
//  seconds BEFORE a Space switch (the "phantom 1508 → 1401" pattern).
//  Treating that 1508 as MC-open would flash a giant banner during
//  every Space switch — the original "大バナー during Space switch"
//  bug. We defend against it by deferring activation by activationDelay
//  (1.5 s); any 1401 that arrives in the meantime cancels the pending
//  activation, so the banner never reaches the screen during a switch.
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
    private var mcDeactivationTimer: Timer?
    private var last1508At: Date = .distantPast
    private var pendingActivationWork: DispatchWorkItem?

    /// Delay between observing a 1508 (probable MC open) and actually showing
    /// banners. macOS sometimes emits a phantom 1508 ~1.2s before a Space
    /// switch (the "1508 then 1401" pattern that produces the "大バナー
    /// during Space switch" bug). Holding off the visibility change for this
    /// long lets a subsequent 1401 cancel the activation before any pixels
    /// hit the screen.
    private static let activationDelay: TimeInterval = 1.5

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
            // Active Space changed. Record the timestamp so a deferred 1508
            // evaluation can recognise "this 1508 is just a Space-change side
            // effect". Also cancel any pending activation: a phantom 1508 ~1
            // sec before this 1401 must NOT cause the banner to flash on
            // screen during the switch animation. And if MC is already
            // active, force it inactive — a Space change closes MC anyway
            // (e.g., clicking a thumbnail to switch desktops).
            lastSpaceChangeAt = Date()
            cancelPendingActivation(reason: "1401-spaceChange")
            if isMissionControlActive {
                deactivateMissionControl(reason: "1401-spaceChange")
            }
        case 1508:
            // On macOS 26 (Tahoe / 26.3.1) MC open emits a single 1508 while
            // MC close emits two 1508s within the same millisecond. Debounce
            // them so each user-visible toggle counts once: ignore any 1508
            // that arrives within 250ms of the previous one.
            let now = Date()
            let timeSinceLast1508 = now.timeIntervalSince(last1508At)
            last1508At = now
            if timeSinceLast1508 < 0.25 {
                DebugLog.log("MissionControlLabel", "1508 debounced", details: [
                    "deltaMs": "\(Int(timeSinceLast1508 * 1000))"
                ])
                return
            }
            // Defer 100ms so a paired 1401 (Space switch) has time to update
            // lastSpaceChangeAt regardless of callback ordering.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                let evalTime = Date()
                let timeSinceSpaceChange = evalTime.timeIntervalSince(self.lastSpaceChangeAt)
                if timeSinceSpaceChange < 0.3 {
                    DebugLog.log("MissionControlLabel", "1508 ignored (paired with 1401)", details: [
                        "deltaMs": "\(Int(timeSinceSpaceChange * 1000))"
                    ])
                    return
                }
                if self.isMissionControlActive {
                    self.deactivateMissionControl(reason: "1508-toggle")
                } else if self.pendingActivationWork != nil {
                    // A previous 1508 is still queued for delayed activation.
                    // This new 1508 is therefore the close-pair (or an
                    // open→close toggle within the activationDelay window).
                    // Either way, cancel — net effect: no banner ever shows.
                    self.cancelPendingActivation(reason: "1508-toggle close pair")
                } else {
                    // Schedule activation with a delay so a subsequent 1401
                    // (Space change) can cancel it. See activationDelay docs.
                    self.scheduleDelayedActivation(reason: "1508-toggle")
                }
            }
        case 1507:
            // Some older macOS versions emit 1507 on MC close. Keep it as a
            // belt-and-braces deactivation path.
            if isMissionControlActive {
                deactivateMissionControl(reason: "1507")
            }
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

    private func scheduleDelayedActivation(reason: String) {
        cancelPendingActivation(reason: "rescheduled")
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingActivationWork = nil
            self.activateMissionControl(reason: "\(reason) (after \(Int(Self.activationDelay * 1000))ms)")
        }
        pendingActivationWork = work
        DebugLog.log("MissionControlLabel", "scheduled delayed activation", details: [
            "reason": reason,
            "delayMs": "\(Int(Self.activationDelay * 1000))"
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.activationDelay, execute: work)
    }

    private func cancelPendingActivation(reason: String) {
        guard pendingActivationWork != nil else { return }
        pendingActivationWork?.cancel()
        pendingActivationWork = nil
        DebugLog.log("MissionControlLabel", "cancelled pending activation", details: [
            "reason": reason
        ])
    }

    private func activateMissionControl(reason: String) {
        rearmSafetyTimer()
        if !isMissionControlActive {
            isMissionControlActive = true
            applyVisibility(reason: "mc activate (\(reason))")
        }
    }

    private func deactivateMissionControl(reason: String) {
        cancelPendingActivation(reason: "deactivate")
        mcDeactivationTimer?.invalidate()
        mcDeactivationTimer = nil
        if isMissionControlActive {
            isMissionControlActive = false
            applyVisibility(reason: "mc deactivate (\(reason))")
        }
    }

    func stop() {
        cancelPendingActivation(reason: "stop")
        mcDeactivationTimer?.invalidate()
        mcDeactivationTimer = nil

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
    ///   - Mission Control NOT active: every banner is alpha=0 — the user
    ///     never sees the banner during normal desktop work.
    ///   - Mission Control active: every banner is alpha=1, including the
    ///     active Space's. macOS 26 (Tahoe) MC keeps the active Space's
    ///     content visible in the main MC area, so showing the banner there
    ///     gives the user a visible name for the focused Space.
    private func applyVisibility(reason: String) {
        let activeSpaceID = spaceIdentifier.getActiveSpaceID()

        for (_, window) in windows {
            let target: CGFloat
            if Self.debugAlwaysVisible {
                target = 1
            } else if isMissionControlActive {
                target = 1
            } else {
                target = 0
            }
            window.alphaValue = target

            // When making the banner visible, raise it above same-level
            // user windows on its pinned Space so it is not occluded in
            // the Mission Control thumbnail. The CGS-level reorder does
            // NOT switch Spaces (NSWindow.orderFront would).
            if target > 0 {
                window.raiseInZOrder()
            }
        }

        DebugLog.log("MissionControlLabel", "applied visibility", details: [
            "reason": reason,
            "isMissionControlActive": "\(isMissionControlActive)",
            "activeSpaceID": "\(activeSpaceID)",
            "windowCount": "\(windows.count)"
        ])
    }
}

// MARK: - CGS notification monitor

/// Registers callbacks for the SkyLight notification IDs we actually act
/// on. The IDs themselves are not publicly documented, so what each one
/// signals was determined empirically on macOS 26 (Tahoe / 26.3.1):
///   • 1401 — active Space changed.
///   • 1507 — Mission Control fully closed (legacy-macOS deactivation
///     path; Tahoe rarely emits it but the handler stays for safety).
///   • 1508 — Mission Control toggle (single fire on open, paired on
///     close).
private final class CGSEventMonitor {
    private static let candidateTypeIDs: [UInt32] = [1401, 1507, 1508]

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
        // Stay at .normal so per-Space pinning enforced via
        // CGSAddWindowsToSpaces is honoured — any higher level (even +1)
        // makes macOS treat the window as system-level and breaks the pin,
        // causing the banner to leak onto the active Space. Trade-off: at
        // .normal, user app windows on the same Space CAN occlude the
        // banner in the MC thumbnail. We mitigate by keeping the banner
        // large (88×41% of the Space) so partial occlusion still shows
        // enough of the label to read.
        level = .normal
        sharingType = .readWrite
        collectionBehavior = []
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

    /// Raises the window above other same-level windows on its pinned Space
    /// without changing its NSWindow level (changing the level would break
    /// per-Space pinning on macOS Tahoe). Call this whenever the banner
    /// should win against user app windows in the MC thumbnail.
    func raiseInZOrder() {
        guard windowNumber > 0 else { return }
        let connection = CGSMainConnectionID()
        // place=1 (kCGSOrderAbove), relative=0 → above the entire stack.
        _ = CGSOrderWindow(connection, Int32(windowNumber), 1, 0)
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
