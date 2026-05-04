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

    private struct SpacePosition: Hashable {
        let displayID: String
        let index: Int
    }

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
        syncBeforeEditingIfNeeded(spaceID: spaceID, displayIndex: displayIndex, displayID: displayID)

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
        syncBeforeEditingIfNeeded(spaceID: spaceID, displayIndex: displayIndex, displayID: displayID)

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
        configsByProfile.removeAll()
        persistConfigs()
    }

    /// Sync configurations with current spaces (remove stale, add new)
    func syncWithCurrentSpaces() {
        let currentSpaces = SpaceIdentifier.shared.getAllSpaces()
        guard !currentSpaces.isEmpty else { return }

        normalizeConfigs(with: currentSpaces)
        persistConfigs()
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
        let currentSpaces = SpaceIdentifier.shared.getAllSpaces()
        guard !currentSpaces.isEmpty else { return }

        normalizeConfigs(with: currentSpaces)
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

    private func syncBeforeEditingIfNeeded(spaceID: UInt64, displayIndex: Int, displayID: String?) {
        guard let config = configs[spaceID] else {
            saveCurrentConfigs()
            return
        }

        if config.displayIndex != displayIndex || config.displayID != displayID {
            saveCurrentConfigs()
        }
    }

    private func normalizeConfigs(with currentSpaces: [SpaceInfo]) {
        let spacesByProfile = Dictionary(grouping: currentSpaces) { space in
            effectiveProfileID(for: space.displayID)
        }

        var nextConfigsByProfile = configsByProfile
        var nextMergedConfigs: [UInt64: SpaceConfig] = [:]

        for (profileID, profileSpaces) in spacesByProfile {
            let activeDisplayIDs = Set(profileSpaces.map(\.displayID))
            let existingProfileConfigs = configsByProfile[profileID] ?? [:]
            let sourceConfigs = sourceConfigsForNormalization(profileID: profileID)
            var consumedSourceIDs = Set<UInt64>()

            var rebuiltProfileConfigs = existingProfileConfigs.filter { _, config in
                guard let existingDisplayID = config.displayID else {
                    return false
                }
                return !activeDisplayIDs.contains(existingDisplayID)
            }

            for space in profileSpaces.sorted(by: spaceSortOrder) {
                let reusable = reusableConfig(
                    for: space,
                    in: sourceConfigs,
                    consumedSourceIDs: consumedSourceIDs
                )
                if let reusableID = reusable.id {
                    consumedSourceIDs.insert(reusableID)
                }

                let normalizedConfig = normalizedConfig(from: reusable.config, for: space)
                rebuiltProfileConfigs[space.id] = normalizedConfig
                nextMergedConfigs[space.id] = normalizedConfig
            }

            nextConfigsByProfile[profileID] = rebuiltProfileConfigs
        }

        if currentMode == .inherit {
            let activeDisplayIDs = Set(currentSpaces.map(\.displayID))
            pruneActiveDisplayConfigs(from: &nextConfigsByProfile[activeProfileID], activeDisplayIDs: activeDisplayIDs)
        }

        configsByProfile = nextConfigsByProfile
        configs = nextMergedConfigs
    }

    private func sourceConfigsForNormalization(profileID: String) -> [UInt64: SpaceConfig] {
        var sourceConfigs = configsByProfile[profileID] ?? [:]

        if currentMode == .inherit, profileID != activeProfileID {
            // Older versions stored inherited-mode names under the topology profile.
            // Use them as migration sources, then prune them after normalization.
            sourceConfigs.merge(configsByProfile[activeProfileID] ?? [:]) { current, _ in current }
        }

        for (spaceID, config) in configs {
            if let displayID = config.displayID {
                guard effectiveProfileID(for: displayID) == profileID else { continue }
            } else if sourceConfigs[spaceID] == nil {
                continue
            }
            sourceConfigs[spaceID] = config
        }

        return sourceConfigs
    }

    private func reusableConfig(
        for spaceInfo: SpaceInfo,
        in sourceConfigs: [UInt64: SpaceConfig],
        consumedSourceIDs: Set<UInt64>
    ) -> (id: UInt64?, config: SpaceConfig?) {
        if let exact = sourceConfigs[spaceInfo.id] {
            return (spaceInfo.id, exact)
        }

        let position = SpacePosition(displayID: spaceInfo.displayID, index: spaceInfo.index)
        let match = sourceConfigs
            .filter { id, config in
                !consumedSourceIDs.contains(id) &&
                config.hasUserValues &&
                SpacePosition(displayID: config.displayID ?? spaceInfo.displayID, index: config.displayIndex) == position
            }
            .sorted { lhs, rhs in
                let lhsSameDisplay = lhs.value.displayID == spaceInfo.displayID
                let rhsSameDisplay = rhs.value.displayID == spaceInfo.displayID
                if lhsSameDisplay != rhsSameDisplay {
                    return lhsSameDisplay
                }
                return lhs.key < rhs.key
            }
            .first

        return (match?.key, match?.value)
    }

    private func normalizedConfig(from config: SpaceConfig?, for spaceInfo: SpaceInfo) -> SpaceConfig {
        SpaceConfig(
            id: spaceInfo.id,
            name: config?.name ?? "",
            displayIndex: spaceInfo.index,
            displayID: spaceInfo.displayID,
            backgroundColor: config?.backgroundColor?.color,
            textColor: config?.textColor?.color
        )
    }

    private func pruneActiveDisplayConfigs(from profileConfigs: inout [UInt64: SpaceConfig]?, activeDisplayIDs: Set<String>) {
        guard var configs = profileConfigs else { return }

        configs = configs.filter { _, config in
            guard let displayID = config.displayID else {
                return false
            }
            return !activeDisplayIDs.contains(displayID)
        }
        profileConfigs = configs.isEmpty ? nil : configs
    }

    private func spaceSortOrder(_ lhs: SpaceInfo, _ rhs: SpaceInfo) -> Bool {
        if lhs.displayID == rhs.displayID {
            return lhs.index < rhs.index
        }

        let lhsDisplayIndex = activeDisplayIDs.firstIndex(of: lhs.displayID)
        let rhsDisplayIndex = activeDisplayIDs.firstIndex(of: rhs.displayID)

        switch (lhsDisplayIndex, rhsDisplayIndex) {
        case let (lhsIndex?, rhsIndex?):
            return lhsIndex < rhsIndex
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.displayID < rhs.displayID
        }
    }

    private func persistConfigs() {
        guard let data = try? JSONEncoder().encode(SpaceConfigStore(profiles: configsByProfile)) else {
            return
        }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
        UserDefaults.standard.synchronize()
    }
}

private extension SpaceConfig {
    var hasUserValues: Bool {
        !name.isEmpty || backgroundColor != nil || textColor != nil
    }
}
