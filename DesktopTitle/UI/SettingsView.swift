//
//  SettingsView.swift
//  DesktopTitle
//
//  Settings window UI
//

import SwiftUI
import Combine

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var spaceConfigManager = SpaceConfigManager.shared
    @State private var spaces: [SpaceInfo] = []
    @State private var spaceNames: [UInt64: String] = [:]
    @State private var spaceBackgroundColors: [UInt64: Color] = [:]
    @State private var spaceTextColors: [UInt64: Color] = [:]
    @FocusState private var focusedSpaceIndex: Int?

    var body: some View {
        TabView {
            spacesTab
                .tabItem {
                    Label("Desktops", systemImage: "rectangle.split.3x1")
                }

            displayTab
                .tabItem {
                    Label("Display", systemImage: "textformat.size")
                }

            generalTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }
        }
        .padding()
        .frame(minWidth: 400, minHeight: 350)
        .onAppear {
            refreshSpaces()
        }
        .onReceive(SpaceMonitor.shared.$currentSpace.compactMap { $0 }) { _ in
            refreshSpaces()
        }
        .onReceive(settings.$currentConfiguration) { _ in
            refreshSpaces()
        }
    }

    // MARK: - Spaces Tab

    private var spacesTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Desktop Names")
                    .font(.headline)

                Spacer()

                Text(settings.currentProfileSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if spaces.isEmpty {
                Text("No desktops detected")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                List {
                    ForEach(Array(spaces.enumerated()), id: \.element.id) { index, space in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                // Highlight current desktop
                                let isCurrent = SpaceMonitor.shared.currentSpacesByDisplay.values.contains { $0.id == space.id }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Desktop \(space.index)")
                                        .foregroundStyle(isCurrent ? .blue : .secondary)
                                    if NSScreen.screens.count > 1,
                                       let screenName = NSScreen.screens.first(where: { $0.displayUUIDString == space.displayID })?.localizedName {
                                        HStack(spacing: 4) {
                                            Text(screenName)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                            if spaceConfigManager.isInheritedSpace(space) {
                                                Text("(shared)")
                                                    .font(.caption2)
                                                    .foregroundStyle(.blue)
                                            }
                                        }
                                    }
                                }
                                .frame(width: 100, alignment: .leading)

                                TextField("Enter name...", text: binding(for: space))
                                    .textFieldStyle(.roundedBorder)
                                    .focused($focusedSpaceIndex, equals: index)

                                if isCurrent {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                        .help("Current desktop")
                                }
                            }

                            // Per-desktop color settings (only show when not using unified colors)
                            if !settings.useUnifiedColors {
                                HStack(spacing: 16) {
                                    HStack(spacing: 6) {
                                        Text("Background")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        ColorPicker("Background", selection: backgroundColorBinding(for: space))
                                            .labelsHidden()
                                            .help("Background color for this desktop")
                                    }

                                    HStack(spacing: 6) {
                                        Text("Text")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        ColorPicker("Text", selection: textColorBinding(for: space))
                                            .labelsHidden()
                                            .help("Text color for this desktop")
                                    }

                                    Spacer()
                                }
                                .padding(.leading, 100)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
            }

            HStack {
                Button("Refresh") {
                    refreshSpaces()
                }

                Spacer()

                Button("Clear All Names") {
                    clearAllNames()
                }
            }
        }
        .padding()
    }

    // MARK: - Display Tab

    private var displayTab: some View {
        ScrollView {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Current display profile")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(settings.currentProfileSummary)
                    }

                    if settings.isMultiDisplay {
                        Picker("Profile Mode", selection: profileModeBinding) {
                            Text("Inherit from built-in display").tag(ProfileMode.inherit)
                            Text("Independent").tag(ProfileMode.independent)
                        }

                        if settings.profileMode == .inherit {
                            Text("Display settings are shared with the built-in display profile. Changes here also apply when using the built-in display only.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Profile")
                }

                Section {
                    HStack {
                        Text("Display Delay")
                        Spacer()
                        Slider(value: $settings.displayDelay, in: 0...1, step: 0.1) {
                            Text("Delay")
                        }
                        .frame(width: 150)
                        Text("\(settings.displayDelay, specifier: "%.1f") sec")
                            .frame(width: 60)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Display Duration")
                        Spacer()
                        Slider(value: $settings.displayDuration, in: 0.5...5, step: 0.5) {
                            Text("Duration")
                        }
                        .frame(width: 150)
                        Text("\(settings.displayDuration, specifier: "%.1f") sec")
                            .frame(width: 60)
                            .foregroundStyle(.secondary)
                    }

                    Toggle("Show desktop number", isOn: $settings.showSpaceIndex)
                } header: {
                    Text("Timing")
                }

                Section {
                    HStack {
                        Text("Position X")
                        Spacer()
                        Slider(value: $settings.positionX, in: 0...1, step: 0.1) {
                            Text("X")
                        }
                        .frame(width: 150)
                        Text(positionLabel(settings.positionX, axis: "X"))
                            .frame(width: 60)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Position Y")
                        Spacer()
                        Slider(value: $settings.positionY, in: 0...1, step: 0.1) {
                            Text("Y")
                        }
                        .frame(width: 150)
                        Text(positionLabel(settings.positionY, axis: "Y"))
                            .frame(width: 60)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Position")
                }

                Section {
                    Picker("Font", selection: $settings.fontName) {
                        Text("System Default").tag("")
                        ForEach(AppSettings.availableFonts.filter { !$0.isEmpty }, id: \.self) { font in
                            Text(font).tag(font)
                        }
                    }

                    HStack {
                        Text("Font Size")
                        Spacer()
                        Slider(value: $settings.fontSize, in: 24...96, step: 4) {
                            Text("Font Size")
                        }
                        .frame(width: 150)
                        Text("\(Int(settings.fontSize)) pt")
                            .frame(width: 60)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Font")
                }

                Section {
                    Toggle("Use unified colors for all desktops", isOn: $settings.useUnifiedColors)

                    if settings.useUnifiedColors {
                        ColorPicker("Text Color", selection: $settings.textColor)
                        ColorPicker("Background Color", selection: $settings.backgroundColor)
                    } else {
                        Text("Per-desktop colors can be set in the Desktops tab")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Colors")
                }

                Section {
                    // Preview
                    previewView
                        .frame(height: 150)
                } header: {
                    Text("Preview")
                }
            }
            .formStyle(.grouped)
        }
        .padding()
        .onChange(of: settings.useUnifiedColors) { _, _ in
            requestOverlayPreview()
        }
        .onChange(of: settings.textColor) { _, _ in
            guard settings.useUnifiedColors else { return }
            requestOverlayPreview()
        }
        .onChange(of: settings.backgroundColor) { _, _ in
            guard settings.useUnifiedColors else { return }
            requestOverlayPreview()
        }
    }

    private func positionLabel(_ value: Double, axis: String) -> String {
        if value < 0.3 {
            return axis == "X" ? "Left" : "Top"
        } else if value > 0.7 {
            return axis == "X" ? "Right" : "Bottom"
        } else {
            return "Center"
        }
    }

    private var previewView: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.gray.opacity(0.3))

                VStack(spacing: 4) {
                    Text("Desktop Name")
                        .font(previewFont(size: settings.fontSize * 0.4))
                        .foregroundStyle(settings.textColor)

                    if settings.showSpaceIndex {
                        Text("Desktop 1")
                            .font(previewFont(size: settings.fontSize * 0.2))
                            .foregroundStyle(settings.textColor.opacity(0.7))
                    }


                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(settings.backgroundColor)
                }
                .position(
                    x: geometry.size.width * settings.positionX,
                    y: geometry.size.height * settings.positionY
                )
            }
        }
    }

    private func previewFont(size: CGFloat) -> Font {
        if settings.fontName.isEmpty {
            return .system(size: size, weight: .medium, design: .rounded)
        } else {
            return .custom(settings.fontName, size: size)
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Toggle("Show for fullscreen apps", isOn: $settings.showForFullscreen)
            } header: {
                Text("Behavior")
            }

            Section {
                Text("Display settings and desktop names are stored per display configuration. Multi-display configurations can inherit settings from the built-in display profile or use independent settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Reset Current Profile to Defaults") {
                    settings.resetCurrentProfileToDefaults()
                }
            } header: {
                Text("Reset")
            }

            Section {
                HStack {
                    Text("Version")
                    Spacer()
                    Text("1.0.3")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Helper Methods

    private var profileModeBinding: Binding<ProfileMode> {
        Binding(
            get: { settings.profileMode },
            set: { newValue in
                settings.setProfileMode(newValue)
                // Re-sync SpaceConfigManager with new mode
                spaceConfigManager.setActiveProfile(
                    settings.currentConfiguration.id,
                    mode: settings.profileMode,
                    baseProfileID: settings.baseProfileID,
                    displayIDs: settings.currentConfiguration.orderedDisplayIDs
                )
                refreshSpaces()
            }
        )
    }

    private func binding(for space: SpaceInfo) -> Binding<String> {
        Binding(
            get: {
                spaceNames[space.id] ?? spaceConfigManager.getConfig(for: space).name
            },
            set: { newValue in
                spaceNames[space.id] = newValue
                spaceConfigManager.setName(newValue, for: space.id, displayIndex: space.index, displayID: space.displayID)
            }
        )
    }

    private func backgroundColorBinding(for space: SpaceInfo) -> Binding<Color> {
        Binding(
            get: {
                spaceBackgroundColors[space.id] ?? spaceConfigManager.getBackgroundColor(for: space) ?? settings.backgroundColor
            },
            set: { newValue in
                spaceBackgroundColors[space.id] = newValue
                let textColor = spaceTextColors[space.id] ?? spaceConfigManager.getTextColor(for: space)
                spaceConfigManager.setColors(backgroundColor: newValue, textColor: textColor, for: space.id, displayIndex: space.index, displayID: space.displayID)
                requestOverlayPreview(for: space)
            }
        )
    }

    private func textColorBinding(for space: SpaceInfo) -> Binding<Color> {
        Binding(
            get: {
                spaceTextColors[space.id] ?? spaceConfigManager.getTextColor(for: space) ?? settings.textColor
            },
            set: { newValue in
                spaceTextColors[space.id] = newValue
                let bgColor = spaceBackgroundColors[space.id] ?? spaceConfigManager.getBackgroundColor(for: space)
                spaceConfigManager.setColors(backgroundColor: bgColor, textColor: newValue, for: space.id, displayIndex: space.index, displayID: space.displayID)
                requestOverlayPreview(for: space)
            }
        )
    }

    private func requestOverlayPreview(for space: SpaceInfo? = nil) {
        DebugLog.log(
            "SettingsView",
            "requested overlay preview from settings",
            details: [
                "space": DebugLog.describe(space: space)
            ]
        )
        AppDelegate.shared?.showPreviewOverlay(for: space)
    }

    private func refreshSpaces() {
        spaces = SpaceIdentifier.shared.getAllSpaces().filter { !$0.isFullscreen }
        spaceConfigManager.syncWithCurrentSpaces()

        var nextSpaceNames: [UInt64: String] = [:]
        var nextBackgroundColors: [UInt64: Color] = [:]
        var nextTextColors: [UInt64: Color] = [:]

        // Rebuild cached values for the active profile so stale colors do not leak across profiles.
        for space in spaces {
            let config = spaceConfigManager.getConfig(for: space)
            nextSpaceNames[space.id] = config.name
            if let bgColor = config.backgroundColor?.color {
                nextBackgroundColors[space.id] = bgColor
            }
            if let txtColor = config.textColor?.color {
                nextTextColors[space.id] = txtColor
            }
        }

        spaceNames = nextSpaceNames
        spaceBackgroundColors = nextBackgroundColors
        spaceTextColors = nextTextColors
    }

    private func clearAllNames() {
        for space in spaces {
            spaceNames[space.id] = ""
            spaceBackgroundColors[space.id] = nil
            spaceTextColors[space.id] = nil
            spaceConfigManager.setName("", for: space.id, displayIndex: space.index, displayID: space.displayID)
            spaceConfigManager.setColors(backgroundColor: nil, textColor: nil, for: space.id, displayIndex: space.index, displayID: space.displayID)
        }
    }
}

#Preview {
    SettingsView()
        .frame(width: 480, height: 500)
}
