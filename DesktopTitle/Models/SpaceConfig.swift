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

        // The very-old bare-`[UInt64: SpaceConfig]` format has neither key,
        // and the keyed container would silently decode it as an empty
        // store — losing every user-edited name and color. Fail decoding
        // here so `loadConfigs` falls through to the bare-dict path.
        guard spaceProfiles != nil || profiles != nil else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "SpaceConfigStore has neither `spaceProfiles` nor `profiles`; treat as legacy bare-dict format."
                )
            )
        }
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
        guard let resolvedDisplayID = resolveDisplayID(provided: displayID, spaceID: spaceID) else {
            DebugLog.log("SpaceConfigManager", "setName ignored — displayID could not be resolved", details: [
                "spaceID": "\(spaceID)",
                "displayIndex": "\(displayIndex)"
            ])
            return
        }
        let key = Self.stableKey(displayID: resolvedDisplayID, displayIndex: displayIndex)
        var data = spaceProfiles[key] ?? SpaceProfileData()
        data.name = name
        spaceProfiles[key] = data
        persistConfigs()
        refreshConfigs()
    }

    /// Update colors for a space.
    func setColors(backgroundColor: Color?, textColor: Color?, for spaceID: UInt64, displayIndex: Int, displayID: String? = nil) {
        guard let resolvedDisplayID = resolveDisplayID(provided: displayID, spaceID: spaceID) else {
            DebugLog.log("SpaceConfigManager", "setColors ignored — displayID could not be resolved", details: [
                "spaceID": "\(spaceID)",
                "displayIndex": "\(displayIndex)"
            ])
            return
        }
        let key = Self.stableKey(displayID: resolvedDisplayID, displayIndex: displayIndex)
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

    /// Resolve the displayID for a setter call. Callers usually pass it
    /// explicitly, but the parameter has a `nil` default for API
    /// compatibility — when that path is taken, fall back to the
    /// SpaceConfig the caller already knows about (via `configs` or
    /// the live SpaceIdentifier list) so the write does not silently
    /// no-op when the caller forgets to thread the displayID through.
    private func resolveDisplayID(provided: String?, spaceID: UInt64) -> String? {
        if let provided { return provided }
        if let existing = configs[spaceID]?.displayID { return existing }
        if let live = SpaceIdentifier.shared.getAllSpaces().first(where: { $0.id == spaceID }) {
            return live.displayID
        }
        return nil
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
        let data: Data
        do {
            data = try JSONEncoder().encode(store)
        } catch {
            DebugLog.log("SpaceConfigManager", "persist failed", details: [
                "error": "\(error)",
                "spaceProfilesCount": "\(spaceProfiles.count)"
            ])
            return
        }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
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
            migrateBareDictConfigs(veryLegacy)
            // Persist immediately so we never re-read the legacy format again.
            persistConfigs()
        }
    }

    /// Best-effort displayID resolution for the very-old bare-dict format,
    /// which predates per-Space `displayID` tracking. Try (1) the current
    /// SpaceIdentifier list keyed by `spaceID`, (2) the `displayIndex`
    /// position when the user is on a single display, and (3) skip with
    /// a log entry if neither yields a result.
    private func migrateBareDictConfigs(_ legacy: [UInt64: SpaceConfig]) {
        let liveSpaces = SpaceIdentifier.shared.getAllSpaces().filter { !$0.isFullscreen }
        let displayIDByLiveSpace: [UInt64: String] = Dictionary(
            liveSpaces.map { ($0.id, $0.displayID) },
            uniquingKeysWith: { first, _ in first }
        )
        let liveDisplayIDs = Set(liveSpaces.map(\.displayID))
        let singleDisplayFallback: String? = liveDisplayIDs.count == 1 ? liveDisplayIDs.first : nil

        var migrated = 0
        var skipped = 0
        for spaceID in legacy.keys.sorted() {
            guard let config = legacy[spaceID] else { continue }
            let candidate = SpaceProfileData(
                name: config.name,
                backgroundColor: config.backgroundColor,
                textColor: config.textColor
            )
            guard candidate.hasUserValues else { continue }

            let resolvedDisplayID = config.displayID
                ?? displayIDByLiveSpace[spaceID]
                ?? singleDisplayFallback
            if migrateSingleConfig(config, fallbackDisplayID: resolvedDisplayID, sourceKey: "bare-dict") {
                migrated += 1
            } else if resolvedDisplayID == nil {
                skipped += 1
                DebugLog.log("SpaceConfigManager", "bare-dict migration skipped (displayID unresolved)", details: [
                    "spaceID": "\(spaceID)",
                    "displayIndex": "\(config.displayIndex)",
                    "name": config.name
                ])
            }
        }
        DebugLog.log("SpaceConfigManager", "bare-dict migration done", details: [
            "migrated": "\(migrated)",
            "skipped": "\(skipped)",
            "totalCandidates": "\(legacy.count)"
        ])
    }

    private func migrateLegacyTopologyConfigs(_ legacy: [String: [UInt64: SpaceConfig]]) {
        // Process single-display profiles BEFORE multi-display topologies, then
        // sort each group by key. A single-display profile's data is rooted in
        // the physical display, so when multiple legacy profiles claim the
        // same `displayID:displayIndex` we trust the single-display copy. The
        // alphabetical sort within each group keeps migration output
        // deterministic regardless of Dictionary iteration order.
        let orderedKeys = legacy.keys.sorted { lhs, rhs in
            let lhsMulti = lhs.contains("|")
            let rhsMulti = rhs.contains("|")
            if lhsMulti != rhsMulti { return !lhsMulti }
            return lhs < rhs
        }

        var migrated = 0
        for legacyKey in orderedKeys {
            guard let configs = legacy[legacyKey] else { continue }
            // Single-display topology keys are themselves the displayID; use them
            // as a fallback for entries whose `displayID` field is missing.
            let fallbackDisplayID: String? = legacyKey.contains("|") ? nil : legacyKey
            // Within a single profile, sort by spaceID to keep ordering stable.
            for spaceID in configs.keys.sorted() {
                guard let config = configs[spaceID] else { continue }
                if migrateSingleConfig(config, fallbackDisplayID: fallbackDisplayID, sourceKey: legacyKey) {
                    migrated += 1
                }
            }
        }
        DebugLog.log("SpaceConfigManager", "legacy topology migration done", details: [
            "migrated": "\(migrated)",
            "legacyKeys": "\(legacy.count)"
        ])
        // Always persist after a migration pass so the legacy `profiles`
        // field is dropped from UserDefaults even when every entry was a
        // collision (migrated == 0). Otherwise the old data sticks around
        // and the same collision logs reappear on every launch.
        persistConfigs()
    }

    @discardableResult
    private func migrateSingleConfig(_ config: SpaceConfig, fallbackDisplayID: String?, sourceKey: String? = nil) -> Bool {
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
            DebugLog.log("SpaceConfigManager", "migration collision (kept first)", details: [
                "key": key,
                "kept": existing.name,
                "skippedSource": sourceKey ?? "(unknown)",
                "skippedName": candidate.name
            ])
            return false
        }
        spaceProfiles[key] = candidate
        return true
    }
}
