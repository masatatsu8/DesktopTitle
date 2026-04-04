//
//  SpaceMonitor.swift
//  DesktopTitle
//
//  Monitors desktop Space changes using NSWorkspace notifications
//

import Foundation
import AppKit
import Combine

struct SpaceChangeEvent {
    let changedSpaces: [SpaceInfo]
    let allCurrentSpaces: [String: SpaceInfo]
    let occurredAt: Date
    let trigger: String
}

/// Monitors Space switching events and publishes the current space info
final class SpaceMonitor: ObservableObject {

    static let shared = SpaceMonitor()

    /// Published current space information
    @Published private(set) var currentSpace: SpaceInfo?

    /// Published current space information for all displays.
    @Published private(set) var currentSpacesByDisplay: [String: SpaceInfo] = [:]

    /// Published space change event (triggers overlay display)
    @Published var spaceChangeEvent: SpaceChangeEvent?

    private let spaceIdentifier = SpaceIdentifier.shared
    private var isMonitoring = false
    private var pendingResolveWorkItem: DispatchWorkItem?
    private var resolutionSequence = 0

    private let resolutionDelay: TimeInterval = 0.08
    private let maxResolutionAttempts = 5

    private init() {
        // Initialize with current space
        updateCurrentSpace()
    }

    /// Start monitoring Space changes
    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(spaceDidChange(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        // Also monitor when app becomes active (helps with menu bar apps)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

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

        DebugLog.log("SpaceMonitor", "started monitoring space changes")
    }

    /// Stop monitoring Space changes
    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        pendingResolveWorkItem?.cancel()
        pendingResolveWorkItem = nil

        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

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

        DebugLog.log("SpaceMonitor", "stopped monitoring space changes")
    }

    /// Force update current space info
    func updateCurrentSpace() {
        let newSpaces = spaceIdentifier.getCurrentSpacesByDisplay()
        guard !newSpaces.isEmpty else {
            DebugLog.log("SpaceMonitor", "updateCurrentSpace failed to resolve any spaces")
            return
        }

        DebugLog.log(
            "SpaceMonitor",
            "updateCurrentSpace resolved spaces",
            details: [
                "spaces": DebugLog.describe(spacesByDisplay: newSpaces)
            ]
        )

        if Thread.isMainThread {
            applyResolvedSpaces(newSpaces, trigger: nil)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.applyResolvedSpaces(newSpaces, trigger: nil)
            }
        }
    }

    // MARK: - Notification Handlers

    @objc private func spaceDidChange(_ notification: Notification) {
        requestResolution(trigger: "spaceDidChange")
    }

    @objc private func appDidBecomeActive(_ notification: Notification) {
        // Refresh space info when app becomes active
        requestResolution(trigger: "appDidBecomeActive")
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        requestResolution(trigger: "didChangeScreenParameters")
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        requestResolution(trigger: "workspaceDidWake")
    }

    // MARK: - Internal

    private func requestResolution(trigger: String) {
        if pendingResolveWorkItem != nil {
            DebugLog.log(
                "SpaceMonitor",
                "cancelling pending resolution before starting a new one",
                details: [
                    "trigger": trigger
                ]
            )
        }

        pendingResolveWorkItem?.cancel()
        pendingResolveWorkItem = nil
        resolutionSequence += 1

        DebugLog.log(
            "SpaceMonitor",
            "resolution requested",
            details: [
                "trigger": trigger,
                "sequence": "\(resolutionSequence)"
            ]
        )

        resolveCurrentSpaceWithRetry(attempt: 0, trigger: trigger, sequence: resolutionSequence)
    }

    private func resolveCurrentSpaceWithRetry(attempt: Int, trigger: String, sequence: Int) {
        DebugLog.log(
            "SpaceMonitor",
            "attempting to resolve current spaces",
            details: [
                "trigger": trigger,
                "sequence": "\(sequence)",
                "attempt": "\(attempt)"
            ]
        )

        let newSpaces = spaceIdentifier.getCurrentSpacesByDisplay()
        guard !newSpaces.isEmpty else {
            if attempt < maxResolutionAttempts {
                let workItem = DispatchWorkItem { [weak self] in
                    self?.resolveCurrentSpaceWithRetry(attempt: attempt + 1, trigger: trigger, sequence: sequence)
                }
                pendingResolveWorkItem = workItem
                DebugLog.log(
                    "SpaceMonitor",
                    "space resolution returned no spaces; scheduling retry",
                    details: [
                        "trigger": trigger,
                        "sequence": "\(sequence)",
                        "attempt": "\(attempt)",
                        "nextAttempt": "\(attempt + 1)",
                        "delaySeconds": String(format: "%.3f", resolutionDelay)
                    ]
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + resolutionDelay, execute: workItem)
            } else {
                // Keep previous state instead of publishing nil
                DebugLog.log(
                    "SpaceMonitor",
                    "failed to resolve current spaces after retries; keeping previous state",
                    details: [
                        "trigger": trigger,
                        "sequence": "\(sequence)",
                        "attempt": "\(attempt)"
                    ]
                )
            }
            return
        }

        pendingResolveWorkItem?.cancel()
        pendingResolveWorkItem = nil

        DebugLog.log(
            "SpaceMonitor",
            "resolved current spaces",
            details: [
                "trigger": trigger,
                "sequence": "\(sequence)",
                "attempt": "\(attempt)",
                "spaces": DebugLog.describe(spacesByDisplay: newSpaces)
            ]
        )

        if Thread.isMainThread {
            applyResolvedSpaces(newSpaces, trigger: trigger)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.applyResolvedSpaces(newSpaces, trigger: trigger)
            }
        }
    }

    private func applyResolvedSpaces(_ newSpaces: [String: SpaceInfo], trigger: String?) {
        let previousSpaces = currentSpacesByDisplay
        currentSpacesByDisplay = newSpaces

        let changedSpaces = orderedSpaces(
            newSpaces.values.filter { previousSpaces[$0.displayID]?.id != $0.id }
        )

        if changedSpaces.isEmpty {
            if let previousCurrentSpace = currentSpace,
               let refreshedCurrentSpace = newSpaces[previousCurrentSpace.displayID] {
                currentSpace = refreshedCurrentSpace
            } else {
                currentSpace = preferredSpace(from: Array(newSpaces.values))
            }
        } else {
            // Keep the menu-bar summary anchored to the preferred display while overlays
            // continue to use the display-specific changedSpaces list.
            currentSpace = preferredSpace(from: Array(newSpaces.values))
        }

        DebugLog.log(
            "SpaceMonitor",
            "applied resolved spaces",
            details: [
                "trigger": trigger,
                "previousSpaces": DebugLog.describe(spacesByDisplay: previousSpaces),
                "newSpaces": DebugLog.describe(spacesByDisplay: newSpaces),
                "changedSpaces": DebugLog.describe(spaces: changedSpaces),
                "currentSpace": DebugLog.describe(space: currentSpace)
            ]
        )

        guard let trigger, !changedSpaces.isEmpty else { return }

        let event = SpaceChangeEvent(
            changedSpaces: changedSpaces,
            allCurrentSpaces: newSpaces,
            occurredAt: Date(),
            trigger: trigger
        )
        spaceChangeEvent = event
    }

    private func preferredSpace(from spaces: [SpaceInfo]) -> SpaceInfo? {
        let orderedDisplayIDs = DisplayConfiguration.current().orderedDisplayIDs

        for displayID in orderedDisplayIDs {
            if let space = spaces.first(where: { $0.displayID == displayID }) {
                return space
            }
        }

        return spaces.first
    }

    private func orderedSpaces(_ spaces: [SpaceInfo]) -> [SpaceInfo] {
        let orderedDisplayIDs = DisplayConfiguration.current().orderedDisplayIDs
        return spaces.sorted { lhs, rhs in
            let lhsIndex = orderedDisplayIDs.firstIndex(of: lhs.displayID) ?? .max
            let rhsIndex = orderedDisplayIDs.firstIndex(of: rhs.displayID) ?? .max
            if lhsIndex == rhsIndex {
                return lhs.index < rhs.index
            }
            return lhsIndex < rhsIndex
        }
    }

    deinit {
        stopMonitoring()
    }
}
