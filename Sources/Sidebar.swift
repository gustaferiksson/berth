import BerthCore
import GhosttyTerminal
import SwiftUI

struct Sidebar: View {
    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme
    @AppStorage("collapsedGroups") private var collapsedGroups = ""
    @State private var expandedGroups: Set<String> = []
    @State private var cursor: SidebarItem?
    @FocusState private var isFocused: Bool

    private static let visibleSessions = 5

    private struct Group {
        let id: String
        let title: String
        let cwd: String
        let count: Int
        let tabs: [Tab]
        let sessions: [SessionSummary]
        let hiddenSessions: Int
    }

    var body: some View {
        ScrollViewReader { proxy in
            list
                .onChange(of: store.selection, initial: true) { _, selection in
                    cursor = nil
                    guard let selection else { return }
                    Task { withAnimation { proxy.scrollTo(selection) } }
                }
                .onChange(of: cursor) { _, cursor in
                    guard let cursor else { return }
                    withAnimation { proxy.scrollTo(cursor) }
                }
        }
    }

    private var groups: [Group] {
        let known = Set(store.groups.map(\.cwd))
        let newProjects = Array(Set(store.tabs.map(\.cwd).filter { !known.contains($0) })).sorted()
            .map { ProjectGroup(cwd: $0, sessions: [], lastActivity: .now) }
        return (newProjects + store.groups).map { group in
            let listed = Set(group.sessions.map(\.id))
            let isOpen = !isCollapsed(group.cwd)
            let sessions = expandedGroups.contains(group.cwd) ? group.sessions : Array(group.sessions.prefix(Self.visibleSessions))
            let tabs = store.tabs.filter { $0.cwd == group.cwd && !($0.sessionID.map(listed.contains) ?? false) }
            return Group(
                id: group.cwd,
                title: group.name,
                cwd: group.cwd,
                count: tabs.count + group.sessions.count,
                tabs: isOpen ? tabs : [],
                sessions: isOpen ? sessions : [],
                hiddenSessions: isOpen ? group.sessions.count - sessions.count : 0
            )
        }
    }

    private var list: some View {
        let groups = groups
        let selection = cursor ?? store.selection ?? Snapshot.forcedSelection(in: store.groups)
        let items = groups.flatMap { $0.tabs.map { SidebarItem.tab($0.id) } + $0.sessions.map { SidebarItem.session($0.id) } }
        return List {
            ForEach(groups, id: \.id) { section($0, selection: selection) }
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { move(by: 1, in: items) }
        .onKeyPress(.upArrow) { move(by: -1, in: items) }
        .onKeyPress(.return) {
            guard let cursor else { return .ignored }
            store.activate(cursor)
            return .handled
        }
        .onKeyPress(.leftArrow) { setExpanded(false, around: selection, in: groups) }
        .onKeyPress(.rightArrow) { setExpanded(true, around: selection, in: groups) }
        .onHover { store.isPointerInSidebar = $0 }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(OverlayScroller())
        .overlay {
            if store.hasScanned, store.groups.isEmpty, store.tabs.isEmpty {
                ContentUnavailableView("No Claude Sessions", systemImage: "bubble.left.and.text.bubble.right", description: Text("Sessions you start with claude show up here, grouped by project."))
            }
        }
    }

    private func move(by offset: Int, in items: [SidebarItem]) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }
        let current = (cursor ?? store.selection).flatMap(items.firstIndex(of:))
        let next = items[min(max((current ?? (offset > 0 ? -1 : items.count)) + offset, 0), items.count - 1)]
        if case let .session(id) = next, store.tab(forSession: id) == nil {
            cursor = next
        } else {
            store.activate(next)
        }
        return .handled
    }

    private func setExpanded(_ expanded: Bool, around item: SidebarItem?, in groups: [Group]) -> KeyPress.Result {
        guard let item, let group = groups.first(where: { group in
            group.tabs.contains { .tab($0.id) == item } || group.sessions.contains { .session($0.id) == item }
        }) else { return .ignored }
        expansion(of: group.id).wrappedValue = expanded
        return .handled
    }

    private func select(_ item: SidebarItem) {
        isFocused = true
        store.activate(item)
    }

    private func section(_ group: Group, selection: SidebarItem?) -> some View {
        Section {
            ForEach(group.tabs) { tab in
                TabRow(tab: tab, live: tab.sessionID.flatMap { store.liveBySession[$0] }, terminal: tab.terminal)
                    .modifier(RowChrome(id: tab.id.uuidString, isSelected: selection == .tab(tab.id), isLocked: false) { select(.tab(tab.id)) })
                    .id(SidebarItem.tab(tab.id))
                    .contextMenu { Button("Close Tab") { store.close(tab.id) } }
            }
            ForEach(group.sessions) { session in
                let tab = store.tab(forSession: session.id)
                SessionRow(
                    session: session,
                    live: store.liveBySession[session.id],
                    isOpen: tab != nil,
                    pullRequestState: session.pullRequest.flatMap { store.pullRequestStates[$0.url] },
                    showsLockedNotice: Binding(get: { store.lockedSessionID == session.id }, set: { if !$0 { store.lockedSessionID = nil } })
                )
                .modifier(RowChrome(id: session.title, isSelected: selection == .session(session.id), isLocked: tab == nil && store.liveBySession[session.id] != nil) {
                    select(.session(session.id))
                })
                .id(SidebarItem.session(session.id))
                .contextMenu {
                    if let tab { Button("Close Tab") { store.close(tab.id) } }
                }
            }
            if group.hiddenSessions > 0 || expandedGroups.contains(group.id) && !group.sessions.isEmpty {
                let isExpanded = expandedGroups.contains(group.id)
                Button(isExpanded ? "Show Less" : "Show \(group.hiddenSessions) More") {
                    if isExpanded { expandedGroups.remove(group.id) } else { expandedGroups.insert(group.id) }
                }
                .buttonStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(theme.secondary)
                .padding(.leading, 8)
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
            }
        } header: {
            GroupHeader(
                title: group.title,
                cwd: group.cwd,
                count: group.count,
                isExpanded: expansion(of: group.id),
                addLabel: "New Claude Session",
                add: { store.openClaude(cwd: group.cwd) }
            )
        }
    }

    private func isCollapsed(_ id: String) -> Bool {
        collapsedGroups.split(separator: "\n").contains { $0 == id }
    }

    private func expansion(of id: String) -> Binding<Bool> {
        Binding {
            !isCollapsed(id)
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
    let addLabel: String
    let add: () -> Void
    @State private var isHovering = false
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(theme.secondary)
                        .frame(width: 16)
                        .padding(.trailing, 4)
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
            .help(cwd)
            .accessibilityLabel("\(title), \(count) items, \(isExpanded ? "expanded" : "collapsed")")
            Spacer(minLength: 4)
            Button(addLabel, systemImage: "plus", action: add)
                .help("\(addLabel) in \(title)")
                .labelStyle(.iconOnly)
            .buttonStyle(HeaderButtonStyle(isHeaderHovered: isHovering, theme: theme))
        }
        .font(.system(size: 11))
        .padding(.top, 16)
        .padding(.leading, -6)
        .padding(.trailing, 8)
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 4, trailing: 8))
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
                .foregroundStyle(theme.secondary.opacity(isHeaderHovered ? 1 : 0.6))
                .frame(width: 24, height: 24)
                .background(theme.foreground.opacity(configuration.isPressed ? 0.12 : isHovering ? 0.06 : 0), in: .rect(cornerRadius: 8))
                .contentShape(.rect)
                .onHover { isHovering = $0 }
        }
    }
}

private struct RowChrome: ViewModifier {
    let id: String
    let isSelected: Bool
    let isLocked: Bool
    let select: () -> Void
    @State private var isHovering = false
    @Environment(\.ghosttyTheme) private var theme

    func body(content: Content) -> some View {
        let isHighlighted = isHovering || Snapshot.forcedHover.contains(id)
        let fill = isSelected ? 0.1 : isHighlighted && !isLocked ? 0.05 : 0
        content
            .contentShape(.rect)
            .onTapGesture(perform: select)
            .onHover { isHovering = $0 }
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, select)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            .listRowBackground(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.foreground.opacity(fill))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
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
            isLoaded: isOpen,
            modified: session.lastActivity,
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
                } else {
                    Text(verbatim: "–")
                        .font(.caption.monospaced())
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
            if tab.kind == .claude {
                CardRow(title: title, state: RowState(live: live), isLocked: false, isLoaded: true, modified: nil) {
                    Text(verbatim: "–").font(.caption.monospaced()).foregroundStyle(theme.secondary)
                }
            }
        }
    }
}

private struct CardRow<Detail: View>: View {
    let title: String
    let state: RowState?
    let isLocked: Bool
    let isLoaded: Bool
    let modified: Date?
    @ViewBuilder let detail: Detail
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let modified {
                    Text(age(since: modified))
                        .font(.caption.weight(isLoaded ? .medium : .regular))
                        .monospacedDigit()
                        .foregroundStyle(isLoaded ? theme.working : theme.secondary)
                }
            }
            ZStack(alignment: .leading) {
                Color.clear
                detail
            }
            .lineLimit(1)
            .frame(height: 16)
        }
        .opacity(isLocked ? 0.55 : 1)
        .padding(.leading, 8)
        .padding(.trailing, -8)
        .padding(.vertical, 8)
        .overlay(alignment: .topLeading) {
            StatusSlot(state: state).offset(x: -8, y: 8)
        }
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
                WorkingDots(label: "Working")
            } else if case let .needsYou(reason) = state {
                Circle()
                    .fill(theme.needsYou)
                    .frame(width: 8, height: 8)
                    .help("Needs you\(reason.map { ": \($0)" } ?? "")")
                    .accessibilityLabel("Needs you")
            }
        }
        .frame(width: 8, height: 16)
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

private struct OverlayScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            var candidates = view.window?.contentView.map { [$0] } ?? []
            while let next = candidates.popLast() {
                if let scrollView = next as? NSScrollView {
                    scrollView.scrollerStyle = .overlay
                    scrollView.autohidesScrollers = true
                    scrollView.tile()
                }
                candidates.append(contentsOf: next.subviews)
            }
        }
    }
}
