//
//  MenuBarController.swift
//  DesktopTitle
//
//  Manages the menu bar status item
//

import AppKit
import SwiftUI

/// Controls the menu bar icon and menu
final class MenuBarController {

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    init() {
        setupStatusItem()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "DesktopTitle")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.font = .menuBarFont(ofSize: 0)
            button.toolTip = "DesktopTitle"
        }

        setupMenu()
    }

    private func setupMenu() {
        let menu = NSMenu()

        // Current space info
        let currentSpaceItem = NSMenuItem(title: "Current: Desktop 1", action: nil, keyEquivalent: "")
        currentSpaceItem.isEnabled = false
        currentSpaceItem.tag = 100  // Tag for updating
        menu.addItem(currentSpaceItem)

        menu.addItem(NSMenuItem.separator())

        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit DesktopTitle", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    /// Update the current space display in the menu
    func updateCurrentSpace(_ spaceInfo: SpaceInfo?) {
        guard let menu = statusItem?.menu,
              let currentItem = menu.item(withTag: 100) else {
            return
        }

        if let space = spaceInfo {
            let name = SpaceConfigManager.shared.getDisplayName(for: space)
            currentItem.title = "Current: \(name)"
            updateStatusButtonTitle(name)
        } else {
            currentItem.title = "Current: Unknown"
            updateStatusButtonTitle(nil)
        }
    }

    private func updateStatusButtonTitle(_ title: String?) {
        guard let button = statusItem?.button else { return }

        if AppSettings.shared.showMenuBarTitle, let title, !title.isEmpty {
            button.title = " \(title)"
            button.toolTip = "DesktopTitle: \(title)"
        } else {
            button.title = ""
            button.toolTip = "DesktopTitle"
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let settingsView = SettingsView()
            let hostingController = NSHostingController(rootView: settingsView)

            // Use an NSPanel with .nonactivatingPanel so opening / closing
            // Settings does not toggle the app's activation state. As an
            // LSUIElement menu-bar app, NSApp.activate followed by close
            // forces macOS to pick a new "active" app, and that app's
            // window can live on a different Space — causing the user's
            // visible Space to jump when Settings closes.
            let panel = NSPanel(contentViewController: hostingController)
            panel.title = "DesktopTitle Settings"
            panel.styleMask = [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel]
            panel.setContentSize(NSSize(width: 480, height: 500))
            panel.minSize = NSSize(width: 400, height: 350)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isFloatingPanel = false
            panel.becomesKeyOnlyIfNeeded = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.center()

            settingsWindow = panel
        }

        // Bring the panel to front and make it key for text input. We
        // intentionally do NOT call NSApp.activate(ignoringOtherApps:);
        // .nonactivatingPanel + makeKeyAndOrderFront is enough to take
        // keyboard input without activating the whole app.
        settingsWindow?.makeKeyAndOrderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.settingsWindow?.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
