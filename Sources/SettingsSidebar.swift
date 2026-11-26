import SwiftUI

struct SidebarSettings: View {
    @Environment(Store.self) private var store
    @AppStorage(PlanUsageFetch.enabledKey) private var showsPlanUsage = false
    @AppStorage("showsSessionUsageDivisions") private var showsSessionUsageDivisions = false
    @AppStorage("showsWeeklyUsageDivisions") private var showsWeeklyUsageDivisions = false
    @AppStorage(ItemPreviewSetting.key) private var richPreviews = false

    var body: some View {
        Form {
            Section {
                Toggle("Show plan usage", isOn: $showsPlanUsage)
                Toggle("Divide session bar into hours", isOn: $showsSessionUsageDivisions)
                    .disabled(!showsPlanUsage)
                Toggle("Divide weekly bar into days", isOn: $showsWeeklyUsageDivisions)
                    .disabled(!showsPlanUsage)
            } header: {
                Text("Usage")
            } footer: {
                Text("Shows the 5-hour and weekly limits with a pace marker. Berth reads Claude Code’s sign-in from the Keychain (macOS may ask once), asks Anthropic for your usage at most once a minute and never stores the token. With Codex on, it adds Codex’s limits from your latest session, which only update while Codex runs.")
            }
            Section {
                Toggle("Rich previews", isOn: $richPreviews)
            } header: {
                Text("Previews")
            } footer: {
                Text("Hover a pull request in the sidebar or a row in the launcher, or press Space on a launcher row, for a preview with checks, reviews and the description. Berth asks GitHub through the gh CLI.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 470)
        .onChange(of: showsPlanUsage) {
            Task {
                await store.refreshPlanUsage()
                await store.refreshCodexUsage()
            }
        }
    }
}
