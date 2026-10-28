import SwiftUI

struct GeneralSettings: View {
    @AppStorage("terminalPanelPosition") private var panelPosition = PanelPosition.bottom
    @AppStorage(NeedsYouAlerts.notifiesKey) private var notifiesWhenNeeded = true

    var body: some View {
        Form {
            Section {
                Toggle("Notify when a session needs you", isOn: $notifiesWhenNeeded)
            } header: {
                Text("Notifications")
            } footer: {
                Text("The Dock icon always shows how many sessions need you.")
            }
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
        .frame(height: 280)
    }
}
