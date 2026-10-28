import BerthCore
import SwiftUI

struct GroupEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ghosttyTheme) private var theme
    @State var group: CustomGroup
    @State private var selectedPath: String?
    @State private var isImporting = false
    @FocusState private var isNameFocused: Bool

    private static let visibleChips = 4

    var body: some View {
        let isNew = !store.customGroups.contains { $0.id == group.id }
        let name = group.name.trimmingCharacters(in: .whitespaces)
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New Group" : "Edit Group")
                .font(.headline)
            Form {
                TextField("Name", text: $group.name, prompt: Text("Group Name"))
                    .focused($isNameFocused)
                LabeledContent("Folders") { folders }
                LabeledContent("Matches") { matches }
            }
            .formStyle(.columns)
            HStack {
                if !isNew {
                    Button("Delete Group…", role: .destructive) {
                        dismiss()
                        store.deletingGroup = group
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    group.name = name
                    store.save(group)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || group.rules.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result else { return }
            add(urls)
        }
        .onAppear { isNameFocused = group.name.isEmpty }
    }

    private var folders: some View {
        VStack(spacing: 0) {
            ForEach($group.rules, id: \.path) { $rule in
                let count = store.activeSessions.count { rule.matches($0.cwd) }
                HStack(spacing: 8) {
                    Text((rule.path as NSString).abbreviatingWithTildeInPath)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(count, format: .number)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Toggle("Subfolders", isOn: $rule.includesSubfolders)
                        .toggleStyle(.checkbox)
                }
                .padding(.horizontal, 8)
                .frame(height: 32)
                .background(theme.foreground.opacity(selectedPath == rule.path ? 0.1 : 0), in: .rect(cornerRadius: 4))
                .contentShape(.rect)
                .onTapGesture { selectedPath = rule.path }
            }
            if !group.rules.isEmpty { Divider() }
            HStack(spacing: 4) {
                Button("Add Folder…", systemImage: "plus") { isImporting = true }
                Button("Remove Folder", systemImage: "minus") {
                    group.rules.removeAll { $0.path == selectedPath }
                    selectedPath = nil
                }
                .disabled(selectedPath == nil)
                Spacer()
                Text(group.rules.isEmpty ? "Add or drop folders" : "Drop folders here")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .frame(height: 28)
        }
        .padding(4)
        .background(.quinary, in: .rect(cornerRadius: 8))
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return true
        }
    }

    private var matches: some View {
        let index = store.customGroups.firstIndex { $0.id == group.id } ?? store.customGroups.count
        let earlier = store.customGroups.prefix(index)
        let sessions = store.activeSessions.filter { session in group.matches(session.cwd) && !earlier.contains { $0.matches(session.cwd) } }
        let projects = Dictionary(grouping: sessions, by: \.cwd).sorted { $0.value.count > $1.value.count }
        return VStack(alignment: .leading, spacing: 8) {
            Text(sessions.isEmpty ? "No sessions yet" : "^[\(sessions.count) session](inflect: true) in ^[\(projects.count) project](inflect: true)")
                .fontWeight(.medium)
            if !projects.isEmpty {
                HStack(spacing: 4) {
                    ForEach(projects.prefix(Self.visibleChips), id: \.key) { folder, sessions in
                        HStack(spacing: 4) {
                            Text(URL(filePath: folder).lastPathComponent)
                            Text(sessions.count, format: .number).foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quinary, in: .capsule)
                        .help(folder)
                    }
                    if projects.count > Self.visibleChips {
                        Text("+\(projects.count - Self.visibleChips) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func add(_ urls: [URL]) {
        let known = Set(group.rules.map(\.path))
        let folders = urls.filter(\.hasDirectoryPath).map { $0.standardizedFileURL.path }.filter { !known.contains($0) }
        group.rules += Array(NSOrderedSet(array: folders)).compactMap { $0 as? String }.map { FolderRule(path: $0, includesSubfolders: false) }
    }
}
