//
//  AppSettings.swift
//  DesktopTitle
//
//  Global application settings
//

import Foundation
import SwiftUI

private struct AppSettingsProfile: Codable, Equatable {
    var fontSize: Double
    var displayDuration: Double
    var displayDelay: Double
    var showSpaceIndex: Bool
    var positionX: Double
    var positionY: Double
    var useUnifiedColors: Bool
    var backgroundColor: CodableColor
    var textColor: CodableColor
    var fontName: String
    var showForFullscreen: Bool

    static let `default` = AppSettingsProfile(
        fontSize: 48,
        displayDuration: 1.5,
        displayDelay: 0.0,
        showSpaceIndex: true,
        positionX: 0.5,
        positionY: 0.5,
        useUnifiedColors: true,
        backgroundColor: CodableColor(Color.black.opacity(0.6)),
        textColor: CodableColor(.white),
        fontName: "",
        showForFullscreen: true
    )
}

/// Profile mode for multi-display configurations
enum ProfileMode: String, Codable, CaseIterable {
    case inherit      // Use base (single-display) profile settings
    case independent  // Fully independent settings per configuration
}

private struct ProfileMetadata: Codable {
    var mode: ProfileMode
    var baseProfileID: String
}

private struct AppSettingsStore: Codable {
    var profiles: [String: AppSettingsProfile]
    var profileMetadata: [String: ProfileMetadata]

    init(profiles: [String: AppSettingsProfile], profileMetadata: [String: ProfileMetadata] = [:]) {
        self.profiles = profiles
        self.profileMetadata = profileMetadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try container.decode([String: AppSettingsProfile].self, forKey: .profiles)
        profileMetadata = try container.decodeIfPresent([String: ProfileMetadata].self, forKey: .profileMetadata) ?? [:]
    }
}

/// Application-wide settings
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    // MARK: - Display Settings

    /// Font size for the overlay text
    @Published var fontSize: CGFloat {
        didSet { saveActiveProfile() }
    }

    /// Duration in seconds to display the overlay
    @Published var displayDuration: Double {
        didSet { saveActiveProfile() }
    }

    /// Delay before showing overlay (seconds)
    @Published var displayDelay: Double {
        didSet { saveActiveProfile() }
    }

    /// Whether to show the space index below the name
    @Published var showSpaceIndex: Bool {
        didSet { saveActiveProfile() }
    }

    // MARK: - Position Settings

    /// Horizontal position (0.0 = left, 0.5 = center, 1.0 = right)
    @Published var positionX: Double {
        didSet { saveActiveProfile() }
    }

    /// Vertical position (0.0 = top, 0.5 = center, 1.0 = bottom)
    @Published var positionY: Double {
        didSet { saveActiveProfile() }
    }

    // MARK: - Appearance Settings

    /// Use unified colors (true) or per-desktop colors (false)
    @Published var useUnifiedColors: Bool {
        didSet { saveActiveProfile() }
    }

    /// Background color (used when useUnifiedColors is true)
    @Published var backgroundColor: Color {
        didSet { saveActiveProfile() }
    }

    /// Text color (used when useUnifiedColors is true)
    @Published var textColor: Color {
        didSet { saveActiveProfile() }
    }

    /// Font name (empty = system default)
    @Published var fontName: String {
        didSet { saveActiveProfile() }
    }

    // MARK: - Behavior Settings

    /// Whether to launch at login
    @Published var launchAtLogin: Bool {
        didSet { saveGlobalSettings() }
    }

    /// Whether to show overlay for fullscreen spaces
    @Published var showForFullscreen: Bool {
        didSet { saveActiveProfile() }
    }

    /// The active screen configuration that owns the current profile.
    @Published private(set) var currentConfiguration: DisplayConfiguration

    /// The profile mode for the current display configuration
    @Published private(set) var profileMode: ProfileMode = .independent

    var currentProfileSummary: String {
        currentConfiguration.summary
    }

    /// Whether the current configuration is multi-display
    var isMultiDisplay: Bool {
        currentConfiguration.isMultiDisplay
    }

    // MARK: - Initialization

    private let defaults = UserDefaults.standard
    private var profiles: [String: AppSettingsProfile] = [:]
    private var profileMetadata: [String: ProfileMetadata] = [:]
    private var activeProfileID: String
    private var isApplyingProfile = false

    /// The profile ID to actually read/write settings from.
    /// In inherit mode, this returns the base profile ID.
    private var effectiveProfileID: String {
        if let meta = profileMetadata[activeProfileID], meta.mode == .inherit {
            return meta.baseProfileID
        }
        return activeProfileID
    }

    /// The base profile ID for the current configuration (if in inherit mode).
    var baseProfileID: String? {
        profileMetadata[activeProfileID]?.baseProfileID
    }

    private enum Keys {
        static let profiles = "appSettings.profiles"
        static let launchAtLogin = "launchAtLogin"
        static let legacyFontSize = "fontSize"
        static let legacyDisplayDuration = "displayDuration"
        static let legacyDisplayDelay = "displayDelay"
        static let legacyShowSpaceIndex = "showSpaceIndex"
        static let legacyPositionX = "positionX"
        static let legacyPositionY = "positionY"
        static let legacyUseUnifiedColors = "useUnifiedColors"
        static let legacyBackgroundColor = "backgroundColor"
        static let legacyTextColor = "textColor"
        static let legacyFontName = "fontName"
        static let legacyShowForFullscreen = "showForFullscreen"
    }

    private init() {
        let configuration = DisplayConfiguration.current()
        let legacyProfile = Self.loadLegacyProfile(from: defaults)
        let stored = Self.loadStore(from: defaults)
        let storedProfiles = stored.profiles
        let initialProfile = storedProfiles[configuration.id] ?? legacyProfile

        self.currentConfiguration = configuration
        self.activeProfileID = configuration.id
        self.profiles = storedProfiles.isEmpty ? [configuration.id: initialProfile] : storedProfiles
        self.profiles[configuration.id] = initialProfile
        self.profileMetadata = stored.profileMetadata

        // Resolve profile mode
        if let meta = profileMetadata[configuration.id] {
            self.profileMode = meta.mode
        } else if configuration.isMultiDisplay {
            // New multi-display config defaults to inherit if a base profile exists
            if let baseID = Self.resolveBaseProfileID(for: configuration, in: profiles) {
                let meta = ProfileMetadata(mode: .inherit, baseProfileID: baseID)
                self.profileMetadata[configuration.id] = meta
                self.profileMode = .inherit
            } else {
                self.profileMode = .independent
            }
        } else {
            self.profileMode = .independent
        }

        // Compute effective profile ID locally (can't use computed property before init completes)
        let resolvedEffectiveID: String
        if let meta = self.profileMetadata[configuration.id], meta.mode == .inherit {
            resolvedEffectiveID = meta.baseProfileID
        } else {
            resolvedEffectiveID = configuration.id
        }
        let effectiveProfile = profiles[resolvedEffectiveID] ?? initialProfile
        self.fontSize = CGFloat(effectiveProfile.fontSize)
        self.displayDuration = effectiveProfile.displayDuration
        self.displayDelay = effectiveProfile.displayDelay
        self.showSpaceIndex = effectiveProfile.showSpaceIndex
        self.positionX = effectiveProfile.positionX
        self.positionY = effectiveProfile.positionY
        self.useUnifiedColors = effectiveProfile.useUnifiedColors
        self.backgroundColor = effectiveProfile.backgroundColor.color
        self.textColor = effectiveProfile.textColor.color
        self.fontName = effectiveProfile.fontName
        self.launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        self.showForFullscreen = effectiveProfile.showForFullscreen

        persistProfiles()
    }

    func applyDisplayConfiguration(_ configuration: DisplayConfiguration) {
        guard configuration != currentConfiguration else { return }

        // Save current settings to the effective profile
        profiles[effectiveProfileID] = makeActiveProfile()
        currentConfiguration = configuration
        activeProfileID = configuration.id

        // Resolve profile mode for the new configuration
        if let meta = profileMetadata[configuration.id] {
            profileMode = meta.mode
            DebugLog.log("AppSettings", "existing metadata found", details: [
                "mode": meta.mode.rawValue,
                "baseProfileID": DebugLog.shortDisplayID(meta.baseProfileID)
            ])
        } else if configuration.isMultiDisplay {
            let profileKeys = profiles.keys.map { DebugLog.shortDisplayID($0) }.joined(separator: ", ")
            DebugLog.log("AppSettings", "resolving base profile for new multi-display config", details: [
                "displayIDs": configuration.displays.map { DebugLog.shortDisplayID($0.id) }.joined(separator: ", "),
                "builtInID": configuration.builtInDisplayID.map { DebugLog.shortDisplayID($0) } ?? "none",
                "existingProfiles": profileKeys
            ])
            if let baseID = Self.resolveBaseProfileID(for: configuration, in: profiles) {
                profileMetadata[configuration.id] = ProfileMetadata(mode: .inherit, baseProfileID: baseID)
                profileMode = .inherit
                DebugLog.log("AppSettings", "inherit mode: base profile found", details: [
                    "baseProfileID": DebugLog.shortDisplayID(baseID)
                ])
            } else {
                profileMode = .independent
                DebugLog.log("AppSettings", "independent mode: no base profile found")
            }
        } else {
            profileMode = .independent
        }

        // In independent mode, create a new profile if needed
        if profileMode == .independent && profiles[configuration.id] == nil {
            profiles[configuration.id] = makeActiveProfile()
        }

        if let profile = profiles[effectiveProfileID] {
            applyProfile(profile)
        }

        persistProfiles()
        DebugLog.log(
            "AppSettings",
            "applied profile for configuration",
            details: [
                "summary": configuration.summary,
                "mode": profileMode.rawValue,
                "effectiveProfileID": DebugLog.shortDisplayID(effectiveProfileID)
            ]
        )
    }

    func resetCurrentProfileToDefaults() {
        let profile = AppSettingsProfile.default
        profiles[effectiveProfileID] = profile
        applyProfile(profile)
        persistProfiles()
    }

    /// Switch the profile mode for the current multi-display configuration.
    func setProfileMode(_ mode: ProfileMode) {
        guard currentConfiguration.isMultiDisplay, mode != profileMode else { return }

        if mode == .independent {
            // Copy effective (base) settings into an independent profile for this config
            profiles[activeProfileID] = makeActiveProfile()
            if let meta = profileMetadata[activeProfileID] {
                profileMetadata[activeProfileID] = ProfileMetadata(mode: .independent, baseProfileID: meta.baseProfileID)
            }
        } else {
            // Switch to inherit: remove independent profile, fall back to base
            if let baseID = profileMetadata[activeProfileID]?.baseProfileID
                ?? Self.resolveBaseProfileID(for: currentConfiguration, in: profiles) {
                profileMetadata[activeProfileID] = ProfileMetadata(mode: .inherit, baseProfileID: baseID)
                profiles.removeValue(forKey: activeProfileID)
                if let baseProfile = profiles[baseID] {
                    applyProfile(baseProfile)
                }
            }
        }

        profileMode = mode
        persistProfiles()
    }

    private func saveActiveProfile() {
        guard !isApplyingProfile else { return }
        profiles[effectiveProfileID] = makeActiveProfile()
        persistProfiles()
    }

    private func saveGlobalSettings() {
        defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
    }

    private func persistProfiles() {
        let store = AppSettingsStore(profiles: profiles, profileMetadata: profileMetadata)
        guard let data = try? JSONEncoder().encode(store) else {
            return
        }
        defaults.set(data, forKey: Keys.profiles)
        saveGlobalSettings()
    }

    private func makeActiveProfile() -> AppSettingsProfile {
        AppSettingsProfile(
            fontSize: Double(fontSize),
            displayDuration: displayDuration,
            displayDelay: displayDelay,
            showSpaceIndex: showSpaceIndex,
            positionX: positionX,
            positionY: positionY,
            useUnifiedColors: useUnifiedColors,
            backgroundColor: CodableColor(backgroundColor),
            textColor: CodableColor(textColor),
            fontName: fontName,
            showForFullscreen: showForFullscreen
        )
    }

    private func applyProfile(_ profile: AppSettingsProfile) {
        isApplyingProfile = true
        fontSize = CGFloat(profile.fontSize)
        displayDuration = profile.displayDuration
        displayDelay = profile.displayDelay
        showSpaceIndex = profile.showSpaceIndex
        positionX = profile.positionX
        positionY = profile.positionY
        useUnifiedColors = profile.useUnifiedColors
        backgroundColor = profile.backgroundColor.color
        textColor = profile.textColor.color
        fontName = profile.fontName
        showForFullscreen = profile.showForFullscreen
        isApplyingProfile = false
    }

    private static func loadStore(from defaults: UserDefaults) -> AppSettingsStore {
        guard let data = defaults.data(forKey: Keys.profiles),
              let decoded = try? JSONDecoder().decode(AppSettingsStore.self, from: data) else {
            return AppSettingsStore(profiles: [:])
        }
        return decoded
    }

    /// Find the base (single-display) profile ID for a multi-display configuration.
    /// Looks for a stored profile whose key is a single UUID matching one of the config's displays.
    /// Prefers the built-in display.
    private static func resolveBaseProfileID(for configuration: DisplayConfiguration, in profiles: [String: AppSettingsProfile]) -> String? {
        let displayIDs = configuration.displays.map(\.id)

        // Prefer built-in display
        if let builtInID = configuration.builtInDisplayID, profiles[builtInID] != nil {
            return builtInID
        }

        // Fall back to any single-display profile matching one of the displays
        for displayID in displayIDs {
            if profiles[displayID] != nil {
                return displayID
            }
        }

        return nil
    }

    private static func loadColor(from defaults: UserDefaults, forKey key: String) -> Color? {
        guard let data = defaults.data(forKey: key),
              let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) else {
            return nil
        }
        return Color(nsColor)
    }

    private static func loadLegacyProfile(from defaults: UserDefaults) -> AppSettingsProfile {
        AppSettingsProfile(
            fontSize: defaults.doubleValue(forKey: Keys.legacyFontSize, default: AppSettingsProfile.default.fontSize),
            displayDuration: defaults.doubleValue(forKey: Keys.legacyDisplayDuration, default: AppSettingsProfile.default.displayDuration),
            displayDelay: defaults.doubleValue(forKey: Keys.legacyDisplayDelay, default: AppSettingsProfile.default.displayDelay),
            showSpaceIndex: defaults.object(forKey: Keys.legacyShowSpaceIndex) as? Bool ?? AppSettingsProfile.default.showSpaceIndex,
            positionX: defaults.doubleValue(forKey: Keys.legacyPositionX, default: AppSettingsProfile.default.positionX),
            positionY: defaults.doubleValue(forKey: Keys.legacyPositionY, default: AppSettingsProfile.default.positionY),
            useUnifiedColors: defaults.object(forKey: Keys.legacyUseUnifiedColors) as? Bool ?? AppSettingsProfile.default.useUnifiedColors,
            backgroundColor: CodableColor(
                loadColor(from: defaults, forKey: Keys.legacyBackgroundColor) ?? AppSettingsProfile.default.backgroundColor.color
            ),
            textColor: CodableColor(
                loadColor(from: defaults, forKey: Keys.legacyTextColor) ?? AppSettingsProfile.default.textColor.color
            ),
            fontName: defaults.string(forKey: Keys.legacyFontName) ?? AppSettingsProfile.default.fontName,
            showForFullscreen: defaults.object(forKey: Keys.legacyShowForFullscreen) as? Bool ?? AppSettingsProfile.default.showForFullscreen
        )
    }

    /// Reset all settings to defaults
    func resetToDefaults() {
        resetCurrentProfileToDefaults()
        launchAtLogin = false
    }

    // MARK: - Available Fonts

    static var availableFonts: [String] {
        let families = NSFontManager.shared.availableFontFamilies
        return [""] + families.sorted()
    }
}

private extension UserDefaults {
    func doubleValue(forKey key: String, default fallback: Double) -> Double {
        guard object(forKey: key) != nil else {
            return fallback
        }
        return double(forKey: key)
    }
}
