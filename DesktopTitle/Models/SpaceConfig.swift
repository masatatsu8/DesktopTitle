//
//  SpaceConfig.swift
//  DesktopTitle
//
//  Configuration for individual Spaces
//

import Foundation
import SwiftUI

private struct SpaceConfigStore: Codable {
    var profiles: [String: [UInt64: SpaceConfig]]
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

/// Manager for Space configurations
final class SpaceConfigManager: ObservableObject {

    static let shared = SpaceConfigManager()

    @Published private(set) var configs: [UInt64: SpaceConfig] = [:]

    private let userDefaultsKey = "SpaceConfigs"
    private var configsByProfile: [String: [UInt64: SpaceConfig]] = [:]
    private var activeProfileID: String = DisplayConfiguration.current().id
    private var currentMode: ProfileMode = .independent
    private var currentBaseProfileID: String?
    /// Display IDs that belong to the base profile (used in inherit mode)
    private var baseDisplayIDs: Set<String> = []
    private var activeDisplayIDs: Set<String> = []

    private init() {
        loadConfigs()
        configs = configsByProfile[activeProfileID] ?? [:]
    }

    func setActiveProfile(_ profileID: String, mode: ProfileMode = .independent, baseProfileID: String? = nil, displayIDs: [String] = []) {
        // Save current configs before switching
        saveCurrentConfigs()

        activeProfileID = profileID
        currentMode = mode
        currentBaseProfileID = baseProfileID
        activeDisplayIDs = Set(displayIDs)

        // Determine which display IDs belong to the base profile
        if mode == .inherit, let baseID = baseProfileID {
            // The base profile ID is a single display UUID
            baseDisplayIDs = Set([baseID])
        } else {
            baseDisplayIDs = []
        }

        rebuildMergedConfigs()
        saveConfigs()
    }

    /// Get the effective profile ID for a given space based on which display it's on.
    private func effectiveProfileID(for displayID: String) -> String {
        if currentMode == .inherit {
            if let baseID = currentBaseProfileID, baseDisplayIDs.contains(displayID) {
                return baseID
            }

            // External displays keep their desktop names with the display itself,
            // not with the transient "built-in + external" topology profile.
            return displayID
        }

        return activeProfileID
    }

    /// Rebuild the merged configs view from base + own profiles.
    private func rebuildMergedConfigs() {
        if currentMode == .inherit, let baseID = currentBaseProfileID {
            var merged: [UInt64: SpaceConfig] = [:]
            // Add base profile's configs (for built-in display spaces)
            if let baseConfigs = configsByProfile[baseID] {
                for (id, config) in baseConfigs {
                    merged[id] = config
                }
            }
            // Add legacy topology-level configs so existing saved names remain visible.
            if let ownConfigs = configsByProfile[activeProfileID] {
                for (id, config) in ownConfigs {
                    merged[id] = config
                }
            }
            // Add per-display configs for currently attached external displays.
            for displayID in activeDisplayIDs where !baseDisplayIDs.contains(displayID) {
                if let displayConfigs = configsByProfile[displayID] {
                    for (id, config) in displayConfigs {
                        merged[id] = config
                    }
                }
            }
            configs = merged
        } else {
            configs = configsByProfile[activeProfileID] ?? [:]
        }
    }

    /// Get or create config for a space
    func getConfig(for spaceInfo: SpaceInfo) -> SpaceConfig {
        if let existing = configs[spaceInfo.id] {
            return existing
        }

        if let reusable = reusableConfig(for: spaceInfo)?.config {
            return reusable
        }

        let config = SpaceConfig(
            id: spaceInfo.id,
            name: "",
            displayIndex: spaceInfo.index,
            displayID: spaceInfo.displayID
        )
        return config
    }

    /// Update the name for a space
    func setName(_ name: String, for spaceID: UInt64, displayIndex: Int, displayID: String? = nil) {
        var config = configs[spaceID] ?? SpaceConfig(id: spaceID, displayIndex: displayIndex, displayID: displayID)
        config.name = name
        config.displayIndex = displayIndex
        config.displayID = displayID ?? config.displayID
        configs[spaceID] = config

        // Route to the correct profile
        let profileID = displayID.map { effectiveProfileID(for: $0) } ?? activeProfileID
        var profileConfigs = configsByProfile[profileID] ?? [:]
        removeStaleConfigs(
            from: &profileConfigs,
            keeping: spaceID,
            displayIndex: displayIndex,
            displayID: displayID
        )
        profileConfigs[spaceID] = config
        configsByProfile[profileID] = profileConfigs
        persistConfigs()
    }

    /// Update colors for a space
    func setColors(backgroundColor: Color?, textColor: Color?, for spaceID: UInt64, displayIndex: Int, displayID: String? = nil) {
        var config = configs[spaceID] ?? SpaceConfig(id: spaceID, displayIndex: displayIndex, displayID: displayID)
        config.backgroundColor = backgroundColor.map { CodableColor($0) }
        config.textColor = textColor.map { CodableColor($0) }
        config.displayIndex = displayIndex
        config.displayID = displayID ?? config.displayID
        configs[spaceID] = config

        let profileID = displayID.map { effectiveProfileID(for: $0) } ?? activeProfileID
        var profileConfigs = configsByProfile[profileID] ?? [:]
        removeStaleConfigs(
            from: &profileConfigs,
            keeping: spaceID,
            displayIndex: displayIndex,
            displayID: displayID
        )
        profileConfigs[spaceID] = config
        configsByProfile[profileID] = profileConfigs
        persistConfigs()
    }

    /// Get background color for a space (returns nil if not set)
    func getBackgroundColor(for spaceInfo: SpaceInfo) -> Color? {
        return getConfig(for: spaceInfo).backgroundColor?.color
    }

    /// Get text color for a space (returns nil if not set)
    func getTextColor(for spaceInfo: SpaceInfo) -> Color? {
        return getConfig(for: spaceInfo).textColor?.color
    }

    /// Get the display name for a space
    func getDisplayName(for spaceInfo: SpaceInfo) -> String {
        return getConfig(for: spaceInfo).displayName()
    }

    /// Clear all configs
    func clearAll() {
        configs.removeAll()
        saveConfigs()
    }

    /// Sync configurations with current spaces (remove stale, add new)
    func syncWithCurrentSpaces() {
        let currentSpaces = SpaceIdentifier.shared.getAllSpaces()
        let currentIDs = Set(currentSpaces.map { $0.id })

        // Update display indices and remap saved names if macOS changed CGSSpaceID
        // after a display was attached or detached.
        for space in currentSpaces {
            let profileID = effectiveProfileID(for: space.displayID)
            let reusable = configs[space.id].map { (id: Optional<UInt64>.none, config: $0) }
                ?? reusableConfig(for: space)

            var config = reusable?.config ?? SpaceConfig(
                id: space.id,
                name: "",
                displayIndex: space.index,
                displayID: space.displayID
            )
            config.displayIndex = space.index
            config.displayID = space.displayID
            configs[space.id] = config

            var profileConfigs = configsByProfile[profileID] ?? [:]
            if let oldID = reusable?.id, oldID != space.id {
                profileConfigs.removeValue(forKey: oldID)
            }
            removeStaleConfigs(
                from: &profileConfigs,
                keeping: space.id,
                displayIndex: space.index,
                displayID: space.displayID
            )
            profileConfigs[space.id] = config
            configsByProfile[profileID] = profileConfigs
        }

        // Remove configs for spaces that no longer exist
        configs = configs.filter { currentIDs.contains($0.key) }

        saveConfigs()
    }

    /// Whether a space belongs to the base (inherited) profile
    func isInheritedSpace(_ spaceInfo: SpaceInfo) -> Bool {
        currentMode == .inherit && baseDisplayIDs.contains(spaceInfo.displayID)
    }

    // MARK: - Persistence

    private func loadConfigs() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else {
            return
        }

        if let decoded = try? JSONDecoder().decode(SpaceConfigStore.self, from: data) {
            configsByProfile = decoded.profiles
            return
        }

        if let legacyConfigs = try? JSONDecoder().decode([UInt64: SpaceConfig].self, from: data) {
            configsByProfile[activeProfileID] = legacyConfigs
        }
    }

    /// Save current merged configs back to the correct underlying profiles.
    private func saveCurrentConfigs() {
        let spacesByID = Dictionary(uniqueKeysWithValues: SpaceIdentifier.shared.getAllSpaces().map { ($0.id, $0) })
        guard !spacesByID.isEmpty else { return }

        for (spaceID, config) in configs {
            guard let space = spacesByID[spaceID] else { continue }

            var updatedConfig = config
            updatedConfig.displayIndex = space.index
            updatedConfig.displayID = space.displayID

            let profileID = effectiveProfileID(for: space.displayID)
            var profileConfigs = configsByProfile[profileID] ?? [:]
            removeStaleConfigs(
                from: &profileConfigs,
                keeping: spaceID,
                displayIndex: space.index,
                displayID: space.displayID
            )
            profileConfigs[spaceID] = updatedConfig
            configsByProfile[profileID] = profileConfigs
        }
    }

    private func removeStaleConfigs(
        from profileConfigs: inout [UInt64: SpaceConfig],
        keeping spaceID: UInt64,
        displayIndex: Int,
        displayID: String?
    ) {
        guard let displayID else { return }

        profileConfigs = profileConfigs.filter { existingSpaceID, config in
            if existingSpaceID == spaceID {
                return true
            }

            let sameDisplay = config.displayID == nil || config.displayID == displayID
            return !(sameDisplay && config.displayIndex == displayIndex)
        }
    }

    private func reusableConfig(for spaceInfo: SpaceInfo) -> (id: UInt64?, config: SpaceConfig)? {
        let profileID = effectiveProfileID(for: spaceInfo.displayID)
        guard let profileConfigs = configsByProfile[profileID] else { return nil }

        if var exact = profileConfigs[spaceInfo.id] {
            exact.displayIndex = spaceInfo.index
            exact.displayID = spaceInfo.displayID
            return (nil, exact)
        }

        guard let match = profileConfigs.first(where: { _, config in
            config.hasUserValues &&
            config.displayIndex == spaceInfo.index &&
            (config.displayID == nil || config.displayID == spaceInfo.displayID)
        }) else {
            return nil
        }

        let config = SpaceConfig(
            id: spaceInfo.id,
            name: match.value.name,
            displayIndex: spaceInfo.index,
            displayID: spaceInfo.displayID,
            backgroundColor: match.value.backgroundColor?.color,
            textColor: match.value.textColor?.color
        )
        return (match.key, config)
    }

    private func saveConfigs() {
        saveCurrentConfigs()
        persistConfigs()
    }

    private func persistConfigs() {
        guard let data = try? JSONEncoder().encode(SpaceConfigStore(profiles: configsByProfile)) else {
            return
        }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }
}

private extension SpaceConfig {
    var hasUserValues: Bool {
        !name.isEmpty || backgroundColor != nil || textColor != nil
    }
}
