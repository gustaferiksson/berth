import SwiftUI

struct AppearanceSettings: View {
    @AppStorage("sidebarPosition") private var sidebarPosition = SidebarPosition.left
    @AppStorage("sidebarTwoLineRows") private var showsTwoLines = false
    @AppStorage(WindowBackdrop.transparencyKey) private var windowTransparency = 0.0
    @AppStorage(WindowBackdrop.backgroundKey) private var windowBackground = WindowBackground.theme
    @AppStorage(WindowBackdrop.matchesSidebarKey) private var matchesSidebarBackground = false

    var body: some View {
        Form {
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
                Text("Session rows show status, pull request and age on one line. Turn on Two-line rows to show the repository and branch below the title. Matching fills the sidebar and Review panel with the terminal theme’s background instead of the system material, so the window reads as one surface.")
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
        .frame(height: 520)
    }
}
