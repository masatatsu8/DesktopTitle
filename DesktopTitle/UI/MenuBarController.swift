//
//  MenuBarController.swift
//  DesktopTitle
//
//  Manages the menu bar status item
//

import AppKit
import Combine
import SwiftUI

/// Controls the menu bar icon and menu
final class MenuBarController {

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    /// Last resolved Space name applied to the status button. Held so the
    /// `showMenuBarTitle` toggle can re-render the button immediately,
    /// without waiting for the next Space change.
    private var currentSpaceName: String?

    init() {
        setupStatusItem()
        observeSettingsChanges()
    }

    private func observeSettingsChanges() {
        AppSettings.shared.$showMenuBarTitle
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyStatusButtonTitle()
            }
            .store(in: &cancellables)
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
            currentSpaceName = name
            currentItem.title = "Current: \(name)"
        } else {
            currentSpaceName = nil
            currentItem.title = "Current: Unknown"
        }
        applyStatusButtonTitle()
    }

    /// Render the status button title from the cached `currentSpaceName`
    /// according to the current `showMenuBarTitle` setting. Called on
    /// Space changes and on toggle changes.
    private func applyStatusButtonTitle() {
        guard let button = statusItem?.button else { return }

        if AppSettings.shared.showMenuBarTitle, let title = currentSpaceName, !title.isEmpty {
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

            let window = NSWindow(contentViewController: hostingController)
            window.title = "DesktopTitle Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 480, height: 500))
            window.minSize = NSSize(width: 400, height: 350)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.center()

            settingsWindow = window
        }

        // Ensure app is activated first, then make window key
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)

        // Force the window to become key after a short delay (workaround for menu bar apps)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.settingsWindow?.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
