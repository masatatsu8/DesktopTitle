//
//  AppSettings.swift
//  DesktopTitle
//
//  Global application settings
//

import Foundation
import SwiftUI

/// Application-wide settings
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    // MARK: - Display Settings

    /// Font size for the overlay text
    @Published var fontSize: CGFloat {
        didSet { save() }
    }

    /// Duration in seconds to display the overlay
    @Published var displayDuration: Double {
        didSet { save() }
    }

    /// Delay before showing overlay (seconds)
    @Published var displayDelay: Double {
        didSet { save() }
    }

    /// Whether to show the space index below the name
    @Published var showSpaceIndex: Bool {
        didSet { save() }
    }

    // MARK: - Position Settings

    /// Horizontal position (0.0 = left, 0.5 = center, 1.0 = right)
    @Published var positionX: Double {
        didSet { save() }
    }

    /// Vertical position (0.0 = top, 0.5 = center, 1.0 = bottom)
    @Published var positionY: Double {
        didSet { save() }
    }

    // MARK: - Appearance Settings

    /// Use unified colors (true) or per-desktop colors (false)
    @Published var useUnifiedColors: Bool {
        didSet { save() }
    }

    /// Background color (used when useUnifiedColors is true)
    @Published var backgroundColor: Color {
        didSet { saveColor(backgroundColor, forKey: Keys.backgroundColor) }
    }

    /// Text color (used when useUnifiedColors is true)
    @Published var textColor: Color {
        didSet { saveColor(textColor, forKey: Keys.textColor) }
    }

    /// Font name (empty = system default)
    @Published var fontName: String {
        didSet { save() }
    }

    // MARK: - Behavior Settings

    /// Whether to launch at login
    @Published var launchAtLogin: Bool {
        didSet { save() }
    }

    /// Whether to show overlay for fullscreen spaces
    @Published var showForFullscreen: Bool {
        didSet { save() }
    }

    /// Whether to show desktop images in settings
    @Published var showDesktopImages: Bool {
        didSet { save() }
    }

    // MARK: - Initialization

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let fontSize = "fontSize"
        static let displayDuration = "displayDuration"
        static let displayDelay = "displayDelay"
        static let showSpaceIndex = "showSpaceIndex"
        static let positionX = "positionX"
        static let positionY = "positionY"
        static let useUnifiedColors = "useUnifiedColors"
        static let backgroundColor = "backgroundColor"
        static let textColor = "textColor"
        static let fontName = "fontName"
        static let launchAtLogin = "launchAtLogin"
        static let showForFullscreen = "showForFullscreen"
        static let showDesktopImages = "showDesktopImages"
    }

    private init() {
        // Load saved values or use defaults
        self.fontSize = defaults.object(forKey: Keys.fontSize) as? CGFloat ?? 48
        self.displayDuration = defaults.object(forKey: Keys.displayDuration) as? Double ?? 1.5
        self.displayDelay = defaults.object(forKey: Keys.displayDelay) as? Double ?? 0.0
        self.showSpaceIndex = defaults.object(forKey: Keys.showSpaceIndex) as? Bool ?? true
        self.positionX = defaults.object(forKey: Keys.positionX) as? Double ?? 0.5
        self.positionY = defaults.object(forKey: Keys.positionY) as? Double ?? 0.5
        self.useUnifiedColors = defaults.object(forKey: Keys.useUnifiedColors) as? Bool ?? true
        self.backgroundColor = Self.loadColor(from: defaults, forKey: Keys.backgroundColor) ?? Color.black.opacity(0.6)
        self.textColor = Self.loadColor(from: defaults, forKey: Keys.textColor) ?? Color.white
        self.fontName = defaults.string(forKey: Keys.fontName) ?? ""
        self.launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        self.showForFullscreen = defaults.object(forKey: Keys.showForFullscreen) as? Bool ?? true
        self.showDesktopImages = defaults.object(forKey: Keys.showDesktopImages) as? Bool ?? false
    }

    private func save() {
        defaults.set(fontSize, forKey: Keys.fontSize)
        defaults.set(displayDuration, forKey: Keys.displayDuration)
        defaults.set(displayDelay, forKey: Keys.displayDelay)
        defaults.set(showSpaceIndex, forKey: Keys.showSpaceIndex)
        defaults.set(positionX, forKey: Keys.positionX)
        defaults.set(positionY, forKey: Keys.positionY)
        defaults.set(useUnifiedColors, forKey: Keys.useUnifiedColors)
        defaults.set(fontName, forKey: Keys.fontName)
        defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
        defaults.set(showForFullscreen, forKey: Keys.showForFullscreen)
        defaults.set(showDesktopImages, forKey: Keys.showDesktopImages)
    }

    // MARK: - Color Persistence

    private func saveColor(_ color: Color, forKey key: String) {
        let nsColor = NSColor(color)
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: nsColor, requiringSecureCoding: false) {
            defaults.set(data, forKey: key)
        }
    }

    private static func loadColor(from defaults: UserDefaults, forKey key: String) -> Color? {
        guard let data = defaults.data(forKey: key),
              let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) else {
            return nil
        }
        return Color(nsColor)
    }

    /// Reset all settings to defaults
    func resetToDefaults() {
        fontSize = 48
        displayDuration = 1.5
        displayDelay = 0.0
        showSpaceIndex = true
        positionX = 0.5
        positionY = 0.5
        useUnifiedColors = true
        backgroundColor = Color.black.opacity(0.6)
        textColor = Color.white
        fontName = ""
        launchAtLogin = false
        showForFullscreen = true
        showDesktopImages = false
    }

    // MARK: - Available Fonts

    static var availableFonts: [String] {
        let families = NSFontManager.shared.availableFontFamilies
        return [""] + families.sorted()
    }
}
