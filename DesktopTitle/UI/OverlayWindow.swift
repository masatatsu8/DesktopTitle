//
//  OverlayWindow.swift
//  DesktopTitle
//
//  A transparent overlay window for displaying Space names
//

import AppKit
import SwiftUI

// MARK: - NSScreen Extension

extension NSScreen {
    /// Get the display UUID string for matching with CGSPrivate display identifiers
    var displayUUIDString: String? {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(screenNumber)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}

/// A borderless, transparent window that displays above all other windows
final class OverlayWindow: NSWindow {

    init() {
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

        // Display above everything including fullscreen apps
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        // Ignore mouse events (click-through)
        ignoresMouseEvents = true

        // Don't show in Mission Control or other system UIs
        isExcludedFromWindowsMenu = true
    }

    /// Update window frame to match the provided screen (or main screen)
    func updateFrame(for screen: NSScreen?) {
        guard let targetScreen = screen ?? NSScreen.main else { return }
        setFrame(targetScreen.frame, display: true)
    }

    /// Display the overlay with the given content
    func show<Content: View>(content: Content, on screen: NSScreen? = nil) {
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]

        contentView?.subviews.forEach { $0.removeFromSuperview() }
        contentView?.addSubview(hostingView)

        updateFrame(for: screen)
        orderFront(nil)
    }

    /// Hide the overlay
    func hide() {
        orderOut(nil)
    }
}
