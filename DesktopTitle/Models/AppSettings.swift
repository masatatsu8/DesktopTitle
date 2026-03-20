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

private struct AppSettingsStore: Codable {
    var profiles: [String: AppSettingsProfile]
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

    var currentProfileSummary: String {
        currentConfiguration.summary
    }

    // MARK: - Initialization

    private let defaults = UserDefaults.standard
    private var profiles: [String: AppSettingsProfile] = [:]
    private var activeProfileID: String
    private var isApplyingProfile = false

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
        let storedProfiles = Self.loadStoredProfiles(from: defaults)
        let initialProfile = storedProfiles[configuration.id] ?? legacyProfile

        self.currentConfiguration = configuration
        self.activeProfileID = configuration.id
        self.profiles = storedProfiles.isEmpty ? [configuration.id: initialProfile] : storedProfiles
        self.profiles[configuration.id] = initialProfile
        self.fontSize = CGFloat(initialProfile.fontSize)
        self.displayDuration = initialProfile.displayDuration
        self.displayDelay = initialProfile.displayDelay
        self.showSpaceIndex = initialProfile.showSpaceIndex
        self.positionX = initialProfile.positionX
        self.positionY = initialProfile.positionY
        self.useUnifiedColors = initialProfile.useUnifiedColors
        self.backgroundColor = initialProfile.backgroundColor.color
        self.textColor = initialProfile.textColor.color
        self.fontName = initialProfile.fontName
        self.launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        self.showForFullscreen = initialProfile.showForFullscreen

        persistProfiles()
    }

    func applyDisplayConfiguration(_ configuration: DisplayConfiguration) {
        guard configuration != currentConfiguration else { return }

        profiles[activeProfileID] = makeActiveProfile()
        currentConfiguration = configuration
        activeProfileID = configuration.id

        if profiles[configuration.id] == nil {
            profiles[configuration.id] = makeActiveProfile()
        }

        if let profile = profiles[configuration.id] {
            applyProfile(profile)
        }

        persistProfiles()
        print("[AppSettings] Applied profile for configuration: \(configuration.summary)")
    }

    func resetCurrentProfileToDefaults() {
        let profile = AppSettingsProfile.default
        profiles[activeProfileID] = profile
        applyProfile(profile)
        persistProfiles()
    }

    private func saveActiveProfile() {
        guard !isApplyingProfile else { return }
        profiles[activeProfileID] = makeActiveProfile()
        persistProfiles()
    }

    private func saveGlobalSettings() {
        defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
    }

    private func persistProfiles() {
        guard let data = try? JSONEncoder().encode(AppSettingsStore(profiles: profiles)) else {
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

    private static func loadStoredProfiles(from defaults: UserDefaults) -> [String: AppSettingsProfile] {
        guard let data = defaults.data(forKey: Keys.profiles),
              let decoded = try? JSONDecoder().decode(AppSettingsStore.self, from: data) else {
            return [:]
        }
        return decoded.profiles
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
