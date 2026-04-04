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

    /// Whether this screen is the built-in display (e.g. MacBook Pro's internal screen).
    var isBuiltIn: Bool {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return false
        }
        return CGDisplayIsBuiltin(screenNumber) != 0
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
    let isBuiltIn: Bool

    init(id: String, name: String, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
    }
}

struct DisplayConfiguration: Codable, Equatable, Identifiable {
    let id: String
    let displays: [DisplayScreenInfo]

    var orderedDisplayIDs: [String] {
        displays.map(\.id)
    }

    var isMultiDisplay: Bool {
        displays.count > 1
    }

    /// The UUID of the built-in display, if present.
    var builtInDisplayID: String? {
        displays.first(where: \.isBuiltIn)?.id
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
            return DisplayScreenInfo(id: id, name: screen.localizedName, isBuiltIn: screen.isBuiltIn)
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
        DebugLog.log(
            "DisplayConfiguration",
            "started monitoring display configuration",
            details: [
                "currentConfigurationID": currentConfiguration.id,
                "summary": currentConfiguration.summary
            ]
        )
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

        DebugLog.log("DisplayConfiguration", "stopped monitoring display configuration")
    }

    func refreshCurrentConfiguration() {
        let configuration = DisplayConfiguration.current()
        guard configuration != currentConfiguration else {
            DebugLog.log(
                "DisplayConfiguration",
                "display configuration refresh produced no change",
                details: [
                    "configurationID": configuration.id,
                    "summary": configuration.summary
                ]
            )
            return
        }

        let previousConfiguration = currentConfiguration
        currentConfiguration = configuration
        DebugLog.log(
            "DisplayConfiguration",
            "active display configuration changed",
            details: [
                "previousID": previousConfiguration.id,
                "previousSummary": previousConfiguration.summary,
                "currentID": configuration.id,
                "currentSummary": configuration.summary
            ]
        )
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
