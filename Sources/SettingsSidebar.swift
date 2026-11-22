import SwiftUI

struct SidebarSettings: View {
    @Environment(Store.self) private var store
    @AppStorage("sidebarPosition") private var sidebarPosition = SidebarPosition.left
    @AppStorage(PlanUsageFetch.enabledKey) private var showsPlanUsage = false
    @AppStorage(SidebarDensity.key) private var density = SidebarDensity.comfortable

    var body: some View {
        Form {
            Section {
                Picker("Position", selection: $sidebarPosition) {
                    Text("Left").tag(SidebarPosition.left)
                    Text("Right").tag(SidebarPosition.right)
                }
                .pickerStyle(.segmented)
                Picker("Density", selection: $density) {
                    ForEach(SidebarDensity.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                SidebarDensityPreview(density: density)
            } header: {
                Text("Layout")
            } footer: {
                Text("Compact shows one line per session, with the pull request beside the title.")
            }
            Section {
                Toggle("Show plan usage", isOn: $showsPlanUsage)
            } header: {
                Text("Usage")
            } footer: {
                Text("Shows the 5-hour and weekly limits with a pace marker. Berth reads Claude Code’s sign-in from the Keychain (macOS may ask once), asks Anthropic for your usage at most once a minute and never stores the token.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
        .onChange(of: showsPlanUsage) { Task { await store.refreshPlanUsage() } }
    }
}

private struct SidebarDensityPreview: View {
    let density: SidebarDensity

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach([("Fix rounding in invoice totals", "#4821"), ("Add the usage export endpoint", "#4790"), ("Tidy the CI pipeline", "")], id: \.0) { title, pullRequest in
                VStack(alignment: .leading, spacing: density.isCompact ? 0 : 4) {
                    HStack {
                        Text(title)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if density.isCompact {
                            Text(verbatim: pullRequest).font(.caption.monospaced())
                        }
                        Text(verbatim: "2m").font(.caption)
                    }
                    if !density.isCompact {
                        Text(verbatim: "billing · fix/rounding")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, density.rowPadding)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
        .accessibilityHidden(true)
    }
}
