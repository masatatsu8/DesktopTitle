//
//  DebugLog.swift
//  DesktopTitle
//
//  Structured debug logging for overlay and Space diagnostics
//

import AppKit
import Foundation
import SwiftUI

enum DebugLog {
    private static let queue = DispatchQueue(label: "DesktopTitle.DebugLog")
    private static let maxLogFileSizeBytes: UInt64 = 2 * 1024 * 1024
    private static let rotatedLogFileName = "debug.log.1"
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    private static let logFileURL: URL = {
        let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DesktopTitle", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: logsDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let logFileURL = logsDirectory.appendingPathComponent("debug.log")
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        return logFileURL
    }()

    private static let rotatedLogFileURL = logFileURL.deletingLastPathComponent().appendingPathComponent(rotatedLogFileName)

    static var diskLoggingEnabled: Bool {
        #if DEBUG
        true
        #else
        UserDefaults.standard.bool(forKey: "debugLoggingEnabled")
        #endif
    }

    static var filePath: String {
        logFileURL.path
    }

    static func beginSession() {
        log(
            "App",
            "debug session started",
            details: [
                "diskLoggingEnabled": "\(diskLoggingEnabled)",
                "logFile": diskLoggingEnabled ? filePath : "disabled",
                "pid": "\(ProcessInfo.processInfo.processIdentifier)",
                "appKitVersion": ProcessInfo.processInfo.operatingSystemVersionString
            ]
        )
    }

    static func log(
        _ category: String,
        _ message: String,
        details: [String: String?] = [:],
        file: StaticString = #fileID,
        function: StaticString = #function,
        line: Int = #line
    ) {
        let timestamp = formatter.string(from: Date())
        let threadLabel = threadDescription()
        let source = "\(file):\(line) \(function)"
        let renderedDetails = details
            .compactMapValues { $0 }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " | ")

        let suffix = renderedDetails.isEmpty ? "" : " | \(renderedDetails)"
        let entry = "\(timestamp) [\(threadLabel)] [\(category)] \(message) | source=\(source)\(suffix)"

        print(entry)

        guard diskLoggingEnabled else { return }

        queue.async {
            guard let data = "\(entry)\n".data(using: .utf8) else { return }
            do {
                try rotateLogFileIfNeeded(incomingByteCount: UInt64(data.count))
                let handle = try FileHandle(forWritingTo: logFileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                print("\(timestamp) [\(threadLabel)] [DebugLog] failed to write log file: \(error)")
            }
        }
    }

    private static func rotateLogFileIfNeeded(incomingByteCount: UInt64) throws {
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: logFileURL.path) {
            _ = fileManager.createFile(atPath: logFileURL.path, contents: nil)
            return
        }

        let attributes = try fileManager.attributesOfItem(atPath: logFileURL.path)
        let currentSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard currentSize + incomingByteCount > maxLogFileSizeBytes else { return }

        if fileManager.fileExists(atPath: rotatedLogFileURL.path) {
            try fileManager.removeItem(at: rotatedLogFileURL)
        }
        try fileManager.moveItem(at: logFileURL, to: rotatedLogFileURL)
        _ = fileManager.createFile(atPath: logFileURL.path, contents: nil)
    }

    static func describe(space: SpaceInfo?) -> String {
        guard let space else { return "nil" }
        return "id=\(space.id),display=\(shortDisplayID(space.displayID)),index=\(space.index),fullscreen=\(space.isFullscreen)"
    }

    static func describe(spaces: [SpaceInfo]) -> String {
        guard !spaces.isEmpty else { return "[]" }
        return spaces.map { "{\(describe(space: $0))}" }.joined(separator: ", ")
    }

    static func describe(spacesByDisplay: [String: SpaceInfo]) -> String {
        guard !spacesByDisplay.isEmpty else { return "[:]" }
        return spacesByDisplay
            .sorted { $0.key < $1.key }
            .map { "\(shortDisplayID($0.key))={\(describe(space: $0.value))}" }
            .joined(separator: ", ")
    }

    static func describe(screen: NSScreen?) -> String {
        guard let screen else { return "nil" }
        let displayID = screen.displayUUIDString ?? "unknown"
        return "name=\(screen.localizedName),display=\(shortDisplayID(displayID)),frame=\(describe(rect: screen.frame)),visibleFrame=\(describe(rect: screen.visibleFrame))"
    }

    static func describe(window: NSWindow?) -> String {
        guard let window else { return "nil" }
        let occlusion = window.occlusionState.contains(.visible) ? "visible" : "notVisible"
        return "window#=\(window.windowNumber),visible=\(window.isVisible),occlusion=\(occlusion),level=\(window.level.rawValue),frame=\(describe(rect: window.frame)),screen=\(describe(screen: window.screen))"
    }

    static func describe(rect: NSRect) -> String {
        "x=\(Int(rect.origin.x)),y=\(Int(rect.origin.y)),w=\(Int(rect.size.width)),h=\(Int(rect.size.height))"
    }

    static func describe(color: Color) -> String {
        let nsColor = NSColor(color)
        guard let deviceColor = nsColor.usingColorSpace(.deviceRGB) else {
            return String(describing: nsColor)
        }

        return String(
            format: "r=%.3f,g=%.3f,b=%.3f,a=%.3f",
            deviceColor.redComponent,
            deviceColor.greenComponent,
            deviceColor.blueComponent,
            deviceColor.alphaComponent
        )
    }

    static func shortDisplayID(_ displayID: String) -> String {
        String(displayID.prefix(8))
    }

    private static func threadDescription() -> String {
        if Thread.isMainThread {
            return "main"
        }

        if let threadName = Thread.current.name, !threadName.isEmpty {
            return threadName
        }

        let pointer = Unmanaged.passUnretained(Thread.current).toOpaque()
        return "bg:\(pointer)"
    }
}
