//
//  SpaceIdentifier.swift
//  DesktopTitle
//
//  Identifies the current Space using CGSPrivate API
//

import Foundation

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

    /// Get the current active Space ID
    func getActiveSpaceID() -> UInt64 {
        let connection = _CGSDefaultConnection()
        return CGSGetActiveSpace(connection)
    }

    /// Get all spaces organized by display
    func getAllSpaces() -> [SpaceInfo] {
        let connection = _CGSDefaultConnection()

        // CGSCopyManagedDisplaySpaces returns CFArrayRef (caller owns it)
        let cfArray: CFArray? = CGSCopyManagedDisplaySpaces(connection)
        guard let cfArray = cfArray else {
            print("[SpaceIdentifier] CGSCopyManagedDisplaySpaces returned nil")
            return []
        }

        // Convert CFArray to Swift Array
        let nsArray = cfArray as NSArray

        // Debug: Print raw data structure
        print("[SpaceIdentifier] Raw data type: \(type(of: nsArray))")
        print("[SpaceIdentifier] Number of displays: \(nsArray.count)")

        guard let displaySpaces = nsArray as? [[String: Any]] else {
            print("[SpaceIdentifier] Failed to cast to [[String: Any]]")
            print("[SpaceIdentifier] Actual content: \(nsArray)")
            return []
        }

        var allSpaces: [SpaceInfo] = []

        for displayInfo in displaySpaces {
            print("[SpaceIdentifier] Display info keys: \(displayInfo.keys)")

            guard let displayID = displayInfo["Display Identifier"] as? String else {
                print("[SpaceIdentifier] Missing 'Display Identifier'")
                continue
            }

            guard let spaces = displayInfo["Spaces"] as? [[String: Any]] else {
                print("[SpaceIdentifier] Missing or invalid 'Spaces'")
                continue
            }

            print("[SpaceIdentifier] Found \(spaces.count) spaces for display: \(displayID)")

            for (index, spaceDict) in spaces.enumerated() {
                print("[SpaceIdentifier] Space \(index) keys: \(spaceDict.keys)")
                print("[SpaceIdentifier] Space \(index) data: \(spaceDict)")

                // Try different possible keys for space ID
                var spaceID: UInt64?
                if let id = spaceDict["ManagedSpaceID"] as? UInt64 {
                    spaceID = id
                } else if let id = spaceDict["ManagedSpaceID"] as? Int64 {
                    spaceID = UInt64(bitPattern: id)
                } else if let id = spaceDict["ManagedSpaceID"] as? Int {
                    spaceID = UInt64(id)
                } else if let id = spaceDict["id64"] as? UInt64 {
                    spaceID = id
                } else if let id = spaceDict["id64"] as? Int64 {
                    spaceID = UInt64(bitPattern: id)
                } else if let id = spaceDict["uuid"] as? Int {
                    spaceID = UInt64(id)
                }

                guard let finalSpaceID = spaceID else {
                    print("[SpaceIdentifier] Could not extract space ID from: \(spaceDict)")
                    continue
                }

                let spaceType = spaceDict["type"] as? Int ?? 0
                let isFullscreen = spaceType == Int(kCGSSpaceFullscreen)

                let spaceInfo = SpaceInfo(
                    id: finalSpaceID,
                    displayID: displayID,
                    index: index + 1,  // 1-based index
                    isFullscreen: isFullscreen
                )

                allSpaces.append(spaceInfo)
            }
        }

        print("[SpaceIdentifier] Total spaces found: \(allSpaces.count)")
        return allSpaces
    }

    /// Get information about the currently active space
    func getCurrentSpaceInfo() -> SpaceInfo? {
        let activeID = getActiveSpaceID()
        let allSpaces = getAllSpaces()
        return allSpaces.first { $0.id == activeID }
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
