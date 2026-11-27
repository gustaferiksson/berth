import SwiftUI

enum AppearanceMode: String, CaseIterable {
    case system, light, dark

    static let key = "appearanceMode"
    static var stored: Self { Self(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

struct AppearanceSettings: View {
    @AppStorage(AppearanceMode.key) private var appearanceMode = AppearanceMode.system
    @AppStorage("sidebarPosition") private var sidebarPosition = SidebarPosition.left
    @AppStorage("sidebarTwoLineRows") private var showsTwoLines = false
    @AppStorage(WindowBackdrop.transparencyKey) private var windowTransparency = 0.0
    @AppStorage(WindowBackdrop.backgroundKey) private var windowBackground = WindowBackground.theme
    @AppStorage(WindowBackdrop.matchesSidebarKey) private var matchesSidebarBackground = false

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearanceMode) { NSApp.appearance = appearanceMode.appearance }
            } header: {
                Text("Theme")
            } footer: {
                Text("Picks the light or dark half of a Ghostty theme written as light:Name,dark:Name, and follows the system with System. A single theme keeps its own look.")
            }
            Section {
                Picker("Position", selection: $sidebarPosition) {
                    Text("Left").tag(SidebarPosition.left)
                    Text("Right").tag(SidebarPosition.right)
                }
                .pickerStyle(.segmented)
                Toggle("Two-line rows", isOn: $showsTwoLines)
                Toggle("Match sidebar and window background", isOn: $matchesSidebarBackground)
            } header: {
                Text("Sidebar")
            } footer: {
                Text("Session rows show status, pull request and age on one line. Turn on Two-line rows to show the repository and branch below the title. Matching fills the sidebar and Review panel with the terminal theme’s background instead of the system material, so the window reads as one surface. With the Glass window background, both stay glass.")
            }
            Section {
                Picker(selection: $windowBackground) {
                    ForEach(WindowBackground.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                } label: {
                    Text("Window Background")
                    Text("Theme uses the theme’s window colour. Glass adds Liquid Glass. Darker matches the cards.")
                }
                Slider(value: $windowTransparency, in: 0...WindowBackdrop.maxTransparency) {
                    Text("Window Transparency")
                    Text("Lets the desktop show through behind the sidebar and Review panel, and through the gaps around the cards with Theme or Darker.")
                } minimumValueLabel: {
                    Text("Opaque")
                } maximumValueLabel: {
                    Text("Clear")
                }
            } header: {
                Text("Window")
            }
        }
        .formStyle(.grouped)
        .frame(height: 600)
    }
}
