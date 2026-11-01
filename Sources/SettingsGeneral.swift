import SwiftUI

struct GeneralSettings: View {
    static let unloadIdleKey = "unloadIdleSessionsAfter"

    @AppStorage("sidebarPosition") private var sidebarPosition = SidebarPosition.left
    @AppStorage(NeedsYouAlerts.notifiesKey) private var notifiesWhenNeeded = true
    @AppStorage(unloadIdleKey) private var unloadIdleAfter = 14_400.0

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
                Picker("Unload idle sessions after", selection: $unloadIdleAfter) {
                    Text("Never").tag(0.0)
                    Text("1 hour").tag(3_600.0)
                    Text("4 hours").tag(14_400.0)
                    Text("1 day").tag(86_400.0)
                }
            } header: {
                Text("Sessions")
            } footer: {
                Text("Unloaded sessions stay in the sidebar and resume when clicked. Pinned, working and waiting sessions stay loaded.")
            }
            Section {
                Picker("Position", selection: $sidebarPosition) {
                    Text("Left").tag(SidebarPosition.left)
                    Text("Right").tag(SidebarPosition.right)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Sidebar")
            }
        }
        .formStyle(.grouped)
        .frame(height: 376)
    }
}
