//
//  SpaceConfig.swift
//  DesktopTitle
//
//  Per-Space user configuration (name + colors).
//
//  Storage model: a single flat dictionary keyed by the stable Space
//  identity `"displayID:displayIndex"`. The display topology (which
//  displays are connected at any moment) does NOT affect storage —
//  names and colors persist regardless of which displays are plugged
//  in. Earlier versions stored per-topology copies and silently lost
//  data when the topology changed; the legacy data is migrated into
//  the flat store on first load.
//

import Foundation
import SwiftUI

/// Stable, display-positioned user data for a Space.
private struct SpaceProfileData: Codable, Equatable {
    var name: String = ""
    var backgroundColor: CodableColor?
    var textColor: CodableColor?

    var hasUserValues: Bool {
        !name.isEmpty || backgroundColor != nil || textColor != nil
    }
}

private struct SpaceConfigStore: Codable {
    /// Authoritative store: stable key (`"displayID:displayIndex"`) → user data.
    var spaceProfiles: [String: SpaceProfileData]?

    /// Legacy per-topology storage. Read for migration, never written.
    var profiles: [String: [UInt64: SpaceConfig]]?

    init(spaceProfiles: [String: SpaceProfileData]) {
        self.spaceProfiles = spaceProfiles
        self.profiles = nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spaceProfiles = try c.decodeIfPresent([String: SpaceProfileData].self, forKey: .spaceProfiles)
        profiles = try c.decodeIfPresent([String: [UInt64: SpaceConfig]].self, forKey: .profiles)
    }
}

/// Codable wrapper for Color
struct CodableColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var opacity: Double

    init(_ color: Color) {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        self.red = Double(nsColor.redComponent)
        self.green = Double(nsColor.greenComponent)
        self.blue = Double(nsColor.blueComponent)
        self.opacity = Double(nsColor.alphaComponent)
    }

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: opacity)
    }
}

/// Configuration for a single Space
struct SpaceConfig: Codable, Identifiable, Equatable {
    let id: UInt64          // CGSSpaceID
    var name: String        // Custom name for the space
    var displayIndex: Int   // 1-based display index
    var displayID: String?  // Display UUID, used to keep profiles stable across display changes
    var backgroundColor: CodableColor?  // Custom background color
    var textColor: CodableColor?        // Custom text color

    init(id: UInt64, name: String = "", displayIndex: Int = 1, displayID: String? = nil, backgroundColor: Color? = nil, textColor: Color? = nil) {
        self.id = id
        self.name = name
        self.displayIndex = displayIndex
        self.displayID = displayID
        self.backgroundColor = backgroundColor.map { CodableColor($0) }
        self.textColor = textColor.map { CodableColor($0) }
    }

    /// Returns the display name (custom name or default "Desktop N")
    func displayName() -> String {
        if name.isEmpty {
            return "Desktop \(displayIndex)"
        }
        return name
    }
}

/// Manager for Space configurations.
///
/// All per-Space user data lives in a single dictionary keyed by
/// `"displayID:displayIndex"`. Topology / profile-mode parameters
/// passed via `setActiveProfile` are accepted for API compatibility
/// but no longer affect what is stored or read.
final class SpaceConfigManager: ObservableObject {

    static let shared = SpaceConfigManager()

    @Published private(set) var configs: [UInt64: SpaceConfig] = [:]

    private let userDefaultsKey = "SpaceConfigs"
    private var spaceProfiles: [String: SpaceProfileData] = [:]

    private init() {
        loadConfigs()
        refreshConfigs()
    }

    // MARK: - Public API

    /// Refresh the published `configs` view. Topology parameters are
    /// retained for API compatibility but no longer affect storage.
    func setActiveProfile(_ profileID: String, mode: ProfileMode = .independent, baseProfileID: String? = nil, displayIDs: [String] = []) {
        refreshConfigs()
    }

    /// Get or create config for a space.
    func getConfig(for spaceInfo: SpaceInfo) -> SpaceConfig {
        let key = Self.stableKey(displayID: spaceInfo.displayID, displayIndex: spaceInfo.index)
        let data = spaceProfiles[key]
        return SpaceConfig(
            id: spaceInfo.id,
            name: data?.name ?? "",
            displayIndex: spaceInfo.index,
            displayID: spaceInfo.displayID,
            backgroundColor: data?.backgroundColor?.color,
            textColor: data?.textColor?.color
        )
    }

    /// Update the name for a space.
    func setName(_ name: String, for spaceID: UInt64, displayIndex: Int, displayID: String? = nil) {
        guard let displayID else {
            DebugLog.log("SpaceConfigManager", "setName ignored — displayID missing", details: [
                "spaceID": "\(spaceID)",
                "displayIndex": "\(displayIndex)"
            ])
            return
        }
        let key = Self.stableKey(displayID: displayID, displayIndex: displayIndex)
        var data = spaceProfiles[key] ?? SpaceProfileData()
        data.name = name
        spaceProfiles[key] = data
        persistConfigs()
        refreshConfigs()
    }

    /// Update colors for a space.
    func setColors(backgroundColor: Color?, textColor: Color?, for spaceID: UInt64, displayIndex: Int, displayID: String? = nil) {
        guard let displayID else {
            DebugLog.log("SpaceConfigManager", "setColors ignored — displayID missing", details: [
                "spaceID": "\(spaceID)",
                "displayIndex": "\(displayIndex)"
            ])
            return
        }
        let key = Self.stableKey(displayID: displayID, displayIndex: displayIndex)
        var data = spaceProfiles[key] ?? SpaceProfileData()
        data.backgroundColor = backgroundColor.map { CodableColor($0) }
        data.textColor = textColor.map { CodableColor($0) }
        spaceProfiles[key] = data
        persistConfigs()
        refreshConfigs()
    }

    /// Get background color for a space (returns nil if not set).
    func getBackgroundColor(for spaceInfo: SpaceInfo) -> Color? {
        return getConfig(for: spaceInfo).backgroundColor?.color
    }

    /// Get text color for a space (returns nil if not set).
    func getTextColor(for spaceInfo: SpaceInfo) -> Color? {
        return getConfig(for: spaceInfo).textColor?.color
    }

    /// Get the display name for a space.
    func getDisplayName(for spaceInfo: SpaceInfo) -> String {
        return getConfig(for: spaceInfo).displayName()
    }

    /// Clear all configs.
    func clearAll() {
        spaceProfiles.removeAll()
        persistConfigs()
        refreshConfigs()
    }

    /// Sync configurations with current spaces (refresh published view).
    func syncWithCurrentSpaces() {
        refreshConfigs()
    }

    /// Per-Space data is no longer scoped by topology, so nothing is
    /// "inherited". Kept for API compatibility.
    func isInheritedSpace(_ spaceInfo: SpaceInfo) -> Bool {
        return false
    }

    // MARK: - Private

    private static func stableKey(displayID: String, displayIndex: Int) -> String {
        "\(displayID):\(displayIndex)"
    }

    private func refreshConfigs() {
        let currentSpaces = SpaceIdentifier.shared.getAllSpaces()
            .filter { !$0.isFullscreen }
        var newConfigs: [UInt64: SpaceConfig] = [:]
        for space in currentSpaces {
            newConfigs[space.id] = getConfig(for: space)
        }
        configs = newConfigs
    }

    private func persistConfigs() {
        let store = SpaceConfigStore(spaceProfiles: spaceProfiles)
        guard let data = try? JSONEncoder().encode(store) else {
            return
        }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
        UserDefaults.standard.synchronize()
    }

    private func loadConfigs() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else {
            return
        }

        if let store = try? JSONDecoder().decode(SpaceConfigStore.self, from: data) {
            if let master = store.spaceProfiles {
                spaceProfiles = master
            }
            // Migrate legacy per-topology data. Existing master entries take
            // precedence so re-running migration never overwrites fresh data.
            if let legacy = store.profiles {
                migrateLegacyTopologyConfigs(legacy)
            }
            DebugLog.log("SpaceConfigManager", "loaded configs", details: [
                "spaceProfilesCount": "\(spaceProfiles.count)",
                "legacyTopologyCount": "\(store.profiles?.count ?? 0)"
            ])
            return
        }

        // Very old format: bare `[UInt64: SpaceConfig]`.
        if let veryLegacy = try? JSONDecoder().decode([UInt64: SpaceConfig].self, from: data) {
            for (_, config) in veryLegacy {
                migrateSingleConfig(config, fallbackDisplayID: nil)
            }
            DebugLog.log("SpaceConfigManager", "migrated legacy bare-dict configs", details: [
                "spaceProfilesCount": "\(spaceProfiles.count)"
            ])
            // Persist immediately so we never re-read the legacy format again.
            persistConfigs()
        }
    }

    private func migrateLegacyTopologyConfigs(_ legacy: [String: [UInt64: SpaceConfig]]) {
        var migrated = 0
        for (legacyKey, configs) in legacy {
            // Single-display topology keys are themselves the displayID; use them
            // as a fallback for entries whose `displayID` field is missing.
            let fallbackDisplayID: String? = legacyKey.contains("|") ? nil : legacyKey
            for (_, config) in configs {
                if migrateSingleConfig(config, fallbackDisplayID: fallbackDisplayID) {
                    migrated += 1
                }
            }
        }
        if migrated > 0 {
            DebugLog.log("SpaceConfigManager", "migrated legacy topology entries", details: [
                "migrated": "\(migrated)"
            ])
            persistConfigs()
        }
    }

    @discardableResult
    private func migrateSingleConfig(_ config: SpaceConfig, fallbackDisplayID: String?) -> Bool {
        let displayID = config.displayID ?? fallbackDisplayID
        guard let displayID else { return false }

        let candidate = SpaceProfileData(
            name: config.name,
            backgroundColor: config.backgroundColor,
            textColor: config.textColor
        )
        guard candidate.hasUserValues else { return false }

        let key = Self.stableKey(displayID: displayID, displayIndex: config.displayIndex)
        if let existing = spaceProfiles[key], existing.hasUserValues {
            return false
        }
        spaceProfiles[key] = candidate
        return true
    }
}
