import SwiftUI

struct GeneralSettings: View {
    @AppStorage("terminalPanelPosition") private var panelPosition = PanelPosition.bottom

    var body: some View {
        Form {
            Section {
                Picker("Position", selection: $panelPosition) {
                    Text("Bottom").tag(PanelPosition.bottom)
                    Text("Right").tag(PanelPosition.right)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Terminal Panel")
            } footer: {
                Text("⌘J shows or hides the panel. ⌘T opens a new terminal in it.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 160)
    }
}
