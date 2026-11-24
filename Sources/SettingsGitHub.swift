import AppKit
import BerthCore
import SwiftUI

struct GitHubSettings: View {
    @Environment(Store.self) private var store
    @AppStorage(ProjectsModel.enabledKey) private var isEnabled = false
    @AppStorage(ProjectsModel.allowsEditingKey) private var allowsEditing = false

    var body: some View {
        Form {
            Section {
                Toggle("Show GitHub Projects", isOn: $isEnabled)
                    .onChange(of: isEnabled) {
                        if isEnabled { store.projects.refreshList() }
                    }
            } header: {
                Text("GitHub Projects")
            } footer: {
                Text("Adds a Project scope to the launcher. Berth asks the GitHub CLI (gh) for your projects and never writes unless you allow it below.")
            }

            if isEnabled {
                Section("Projects") {
                    projectNotice
                    let groups = Dictionary(grouping: store.projects.availableProjects, by: \.ownerLogin)
                    ForEach(groups.keys.sorted(), id: \.self) { owner in
                        Text(owner)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(groups[owner] ?? [], id: \.id) { project in
                            Toggle(isOn: Binding {
                                store.projects.selectedIDs.contains(project.id)
                            } set: { selected in
                                store.projects.select(project.id, isSelected: selected, persists: store.persistsTabs)
                            }) {
                                Text(project.title)
                                Text(verbatim: "\(project.ownerLogin) / #\(project.number)")
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }

                Section {
                    Toggle("Allow changing an item’s status", isOn: $allowsEditing)
                } header: {
                    Text("Changes")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Adds Move To Status to project items in the launcher. This needs the broader project permission.")
                        Text(ProjectQueries.writeScopeCommand)
                            .fontDesign(.monospaced)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: !isEnabled ? 175 : store.projects.state == .needsScope ? 660 : 510)
    }

    @ViewBuilder private var projectNotice: some View {
        switch store.projects.state {
        case .loading:
            ProgressView("Loading projects")
                .controlSize(.small)

        case .needsScope:
            VStack(alignment: .leading, spacing: 8) {
                Label("Berth needs the read:project permission", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                    .foregroundStyle(.orange)
                HStack {
                    Text(ProjectQueries.refreshScopeCommand)
                        .fontDesign(.monospaced)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ProjectQueries.refreshScopeCommand, forType: .string)
                    }
                }
                Text("Run it in a terminal, then come back. Berth never runs it for you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .noCLI:
            LabeledContent {
                Button("Retry") { store.projects.refreshList() }
            } label: {
                Text("Install the GitHub CLI (gh) and sign in")
            }

        case .failed:
            LabeledContent {
                Button("Retry") { store.projects.refreshList() }
            } label: {
                Text("Couldn’t reach GitHub")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .off, .ready:
            if store.projects.availableProjects.isEmpty {
                Text("No projects available")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
