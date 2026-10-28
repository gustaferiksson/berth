import BerthCore
import GhosttyTerminal
import SwiftUI

struct Sidebar: View {
    @Environment(Store.self) private var store
    @AppStorage("collapsedGroups") private var collapsedGroups = ""
    @State private var expandedGroups: Set<String> = []

    private static let visibleSessions = 5

    var body: some View {
        List(selection: Binding(get: { store.selection }, set: { store.activate($0) })) {
            ForEach(store.groups) { group in
                section(id: group.cwd, title: group.name, cwd: group.cwd, sessions: group.sessions)
            }
            let terminals = store.tabs.filter { tab in !store.groups.contains { $0.cwd == tab.cwd } }
            if !terminals.isEmpty {
                section(id: Store.terminalsGroupID, title: "Terminals", cwd: FileManager.default.homeDirectoryForCurrentUser.path, sessions: [])
            }
        }
        .overlay {
            if store.hasScanned, store.groups.isEmpty, store.tabs.isEmpty {
                ContentUnavailableView("No Claude Sessions", systemImage: "bubble.left.and.text.bubble.right", description: Text("Sessions you start with claude show up here, grouped by project."))
            }
        }
    }

    private func section(id: String, title: String, cwd: String, sessions: [SessionSummary]) -> some View {
        let listed = Set(sessions.map(\.id))
        let tabs = store.tabs.filter { tab in
            let inGroup = id == Store.terminalsGroupID ? !store.groups.contains { $0.cwd == tab.cwd } : tab.cwd == id
            return inGroup && !(tab.sessionID.map(listed.contains) ?? false)
        }
        let isExpanded = expandedGroups.contains(id)
        let visible = isExpanded ? sessions : Array(sessions.prefix(Self.visibleSessions))
        return Section(isExpanded: expansion(of: id)) {
            ForEach(tabs) { tab in
                TabRow(tab: tab, live: tab.sessionID.flatMap { store.liveBySession[$0] })
                    .tag(SidebarItem.tab(tab.id))
                    .contextMenu { Button("Close Tab") { store.close(tab.id) } }
            }
            ForEach(visible) { session in
                let tab = store.tab(forSession: session.id)
                SessionRow(session: session, live: store.liveBySession[session.id], isOpen: tab != nil)
                    .tag(SidebarItem.session(session))
                    .contextMenu {
                        if let tab { Button("Close Tab") { store.close(tab.id) } }
                    }
            }
            if sessions.count > Self.visibleSessions {
                Button(isExpanded ? "Show Less" : "Show \(sessions.count - Self.visibleSessions) More") {
                    if isExpanded { expandedGroups.remove(id) } else { expandedGroups.insert(id) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .selectionDisabled()
            }
        } header: {
            HStack(spacing: 4) {
                Text(title)
                    .lineLimit(1)
                    .help(cwd)
                Spacer()
                Button("New Terminal", systemImage: "apple.terminal") { store.openShell(cwd: cwd) }
                    .help("New terminal in \(title)")
                if id != Store.terminalsGroupID {
                    Button("New Claude Session", systemImage: "plus") { store.openClaude(cwd: cwd) }
                        .help("New Claude session in \(title)")
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
    }

    private func expansion(of id: String) -> Binding<Bool> {
        Binding {
            !collapsedGroups.split(separator: "\n").contains { $0 == id }
        } set: { expanded in
            let others = collapsedGroups.split(separator: "\n").filter { $0 != id }.map(String.init)
            collapsedGroups = (expanded ? others : others + [id]).joined(separator: "\n")
        }
    }
}

private struct SessionRow: View {
    let session: SessionSummary
    let live: LiveSession?
    let isOpen: Bool

    var body: some View {
        Label {
            HStack(spacing: 4) {
                Text(session.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                StatusBadge(live: live, isOpen: isOpen)
            }
        } icon: {
            Image(systemName: isOpen ? "bubble.left.fill" : "bubble.left")
        }
        .help("\(session.title)\n\(session.modified.formatted(.relative(presentation: .named)))")
    }
}

private struct TabRow: View {
    let tab: Tab
    let live: LiveSession?

    var body: some View {
        Label {
            HStack(spacing: 4) {
                TabTitle(terminal: tab.terminal, fallback: tab.kind == .shell ? "Terminal" : "New Claude Session")
                Spacer(minLength: 4)
                if tab.kind == .claude { StatusBadge(live: live, isOpen: true) }
            }
        } icon: {
            Image(systemName: tab.kind == .shell ? "apple.terminal" : "bubble.left.fill")
        }
    }
}

private struct TabTitle: View {
    @ObservedObject var terminal: TerminalViewState
    let fallback: String

    var body: some View {
        Text(terminal.title.isEmpty ? fallback : terminal.title)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

private struct StatusBadge: View {
    let live: LiveSession?
    let isOpen: Bool

    var body: some View {
        if let live, isOpen {
            switch live.activity {
            case .working:
                ProgressView()
                    .controlSize(.mini)
                    .help("Working")
            case let .needsInput(reason):
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                    .help("Needs you\(reason.map { ": \($0)" } ?? "")")
            case .idle:
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(.tint)
                    .help("Open in Berth")
            }
        } else if live != nil {
            Image(systemName: "arrow.up.forward.square")
                .foregroundStyle(.tertiary)
                .help("Running in another terminal")
        } else if isOpen {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(.tint)
                .help("Open in Berth")
        }
    }
}
