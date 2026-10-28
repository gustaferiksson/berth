import SwiftUI

struct SettingsView: View {
    @AppStorage("terminalPanelPosition") private var panelPosition = PanelPosition.bottom

    var body: some View {
        TabView {
            SwiftUI.Tab("General", systemImage: "gearshape") {
                Form {
                    Picker("Terminal panel position", selection: $panelPosition) {
                        Text("Bottom").tag(PanelPosition.bottom)
                        Text("Right").tag(PanelPosition.right)
                    }
                    .pickerStyle(.segmented)
                }
                .formStyle(.grouped)
            }
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
