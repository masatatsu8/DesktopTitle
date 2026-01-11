//
//  DesktopImageCache.swift
//  DesktopTitle
//
//  Caches screenshots of each desktop for display in settings
//

import AppKit
import Combine
import CoreGraphics
import ScreenCaptureKit

final class DesktopImageCache: ObservableObject {

    static let shared = DesktopImageCache()

    @Published private(set) var images: [UInt64: NSImage] = [:]
    @Published private(set) var hasPermission: Bool = false

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Check permission on init
        checkPermission()

        // Subscribe to space changes to capture screenshots
        SpaceMonitor.shared.$currentSpace
            .compactMap { $0 }
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] space in
                self?.captureCurrentDesktop(for: space)
            }
            .store(in: &cancellables)
    }

    /// Check screen recording permission
    func checkPermission() {
        print("[DesktopImageCache] Checking permission...")
        let preflight = CGPreflightScreenCaptureAccess()
        Task {
            await MainActor.run {
                self.hasPermission = preflight
                print("[DesktopImageCache] Preflight permission: \(preflight)")
            }

            guard preflight else {
                print("[DesktopImageCache] Screen recording permission not granted (preflight)")
                return
            }

            do {
                // Touch ScreenCaptureKit to verify access and warm the service.
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                print("[DesktopImageCache] Permission granted. Displays: \(content.displays.count)")
                await MainActor.run {
                    self.hasPermission = true
                }
                captureNow()
            } catch {
                print("[DesktopImageCache] Shareable content fetch failed despite preflight: \(error)")
            }
        }
    }

    /// Capture screenshot of current desktop and cache it
    func captureCurrentDesktop(for space: SpaceInfo) {
        print("[DesktopImageCache] captureCurrentDesktop called for space \(space.index), hasPermission: \(hasPermission)")
        guard hasPermission else {
            print("[DesktopImageCache] No permission to capture screen")
            return
        }

        Task {
            print("[DesktopImageCache] Starting capture...")
            guard let screenshot = await captureScreen() else {
                print("[DesktopImageCache] captureScreen returned nil")
                return
            }
            await MainActor.run {
                self.images[space.id] = screenshot
                print("[DesktopImageCache] Captured image for space \(space.index), total cached: \(self.images.count)")
            }
        }
    }

    /// Get cached image for a space
    func getImage(for spaceID: UInt64) -> NSImage? {
        return images[spaceID]
    }

    /// Capture the current screen using ScreenCaptureKit
    private func captureScreen() async -> NSImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            guard let display = content.displays.first else {
                print("[DesktopImageCache] No display found")
                return nil
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            config.showsCursor = false

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )

            let size = NSSize(width: CGFloat(image.width), height: CGFloat(image.height))
            return NSImage(cgImage: image, size: size)

        } catch {
            print("[DesktopImageCache] Failed to capture screen: \(error)")
            return nil
        }
    }

    /// Force capture current desktop
    func captureNow() {
        guard let space = SpaceMonitor.shared.currentSpace else { return }
        captureCurrentDesktop(for: space)
    }

    /// Clear all cached images
    func clearAllImages() {
        images.removeAll()
        print("[DesktopImageCache] All images cleared")
    }

    /// Request permission - opens System Settings
    func requestPermission() {
        print("[DesktopImageCache] Requesting screen recording permission...")

        // First try to request permission (this adds the app to the list)
        let granted = CGRequestScreenCaptureAccess()
        print("[DesktopImageCache] CGRequestScreenCaptureAccess result: \(granted)")

        if granted {
            hasPermission = true
            captureNow()
            return
        }

        // Open System Settings > Privacy & Security > Screen Recording
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Get the app's bundle path for reference
    static var appPath: String {
        Bundle.main.bundlePath
    }
}
