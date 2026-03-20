//
//  DisplayConfiguration.swift
//  DesktopTitle
//
//  Tracks the current display topology and exposes a stable profile identifier
//

import AppKit
import Foundation

extension NSScreen {
    /// Get the display UUID string for matching with CoreGraphics display identifiers.
    var displayUUIDString: String? {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        return Self.displayUUIDString(for: screenNumber)
    }

    static func displayUUIDString(for displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}

struct DisplayScreenInfo: Codable, Equatable, Identifiable {
    let id: String
    let name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

struct DisplayConfiguration: Codable, Equatable, Identifiable {
    let id: String
    let displays: [DisplayScreenInfo]

    var orderedDisplayIDs: [String] {
        displays.map(\.id)
    }

    var summary: String {
        if displays.isEmpty {
            return "No Displays"
        }
        return displays.map(\.name).joined(separator: " + ")
    }

    static func current() -> DisplayConfiguration {
        let screens = NSScreen.screens.compactMap { screen -> DisplayScreenInfo? in
            guard let id = screen.displayUUIDString else { return nil }
            return DisplayScreenInfo(id: id, name: screen.localizedName)
        }

        let profileKey = screens
            .map(\.id)
            .sorted()
            .joined(separator: "|")

        return DisplayConfiguration(
            id: profileKey.isEmpty ? "no-displays" : profileKey,
            displays: screens
        )
    }
}

final class DisplayConfigurationMonitor: ObservableObject {
    static let shared = DisplayConfigurationMonitor()

    @Published private(set) var currentConfiguration: DisplayConfiguration

    private var isMonitoring = false

    private init() {
        currentConfiguration = DisplayConfiguration.current()
    }

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake(_:)),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )

        refreshCurrentConfiguration()
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false

        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
    }

    func refreshCurrentConfiguration() {
        let configuration = DisplayConfiguration.current()
        guard configuration != currentConfiguration else { return }
        currentConfiguration = configuration
        print("[DisplayConfigurationMonitor] Active configuration: \(configuration.summary)")
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        refreshCurrentConfiguration()
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        refreshCurrentConfiguration()
    }

    deinit {
        stopMonitoring()
    }
}
