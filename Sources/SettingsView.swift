import SwiftUI

enum SettingsTab: String {
    case general, appearance, about
}

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            SwiftUI.Tab("General", systemImage: "gearshape", value: .general) {
                GeneralSettings()
            }
            SwiftUI.Tab("Appearance", systemImage: "paintpalette", value: .appearance) {
                AppearanceSettings()
            }
            SwiftUI.Tab("About", systemImage: "info.circle", value: .about) {
                AboutSettings()
            }
        }
        .frame(width: 500)
    }
}
