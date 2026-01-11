//
//  DesktopTitleApp.swift
//  DesktopTitle
//
//  Main application entry point
//

import SwiftUI

@main
struct DesktopTitleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No main window - this is a menu bar only app
        Settings {
            SettingsView()
        }
    }
}
