import BerthCore
import GhosttyTerminal
import SwiftUI

struct Sidebar: View {
    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme
    @AppStorage("collapsedGroups") private var collapsedGroups = ""
    @AppStorage("archivedExpanded") private var isArchiveExpanded = false
    @State private var expandedGroups: Set<String> = []
    @State private var cursor: SidebarItem?
    @State private var renaming: CustomGroup?
    @State private var browseRoot: String?
    @FocusState private var isFocused: Bool

    private static let visibleSessions = 5
    static let collapsedByDefault: Set = ["recent:older"]

    private struct Group {
        let source: SessionGroup
        let count: Int
        let tabs: [Tab]
        let sessions: [SessionSummary]
        let hiddenSessions: Int
        var id: String { source.id }
    }

    var body: some View {
        ScrollViewReader { proxy in
            list
                .onChange(of: store.selection, initial: true) { _, selection in
                    cursor = nil
                    guard let selection else { return }
                    Task { withAnimation { proxy.scrollTo(selection) } }
                }
                .onChange(of: store.lockedSessionID) { _, id in
                    guard let id else { return }
                    Task { withAnimation { proxy.scrollTo(SidebarItem.session(id)) } }
                }
                .onChange(of: store.archivedSessions.last?.id, initial: true) { _, id in
                    guard Snapshot.scrollsToArchive, let id else { return }
                    Task { proxy.scrollTo(SidebarItem.session(id)) }
                }
                .onChange(of: cursor) { _, cursor in
                    guard let cursor else { return }
                    withAnimation { proxy.scrollTo(cursor) }
                }
        }
    }

    private var groups: [Group] {
        store.sidebarGroups.map { group, tabs in
            let isOpen = !isCollapsed(group.id)
            let sessions = expandedGroups.contains(group.id) ? group.sessions : Array(group.sessions.prefix(Self.visibleSessions))
            return Group(
                source: group,
                count: tabs.count + group.sessions.count,
                tabs: isOpen ? tabs : [],
                sessions: isOpen ? sessions : [],
                hiddenSessions: isOpen ? group.sessions.count - sessions.count : 0
            )
        }
    }

    private var items: [SidebarItem] {
        groups.flatMap { $0.tabs.map { SidebarItem.tab($0.id) } + $0.sessions.map { SidebarItem.session($0.id) } }
            + (isArchiveExpanded ? store.archivedSessions : []).map { SidebarItem.session($0.id) }
    }

    private var list: some View {
        let groups = groups
        let selection = cursor ?? store.selection ?? Snapshot.forcedSelection(in: store.groups)
        let archived = isArchiveExpanded ? store.archivedSessions : []
        let custom = groups.prefix { if case .custom = $0.source.kind { true } else { false } }
        return List {
            ForEach(custom, id: \.id) { section($0, selection: selection) }
            if !custom.isEmpty, custom.count < groups.count {
                Hairline(axis: .horizontal)
                    .padding(.top, 12)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .accessibilityHidden(true)
            }
            ForEach(groups.dropFirst(custom.count), id: \.id) { section($0, selection: selection) }
            if !store.archivedSessions.isEmpty {
                Section {
                    ForEach(archived) { session in
                        sessionRow(session, in: nil, selection: selection)
                            .contextMenu { Button("Unarchive") { store.unarchive(session.id) } }
                    }
                } header: {
                    GroupHeader(title: "Archived", help: "Archived sessions", count: store.archivedSessions.count, isExpanded: $isArchiveExpanded) { _ in EmptyView() }
                }
            }
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
        .fileImporter(isPresented: Binding(get: { browseRoot != nil }, set: { if !$0 { browseRoot = nil } }), allowedContentTypes: [.folder]) { result in
            guard case let .success(url) = result else { return }
            store.openClaude(cwd: url.path)
        }
        .fileDialogDefaultDirectory(browseRoot.map { URL(filePath: $0) })
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
                sessionRow(session, in: group.source, selection: selection)
                    .contextMenu {
                        if let tab = store.tab(forSession: session.id) { Button("Close Tab") { store.close(tab.id) } }
                        Button("Archive") { store.archive(session.id) }
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
            header(group)
        }
    }

    private func header(_ group: Group) -> some View {
        let source = group.source
        let custom: CustomGroup? = if case let .custom(custom) = source.kind { custom } else { nil }
        let singleFolder = source.folder ?? custom.flatMap { $0.rules.count == 1 && !$0.rules[0].includesSubfolders ? $0.rules[0].path : nil }
        return GroupHeader(
            title: source.title,
            help: source.folder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? custom.map { $0.rules.map { ($0.path as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ") } ?? source.title,
            count: group.count,
            isExpanded: expansion(of: group.id),
            renaming: custom != nil && renaming?.id == custom?.id ? $renaming : nil,
            commitRename: { store.save($0) }
        ) { isHovering in
            if let singleFolder {
                Button("New Session", systemImage: "plus") { store.openClaude(cwd: singleFolder) }
                    .help("New session in \(URL(filePath: singleFolder).lastPathComponent)")
                    .labelStyle(.iconOnly)
                    .buttonStyle(HeaderButtonStyle(isHeaderHovered: isHovering, theme: theme))
            } else if let custom {
                Menu {
                    startItems(custom)
                } label: {
                    Label("New Session", systemImage: "plus").labelStyle(.iconOnly)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(HeaderButtonStyle(isHeaderHovered: isHovering, theme: theme))
                .fixedSize()
                .help("New session in \(custom.name)")
            }
        }
        .contextMenu {
            if let custom {
                customGroupMenu(custom, singleFolder: singleFolder)
            } else if let folder = source.folder {
                folderGroupMenu(Array(Set(source.sessions.map(\.cwd)).union([folder])).sorted(), root: folder, title: source.title)
            }
        }
    }

    @ViewBuilder
    private func startItems(_ custom: CustomGroup) -> some View {
        let candidates = store.knownFolders.map(\.path).filter(custom.matches) + custom.rules.filter { !$0.includesSubfolders }.map(\.path)
        let folders = NSOrderedSet(array: candidates).array.compactMap { $0 as? String }.filter { FileManager.default.fileExists(atPath: $0) }
        Section("Start in") {
            ForEach(folders, id: \.self) { folder in
                Button(URL(filePath: folder).lastPathComponent) { store.openClaude(cwd: folder) }
            }
        }
        Section {
            ForEach(custom.rules.filter(\.includesSubfolders), id: \.path) { rule in
                Button("Other Folder in \(URL(filePath: rule.path).lastPathComponent)…") { browseRoot = rule.path }
            }
        }
    }

    @ViewBuilder
    private func customGroupMenu(_ custom: CustomGroup, singleFolder: String?) -> some View {
        let index = store.customGroups.firstIndex { $0.id == custom.id } ?? 0
        if let singleFolder {
            Button("New Session") { store.openClaude(cwd: singleFolder) }
        } else {
            Menu("New Session in") { startItems(custom) }
        }
        Divider()
        Button("Edit Group…") { store.editingGroup = custom }
        Button("Rename") { renaming = custom }
        if index > 0 { Button("Move Up") { store.moveGroup(custom.id, by: -1) } }
        if index < store.customGroups.count - 1 { Button("Move Down") { store.moveGroup(custom.id, by: 1) } }
        Divider()
        Button("Delete Group…", role: .destructive) { store.deletingGroup = custom }
    }

    @ViewBuilder
    private func folderGroupMenu(_ folders: [String], root: String, title: String) -> some View {
        Button("New Session") { store.openClaude(cwd: root) }
        Menu("Add to Group") {
            ForEach(store.customGroups) { custom in
                Button(custom.name) { for folder in folders { store.addFolder(folder, to: custom.id) } }
            }
            if !store.customGroups.isEmpty { Divider() }
            Button("New Group from \(title)…") { store.editingGroup = CustomGroup(name: title, rules: folders.map { FolderRule(path: $0, includesSubfolders: false) }) }
        }
        Divider()
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(root, forType: .string)
        }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: root)]) }
    }

    private func sessionRow(_ session: SessionSummary, in group: SessionGroup?, selection: SidebarItem?) -> some View {
        let tab = store.tab(forSession: session.id)
        return SessionRow(
            session: session,
            projectName: group.flatMap { $0.folder == session.cwd ? nil : URL(filePath: session.cwd).lastPathComponent },
            live: store.liveBySession[session.id],
            isOpen: tab != nil,
            pullRequestState: session.pullRequest.flatMap { store.pullRequestStates[$0.url] },
            showsLockedNotice: Binding(get: { store.lockedSessionID == session.id }, set: { if !$0 { store.lockedSessionID = nil } })
        )
        .modifier(RowChrome(id: session.title, isSelected: selection == .session(session.id), isLocked: tab == nil && store.liveBySession[session.id] != nil) {
            select(.session(session.id))
        })
        .id(SidebarItem.session(session.id))
    }

    private func isCollapsed(_ id: String) -> Bool {
        collapsedGroups.split(separator: "\n").contains { $0 == id } != Self.collapsedByDefault.contains(id)
    }

    private func expansion(of id: String) -> Binding<Bool> {
        Binding {
            !isCollapsed(id)
        } set: { expanded in
            let others = collapsedGroups.split(separator: "\n").filter { $0 != id }.map(String.init)
            let isListed = expanded == Self.collapsedByDefault.contains(id)
            collapsedGroups = (isListed ? others + [id] : others).joined(separator: "\n")
        }
    }
}

struct GroupingMenuItems: View {
    @Bindable var store: Store

    var body: some View {
        Picker("Group By", selection: $store.groupingMode) {
            ForEach(GroupingMode.allCases, id: \.self) { mode in
                Text(mode.title)
                    .tag(mode)
                    .keyboardShortcut(AppAction.groupBy(mode).shortcut)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        Divider()
        Toggle("Show Custom Groups", isOn: $store.showsCustomGroups)
    }
}

private struct GroupHeader<Accessory: View>: View {
    let title: String
    let help: String
    let count: Int
    @Binding var isExpanded: Bool
    var renaming: Binding<CustomGroup?>?
    var commitRename: (CustomGroup) -> Void = { _ in }
    @ViewBuilder let accessory: (Bool) -> Accessory
    @State private var isHovering = false
    @State private var name = ""
    @FocusState private var isNameFocused: Bool
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            if let renaming {
                chevron
                TextField("Group Name", text: $name)
                    .textFieldStyle(.plain)
                    .fontWeight(.semibold)
                    .focused($isNameFocused)
                    .onAppear {
                        name = title
                        isNameFocused = true
                    }
                    .onSubmit { commit(renaming) }
                    .onExitCommand { renaming.wrappedValue = nil }
                    .onChange(of: isNameFocused) { if !isNameFocused { commit(renaming) } }
            } else {
                Button {
                    withAnimation(.snappy) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        chevron
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
                .help(help)
                .accessibilityLabel("\(title), \(count) items, \(isExpanded ? "expanded" : "collapsed")")
            }
            Spacer(minLength: 4)
            accessory(isHovering)
        }
        .frame(height: 24)
        .font(.system(size: 11))
        .padding(.top, 16)
        .padding(.leading, -6)
        .padding(.trailing, 8)
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 4, trailing: 8))
        .onHover { isHovering = $0 }
        .onAppear { isHovering = Snapshot.forcedHover.contains(title) }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .foregroundStyle(theme.secondary)
            .frame(width: 16)
            .padding(.trailing, 4)
    }

    private func commit(_ renaming: Binding<CustomGroup?>) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if var group = renaming.wrappedValue, !trimmed.isEmpty {
            group.name = trimmed
            commitRename(group)
        }
        renaming.wrappedValue = nil
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
    let projectName: String?
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
                if session.pullRequest != nil || session.branch != nil || projectName != nil {
                    HStack(spacing: 8) {
                        if let projectName {
                            HStack(spacing: 4) {
                                Text(projectName)
                                    .foregroundStyle(theme.secondary)
                                if session.pullRequest != nil || session.branch != nil {
                                    Text(verbatim: "·")
                                        .foregroundStyle(theme.secondary.opacity(0.6))
                                }
                            }
                            .font(.caption)
                            .fixedSize()
                        }
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

struct CompactLabel: LabelStyle {
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

func age(since date: Date) -> String {
    let seconds = max(0, Int(Date.now.timeIntervalSince(date)))
    if seconds < 60 { return "now" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    if seconds < 86400 { return "\(seconds / 3600)h" }
    if seconds < 7 * 86400 { return "\(seconds / 86400)d" }
    return "\(seconds / (7 * 86400))w"
}
