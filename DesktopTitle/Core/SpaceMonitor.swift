//
//  SpaceMonitor.swift
//  DesktopTitle
//
//  Monitors desktop Space changes using NSWorkspace notifications
//

import Foundation
import AppKit
import Combine

/// Monitors Space switching events and publishes the current space info
final class SpaceMonitor: ObservableObject {

    static let shared = SpaceMonitor()

    /// Published current space information
    @Published private(set) var currentSpace: SpaceInfo?

    /// Published space change event (triggers overlay display)
    @Published var spaceChangedAt: Date?

    private let spaceIdentifier = SpaceIdentifier.shared
    private var isMonitoring = false

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

        print("[SpaceMonitor] Started monitoring space changes")
    }

    /// Stop monitoring Space changes
    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false

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

        print("[SpaceMonitor] Stopped monitoring space changes")
    }

    /// Force update current space info
    func updateCurrentSpace() {
        let newSpace = spaceIdentifier.getCurrentSpaceInfo()
        if Thread.isMainThread {
            currentSpace = newSpace
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.currentSpace = newSpace
            }
        }
    }

    // MARK: - Notification Handlers

    @objc private func spaceDidChange(_ notification: Notification) {
        let newSpace = spaceIdentifier.getCurrentSpaceInfo()
        let publishChange = { [weak self] in
            guard let self = self else { return }
            let previousSpace = self.currentSpace
            self.currentSpace = newSpace

            // Only trigger overlay if space actually changed
            if newSpace?.id != previousSpace?.id {
                self.spaceChangedAt = Date()

                if let space = newSpace {
                    print("[SpaceMonitor] Space changed to: \(space.index) (ID: \(space.id))")
                }
            }
        }

        if Thread.isMainThread {
            publishChange()
        } else {
            DispatchQueue.main.async(execute: publishChange)
        }
    }

    @objc private func appDidBecomeActive(_ notification: Notification) {
        // Refresh space info when app becomes active
        updateCurrentSpace()
    }

    deinit {
        stopMonitoring()
    }
}
