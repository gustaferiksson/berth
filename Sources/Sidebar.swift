import BerthCore
import GhosttyTerminal
import SwiftUI

struct Sidebar: View {
    @Environment(Store.self) private var store
    @AppStorage("collapsedGroups") private var collapsedGroups = ""
    @State private var expandedGroups: Set<String> = []

    private static let visibleSessions = 5

    var body: some View {
        ScrollViewReader { proxy in
            list.onChange(of: store.selection, initial: true) { _, selection in
                guard let selection else { return }
                Task { withAnimation { proxy.scrollTo(selection) } }
            }
        }
    }

    private var list: some View {
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
                TabRow(tab: tab, live: tab.sessionID.flatMap { store.liveBySession[$0] }, terminal: tab.terminal)
                    .tag(SidebarItem.tab(tab.id))
                    .id(SidebarItem.tab(tab.id))
                    .contextMenu { Button("Close Tab") { store.close(tab.id) } }
            }
            ForEach(visible) { session in
                let tab = store.tab(forSession: session.id)
                SessionRow(session: session, live: store.liveBySession[session.id], isOpen: tab != nil)
                    .tag(SidebarItem.session(session.id))
                    .id(SidebarItem.session(session.id))
                    .contextMenu {
                        if let tab { Button("Close Tab") { store.close(tab.id) } }
                    }
            }
            if sessions.count > Self.visibleSessions {
                Button(isExpanded ? "Show Less" : "Show \(sessions.count - Self.visibleSessions) More") {
                    if isExpanded { expandedGroups.remove(id) } else { expandedGroups.insert(id) }
                }
                .buttonStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .selectionDisabled()
            }
        } header: {
            GroupHeader(
                title: title,
                cwd: cwd,
                count: tabs.count + sessions.count,
                newTerminal: { store.openShell(cwd: cwd) },
                newClaude: id == Store.terminalsGroupID ? nil : { store.openClaude(cwd: cwd) }
            )
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

private struct GroupHeader: View {
    let title: String
    let cwd: String
    let count: Int
    let newTerminal: () -> Void
    let newClaude: (() -> Void)?
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .lineLimit(1)
                .help(cwd)
            Spacer(minLength: 4)
            ZStack(alignment: .trailing) {
                Text(count, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .opacity(isHovering ? 0 : 1)
                HStack(spacing: 4) {
                    Button("New Terminal", systemImage: "apple.terminal", action: newTerminal)
                        .help("New terminal in \(title)")
                    if let newClaude {
                        Button("New Claude Session", systemImage: "plus", action: newClaude)
                            .help("New Claude session in \(title)")
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .opacity(isHovering ? 1 : 0)
            }
        }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(count) items")
        .accessibilityAction(named: "New Terminal", newTerminal)
        .accessibilityAction(named: "New Claude Session") { newClaude?() }
    }
}

private enum RowState: Equatable {
    case working
    case needsYou(String?)
    case idle
    case elsewhere

    init?(live: LiveSession?, isOpen: Bool) {
        guard let live else { return nil }
        switch live.activity {
        case .working: self = .working
        case let .needsInput(reason): self = .needsYou(reason)
        case .idle: self = isOpen ? .idle : .elsewhere
        }
    }

    var word: String {
        switch self {
        case .working: "Working"
        case .needsYou: "Needs you"
        case .idle: "Idle"
        case .elsewhere: "Elsewhere"
        }
    }

    var isNeedsYou: Bool {
        if case .needsYou = self { return true }
        return false
    }
}

private struct SessionRow: View {
    let session: SessionSummary
    let live: LiveSession?
    let isOpen: Bool

    var body: some View {
        let state = RowState(live: live, isOpen: isOpen)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(session.title)
                    .fontWeight(state?.isNeedsYou == true ? .semibold : nil)
                    .foregroundStyle(state == .elsewhere ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Metadata(state: state, modified: session.modified, branch: session.branch)
            }
            Spacer(minLength: 0)
            StatusIndicator(state: state, isOpen: isOpen)
        }
        .padding(.vertical, 4)
        .help("\(session.title)\n\(session.modified.formatted(.relative(presentation: .named)))")
    }
}

private struct Metadata: View {
    let state: RowState?
    let modified: Date?
    let branch: String?

    var body: some View {
        HStack(spacing: 4) {
            if let state {
                Text(state.word)
                    .fontWeight(state.isNeedsYou ? .semibold : nil)
                    .foregroundStyle(state.isNeedsYou ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            if let modified {
                if state != nil { Text("·") }
                Text(age(since: modified))
                    .monospacedDigit()
            }
            if let branch {
                Text("·")
                Label(branch, systemImage: "arrow.triangle.branch")
                    .labelStyle(BranchLabelStyle())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func age(since modified: Date) -> String {
        let seconds = max(0, Int(Date.now.timeIntervalSince(modified)))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        if seconds < 7 * 86400 { return "\(seconds / 86400)d" }
        return "\(seconds / (7 * 86400))w"
    }
}

private struct BranchLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

private struct TabRow: View {
    let tab: Tab
    let live: LiveSession?
    @ObservedObject var terminal: TerminalViewState

    var body: some View {
        let title = Text(tab.title(terminalTitle: terminal.title, sessionTitle: nil))
            .lineLimit(1)
            .truncationMode(.tail)
        if tab.kind == .shell {
            Label { title } icon: { Image(systemName: "apple.terminal") }
        } else {
            let state = RowState(live: live, isOpen: true)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    title.fontWeight(state?.isNeedsYou == true ? .semibold : nil)
                    Metadata(state: state ?? .idle, modified: nil, branch: nil)
                }
                Spacer(minLength: 0)
                StatusIndicator(state: state, isOpen: true)
            }
            .padding(.vertical, 4)
        }
    }
}

private struct StatusIndicator: View {
    let state: RowState?
    let isOpen: Bool

    var body: some View {
        Group {
            switch state {
            case .working:
                Image(systemName: "ellipsis")
                    .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeat(.continuous))
                    .fontWeight(.bold)
                    .foregroundStyle(.tint)
                    .help("Working")
            case let .needsYou(reason):
                Image(systemName: "hand.raised.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .orange)
                    .font(.title3)
                    .help("Needs you\(reason.map { ": \($0)" } ?? "")")
            case .elsewhere:
                Image(systemName: "arrow.up.forward.square")
                    .foregroundStyle(.tertiary)
                    .help("Running in another terminal")
            case .idle, nil:
                if isOpen {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.tint)
                        .help("Open in Berth")
                }
            }
        }
        .frame(minWidth: 20)
    }
}
