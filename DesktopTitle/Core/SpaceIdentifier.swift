//
//  SpaceIdentifier.swift
//  DesktopTitle
//
//  Identifies the current Space using CGSPrivate API
//

import Foundation

private struct ManagedDisplaySpace {
    let displayID: String
    let spaces: [SpaceInfo]
    let currentSpace: SpaceInfo?
}

/// Represents information about a single Space
struct SpaceInfo: Identifiable, Equatable {
    let id: UInt64          // CGSSpaceID
    let displayID: String   // Display UUID
    let index: Int          // 1-based index within the display
    let isFullscreen: Bool  // Whether this is a fullscreen space

    var displayIndex: Int {
        index
    }
}

/// Manages Space identification using CGSPrivate API
final class SpaceIdentifier {

    static let shared = SpaceIdentifier()

    private init() {}

    private func extractUInt64(from value: Any?) -> UInt64? {
        switch value {
        case let v as UInt64:
            return v
        case let v as Int64:
            return UInt64(bitPattern: v)
        case let v as Int:
            return UInt64(v)
        case let v as NSNumber:
            return v.uint64Value
        default:
            return nil
        }
    }

    /// Get the current active Space ID
    func getActiveSpaceID() -> UInt64 {
        let connection = _CGSDefaultConnection()
        return CGSGetActiveSpace(connection)
    }

    /// Get all spaces organized by display
    func getAllSpaces() -> [SpaceInfo] {
        managedDisplaySpaces().flatMap(\.spaces)
    }

    /// Get the currently active space for each display.
    func getCurrentSpacesByDisplay() -> [String: SpaceInfo] {
        let activeSpaceID = getActiveSpaceID()
        var currentSpaces: [String: SpaceInfo] = [:]
        var usedFallback = false

        for displaySpace in managedDisplaySpaces() {
            if let currentSpace = displaySpace.currentSpace {
                currentSpaces[displaySpace.displayID] = currentSpace
            } else if let fallback = displaySpace.spaces.first(where: { $0.id == activeSpaceID }) {
                currentSpaces[displaySpace.displayID] = fallback
                usedFallback = true
            }
        }

        DebugLog.log(
            "SpaceIdentifier",
            "resolved current spaces by display",
            details: [
                "activeSpaceID": "\(activeSpaceID)",
                "usedFallback": "\(usedFallback)",
                "currentSpaces": DebugLog.describe(spacesByDisplay: currentSpaces)
            ]
        )

        return currentSpaces
    }

    private func managedDisplaySpaces() -> [ManagedDisplaySpace] {
        let connection = _CGSDefaultConnection()

        // CGSCopyManagedDisplaySpaces returns CFArrayRef (caller owns it)
        let cfArray: CFArray? = CGSCopyManagedDisplaySpaces(connection)
        guard let cfArray = cfArray else {
            DebugLog.log("SpaceIdentifier", "CGSCopyManagedDisplaySpaces returned nil")
            return []
        }

        // Convert CFArray to Swift Array
        let nsArray = cfArray as NSArray

        guard let displaySpaces = nsArray as? [[String: Any]] else {
            DebugLog.log(
                "SpaceIdentifier",
                "failed to cast managed display spaces payload",
                details: [
                    "payloadType": "\(type(of: nsArray))"
                ]
            )
            return []
        }

        var managedSpaces: [ManagedDisplaySpace] = []

        for displayInfo in displaySpaces {
            guard let displayID = displayInfo["Display Identifier"] as? String else {
                continue
            }

            let spaces = (displayInfo["Spaces"] as? [[String: Any]] ?? []).enumerated().compactMap { index, spaceDict in
                parseSpaceInfo(from: spaceDict, displayID: displayID, index: index + 1)
            }

            let currentSpaceDict = displayInfo["Current Space"] as? [String: Any]
            let currentSpaceID =
                extractUInt64(from: currentSpaceDict?["ManagedSpaceID"]) ??
                extractUInt64(from: currentSpaceDict?["id64"]) ??
                extractUInt64(from: currentSpaceDict?["uuid"])
            let currentSpaceIndex = currentSpaceID.flatMap { id in
                spaces.firstIndex(where: { $0.id == id }).map { $0 + 1 }
            } ?? 1

            let currentSpace = currentSpaceID.flatMap { id in
                spaces.first(where: { $0.id == id })
            } ?? currentSpaceDict.flatMap { dict in
                parseSpaceInfo(
                    from: dict,
                    displayID: displayID,
                    index: currentSpaceIndex
                )
            }

            managedSpaces.append(
                ManagedDisplaySpace(
                    displayID: displayID,
                    spaces: spaces,
                    currentSpace: currentSpace
                )
            )
        }

        let summary = managedSpaces
            .map { displaySpace in
                let currentSpace = displaySpace.currentSpace.map { "\($0.id)" } ?? "nil"
                return "display=\(DebugLog.shortDisplayID(displaySpace.displayID)),spaces=\(displaySpace.spaces.count),currentSpaceID=\(currentSpace)"
            }
            .joined(separator: "; ")
        DebugLog.log(
            "SpaceIdentifier",
            "parsed managed display spaces",
            details: [
                "displayCount": "\(managedSpaces.count)",
                "summary": summary
            ]
        )

        return managedSpaces
    }

    private func parseSpaceInfo(from spaceDict: [String: Any], displayID: String, index: Int) -> SpaceInfo? {
        let spaceID =
            extractUInt64(from: spaceDict["ManagedSpaceID"]) ??
            extractUInt64(from: spaceDict["id64"]) ??
            extractUInt64(from: spaceDict["uuid"])

        guard let finalSpaceID = spaceID else {
            return nil
        }

        let spaceType = spaceDict["type"] as? Int ?? 0
        let isFullscreen = spaceType == Int(kCGSSpaceFullscreen)

        return SpaceInfo(
            id: finalSpaceID,
            displayID: displayID,
            index: index,
            isFullscreen: isFullscreen
        )
    }

    /// Get information about the currently active space
    func getCurrentSpaceInfo() -> SpaceInfo? {
        let currentSpaces = getCurrentSpacesByDisplay()

        if let mainDisplayID = DisplayConfiguration.current().orderedDisplayIDs.first,
           let mainSpace = currentSpaces[mainDisplayID] {
            return mainSpace
        }

        return currentSpaces.values.first
    }

    /// Get the 1-based index of the current space on its display
    func getCurrentSpaceIndex() -> Int {
        return getCurrentSpaceInfo()?.index ?? 1
    }

    /// Get the total number of spaces on the current display
    func getSpaceCount() -> Int {
        guard let currentSpace = getCurrentSpaceInfo() else {
            return 1
        }

        let allSpaces = getAllSpaces()
        return allSpaces.filter { $0.displayID == currentSpace.displayID }.count
    }
}
