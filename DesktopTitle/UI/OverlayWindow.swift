//
//  OverlayWindow.swift
//  DesktopTitle
//
//  A transparent overlay window for displaying Space names
//

import AppKit
import SwiftUI

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

        // Display above normal app windows and fullscreen content.
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        // Ignore mouse events (click-through)
        ignoresMouseEvents = true

        // Don't show in Mission Control or other system UIs
        isExcludedFromWindowsMenu = true

        // Prevent this window from ever becoming key or main
        // This is critical to prevent focus stealing
        isReleasedWhenClosed = false
    }

    // Prevent overlay from becoming key window (stealing focus)
    override var canBecomeKey: Bool { false }

    // Prevent overlay from becoming main window
    override var canBecomeMain: Bool { false }

    /// Update window frame to match the provided screen (or main screen)
    func updateFrame(for screen: NSScreen?) {
        guard let targetScreen = screen ?? NSScreen.main else { return }
        setFrame(targetScreen.frame, display: true)
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

        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]

        contentView?.subviews.forEach { $0.removeFromSuperview() }
        contentView?.addSubview(hostingView)

        updateFrame(for: screen)
        orderFrontRegardless()  // Use orderFrontRegardless to ensure visibility
        print("[OverlayWindow] Shown on screen: \(screen?.localizedName ?? "main")")
    }

    /// Hide the overlay
    func hide() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.hide()
            }
            return
        }
        orderOut(nil)
        print("[OverlayWindow] Hidden")
    }
}
