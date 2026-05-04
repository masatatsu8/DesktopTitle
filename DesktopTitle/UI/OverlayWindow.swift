//
//  OverlayWindow.swift
//  DesktopTitle
//
//  A transparent overlay window for displaying Space names
//

import AppKit
import SwiftUI

/// A borderless, transparent window that displays above all other windows
final class OverlayWindow: NSWindow, NSWindowDelegate {
    private let displayID: String

    init(displayID: String) {
        self.displayID = displayID

        // Create window that covers the main screen
        let screenRect = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 800, height: 600)

        super.init(
            contentRect: screenRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        configureWindow()
    }

    private func configureWindow() {
        // Make window transparent
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        delegate = self

        // Display above normal app windows and fullscreen content.
        // No .canJoinAllSpaces or .moveToActiveSpace: window is created fresh
        // on the current space each time, then destroyed after animation.
        level = .screenSaver
        collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary]

        // Ignore mouse events (click-through)
        ignoresMouseEvents = true

        // Don't show in Mission Control or other system UIs
        isExcludedFromWindowsMenu = true

        // Prevent this window from ever becoming key or main
        // This is critical to prevent focus stealing
        // Windows are created fresh each time and released via ARC after close
        isReleasedWhenClosed = false

        DebugLog.log(
            "OverlayWindow",
            "configured overlay window",
            details: [
                "display": DebugLog.shortDisplayID(displayID),
                "window": DebugLog.describe(window: self)
            ]
        )
    }

    // Prevent overlay from becoming key window (stealing focus)
    override var canBecomeKey: Bool { false }

    // Prevent overlay from becoming main window
    override var canBecomeMain: Bool { false }

    /// Update window frame to match the provided screen (or main screen)
    func updateFrame(for screen: NSScreen?) {
        guard let targetScreen = screen ?? NSScreen.main else {
            DebugLog.log(
                "OverlayWindow",
                "failed to update frame because no target screen was available",
                details: [
                    "display": DebugLog.shortDisplayID(displayID)
                ]
            )
            return
        }

        let oldFrame = frame
        setFrame(targetScreen.frame, display: true)
        DebugLog.log(
            "OverlayWindow",
            "updated overlay frame",
            details: [
                "display": DebugLog.shortDisplayID(displayID),
                "oldFrame": DebugLog.describe(rect: oldFrame),
                "newFrame": DebugLog.describe(rect: frame),
                "screen": DebugLog.describe(screen: targetScreen)
            ]
        )
    }

    /// Display the overlay with the given content
    func show<Content: View>(content: Content, on screen: NSScreen? = nil) {
        // Ensure we're on main thread
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.show(content: content, on: screen)
            }
            return
        }

        DebugLog.log(
            "OverlayWindow",
            "show requested",
            details: [
                "display": DebugLog.shortDisplayID(displayID),
                "targetScreen": DebugLog.describe(screen: screen),
                "windowBeforeShow": DebugLog.describe(window: self),
                "contentViewExists": "\(contentView != nil)"
            ]
        )

        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]

        let previousSubviewCount = contentView?.subviews.count ?? 0
        contentView?.subviews.forEach { $0.removeFromSuperview() }
        contentView?.addSubview(hostingView)

        updateFrame(for: screen)
        orderFrontRegardless()  // Use orderFrontRegardless to ensure visibility
        DebugLog.log(
            "OverlayWindow",
            "orderFrontRegardless called",
            details: [
                "display": DebugLog.shortDisplayID(displayID),
                "removedSubviews": "\(previousSubviewCount)",
                "windowAfterShow": DebugLog.describe(window: self)
            ]
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            DebugLog.log(
                "OverlayWindow",
                "post-show run loop state",
                details: [
                    "display": DebugLog.shortDisplayID(self.displayID),
                    "window": DebugLog.describe(window: self)
                ]
            )
        }
    }

    /// Hide the overlay
    func hide(reason: String = "unspecified") {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.hide(reason: reason)
            }
            return
        }

        DebugLog.log(
            "OverlayWindow",
            "hide requested",
            details: [
                "display": DebugLog.shortDisplayID(displayID),
                "reason": reason,
                "windowBeforeHide": DebugLog.describe(window: self)
            ]
        )
        contentView?.subviews.forEach { $0.removeFromSuperview() }
        orderOut(nil)
        DebugLog.log(
            "OverlayWindow",
            "orderOut completed",
            details: [
                "display": DebugLog.shortDisplayID(displayID),
                "windowAfterHide": DebugLog.describe(window: self)
            ]
        )
    }

    func windowDidChangeScreen(_ notification: Notification) {
        DebugLog.log(
            "OverlayWindow",
            "window changed screen",
            details: [
                "display": DebugLog.shortDisplayID(displayID),
                "window": DebugLog.describe(window: self)
            ]
        )
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        DebugLog.log(
            "OverlayWindow",
            "window occlusion state changed",
            details: [
                "display": DebugLog.shortDisplayID(displayID),
                "window": DebugLog.describe(window: self)
            ]
        )
    }
}
