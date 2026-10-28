import BerthCore
import GhosttyTerminal
import SwiftUI

struct Sidebar: View {
    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme
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
        List(selection: Binding(get: { store.selection ?? Snapshot.forcedSelection(in: store.groups) }, set: { store.activate($0) })) {
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
        let isOpen = expansion(of: id)
        let visible = !isOpen.wrappedValue ? [] : isExpanded ? sessions : Array(sessions.prefix(Self.visibleSessions))
        return Section {
            ForEach(isOpen.wrappedValue ? tabs : []) { tab in
                TabRow(tab: tab, live: tab.sessionID.flatMap { store.liveBySession[$0] }, terminal: tab.terminal)
                    .tag(SidebarItem.tab(tab.id))
                    .id(SidebarItem.tab(tab.id))
                    .contextMenu { Button("Close Tab") { store.close(tab.id) } }
            }
            ForEach(visible) { session in
                let tab = store.tab(forSession: session.id)
                SessionRow(
                    session: session,
                    live: store.liveBySession[session.id],
                    isOpen: tab != nil,
                    pullRequestState: session.pullRequest.flatMap { store.pullRequestStates[$0.url] },
                    showsLockedNotice: Binding(get: { store.lockedSessionID == session.id }, set: { if !$0 { store.lockedSessionID = nil } })
                )
                    .tag(SidebarItem.session(session.id))
                    .id(SidebarItem.session(session.id))
                    .contextMenu {
                        if let tab { Button("Close Tab") { store.close(tab.id) } }
                    }
            }
            if isOpen.wrappedValue, sessions.count > Self.visibleSessions {
                Button(isExpanded ? "Show Less" : "Show \(sessions.count - Self.visibleSessions) More") {
                    if isExpanded { expandedGroups.remove(id) } else { expandedGroups.insert(id) }
                }
                .buttonStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(theme.secondary)
                .pointerStyle(.link)
                .selectionDisabled()
            }
        } header: {
            GroupHeader(
                title: title,
                cwd: cwd,
                count: tabs.count + sessions.count,
                isExpanded: isOpen,
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
    @Binding var isExpanded: Bool
    let newTerminal: () -> Void
    let newClaude: (() -> Void)?
    @State private var isHovering = false
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(theme.secondary.opacity(isHovering ? 1 : 0.6))
                        .frame(width: 12)
                    Text(title)
                        .fontWeight(.semibold)
                        .foregroundStyle(theme.secondary)
                        .lineLimit(1)
                    Text(count, format: .number)
                        .monospacedDigit()
                        .foregroundStyle(theme.secondary.opacity(0.6))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help(cwd)
            .accessibilityLabel("\(title), \(count) items, \(isExpanded ? "expanded" : "collapsed")")
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                Button("New Terminal", systemImage: "apple.terminal", action: newTerminal)
                    .help("New terminal in \(title)")
                if let newClaude {
                    Button("New Claude Session", systemImage: "plus", action: newClaude)
                        .help("New Claude session in \(title)")
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(HeaderButtonStyle(isHeaderHovered: isHovering, theme: theme))
        }
        .font(.system(size: 11))
        .padding(.top, 16)
        .onHover { isHovering = $0 }
        .onAppear { isHovering = Snapshot.forcedHover.contains(title) }
    }
}

private struct HeaderButtonStyle: ButtonStyle {
    let isHeaderHovered: Bool
    let theme: GhosttyTheme

    func makeBody(configuration: Configuration) -> some View {
        HeaderButton(configuration: configuration, isHeaderHovered: isHeaderHovered, theme: theme)
    }

    private struct HeaderButton: View {
        let configuration: ButtonStyleConfiguration
        let isHeaderHovered: Bool
        let theme: GhosttyTheme
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.body.weight(.medium))
                .foregroundStyle(isHeaderHovered ? theme.foreground : theme.secondary.opacity(0.6))
                .frame(width: 24, height: 24)
                .background(.quaternary.opacity(configuration.isPressed ? 2 : isHovering ? 1 : 0), in: .rect(cornerRadius: 8))
                .contentShape(.rect)
                .onHover { isHovering = $0 }
                .pointerStyle(.link)
        }
    }
}

private struct RowHover: ViewModifier {
    let id: String
    var isLocked = false
    @State private var isHovering: Bool

    init(id: String, isLocked: Bool = false) {
        self.id = id
        self.isLocked = isLocked
        _isHovering = State(initialValue: Snapshot.forcedHover.contains(id))
    }

    func body(content: Content) -> some View {
        content
            .contentShape(.rect)
            .onHover { isHovering = $0 }
            .pointerStyle(isLocked ? nil : .link)
            .listRowBackground(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(isHovering && !isLocked ? 0.6 : 0))
                    .padding(.horizontal, 8)
            )
    }
}

private enum RowState: Equatable {
    case working
    case needsYou(String?)

    init?(live: LiveSession?) {
        guard let live else { return nil }
        switch live.activity {
        case .working: self = .working
        case let .needsInput(reason): self = .needsYou(reason)
        case .idle: return nil
        }
    }
}

private struct SessionRow: View {
    let session: SessionSummary
    let live: LiveSession?
    let isOpen: Bool
    let pullRequestState: PullRequestState?
    @Binding var showsLockedNotice: Bool
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        let isLocked = live != nil && !isOpen
        CardRow(
            title: session.title,
            state: RowState(live: live),
            isLocked: isLocked,
            modified: session.modified,
            detail: {
                if session.pullRequest != nil || session.branch != nil {
                    HStack(spacing: 8) {
                        if let pullRequest = session.pullRequest {
                            PullRequestTag(link: pullRequest, state: pullRequestState)
                        }
                        if let branch = session.branch {
                            BranchText(branch: branch)
                        }
                    }
                } else if let prompt = session.lastPrompt {
                    Label(prompt, systemImage: "text.bubble")
                        .labelStyle(CompactLabel())
                        .font(.caption)
                        .foregroundStyle(theme.secondary)
                }
            }
        )
        .help(isLocked ? "Running in another terminal" : session.title)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isLocked ? "locked, running in another terminal" : "")
        .popover(isPresented: $showsLockedNotice, arrowEdge: .trailing) {
            Text("“\(session.title)” is running in another terminal. Quit it there to open it here, so the transcript isn’t written by two processes.")
                .font(.callout)
                .frame(width: 280)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
        }
        .modifier(RowHover(id: session.title, isLocked: isLocked))
    }
}

private struct TabRow: View {
    let tab: Tab
    let live: LiveSession?
    @ObservedObject var terminal: TerminalViewState
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        let title = tab.title(terminalTitle: terminal.title, sessionTitle: nil)
        Group {
            if tab.kind == .shell {
                Label {
                    Text(title).foregroundStyle(theme.foreground).lineLimit(1)
                } icon: {
                    Image(systemName: "apple.terminal").foregroundStyle(theme.secondary)
                }
                .padding(.vertical, 8)
            } else {
                CardRow(title: title, state: RowState(live: live), isLocked: false, modified: nil) {
                    Text("New session").font(.caption).foregroundStyle(theme.secondary)
                }
            }
        }
        .modifier(RowHover(id: tab.id.uuidString))
    }
}

private struct CardRow<Detail: View>: View {
    let title: String
    let state: RowState?
    let isLocked: Bool
    let modified: Date?
    @ViewBuilder let detail: Detail
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusSlot(state: state)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .foregroundStyle(theme.foreground)
                        .lineLimit(1)
                        .opacity(isLocked ? 0.6 : 1)
                    Spacer(minLength: 0)
                    if let modified {
                        Text(age(since: modified))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(theme.secondary)
                    }
                }
                ZStack(alignment: .leading) {
                    Color.clear
                    detail
                }
                .lineLimit(1)
                .frame(height: 16)
                    .opacity(isLocked ? 0.6 : 1)
            }
        }
        .padding(.vertical, 8)
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

private struct StatusSlot: View {
    let state: RowState?
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        ZStack {
            if state == .working {
                Image(systemName: "ellipsis")
                    .font(.system(size: 9, weight: .black))
                    .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeat(.continuous))
                    .foregroundStyle(theme.working)
                    .help("Working")
                    .accessibilityLabel("Working")
            } else if case let .needsYou(reason) = state {
                Circle()
                    .fill(theme.needsYou)
                    .frame(width: 8, height: 8)
                    .help("Needs you\(reason.map { ": \($0)" } ?? "")")
                    .accessibilityLabel("Needs you")
            }
        }
        .frame(width: 12, height: 16)
    }
}

private struct PullRequestTag: View {
    let link: PullRequestLink
    let state: PullRequestState?
    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var isHovering = false

    var body: some View {
        let color = color(for: state)
        Button {
            openURL(link.url)
        } label: {
            Label {
                Text(verbatim: "#\(link.number)")
            } icon: {
                Image(systemName: "arrow.triangle.pull")
            }
            .labelStyle(CompactLabel())
            .font(.caption.monospaced())
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(color.opacity(isHovering ? 0.28 : 0.16), in: .rect(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .pointerStyle(.link)
        .help("Open pull request #\(link.number)")
    }

    private func color(for state: PullRequestState?) -> Color {
        guard let state else { return theme.secondary }
        if state == .open { return theme.working }
        if state == .merged { return theme.merged }
        if state == .closed { return theme.closed }
        return theme.secondary
    }
}

private struct BranchText: View {
    let branch: String
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        Label(branch, systemImage: "arrow.triangle.branch")
            .labelStyle(CompactLabel())
            .font(.caption.monospaced())
            .foregroundStyle(theme.branch.opacity(0.8))
            .truncationMode(.middle)
            .layoutPriority(-1)
    }
}

private struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}
