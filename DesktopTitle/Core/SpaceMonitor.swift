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

        print("[SpaceMonitor] Started monitoring space changes")
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

        print("[SpaceMonitor] Stopped monitoring space changes")
    }

    /// Force update current space info
    func updateCurrentSpace() {
        let newSpaces = spaceIdentifier.getCurrentSpacesByDisplay()
        guard !newSpaces.isEmpty else {
            print("[SpaceMonitor] updateCurrentSpace: failed to resolve current spaces")
            return
        }

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
        pendingResolveWorkItem?.cancel()
        pendingResolveWorkItem = nil
        resolveCurrentSpaceWithRetry(attempt: 0, trigger: "spaceDidChange")
    }

    @objc private func appDidBecomeActive(_ notification: Notification) {
        // Refresh space info when app becomes active
        pendingResolveWorkItem?.cancel()
        pendingResolveWorkItem = nil
        resolveCurrentSpaceWithRetry(attempt: 0, trigger: "appDidBecomeActive")
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        pendingResolveWorkItem?.cancel()
        pendingResolveWorkItem = nil
        resolveCurrentSpaceWithRetry(attempt: 0, trigger: "didChangeScreenParameters")
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        pendingResolveWorkItem?.cancel()
        pendingResolveWorkItem = nil
        resolveCurrentSpaceWithRetry(attempt: 0, trigger: "workspaceDidWake")
    }

    // MARK: - Internal

    private func resolveCurrentSpaceWithRetry(attempt: Int, trigger: String) {
        let newSpaces = spaceIdentifier.getCurrentSpacesByDisplay()
        guard !newSpaces.isEmpty else {
            if attempt < maxResolutionAttempts {
                let workItem = DispatchWorkItem { [weak self] in
                    self?.resolveCurrentSpaceWithRetry(attempt: attempt + 1, trigger: trigger)
                }
                pendingResolveWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + resolutionDelay, execute: workItem)
            } else {
                // Keep previous state instead of publishing nil
                print("[SpaceMonitor] Failed to resolve current space after \(trigger); keeping previous state")
            }
            return
        }

        pendingResolveWorkItem?.cancel()
        pendingResolveWorkItem = nil

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

        guard let trigger, !changedSpaces.isEmpty else { return }

        let event = SpaceChangeEvent(
            changedSpaces: changedSpaces,
            allCurrentSpaces: newSpaces,
            occurredAt: Date(),
            trigger: trigger
        )
        spaceChangeEvent = event

        let summary = changedSpaces
            .map { "\($0.index)@\($0.displayID.prefix(6))" }
            .joined(separator: ", ")
        print("[SpaceMonitor] Spaces changed after \(trigger): \(summary)")
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
