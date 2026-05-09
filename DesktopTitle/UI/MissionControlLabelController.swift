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
    private var globalMouseMonitor: Any?
    fileprivate var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var eventTapThread: Thread?
    /// Window IDs of all banners, cached for thread-safe access from the
    /// CGEventTap background thread. Updated atomically when windows change.
    private let bannerWindowIDsLock = NSLock()
    private var bannerWindowIDs: [UInt32] = []
    private var lastSpaceChangeAt: Date = .distantPast
    private var mcDeactivationTimer: Timer?
    private var pendingActivationWork: DispatchWorkItem?
    private var pending1508s: [Date] = []
    private var pending1508EvalWork: DispatchWorkItem?
    private var pendingVisibilityRestore: DispatchWorkItem?

    /// Height (in points) of the MC thumbnail strip / target click region.
    /// A mouse-down inside this band while MC is active is treated as a
    /// thumbnail click, prompting an immediate banner hide so the
    /// destination Space's zoom-in animation does not include the banner.
    private static let mcStripHeight: CGFloat = 200

    /// Window during which we coalesce 1508 events to classify them.
    /// Empirically on macOS Tahoe (26.3.1):
    ///   • MC open: emits 1 single 1508 (sometimes 2 with ~165 ms gap).
    ///   • MC close: emits 2 paired 1508s within the SAME millisecond.
    /// 30 ms catches the same-ms pair without merging the 165 ms-spaced
    /// open pair, letting us classify the burst as open vs close.
    private static let pulseClassificationWindow: TimeInterval = 0.03

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

        // Global mouse-down monitor. Kept as a fallback because CGEventTap
        // requires Input Monitoring permission. addGlobalMonitorForEvents
        // does NOT see MC thumbnail clicks (WindowServer captures them
        // before they're delivered as application events), so this is
        // effectively only useful for non-MC click logging.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handleGlobalMouseDown(event)
        }

        // CGEventTap on kCGSessionEventTap. Runs at the system event-tap
        // layer, so it sees mouse-downs DURING Mission Control (the MC UI
        // does not consume them at this layer). The source is attached to
        // the main run loop, which lets the callback run on the main thread
        // synchronously when the run loop services it — eliminating the
        // ~80 ms DispatchQueue.main.async hop that 1401-based hides suffer.
        // CGEventTap requires Input Monitoring permission. If permission is
        // missing, tapCreate returns nil and we silently fall back to the
        // 1401 preemptive hide path (still works, just slower).
        startEventTap()

        DebugLog.log("MissionControlLabel", "started", details: [
            "windowCount": "\(windows.count)",
            "debugAlwaysVisible": "\(Self.debugAlwaysVisible)"
        ])
    }

    private func startEventTap() {
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, _ in
            // Log every event observed so we can verify the tap is firing.
            DebugLog.log("MissionControlLabel", "eventTap callback", details: [
                "type": "\(type.rawValue)"
            ])
            switch type {
            case .leftMouseDown:
                MissionControlLabelController.shared?.handleEventTapMouseDownFromBackground()
            case .leftMouseUp:
                MissionControlLabelController.shared?.handleEventTapMouseUpFromBackground()
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                if let tap = MissionControlLabelController.shared?.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                    DebugLog.log("MissionControlLabel", "CGEventTap re-enabled", details: [
                        "reason": type == .tapDisabledByTimeout ? "timeout" : "userInput"
                    ])
                }
            default:
                break
            }
            return Unmanaged.passUnretained(event)
        }

        // Use kCGSessionEventTap. HID-level tap is repeatedly auto-disabled
        // by macOS Tahoe within ~500 ms of each enable (we logged this with
        // a health-check timer), making it useless for our purpose. Session
        // tap is more lenient and is what gets us reliable mouse-down
        // delivery while MC is active.
        let tapLocation: CGEventTapLocation = .cgSessionEventTap
        guard let tap = CGEvent.tapCreate(
            tap: tapLocation,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: nil
        ) else {
            DebugLog.log("MissionControlLabel", "CGEventTap creation failed")
            return
        }
        DebugLog.log("MissionControlLabel", "CGEventTap created", details: [
            "tapLocation": "Session"
        ])

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        // Run the tap on a dedicated background thread with its own
        // CFRunLoop. Attaching the tap source to the MAIN run loop made the
        // tap susceptible to tapDisabledByUserInput whenever the main queue
        // was busy (e.g., during MC open / Space-change CGS bursts), causing
        // the tap to silently stop firing right at the moment we needed it
        // (the user's thumbnail click). A dedicated userInteractive thread
        // services the tap independently of main-queue load, so the callback
        // runs immediately on mouse-down.
        // Capture tap and source strongly — they need to outlive this
        // closure for as long as CFRunLoopRun is running on the thread, and
        // CFMachPort does not support weak references (it's a CF type
        // bridged to NSMachPort which is not retainable for weak).
        let thread = Thread {
            Thread.current.name = "DesktopTitle-CGEventTap"
            DebugLog.log("MissionControlLabel", "CGEventTap thread starting CFRunLoop")
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)

            // macOS sometimes silently disables the tap without firing the
            // tapDisabledBy* event. Periodically check tap state and re-
            // enable when needed. The timer is scheduled on this thread's
            // run loop, so it runs alongside the tap callback.
            let healthTimer = Timer(
                timeInterval: 0.5,
                repeats: true
            ) { _ in
                if !CGEvent.tapIsEnabled(tap: tap) {
                    CGEvent.tapEnable(tap: tap, enable: true)
                    DebugLog.log("MissionControlLabel", "CGEventTap re-enabled (health-check)")
                }
            }
            RunLoop.current.add(healthTimer, forMode: .common)

            CFRunLoopRun()
            DebugLog.log("MissionControlLabel", "CGEventTap thread CFRunLoop returned (unexpected)")
        }
        thread.qualityOfService = .userInteractive
        thread.start()

        eventTap = tap
        eventTapSource = source
        eventTapThread = thread

        DebugLog.log("MissionControlLabel", "CGEventTap started (dedicated thread)")
    }

    private func stopEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        // Letting the source go out of scope + tap disabled is enough to
        // exit CFRunLoopRun on the dedicated thread shortly. We do not
        // forcibly cancel the thread.
        eventTap = nil
        eventTapSource = nil
        eventTapThread = nil
    }

    /// Updates the cached banner windowIDs used by the CGEventTap background
    /// thread for direct CGSSetWindowAlpha calls. Call from main thread
    /// whenever the banner window set changes.
    private func refreshBannerWindowIDsCache() {
        let ids = windows.values.compactMap { window -> UInt32? in
            let n = window.windowNumber
            return n > 0 ? UInt32(n) : nil
        }
        bannerWindowIDsLock.lock()
        bannerWindowIDs = ids
        bannerWindowIDsLock.unlock()
    }

    /// Synchronously hides every banner via direct WindowServer IPC. Safe
    /// to call from any thread because CGSSetWindowAlpha is a Mach IPC call,
    /// not an AppKit call. Used from the CGEventTap background thread to
    /// drop banner alpha to 0 the same instant a left mouse-down is observed,
    /// before the click can commit a Space switch and start a zoom-in.
    private func hideAllBannersViaCGS() {
        bannerWindowIDsLock.lock()
        let ids = bannerWindowIDs
        bannerWindowIDsLock.unlock()
        let connection = CGSMainConnectionID()
        for id in ids {
            _ = CGSSetWindowAlpha(connection, id, 0)
        }
    }

    /// Background-thread-safe wrapper around hideAllBannersViaCGS that
    /// short-circuits when MC isn't active. `isMissionControlActive` is read
    /// without a lock; a stale read of false is acceptable (we'd just skip
    /// an unnecessary CGS call), and a stale read of true at most causes
    /// one redundant alpha=0 to WindowServer (also harmless).
    fileprivate func hideAllBannersViaCGSIfMCActive() {
        if isMissionControlActive {
            hideAllBannersViaCGS()
        }
    }

    /// Called from the CGEventTap dedicated background thread. We use the
    /// thread-safe CGSSetWindowAlpha private API to drop every banner's
    /// alpha to 0 the instant a left mouse-down is observed — without ever
    /// hopping to the main thread. The follow-up dispatch syncs NSWindow's
    /// own alphaValue state on main so AppKit / SwiftUI agree with the
    /// WindowServer state. We schedule a LONG fallback restore (5 s) so the
    /// `pendingVisibilityRestore` flag stays set throughout the hold-time
    /// + zoom-in window — applyVisibility checks this flag and refuses to
    /// re-show banners while a transition is in progress. mouseUp / 1401 /
    /// close events all replace or cancel this restore as needed.
    fileprivate func handleEventTapMouseDownFromBackground() {
        // CGS IPC: thread-safe, runs RIGHT NOW from the bg thread.
        hideAllBannersViaCGS()
        // Then sync AppKit state on main.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isMissionControlActive else { return }
            for window in self.windows.values {
                window.alphaValue = 0
            }
            // Long fallback so pendingVisibilityRestore is non-nil for the
            // entire click → zoom → close window. applyVisibility uses this
            // to suppress alpha=1 restores from rebuildWindows triggered by
            // NSWorkspace.activeSpaceDidChange while zoom-in is on screen.
            self.scheduleVisibilityRestore(after: 5.0, reason: "eventTap-mouseDown fallback")
            DebugLog.log("MissionControlLabel", "eventTap mouseDown handled", details: [:])
        }
    }

    /// On mouse-up: schedule deferred restore on main. The CGS bursts that
    /// follow a thumbnail click (1401 + 1508×2) will cancel or re-schedule
    /// this restore as needed. For benign clicks that do not switch Space
    /// or close MC, this restore re-shows the banners after a longer delay.
    /// 600 ms gives the click → MC close pipeline plenty of time to fire
    /// the 1508 close burst (we have observed 294 ms gaps); restoring earlier
    /// re-shows the banners while the zoom-in is still on screen.
    fileprivate func handleEventTapMouseUpFromBackground() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isMissionControlActive else { return }
            self.scheduleVisibilityRestore(after: 0.6, reason: "eventTap-mouseUp restore")
        }
    }

    private func handleGlobalMouseDown(_ event: NSEvent) {
        guard isMissionControlActive else { return }
        // NSEvent.mouseLocation is in the unified screen coordinate system
        // (origin = bottom-left of the primary display). The MC thumbnail
        // strip sits at the TOP of EACH display — with an external display
        // attached, the cursor can be on either screen, so check the screen
        // that contains the cursor rather than assuming NSScreen.main.
        let location = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSPointInRect(location, $0.frame) })
        let inStrip: Bool
        if let screen {
            let topY = screen.frame.maxY
            inStrip = location.y >= topY - Self.mcStripHeight
        } else {
            inStrip = false
        }
        DebugLog.log("MissionControlLabel", "mouseDown while MC active", details: [
            "x": "\(Int(location.x))",
            "y": "\(Int(location.y))",
            "screen": screen?.displayUUIDString ?? "nil",
            "inStrip": "\(inStrip)"
        ])
        if inStrip {
            hideAllBannersImmediately(reason: "mouseDown-in-mc-strip x=\(Int(location.x)) y=\(Int(location.y))")
        }
    }

    fileprivate func handleCGSNotification(type: UInt32) {
        switch type {
        case 1401:
            // Active Space changed. Record the timestamp so a deferred 1508
            // evaluation can recognise "this 1508 is just a Space-change side
            // effect". Cancel any pending activation: a phantom 1508 ~1 sec
            // before this 1401 must NOT cause the banner to flash on screen
            // during the switch animation.
            //
            // Do NOT deactivate MC here. In-MC navigation (Ctrl+←/→ while
            // MC is open) fires 1401 alone — MC stays open. Click-thumbnail
            // also fires 1401 but is followed by a paired 1508 close pulse;
            // the 1508 handler is responsible for closing MC in that case.
            //
            // We unconditionally hide ALL banners while MC is active and
            // schedule a deferred restore. NSEvent.addGlobalMonitorForEvents
            // does not reliably fire for MC thumbnail clicks (WindowServer
            // captures them before global monitor delivery on Tahoe), so the
            // mouse-down hide path is unreliable. Hiding here on 1401 catches
            // both click-thumbnail (then close burst cancels the restore so
            // the hide sticks through the zoom-in) and Ctrl+arrow in-MC
            // navigation (no close burst → restore re-shows the banners
            // after a short flicker).
            lastSpaceChangeAt = Date()
            cancelPendingActivation(reason: "1401-spaceChange")
            if isMissionControlActive {
                hideAllBannersImmediately(reason: "1401-spaceChange preemptive")
                scheduleVisibilityRestore(after: 0.2, reason: "1401-spaceChange restore")
            }
        case 1508:
            // Buffer all 1508 events that arrive within
            // pulseClassificationWindow, then classify the burst by COUNT —
            // not by toggling state (which drifts). Two events in the same
            // window means MC close (paired same-ms pulse). One isolated
            // event means MC open. Forcing the resulting state, rather
            // than toggling, makes the controller self-healing if state
            // ever desyncs (e.g., MC closing while DesktopTitle was paused).
            let now = Date()
            pending1508s.append(now)
            // If a 1401 fired within the last 50 ms, this 1508 is part of a
            // click-thumbnail close pulse. Hide banners synchronously now
            // so they don't show during the destination Space's zoom-in.
            if isMissionControlActive && now.timeIntervalSince(lastSpaceChangeAt) < 0.05 {
                hideAllBannersImmediately(reason: "1508-with-recent-1401")
            }
            if pending1508EvalWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.classify1508Burst()
                }
                pending1508EvalWork = work
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + Self.pulseClassificationWindow,
                    execute: work
                )
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

    /// Synchronously force every banner to alpha=0. Used as the fast
    /// hide-path for click-thumbnail closes: the burst classifier needs
    /// 30 ms to confirm "this is a close", but the user's MC zoom-in
    /// animation starts immediately, so we must drop the banners before
    /// the zoom captures them.
    private func hideAllBannersImmediately(reason: String) {
        for window in windows.values {
            window.alphaValue = 0
        }
        DebugLog.log("MissionControlLabel", "hideAllBannersImmediately", details: [
            "reason": reason
        ])
    }

    /// Classifies the buffered 1508 burst that just expired its window.
    /// Two-or-more events in the burst means MC closed (paired pulse);
    /// a single event means MC opened. We force the resulting state
    /// directly rather than toggle so a desynced state can self-heal.
    private func classify1508Burst() {
        let events = pending1508s
        pending1508s.removeAll()
        pending1508EvalWork = nil

        let now = Date()
        let timeSinceSpaceChange = now.timeIntervalSince(lastSpaceChangeAt)
        let count = events.count

        if count >= 2 {
            // Same-ms paired 1508 → MC CLOSE. Force state inactive.
            DebugLog.log("MissionControlLabel", "1508 burst → MC close", details: [
                "count": "\(count)",
                "wasActive": "\(isMissionControlActive)"
            ])
            cancelPendingActivation(reason: "1508-close")
            cancelPendingVisibilityRestore(reason: "1508-close")
            if isMissionControlActive {
                deactivateMissionControl(reason: "1508-close")
            }
            return
        }

        // Single 1508 — MC OPEN signal, OR phantom-from-Ctrl-arrow.
        if timeSinceSpaceChange < 0.3 {
            // Phantom 1508 from a Space switch; ignore.
            DebugLog.log("MissionControlLabel", "1508 ignored (paired with 1401)", details: [
                "deltaMs": "\(Int(timeSinceSpaceChange * 1000))"
            ])
            return
        }

        // Wait briefly to see if a 1401 follows (phantom→space-switch
        // pattern). scheduleDelayedActivation already builds in the 1.5 s
        // wait that lets a subsequent 1401 cancel us.
        if isMissionControlActive {
            // Already active and a single 1508 arrived without a paired
            // partner. macOS occasionally emits a 1508 mid-MC for other
            // reasons; do not treat it as a toggle. We may have hidden
            // banners early via hideAllBannersImmediately if a 1401 was
            // recent, so re-apply visibility to restore them.
            DebugLog.log("MissionControlLabel", "1508 single while active → restore", details: [:])
            applyVisibility(reason: "1508-single restore")
        } else {
            scheduleDelayedActivation(reason: "1508-open")
        }
    }

    private func rearmSafetyTimer() {
        // Belt-and-braces deactivation in case both the close pulse and
        // any in-MC space-change events are missed for some reason. 5
        // minutes is long enough that a normal MC viewing session never
        // hits it, but short enough that a stuck-active state self-heals
        // without requiring an app restart. Earlier 60s was too short —
        // it deactivated banners while the user was still browsing MC.
        mcDeactivationTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: false) { [weak self] _ in
            self?.deactivateMissionControl(reason: "safetyTimeout")
        }
        mcDeactivationTimer = timer
    }

    private func scheduleVisibilityRestore(after delay: TimeInterval, reason: String) {
        pendingVisibilityRestore?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingVisibilityRestore = nil
            guard self.isMissionControlActive else { return }
            self.applyVisibility(reason: reason)
        }
        pendingVisibilityRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelPendingVisibilityRestore(reason: String) {
        guard pendingVisibilityRestore != nil else { return }
        pendingVisibilityRestore?.cancel()
        pendingVisibilityRestore = nil
        DebugLog.log("MissionControlLabel", "cancelled visibility restore", details: [
            "reason": reason
        ])
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
            // Raise non-active banners above same-level user windows so
            // they aren't occluded inside their MC thumbnails. Doing this
            // here (once on activation) and lowering them on deactivation
            // keeps the z-state clean — repeating the raise on every
            // applyVisibility caused MC bounce-back / multi-skip in
            // earlier iterations. Skip every display's active Space (not
            // just the primary's) so external displays' active Spaces are
            // also left alone.
            let activePerDisplay = Set(spaceIdentifier.getCurrentSpacesByDisplay().values.map(\.id))
            for (spaceID, window) in windows where !activePerDisplay.contains(spaceID) {
                window.raiseInZOrder()
            }
        }
    }

    private func deactivateMissionControl(reason: String) {
        cancelPendingActivation(reason: "deactivate")
        cancelPendingVisibilityRestore(reason: "deactivate")
        mcDeactivationTimer?.invalidate()
        mcDeactivationTimer = nil
        if isMissionControlActive {
            isMissionControlActive = false
            applyVisibility(reason: "mc deactivate (\(reason))")
            // NB: do NOT call lowerInZOrder here. CGSOrderWindow(place=0)
            // pushes the banner below desktop wallpaper level on macOS
            // Tahoe, after which the next raise on activation can leave it
            // invisible inside MC thumbnails (only the active Space banner
            // shows up because the live preview composites on top).
        }
    }

    func stop() {
        cancelPendingActivation(reason: "stop")
        cancelPendingVisibilityRestore(reason: "stop")
        pending1508EvalWork?.cancel()
        pending1508EvalWork = nil
        pending1508s.removeAll()
        mcDeactivationTimer?.invalidate()
        mcDeactivationTimer = nil

        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        cgsMonitor?.stop()
        cgsMonitor = nil

        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }

        stopEventTap()

        for window in windows.values {
            window.close()
        }
        windows.removeAll()

        DebugLog.log("MissionControlLabel", "stopped")
    }

    func hideImmediately(reason: String) {
        guard !Self.debugAlwaysVisible else { return }
        // While MC is active the banners are intentionally visible. A
        // Space change inside MC (Ctrl+←/→ in the strip) still fires the
        // app's space-change event; hiding here would make the titles
        // disappear in the MC thumbnails until the user closes MC.
        guard !isMissionControlActive else {
            DebugLog.log("MissionControlLabel", "hideImmediately skipped (MC active)", details: ["reason": reason])
            return
        }
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

        refreshBannerWindowIDsCache()
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
    ///   - Mission Control active: every NON-active Space's banner is
    ///     alpha=1 so it shows up inside that Space's thumbnail. The
    ///     active Space's banner is alpha=1 only when the user has
    ///     opted-in via showMissionControlLabelOnActiveSpace; otherwise
    ///     it stays hidden so the live preview is uncovered.
    ///   - The banner stays at NSWindow.Level.normal and we do NOT call
    ///     CGSOrderWindow to raise it. Both higher levels and CGS reorders
    ///     break per-Space pinning or cause Space-switch side effects on
    ///     macOS Tahoe (bounce-back, multi-skip on Ctrl+arrow). The
    ///     trade-off: user app windows on the same Space CAN occlude the
    ///     banner inside that Space's MC thumbnail.
    private func applyVisibility(reason: String) {
        // Each display has its own "active" Space. With an external display
        // attached, getActiveSpaceID() only reports ONE Space (the focused
        // display's), so the external display's active Space would still get
        // target=1 and the giant banner would show on it during MC. Use the
        // per-display map instead so every display's active Space is treated
        // as the local "do not show banner" Space.
        let activePerDisplay = Set(spaceIdentifier.getCurrentSpacesByDisplay().values.map(\.id))
        let showOnActive = settings.showMissionControlLabelOnActiveSpace
        // While a visibility restore is pending we are in a click → zoom →
        // close transition. applyVisibility called here from rebuildWindows
        // (triggered by NSWorkspace.activeSpaceDidChangeNotification) would
        // otherwise reset non-active banners back to alpha=1 mid-zoom-in,
        // which is exactly the giant banner the user sees during zoom.
        // Suppress here; the pending restore will fire applyVisibility again
        // (with pendingVisibilityRestore == nil) once the transition is over.
        let inTransition = (pendingVisibilityRestore != nil)

        for (spaceID, window) in windows {
            let target: CGFloat
            if Self.debugAlwaysVisible {
                target = 1
            } else if !isMissionControlActive {
                target = 0
            } else if inTransition {
                target = 0
            } else if activePerDisplay.contains(spaceID) {
                target = showOnActive ? 1 : 0
            } else {
                target = 1
            }
            window.alphaValue = target
        }

        DebugLog.log("MissionControlLabel", "applied visibility", details: [
            "reason": reason,
            "isMissionControlActive": "\(isMissionControlActive)",
            "inTransition": "\(inTransition)",
            "activePerDisplay": activePerDisplay.sorted().map(String.init).joined(separator: ","),
            "showOnActive": "\(showOnActive)",
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
    // For 1401 (active Space changed) — and 1508 (MC toggle, including the
    // close burst that follows a thumbnail click) — synchronously hide all
    // banners via direct WindowServer IPC (CGSSetWindowAlpha). NSWindow's
    // alphaValue setter requires the main thread, but CGSSetWindowAlpha is
    // a Mach IPC that's safe from the CGS callback thread. This eliminates
    // the ~30–80 ms DispatchQueue.main.async hop that lets the MC zoom-in
    // animation capture alpha=1 banners — by the time the main handler
    // gets to run, the WindowServer already shows alpha=0.
    if type == 1401 || type == 1508 {
        MissionControlLabelController.shared?.hideAllBannersViaCGSIfMCActive()
        // Force-enable the CGEventTap on every MC-related CGS event. macOS
        // Tahoe silently disables listenOnly taps during idle, and our
        // 500 ms health-check timer can miss the very first click after
        // MC opens (the user-reported "1回目だけバナーが見える" pattern).
        // Re-enabling here guarantees the tap is hot at MC open time so
        // the upcoming thumbnail click fires our mouse-down handler.
        if let tap = MissionControlLabelController.shared?.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
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

    /// Raises this banner above same-level user windows on its pinned
    /// Space without changing NSWindow.level. The CGS reorder does NOT
    /// switch Spaces.
    func raiseInZOrder() {
        guard windowNumber > 0 else { return }
        let connection = CGSMainConnectionID()
        // place=1 (kCGSOrderAbove), relative=0 → above the entire stack.
        _ = CGSOrderWindow(connection, Int32(windowNumber), 1, 0)
    }

    /// Lowers this banner so subsequent raise side effects do not linger
    /// once MC closes (see deactivateMissionControl cleanup).
    func lowerInZOrder() {
        guard windowNumber > 0 else { return }
        let connection = CGSMainConnectionID()
        // place=0 (kCGSOrderBelow), relative=0 → below the entire stack.
        _ = CGSOrderWindow(connection, Int32(windowNumber), 0, 0)
    }

    private func pinToAssignedSpace() {
        guard windowNumber > 0 else { return }

        let connection = CGSMainConnectionID()
        let windowIDs = [NSNumber(value: Int32(windowNumber))] as CFArray

        // Fast path: skip CGS pin operations entirely if the window is
        // already pinned exclusively to its target Space. Re-running
        // CGSAddWindowsToSpaces / CGSRemoveWindowsFromSpaces on every
        // settings tick can drag the user's active Space when the bursts
        // are large (e.g. dragging a color slider in Settings).
        if let currentSpaces = CGSCopySpacesForWindows(connection, kCGSAllSpacesMask, windowIDs) {
            let currentIDs = (currentSpaces as NSArray).compactMap { ($0 as? NSNumber)?.uint64Value }
            if currentIDs == [pinnedSpaceID] {
                return
            }
        }

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
