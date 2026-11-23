import BerthCore
import GhosttyTerminal
import SwiftUI
import UniformTypeIdentifiers

enum SidebarDensity: String, CaseIterable {
    case comfortable, compact

    static let key = "sidebarDensity"

    var title: String { rawValue.capitalized }
    var isCompact: Bool { self == .compact }
    var rowPadding: CGFloat { self == .comfortable ? 8 : 5 }
    var headerHeight: CGFloat { self == .comfortable ? 24 : 20 }
    var headerTopPadding: CGFloat { self == .comfortable ? 4 : 1 }
    var headerBottomInset: CGFloat { self == .comfortable ? 4 : 1 }
    var showMoreInset: CGFloat { self == .comfortable ? 4 : 1 }
    var suggestionBottomPadding: CGFloat { self == .comfortable ? 8 : 5 }
}

extension EnvironmentValues {
    @Entry var sidebarDensity = SidebarDensity.comfortable
    @Entry var headerInset: Double?
}

struct SidebarLayout: Equatable {
    enum Entry: Equatable, Identifiable {
        case session(String)
        case task(id: String, memberIDs: [String])

        var id: String {
            switch self {
            case let .session(id), let .task(id, _): id
            }
        }

        var memberIDs: [String] {
            guard case let .task(_, memberIDs) = self else { return [] }

            return memberIDs
        }

        var sessionCount: Int {
            guard case let .task(_, memberIDs) = self else { return 1 }

            return memberIDs.count
        }
    }

    struct Group: Equatable, Identifiable {
        let source: SessionGroup
        let tabIDs: [Tab.ID]
        let entries: [Entry]
        let visibleLimit: Int
        let folders: [String]
        var id: String { source.id }
    }

    let terminalIDs: [Tab.ID]
    let attentionIDs: [String]
    let workingIDs: [String]
    let unreadIDs: [String]
    let pinnedIDs: [String]
    let active: Group?
    let groups: [Group]
    let snoozedIDs: [String]
    let archivedIDs: [String]
    let isEmpty: Bool
    let isCaughtUp: Bool
    let showsTriage: Bool
    let filter: String
    let status: SidebarStatus
    let hasNoMatches: Bool
}

struct Sidebar: View, Equatable {
    @Environment(Store.self) private var store

    static let collapsedByDefault: Set = ["recent:older"]
    static let terminalsID = "terminals"
    static let attentionID = "attention"
    static let workingID = "working"
    static let unreadID = "unread"

    // Its property wrappers never compare equal, so SwiftUI would re-render it on every ContentView update.
    static func == (_: Self, _: Self) -> Bool { true }

    var body: some View {
        ScrollViewReader { proxy in
            SidebarList(layout: store.sidebarLayout)
                .equatable()
                .onChange(of: store.selection, initial: true) { previous, selection in
                    if previous != selection, store.sidebarCursor != nil { store.sidebarCursor = nil }
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
                .onChange(of: store.sidebarCursor) { _, cursor in
                    guard let cursor else { return }

                    withAnimation { proxy.scrollTo(cursor) }
                }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 8) {
                    UsageBar()
                    SidebarFilterField()
                }
            }
            .padding(10)
        }
    }
}

private struct SidebarFilterField: View {
    @Environment(Store.self) private var store
    @FocusState private var isFocused: Bool

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Filter", text: $store.sidebarFilter)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onKeyPress(.escape) {
                    if store.sidebarFilter.isEmpty, store.sidebarStatus == .all {
                        isFocused = false
                        store.focusSelected()
                    } else {
                        store.sidebarFilter = ""
                        store.sidebarStatus = .all
                    }
                    return .handled
                }
            if !store.sidebarFilter.isEmpty {
                Button("Clear Filter", systemImage: "xmark.circle.fill") { store.sidebarFilter = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Menu {
                Picker("Show", selection: $store.sidebarStatus) {
                    ForEach(SidebarStatus.allCases) { status in
                        let count = status == .all ? 0 : store.sidebarCount(status)
                        Label(count > 0 ? "\(status.title) (\(count))" : status.title, systemImage: status.symbol).tag(status)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: store.sidebarStatus == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(store.sidebarStatus == .all ? Color.secondary : Color.accentColor)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .accessibilityLabel("Show")
            .buttonStyle(.plain)
            .fixedSize()
            .help(store.sidebarStatus == .all ? "Show only the sessions a status dot marks: needs you, working, background shell, unread or flagged" : "Showing \(store.sidebarStatus.title.lowercased()) sessions")
        }
        .font(.body)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .glassEffect(.regular, in: .capsule)
        .onChange(of: store.sidebarFilterFocusRequests) { isFocused = true }
    }
}

private struct SidebarList: View, Equatable {
    let layout: SidebarLayout
    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme
    @AppStorage("collapsedGroups") private var collapsedGroups = ""
    @AppStorage("archivedExpanded") private var isArchiveExpanded = false
    @AppStorage("snoozedExpanded") private var isSnoozedExpanded = false
    @AppStorage(SidebarDensity.key) private var density = SidebarDensity.comfortable
    @Environment(\.sidebarRowSize) private var rowSize
    @State private var expandedGroups = Snapshot.expandedGroups
    @State private var renaming: CustomGroup?
    @State private var renamingTask: SessionTask?
    @State private var taskName = ""
    @State private var deletingTask: SessionTask?
    @State private var finishingTask: SessionTask?
    @State private var browseRoot: String?
    @FocusState private var isFocused: Bool

    private static let pinnedID = "pinned"

    private struct Group {
        let layout: SidebarLayout.Group
        let entries: [SidebarLayout.Entry]
        let hiddenSessions: Int
        var id: String { layout.id }
        var count: Int { layout.tabIDs.count + layout.entries.reduce(0) { $0 + $1.sessionCount } }
    }

    private enum Row: Hashable {
        case session(String)
        case task(String)
        case member(String)

        var item: SidebarItem {
            switch self {
            case let .session(id), let .member(id): .session(id)
            case let .task(id): .task(id)
            }
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.layout == rhs.layout }

    private var groups: [Group] {
        layout.groups.map(visible)
    }

    private var active: Group? {
        layout.active.map(visible)
    }

    private func visible(_ group: SidebarLayout.Group) -> Group {
        let entries = expandedGroups.contains(group.id) || !layout.filter.isEmpty ? group.entries : Array(group.entries.prefix(group.visibleLimit))
        return Group(layout: group, entries: entries, hiddenSessions: group.entries.count - entries.count)
    }

    private func rows(of entries: [SidebarLayout.Entry]) -> [Row] {
        entries.flatMap { entry -> [Row] in
            guard case let .task(id, memberIDs) = entry else { return [.session(entry.id)] }

            return [.task(id)] + (isCollapsed(id) ? [] : memberIDs.map(Row.member))
        }
    }

    private var activeItems: [SidebarItem] {
        guard let active, !isCollapsed(active.id) else { return [] }

        return active.layout.tabIDs.map(SidebarItem.tab) + rows(of: active.entries).map(\.item)
    }

    private var items: [SidebarItem] {
        let owners = (isCollapsed(Sidebar.terminalsID) ? [] : layout.terminalIDs).map(SidebarItem.tab)
            + (isCollapsed(Sidebar.attentionID) ? [] : layout.attentionIDs).map(SidebarItem.session)
            + activeItems
            + (isCollapsed(Sidebar.workingID) ? [] : layout.workingIDs).map(SidebarItem.session)
            + (isCollapsed(Sidebar.unreadID) ? [] : layout.unreadIDs).map(SidebarItem.session)
            + (isCollapsed(Self.pinnedID) ? [] : layout.pinnedIDs).map(SidebarItem.session)
            + groups.filter { !isCollapsed($0.id) }.flatMap { $0.layout.tabIDs.map(SidebarItem.tab) + rows(of: $0.entries).map(\.item) }
            + (isSnoozedExpanded ? layout.snoozedIDs : []).map(SidebarItem.session)
            + (isArchiveExpanded ? layout.archivedIDs : []).map(SidebarItem.session)
        return owners.flatMap { item -> [SidebarItem] in
            let parent: Tab.ID? = if case let .tab(id) = item {
                id
            } else if case let .session(id) = item {
                store.tab(forSession: id)?.id
            } else {
                nil
            }
            guard let parent else { return [item] }

            return [item] + store.tabs.filter { $0.parentTabID == parent }.map { .tab($0.id) }
        }
    }

    var body: some View {
        let groups = groups
        List {
            if !layout.terminalIDs.isEmpty {
                terminalsSection
            }
            if !layout.attentionIDs.isEmpty {
                Section(isExpanded: expansion(of: Sidebar.attentionID)) {
                    ForEach(layout.attentionIDs, id: \.self) { id in
                        SessionItem(id: id, place: .triage, select: select)
                            .id(SidebarItem.session(id))
                    }
                } header: {
                    GroupHeader(title: layout.showsTriage ? "Needs You" : "Needs Attention", help: "Needs you or your PR has failing checks", count: layout.attentionIDs.count, tint: theme.needsYou) { EmptyView() } accessory: { _ in EmptyView() }
                }
            }
            if let active {
                section(active, at: 0, in: [])
            }
            if layout.isCaughtUp {
                caughtUp
            }
            triageSection(Sidebar.workingID, title: "Working", help: "Sessions that are working", ids: layout.workingIDs, tint: theme.working)
            triageSection(Sidebar.unreadID, title: "Unread", help: "Sessions with replies you haven’t seen", ids: layout.unreadIDs, tint: nil)
            if !layout.pinnedIDs.isEmpty {
                Section(isExpanded: expansion(of: Self.pinnedID)) {
                    ForEach(Array(layout.pinnedIDs.enumerated()), id: \.element) { index, id in
                        SessionItem(id: id, place: .pinned, select: select)
                            .id(SidebarItem.session(id))
                            .draggable(PinDrag(id: id))
                            .modifier(GroupDropTarget<PinDrag>(indicatorOffset: 0) { movePin($0, onto: index) })
                    }
                } header: {
                    GroupHeader(title: "Pinned", help: "Pinned sessions", count: layout.pinnedIDs.count) { EmptyView() } accessory: { _ in EmptyView() }
                }
            }
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                section(group, at: index, in: groups)
            }
            if groups.contains(where: { $0.layout.source.custom != nil }) {
                Color.clear
                    .frame(height: 12)
                    .modifier(GroupDropTarget<GroupDrag>(indicatorOffset: 2) { moveGroup($0, to: groups.count, in: groups) })
                    .listRowInsets(EdgeInsets())
                    .accessibilityHidden(true)
            }
            if !layout.snoozedIDs.isEmpty {
                Section(isExpanded: $isSnoozedExpanded) {
                    ForEach(layout.snoozedIDs, id: \.self) { id in
                        SessionItem(id: id, place: .snoozed, select: select)
                            .id(SidebarItem.session(id))
                    }
                } header: {
                    GroupHeader(title: "Snoozed", help: "Snoozed sessions", count: layout.snoozedIDs.count) { EmptyView() } accessory: { _ in EmptyView() }
                }
            }
            if !layout.archivedIDs.isEmpty {
                Section(isExpanded: $isArchiveExpanded) {
                    ForEach(layout.archivedIDs, id: \.self) { id in
                        SessionItem(id: id, place: .archived, select: select)
                            .id(SidebarItem.session(id))
                    }
                } header: {
                    GroupHeader(title: "Done", help: "Done sessions", count: layout.archivedIDs.count) { EmptyView() } accessory: { _ in EmptyView() }
                }
            }
        }
        .environment(\.sidebarDensity, density)
        .environment(\.sidebarRowSize, density.isCompact ? .small : rowSize)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow, phases: [.down, .repeat]) { $0.modifiers.contains(.shift) ? extend(by: 1, in: items) : move(by: 1, in: items) }
        .onKeyPress(.upArrow, phases: [.down, .repeat]) { $0.modifiers.contains(.shift) ? extend(by: -1, in: items) : move(by: -1, in: items) }
        .onKeyPress(.return) {
            guard let item = store.sidebarCursor ?? store.selection else { return .ignored }

            store.activate(item)
            return .handled
        }
        .onKeyPress(keys: ["e"], phases: .down) { press in
            guard press.modifiers.isEmpty else { return .ignored }

            return markDone()
        }
        .onKeyPress(.escape) {
            guard !store.multiSelection.isEmpty || store.sidebarStatus != .all || !store.sidebarFilter.isEmpty else { return .ignored }

            store.multiSelection = []
            store.sidebarStatus = .all
            store.sidebarFilter = ""
            return .handled
        }
        .alert("Rename Task", isPresented: Binding(get: { renamingTask != nil }, set: { if !$0 { renamingTask = nil } })) {
            TextField("Task Name", text: $taskName)
            Button("Rename") { if let task = renamingTask { store.renameTask(task.id, to: taskName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(deletingTask?.title ?? "")”?", isPresented: Binding(get: { deletingTask != nil }, set: { if !$0 { deletingTask = nil } }), presenting: deletingTask) { task in
            Button("Delete Task", role: .destructive) { store.deleteTask(task.id) }
        } message: { _ in
            Text("Its sessions stay where they are and the task won’t form again from the same issue or pull request. No transcripts are deleted.")
        }
        .confirmationDialog("Mark “\(finishingTask?.title ?? "")” as Done?", isPresented: Binding(get: { finishingTask != nil }, set: { if !$0 { finishingTask = nil } }), presenting: finishingTask) { task in
            Button("Mark Task as Done") { store.markTaskDone(task.id) }
        } message: { task in
            let working = task.sessions.count { store.liveBySession[$0.id]?.activity == .working }
            Text("^[\(working) session](inflect: true) \(working == 1 ? "is" : "are") still working. Marking the task as done closes them.")
        }
        .onKeyPress(.leftArrow) { setExpanded(false, in: groups) }
        .onKeyPress(.rightArrow) { setExpanded(true, in: groups) }
        .onHover { store.isPointerInSidebar = $0 }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .fileImporter(isPresented: Binding(get: { browseRoot != nil }, set: { if !$0 { browseRoot = nil } }), allowedContentTypes: [.folder]) { result in
            guard case let .success(url) = result else { return }

            store.openSession(cwd: url.path)
        }
        .fileDialogDefaultDirectory(browseRoot.map { URL(filePath: $0) })
        .overlay {
            if layout.hasNoMatches, layout.filter.isEmpty {
                ContentUnavailableView("No \(layout.status.title) Sessions", systemImage: layout.status.symbol)
            } else if layout.hasNoMatches {
                ContentUnavailableView.search(text: layout.filter)
            } else if layout.isEmpty {
                ContentUnavailableView("No Claude Sessions", systemImage: "bubble.left.and.text.bubble.right", description: Text("Sessions you start with claude show up here, grouped by project."))
            }
        }
    }

    @ViewBuilder
    private func triageSection(_ id: String, title: String, help: String, ids: [String], tint: Color?) -> some View {
        if !ids.isEmpty {
            Section(isExpanded: expansion(of: id)) {
                ForEach(ids, id: \.self) { id in
                    SessionItem(id: id, place: .triage, select: select)
                        .id(SidebarItem.session(id))
                }
            } header: {
                GroupHeader(title: title, help: help, count: ids.count, tint: tint) { EmptyView() } accessory: { _ in EmptyView() }
            }
        }
    }

    private var caughtUp: some View {
        VStack(spacing: 2) {
            Text("All caught up")
                .font(.headline)
            Text("Nothing needs you right now")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
    }

    private func markDone() -> KeyPress.Result {
        if store.multiSelection.isEmpty, case let .task(id) = store.sidebarCursor ?? store.selection, let task = store.sessionTasks.first(where: { $0.id == id }) {
            markDone(task)
            return .handled
        }

        let selected = store.multiSelection.isEmpty ? [store.sidebarCursor ?? store.selection].compactMap { item -> String? in
            guard case let .session(id) = item else { return nil }

            return id
        } : store.multiSelectedSessions.map(\.id)
        let done = selected.filter { id in store.activeSessions.contains { $0.id == id } }
        guard !done.isEmpty else { return .ignored }

        for id in done { store.archive(id) }
        return .handled
    }

    private func markDone(_ task: SessionTask) {
        guard task.sessions.contains(where: { store.liveBySession[$0.id]?.activity == .working }) else { return store.markTaskDone(task.id) }

        finishingTask = task
    }

    private func move(by offset: Int, in items: [SidebarItem]) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }

        if !store.multiSelection.isEmpty { store.multiSelection = [] }

        let current = (store.sidebarCursor ?? store.selection).flatMap(items.firstIndex(of:))
        let next = items[min(max((current ?? (offset > 0 ? -1 : items.count)) + offset, 0), items.count - 1)]
        let tab: Tab? = switch next {
        case let .tab(id): store.tabs.first { $0.id == id }
        case let .session(id): store.tab(forSession: id)
        case .task: nil
        }
        guard let tab else {
            store.sidebarCursor = next
            return .handled
        }

        store.selectedTabID = tab.id
        store.isHarborShown = false
        return .handled
    }

    private func extend(by offset: Int, in items: [SidebarItem]) -> KeyPress.Result {
        guard let lead = store.multiSelection.last ?? store.sidebarCursor ?? store.selection, let index = items.firstIndex(of: lead) else { return .ignored }

        store.extendMultiSelection(to: items[min(max(index + offset, 0), items.count - 1)], in: items)
        return .handled
    }

    private func setExpanded(_ expanded: Bool, in groups: [Group]) -> KeyPress.Result {
        let item = store.sidebarCursor ?? store.selection
        if layout.terminalIDs.contains(where: { .tab($0) == item }) {
            expansion(of: Sidebar.terminalsID).wrappedValue = expanded
            return .handled
        }
        if case let .session(id) = item, layout.attentionIDs.contains(id) {
            expansion(of: Sidebar.attentionID).wrappedValue = expanded
            return .handled
        }
        if case let .session(id) = item, layout.workingIDs.contains(id) {
            expansion(of: Sidebar.workingID).wrappedValue = expanded
            return .handled
        }
        if case let .session(id) = item, layout.unreadIDs.contains(id) {
            expansion(of: Sidebar.unreadID).wrappedValue = expanded
            return .handled
        }
        if case let .session(id) = item, layout.pinnedIDs.contains(id) {
            expansion(of: Self.pinnedID).wrappedValue = expanded
            return .handled
        }
        if case let .task(id) = item {
            expansion(of: id).wrappedValue = expanded
            return .handled
        }
        if !expanded, case let .session(sessionID) = item, let task = groups.flatMap(\.layout.entries).first(where: { $0.memberIDs.contains(sessionID) }) {
            expansion(of: task.id).wrappedValue = false
            store.sidebarCursor = .task(task.id)
            return .handled
        }
        guard let item, let group = groups.first(where: { group in
            group.layout.tabIDs.contains { .tab($0) == item } || group.layout.entries.contains { entry in
                if case let .session(id) = item { entry.id == id || entry.memberIDs.contains(id) } else { false }
            }
        }) else { return .ignored }

        expansion(of: group.id).wrappedValue = expanded
        return .handled
    }

    private func select(_ item: SidebarItem) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift) {
            store.extendMultiSelection(to: item, in: items)
            isFocused = true
            return
        }
        if modifiers.contains(.command) {
            store.toggleMultiSelection(item)
            isFocused = true
            return
        }

        store.activate(item)
        if store.selection != item { isFocused = true }
    }

    private func moveGroup(_ id: String, to destination: Int, in groups: [Group]) -> Bool {
        guard let source = groups.firstIndex(where: { $0.id == id && $0.layout.source.custom != nil }) else { return false }

        withAnimation(.snappy) { store.moveGroup(from: source, to: destination) }
        return true
    }

    private func movePin(_ id: String, onto index: Int) -> Bool {
        withAnimation(.snappy) { store.movePin(id, onto: index) }
        return true
    }

    private var terminalsSection: some View {
        Section(isExpanded: expansion(of: Sidebar.terminalsID)) {
            ForEach(layout.terminalIDs, id: \.self) { id in
                TabItem(id: id, select: select)
                    .environment(\.sidebarDensity, .compact)
                    .id(SidebarItem.tab(id))
            }
        } header: {
            GroupHeader(title: "Terminals", help: "Terminals", count: layout.terminalIDs.count) { EmptyView() } accessory: { isHovering in
                Button("New Terminal", systemImage: "plus") { store.newTerminal() }
                    .help("New terminal (⌘T)")
                    .labelStyle(.iconOnly)
                    .buttonStyle(HeaderButtonStyle(isHeaderHovered: isHovering, theme: theme))
            }
        }
    }

    private func section(_ group: Group, at index: Int, in groups: [Group]) -> some View {
        Section(isExpanded: expansion(of: group.id)) {
            ForEach(group.layout.tabIDs, id: \.self) { id in
                TabItem(id: id, select: select)
                    .id(SidebarItem.tab(id))
            }
            ForEach(rows(of: group.entries), id: \.self) { row in
                switch row {
                case let .session(id):
                    SessionItem(id: id, place: .group(folder: group.layout.source.folder), select: select)
                        .id(SidebarItem.session(id))

                case let .task(id):
                    TaskItem(id: id, isExpanded: expansion(of: id), select: select, rename: { renamingTask = $0; taskName = $0.title }, markDone: markDone, delete: { deletingTask = $0 })
                        .id(SidebarItem.task(id))

                case let .member(id):
                    SessionItem(id: id, place: .task, select: select)
                        .id(SidebarItem.session(id))
                }
            }
            if group.hiddenSessions > 0 || expandedGroups.contains(group.id) && group.entries.count > group.layout.visibleLimit {
                let isExpanded = expandedGroups.contains(group.id)
                Button(isExpanded ? "Show Less" : "Show \(group.hiddenSessions) More") {
                    if isExpanded { expandedGroups.remove(group.id) } else { expandedGroups.insert(group.id) }
                }
                .buttonStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
                .padding(.leading, 8)
                .listRowInsets(EdgeInsets(top: density.showMoreInset, leading: 8, bottom: density.showMoreInset, trailing: 8))
            }
        } header: {
            header(group, at: index, in: groups)
        }
    }

    private func header(_ group: Group, at index: Int, in groups: [Group]) -> some View {
        let source = group.layout.source
        let custom = source.custom
        let singleFolder = source.folder ?? custom.flatMap { $0.rules.count == 1 && !$0.rules[0].includesSubfolders ? $0.rules[0].path : nil }
        return GroupHeader(
            title: source.title,
            help: source.folder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? custom.map { $0.rules.map { ($0.path as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ") } ?? source.title,
            count: group.count,
            renaming: custom != nil && renaming?.id == custom?.id ? $renaming : nil,
            commitRename: { store.save($0) },
            dragID: custom.map { _ in source.id },
            drop: { moveGroup($0, to: index, in: groups) },
            menu: {
                if let custom {
                    customGroupMenu(custom, at: index, of: groups.count, singleFolder: singleFolder)
                } else if let folder = source.folder {
                    folderGroupMenu(group.layout.folders, root: folder, title: source.title)
                }
            },
            accessory: { isHovering in
                if let singleFolder {
                    Button("New Session", systemImage: "plus") { store.openSession(cwd: singleFolder) }
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
        )
    }

    @ViewBuilder
    private func startItems(_ custom: CustomGroup) -> some View {
        let candidates = store.knownFolders.map(\.path).filter(custom.matches) + custom.rules.filter { !$0.includesSubfolders }.map(\.path)
        let folders = NSOrderedSet(array: candidates).array.compactMap { $0 as? String }.filter { FileManager.default.fileExists(atPath: $0) }
        Section("Start in") {
            ForEach(folders, id: \.self) { folder in
                Button(URL(filePath: folder).lastPathComponent) { store.openSession(cwd: folder) }
            }
        }
        Section {
            ForEach(custom.rules.filter(\.includesSubfolders), id: \.path) { rule in
                Button("Other Folder in \(URL(filePath: rule.path).lastPathComponent)…") { browseRoot = rule.path }
            }
        }
    }

    @ViewBuilder
    private func customGroupMenu(_ custom: CustomGroup, at index: Int, of count: Int, singleFolder: String?) -> some View {
        if let singleFolder {
            Button("New Session") { store.openSession(cwd: singleFolder) }
        } else {
            Menu("New Session in") { startItems(custom) }
        }
        Divider()
        Button("Edit Group…") { store.editingGroup = custom }
        Button("Rename") { renaming = custom }
        if index > 0 { Button("Move Up") { store.moveGroup(from: index, to: index - 1) } }
        if index < count - 1 { Button("Move Down") { store.moveGroup(from: index, to: index + 2) } }
        Divider()
        Button("Delete Group…", role: .destructive) { store.deletingGroup = custom }
    }

    @ViewBuilder
    private func folderGroupMenu(_ folders: [String], root: String, title: String) -> some View {
        Button("New Session") { store.openSession(cwd: root) }
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

    private func isCollapsed(_ id: String) -> Bool {
        if !layout.filter.isEmpty { return false }

        return collapsedGroups.split(separator: "\n").contains { $0 == id } != Sidebar.collapsedByDefault.contains(id)
    }

    private func expansion(of id: String) -> Binding<Bool> {
        Binding {
            !isCollapsed(id)
        } set: { expanded in
            let others = collapsedGroups.split(separator: "\n").filter { $0 != id }.map(String.init)
            let isListed = expanded == Sidebar.collapsedByDefault.contains(id)
            collapsedGroups = (isListed ? others + [id] : others).joined(separator: "\n")
        }
    }
}

private struct OwnedTerminalItems: View {
    let parent: Tab.ID?
    let indent: Double
    let select: (SidebarItem) -> Void
    @Environment(Store.self) private var store

    var body: some View {
        if let parent {
            ForEach(store.tabs.filter { $0.parentTabID == parent }) { tab in
                TabRow(tab: tab, live: nil, terminal: tab.terminal) { store.close(tab.id) }
                    .padding(.leading, indent)
                    .modifier(RowChrome(item: .tab(tab.id), hoverID: tab.id.uuidString, isLocked: false, indent: indent) { select(.tab(tab.id)) })
                    .help((tab.folder as NSString).abbreviatingWithTildeInPath)
                    .contextMenu {
                        Button("Close Terminal") { store.close(tab.id) }
                    }
                    .environment(\.sidebarDensity, .compact)
                    .id(SidebarItem.tab(tab.id))
            }
        }
    }
}

private struct TabItem: View {
    let id: Tab.ID
    let select: (SidebarItem) -> Void
    @Environment(Store.self) private var store

    var body: some View {
        let tab = store.tabs.first { $0.id == id }
        Group {
            HStack(spacing: 0) {
                if let tab, tab.kind == .shell {
                    TabRow(tab: tab, live: nil, terminal: tab.terminal) { store.close(tab.id) }
                        .help((tab.folder as NSString).abbreviatingWithTildeInPath)
                } else if let tab {
                    TabRow(tab: tab, live: tab.sessionID.flatMap { store.liveBySession[$0] }, terminal: tab.terminal)
                }
            }
            .modifier(RowChrome(item: .tab(id), hoverID: id.uuidString, isLocked: false) { select(.tab(id)) })
            .help(tab?.kind == .shell ? (tab?.folder as NSString?)?.abbreviatingWithTildeInPath ?? "" : "")
            .contextMenu {
                if store.multiSelection.contains(.tab(id)) {
                    MultiSelectionMenu()
                } else if tab?.kind == .shell {
                    Button("Close Terminal") { store.close(id) }
                } else {
                    Button("New Terminal") { store.newTerminal(for: id) }
                    Button("Unload Session") { store.close(id) }
                    if let sessionID = tab?.sessionID { CopySessionIDButton(sessionID: sessionID) }
                }
            }
            OwnedTerminalItems(parent: id, indent: 16, select: select)
        }
    }
}

private struct SessionItem: View {
    enum Place: Equatable {
        case triage
        case pinned
        case group(folder: String?)
        case task
        case snoozed
        case archived
    }

    let id: String
    let place: Place
    private static let taskIndent = 16.0
    let select: (SidebarItem) -> Void
    @Environment(Store.self) private var store
    @Environment(\.sidebarDensity) private var density

    var body: some View {
        let session = store.sessionsByID[id]
        let tab = store.tab(forSession: id)
        let live = store.liveBySession[id]
        let isLocked = tab == nil && store.isLockedElsewhere(live)
        let suggestion = store.taskSuggestions[id]
        let suggestionLabel = suggestion.flatMap(suggestionText)
        let pullRequests = session.map(store.pullRequests(of:)) ?? []
        Group {
            VStack(alignment: .leading, spacing: 0) {
                if let session {
                    SessionRow(
                        session: session,
                        projectName: place == .archived || place == .group(folder: session.checkout) ? nil : URL(filePath: session.checkout).lastPathComponent,
                        live: live,
                        isOpen: tab != nil,
                        isLocked: isLocked,
                        hasBackgroundShell: store.backgroundShellIDs.contains(id),
                        isUnread: store.isUnread(session),
                        isFlagged: store.flaggedIDs.contains(id),
                        context: tab != nil || live != nil ? session.context : nil,
                        pullRequest: pullRequests.first.map { link in
                            var pullRequest = link.pullRequest
                            if pullRequest.checks == .passed { pullRequest.checks = nil }
                            return pullRequest
                        },
                        morePullRequests: max(pullRequests.count - 1, 0),
                        suggestion: suggestionLabel,
                        issue: place == .task ? nil : store.sessionTasks.first { $0.sessions.count == 1 && $0.sessions[0].id == id }?.issue,
                        showsLockedNotice: Binding(get: { store.lockedSessionID == id }, set: { if !$0 { store.lockedSessionID = nil } })
                    )
                    .modifier(SessionHoverTrigger(session: session, pullRequests: pullRequests, context: tab != nil || live != nil ? session.context : nil, isNoticeShown: store.lockedSessionID == id, store: store))
                    .padding(.leading, place == .task ? Self.taskIndent : 0)
                    if let suggestion, let suggestionLabel, !density.isCompact {
                        SuggestionLine(text: suggestionLabel, accept: { store.accept(suggestion) }, dismiss: { store.dismiss(suggestion) })
                            .padding(.leading, place == .task ? Self.taskIndent : 0)
                    }
                }
            }
            .modifier(RowChrome(item: .session(id), hoverID: session?.title ?? id, isLocked: isLocked, indent: place == .task ? Self.taskIndent : 0) {
                select(.session(id))
            })
            .opacity(place == .snoozed ? 0.6 : 1)
            .help(place == .snoozed ? snoozeHelp : "")
            .contextMenu {
                if store.multiSelection.contains(.session(id)) {
                    MultiSelectionMenu()
                } else if place == .archived {
                    if let tab { Button("New Terminal") { store.newTerminal(for: tab.id) } }
                    Button("Mark as Not Done") { store.unarchive(id) }
                    if store.task(containing: id) != nil { Button("Mark Task as Not Done") { store.markTaskNotDone(containing: id) } }
                    flagButton
                    Divider()
                    CopySessionIDButton(sessionID: id)
                } else if let session {
                    menu(session, tab: tab)
                }
            }
            OwnedTerminalItems(parent: tab?.id, indent: place == .task ? Self.taskIndent * 2 : Self.taskIndent, select: select)
        }
    }

    private func suggestionText(_ suggestion: TaskSuggestion) -> String? {
        guard let taskID = suggestion.taskID else { return "Make a task from \(suggestion.sessionIDs.count + 1) sessions?" }

        return store.sessionTasks.first { $0.id == taskID }.map { "Join “\($0.title)”?" }
    }

    private var snoozeHelp: String {
        guard case let .until(date) = store.snooze(of: id) else { return "Back when it needs you" }

        return "Back \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    @ViewBuilder
    private func menu(_ session: SessionSummary, tab: Tab?) -> some View {
        if place == .snoozed { Button("Unsnooze") { store.unsnooze(id) } }
        if let tab {
            Button("New Terminal") { store.newTerminal(for: tab.id) }
            Button("Unload Session") { store.close(tab.id) }
        }
        if place == .pinned {
            Button("Unpin") { store.unpin(id) }
        } else {
            Button("Pin") { store.pin(id) }
        }
        if store.isUnread(session) {
            Button("Mark as Read") { store.markRead(id) }
        } else if store.selection != .session(id) {
            Button("Mark as Unread") { store.markUnread(id) }
        }
        flagButton
        if place == .triage, store.canDismissAttention(session) { Button("Dismiss") { store.dismissAttention(id) } }
        Button("Mark as Done") { store.archive(id) }
        Menu("Snooze") {
            Button("1 Hour") { store.snooze(id, .until(.now.addingTimeInterval(3600))) }
            Button("Tomorrow") { store.snooze(id, .until(SessionTriage.tomorrowMorning(after: .now))) }
            Button("Until It Needs You") { store.snooze(id, .needsYou) }
        }
        if store.task(containing: id) != nil || store.taskSuggestions[id] != nil {
            Divider()
            if store.task(containing: id) != nil { Button("Remove from Task") { store.removeFromTask(id) } }
            if let suggestion = store.taskSuggestions[id], let text = suggestionText(suggestion) {
                Button(String(text.dropLast())) { store.accept(suggestion) }
                Button("Not Related") { store.dismiss(suggestion) }
            }
        }
        Divider()
        CopySessionIDButton(sessionID: id)
    }

    @ViewBuilder private var flagButton: some View {
        if store.flaggedIDs.contains(id) {
            Button("Unflag") { store.unflag(id) }
        } else {
            Button("Flag") { store.flag(id) }
        }
    }
}

struct MultiSelectionMenu: View {
    @Environment(Store.self) private var store

    var body: some View {
        ForEach(Array(Self.actions(in: store).enumerated()), id: \.offset) { _, action in
            Button(action.title, action: action.perform)
        }
    }

    static func actions(in store: Store) -> [(title: String, perform: () -> Void)] {
        let tabs = store.multiSelectedTabs
        let claudeTabs = tabs.filter { $0.kind == .claude }
        let terminals = tabs.filter { $0.kind == .shell }
        let sessions = store.multiSelectedSessions
        let active = sessions.filter { session in store.activeSessions.contains { $0.id == session.id } }
        let pinned = store.pinnedSessions.filter { session in active.contains { $0.id == session.id } }
        let unpinned = store.groups.flatMap(\.sessions).filter { session in active.contains { $0.id == session.id } }
        let unread = active.filter(store.isUnread)
        let read = active.filter { !store.isUnread($0) && store.selection != .session($0.id) }
        let flagged = sessions.filter { store.flaggedIDs.contains($0.id) }
        let unflagged = sessions.filter { !store.flaggedIDs.contains($0.id) }
        let actions: [(title: String.LocalizationValue, count: Int, perform: () -> Void)] = [
            ("Unload ^[\(claudeTabs.count) Session](inflect: true)", claudeTabs.count, { for tab in claudeTabs { store.close(tab.id) } }),
            ("Close ^[\(terminals.count) Terminal](inflect: true)", terminals.count, { for tab in terminals { store.close(tab.id) } }),
            ("Pin ^[\(unpinned.count) Session](inflect: true)", unpinned.count, { for session in unpinned { store.pin(session.id) } }),
            ("Unpin ^[\(pinned.count) Session](inflect: true)", pinned.count, { for session in pinned { store.unpin(session.id) } }),
            ("Mark ^[\(unread.count) Session](inflect: true) as Read", unread.count, { for session in unread { store.markRead(session.id) } }),
            ("Mark ^[\(read.count) Session](inflect: true) as Unread", read.count, { for session in read { store.markUnread(session.id) } }),
            ("Flag ^[\(unflagged.count) Session](inflect: true)", unflagged.count, { for session in unflagged { store.flag(session.id) } }),
            ("Unflag ^[\(flagged.count) Session](inflect: true)", flagged.count, { for session in flagged { store.unflag(session.id) } }),
            ("Mark ^[\(active.count) Session](inflect: true) as Done", active.count, { for session in active { store.archive(session.id) } }),
            ("New Task from ^[\(active.count) Session](inflect: true)", active.count > 1 ? active.count : 0, { store.newTask(from: active.map(\.id)) }),
        ]
        return actions.filter { $0.count > 0 }.map { (String(AttributedString(localized: $0.title).characters), $0.perform) }
    }
}

private struct CopySessionIDButton: View {
    let sessionID: String

    var body: some View {
        Button("Copy Session ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(sessionID, forType: .string)
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
        Toggle("Show Triage", isOn: $store.showsTriage)
    }
}

struct GroupHeader<Menu: View, Accessory: View>: View {
    let title: String
    let help: String
    let count: Int?
    var tint: Color?
    var renaming: Binding<CustomGroup?>?
    var commitRename: (CustomGroup) -> Void = { _ in }
    var dragID: String?
    var drop: ((String) -> Bool)?
    var isExpanded: Binding<Bool>?
    @ViewBuilder let menu: () -> Menu
    @ViewBuilder let accessory: (Bool) -> Accessory
    @State private var isHovering = false
    @State private var restingWidth = 0.0
    @State private var name = ""
    @FocusState private var isNameFocused: Bool
    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.sidebarDensity) private var density
    @Environment(\.headerInset) private var inset

    var body: some View {
        Group {
            if let dragID, renaming == nil {
                label.draggable(GroupDrag(id: dragID))
            } else {
                label
            }
        }
        .font(.subheadline)
        .padding(.top, density.headerTopPadding)
        .padding(.leading, inset ?? -6)
        .padding(.trailing, inset ?? 6)
        .modifier(GroupDropTarget<GroupDrag>(indicatorOffset: 0, drop: drop))
        .listRowInsets(EdgeInsets(top: 0, leading: inset == nil ? 8 : 0, bottom: density.headerBottomInset, trailing: inset == nil ? 8 : 0))
        .listRowSeparator(inset == nil ? .automatic : .hidden)
        .onGeometryChange(for: Double.self) { $0.size.width } action: { width in
            if !isHovering || restingWidth == 0 { restingWidth = width }
        }
        .onHover { isHovering = $0 }
        .onAppear { isHovering = Snapshot.forcedHover.contains(title) }
    }

    @ViewBuilder private var label: some View {
        if let isExpanded {
            Button { isExpanded.wrappedValue.toggle() } label: { row }
                .buttonStyle(.plain)
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 4) {
            if let renaming {
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
                Text(title)
                    .fontWeight(.semibold)
                    .foregroundStyle(tint ?? Color.secondary)
                    .lineLimit(1)
                    .help(help)
                if let count {
                    Text(count, format: .number)
                        .monospacedDigit()
                        .foregroundStyle((tint ?? Color.secondary).opacity(0.6))
                }
            }
            Spacer(minLength: 4)
            accessory(isHovering)
            if let isExpanded {
                Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 10)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: isExpanded == nil && restingWidth > 0 ? restingWidth - 25 : nil, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: density.headerHeight)
        .contentShape([.interaction, .dragPreview], .rect(cornerRadius: 8))
        .contextMenu(menuItems: menu)
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

private struct GroupDrag: Codable, Transferable, Identifiable {
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "dev.gustaf.berth.group"))
    }
}

private struct PinDrag: Codable, Transferable, Identifiable {
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "dev.gustaf.berth.pin"))
    }
}

private struct GroupDropTarget<Drag: Transferable & Identifiable<String>>: ViewModifier {
    let indicatorOffset: Double
    let drop: ((String) -> Bool)?
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if isTargeted {
                    HStack(spacing: 0) {
                        Circle()
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .frame(width: 8, height: 8)
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(height: 2)
                    }
                    .padding(.top, indicatorOffset)
                    .allowsHitTesting(false)
                }
            }
            .dropDestination(for: Drag.self) { drags, _ in
                drags.first.flatMap { drop?($0.id) } ?? false
            } isTargeted: { targeted in
                isTargeted = drop != nil && targeted
            }
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
                .foregroundStyle(Color.secondary.opacity(isHeaderHovered ? 1 : 0.6))
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(configuration.isPressed ? 0.12 : isHovering ? 0.06 : 0), in: .rect(cornerRadius: 8))
                .contentShape(.rect)
                .onHover { isHovering = $0 }
        }
    }
}

private struct RowChrome: ViewModifier {
    let item: SidebarItem
    let hoverID: String
    let isLocked: Bool
    var indent = 0.0
    let select: () -> Void
    @State private var isHovering = false
    @Environment(Store.self) private var store

    private var isSelected: Bool {
        if !store.multiSelection.isEmpty { return store.multiSelection.contains(item) }
        if let cursor = store.sidebarCursor { return cursor == item }
        if case let .session(id) = item { return store.tabs.first { $0.id == store.selectedTabID }?.sessionID == id }
        return item == store.selectedTabID.map(SidebarItem.tab)
    }

    func body(content: Content) -> some View {
        let isSelected = isSelected
        let isHighlighted = isHovering || Snapshot.forcedHover.contains(hoverID)
        let fill = isSelected ? 0.1 : isHighlighted && !isLocked ? 0.05 : 0
        content
            .contentShape(.rect)
            .onTapGesture(perform: select)
            .onHover { isHovering = $0 }
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, select)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            .listRowBackground(
                RowFill(opacity: fill, indent: indent)
            )
    }
}

struct RowFill: View {
    let opacity: Double
    var indent = 0.0
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(opacity))
            .padding(.leading, 8 + indent)
            .padding(.trailing, 8)
            .padding(.vertical, 2)
            .background(alignment: .leading) {
                if indent > 0 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 1)
                        .padding(.leading, 19.5)
                }
            }
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
        case .idle, .shell: return nil
        }
    }
}

private struct SessionRow: View {
    let session: SessionSummary
    let projectName: String?
    let live: LiveSession?
    let isOpen: Bool
    let isLocked: Bool
    let hasBackgroundShell: Bool
    let isUnread: Bool
    let isFlagged: Bool
    let context: SessionContext?
    let pullRequest: PullRequest?
    let morePullRequests: Int
    let suggestion: String?
    let issue: IssueRef?
    @Binding var showsLockedNotice: Bool
    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.sidebarDensity) private var density

    var body: some View {
        CardRow(
            title: session.title,
            state: RowState(live: live),
            isLocked: isLocked,
            modified: session.lastPrompt,
            isOpen: isOpen,
            hasBackgroundShell: hasBackgroundShell,
            isUnread: isUnread,
            isFlagged: isFlagged,
            context: context,
            issue: issue,
            detail: {
                if density.isCompact {
                    HStack(spacing: 6) {
                        if let suggestion {
                            Image(systemName: "sparkle")
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                                .help(suggestion)
                                .accessibilityLabel(suggestion)
                        }
                        if let pullRequest {
                            PullRequestTag(pullRequest: pullRequest, more: morePullRequests)
                                .fixedSize()
                        }
                    }
                } else if pullRequest != nil || session.branch != nil || projectName != nil {
                    let branch = session.branch
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            if let projectName {
                                HStack(spacing: 4) {
                                    ViewThatFits(in: .horizontal) {
                                        Text(projectName)
                                        ZStack(alignment: .leading) {
                                            Text(verbatim: projectName.count > 4 ? "\(projectName.prefix(4))…" : projectName)
                                                .fixedSize()
                                                .hidden()
                                            Text(projectName)
                                                .truncationMode(.tail)
                                        }
                                    }
                                    .foregroundStyle(Color.secondary)
                                    if branch != nil {
                                        Text(verbatim: "·")
                                            .foregroundStyle(Color.secondary.opacity(0.6))
                                            .fixedSize()
                                            .offset(y: -1)
                                    }
                                }
                                .font(.caption)
                                .layoutPriority(1)
                            }
                            if let branch {
                                BranchText(branch: branch)
                                    .frame(minWidth: 48, alignment: .leading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if let pullRequest {
                            PullRequestTag(pullRequest: pullRequest, more: morePullRequests)
                                .fixedSize()
                        }
                    }
                } else {
                    Text(verbatim: "–")
                        .font(.caption.monospaced())
                        .foregroundStyle(Color.secondary)
                }
            }
        )
        .help(isLocked ? "Running in another terminal" : "")
        .accessibilityElement(children: .combine)
        .accessibilityValue([session.agent.harness.isOptIn ? session.agent.harness.name : nil, isLocked ? "locked, running in another terminal" : nil].compactMap(\.self).joined(separator: ", "))
        .popover(isPresented: $showsLockedNotice, arrowEdge: .trailing) {
            Text("“\(session.title)” is running in another terminal. Quit it there to open it here, so the transcript isn’t written by two processes.")
                .font(.callout)
                .frame(width: 280)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
        }
    }
}

private struct TaskItem: View {
    let id: String
    @Binding var isExpanded: Bool
    let select: (SidebarItem) -> Void
    let rename: (SessionTask) -> Void
    let markDone: (SessionTask) -> Void
    let delete: (SessionTask) -> Void
    @Environment(Store.self) private var store

    var body: some View {
        let task = store.sessionTasks.first { $0.id == id }
        // A layout container makes the row one static view, so List builds only the visible rows.
        HStack(spacing: 0) {
            if let task {
                TaskRow(
                    task: task,
                    isExpanded: isExpanded,
                    state: states(of: task),
                    isUnread: task.sessions.contains(where: store.isUnread)
                )
            }
        }
        .modifier(RowChrome(item: .task(id), hoverID: task?.title ?? id, isLocked: false) {
            isExpanded.toggle()
            if NSApp.currentEvent?.clickCount == 2 { store.activate(.task(id)) }
        })
        .contextMenu {
            if let task {
                Button("Rename Task…") { rename(task) }
                Button("Mark Task as Done") { markDone(task) }
                if let done = task.sessions.first, store.task(containing: done.id)?.sessionIDs.contains(where: { id in store.archivedSessions.contains { $0.id == id } }) == true {
                    Button("Mark Task as Not Done") { store.markTaskNotDone(containing: done.id) }
                }
                Divider()
                Button("Delete Task…", role: .destructive) { delete(task) }
            }
        }
    }

    private func states(of task: SessionTask) -> RowState? {
        let states = task.sessions.compactMap { RowState(live: store.liveBySession[$0.id]) }
        return states.contains(.working) ? .working : states.first
    }
}

private struct TaskRow: View {
    let task: SessionTask
    let isExpanded: Bool
    let state: RowState?
    let isUnread: Bool
    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.sidebarDensity) private var density

    var body: some View {
        CardRow(
            title: task.title,
            state: isExpanded ? nil : state,
            isLocked: false,
            modified: task.sessions[0].lastPrompt,
            isUnread: !isExpanded && isUnread,
            chevron: isExpanded ? "chevron.down" : "chevron.right",
            issue: task.issue
        ) {
            if density.isCompact {
                Text(task.sessions.count, format: .number)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Color.secondary)
                    .fixedSize()
                    .help("^[\(task.sessions.count) session](inflect: true)")
            } else {
                Text("^[\(task.sessions.count) session](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
        }
        .help(task.title)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
    }
}

struct IssueTag: View {
    let issue: IssueRef
    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var isHovering = false

    var body: some View {
        let state = store.state(of: issue)
        let color = state.color(in: theme)
        Button {
            if let url = issue.url { openURL(url) }
        } label: {
            Label {
                Text(verbatim: "#\(issue.number)")
            } icon: {
                Image(systemName: state.symbol)
            }
            .labelStyle(CompactLabel())
            .font(.caption.monospaced())
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(isHovering ? 0.28 : 0.16), in: .capsule)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .pointerStyle(.link)
        .help("Open issue \(issue.repository)#\(String(issue.number))")
    }
}

struct IssueStatePill: View {
    let issue: IssueRef
    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var isHovering = false

    var body: some View {
        let state = store.state(of: issue)
        let color = state.color(in: theme)
        HStack(spacing: 6) {
            Button {
                if let url = issue.url { openURL(url) }
            } label: {
                Label(state.title, systemImage: state.symbol)
                    .labelStyle(CompactLabel())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(color.opacity(isHovering ? 0.28 : 0.16), in: .capsule)
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .pointerStyle(.link)
            Text(verbatim: "#\(issue.number)")
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(Color.secondary)
            Spacer(minLength: 0)
        }
        .help("Open issue \(issue.repository)#\(String(issue.number))")
    }
}

extension IssueState? {
    func color(in theme: GhosttyTheme) -> Color {
        if self == .open { return theme.working }
        if self == .completed { return theme.merged }
        return Color.secondary
    }

    var symbol: String {
        if self == .completed { return "checkmark.circle" }
        if self == .notPlanned { return "slash.circle" }
        return "smallcircle.filled.circle"
    }

    var title: String {
        if self == .open { return "Open" }
        if self == .completed { return "Completed" }
        if self == .notPlanned { return "Not planned" }
        return "Issue"
    }
}

private struct SuggestionLine: View {
    let text: String
    let accept: () -> Void
    let dismiss: () -> Void
    @State private var isHovering = false
    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.sidebarDensity) private var density

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Group {
                Button("Accept", systemImage: "checkmark", action: accept)
                    .help("Accept")
                Button("Not Related", systemImage: "xmark", action: dismiss)
                    .help("Not related")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .opacity(isHovering || Snapshot.forcedHover.contains(text) ? 1 : 0)
            .allowsHitTesting(isHovering)
        }
        .font(.caption)
        .foregroundStyle(Color.secondary)
        .padding(.leading, 8)
        .padding(.top, -4)
        .padding(.bottom, density.suggestionBottomPadding)
        .onHover { isHovering = $0 }
    }
}

private struct TabRow: View {
    let tab: Tab
    let live: LiveSession?
    @ObservedObject var terminal: TerminalViewState
    var close: (() -> Void)?
    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.sidebarDensity) private var density

    var body: some View {
        let title = tab.title(terminalTitle: terminal.title, sessionTitle: nil)
        if tab.kind == .claude {
            CardRow(title: title, state: RowState(live: live), isLocked: false, modified: nil, isOpen: true) {
                if !density.isCompact { Text(verbatim: "–").font(.caption.monospaced()).foregroundStyle(Color.secondary) }
            }
            .accessibilityValue(tab.agent.harness.isOptIn ? tab.agent.harness.name : "")
        } else {
            CardRow(title: title, state: title == terminal.title ? .working : nil, isLocked: false, modified: nil, isTerminal: true, close: close) {
                let folder = (tab.folder as NSString).abbreviatingWithTildeInPath
                if density.isCompact {
                    ViewThatFits(in: .horizontal) {
                        Text(folder).font(.caption).foregroundStyle(Color.secondary).fixedSize()
                        Color.clear.frame(width: 0)
                    }
                } else {
                    Text(folder)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .truncationMode(.middle)
                }
            }
        }
    }
}

private struct CardRow<Detail: View>: View {
    let title: String
    let state: RowState?
    let isLocked: Bool
    let modified: Date?
    var isOpen = false
    var hasBackgroundShell = false
    var isUnread = false
    var isFlagged = false
    var isTerminal = false
    var context: SessionContext?
    var chevron: String?
    var issue: IssueRef?
    var close: (() -> Void)?
    @ViewBuilder let detail: Detail
    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.sidebarDensity) private var density

    var body: some View {
        let isWorking = chevron != nil && state == .working
        let hasMemberDot = chevron != nil && (state != nil || isUnread)
        let ringWindow = context.flatMap { context in context.window.flatMap { context.tokens * 5 >= $0 * 4 && context.tokens <= $0 ? $0 : nil } }
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let issue { IssueTag(issue: issue).fixedSize() }
                Text(title)
                    .font(.body)
                    .fontWeight(isUnread ? .semibold : .regular)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .layoutPriority(density.isCompact ? 1 : 0)
                Spacer(minLength: 0)
                if density.isCompact {
                    detail
                        .lineLimit(1)
                }
                if let close {
                    Button("Close Terminal", systemImage: "xmark", action: close)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(.rect)
                        .help("Close terminal")
                }
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.secondary)
                        .help("Running in another terminal")
                        .accessibilityHidden(true)
                }
                if isFlagged {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 9))
                        .frame(width: 8)
                        .foregroundStyle(theme.closed)
                        .help("Flagged")
                        .accessibilityLabel("Flagged")
                        .padding(.trailing, hasMemberDot || ringWindow != nil ? 0 : 10)
                }
                if let modified {
                    HStack(spacing: 8) {
                        if let context, let ringWindow {
                            ContextRing(context: context, window: ringWindow)
                                .padding(.trailing, hasMemberDot ? 0 : 10)
                        }
                        ZStack(alignment: .trailing) {
                            Text(verbatim: "00m").hidden()
                            Text(age(since: modified))
                        }
                        .font(.caption)
                        .monospacedDigit()
                        .fixedSize()
                        .foregroundStyle(Color.secondary)
                        .padding(.leading, isWorking ? 20 : hasMemberDot ? 10 : 0)
                        .overlay(alignment: .leading) {
                            if hasMemberDot {
                                MemberDot(state: state)
                            }
                        }
                    }
                }
            }
            .frame(height: density.isCompact ? 16 : nil)
            if !density.isCompact {
                ZStack(alignment: .leading) {
                    Color.clear
                    detail
                }
                .lineLimit(1)
                .frame(height: 16)
            }
        }
        .opacity(isLocked && state == nil ? 0.55 : 1)
        .padding(.leading, 8)
        .padding(.trailing, -10)
        .padding(.vertical, density.rowPadding)
        .overlay(alignment: .topLeading) {
            StatusSlot(state: state, isUnread: isUnread, isOpen: isOpen, hasBackgroundShell: hasBackgroundShell, isTerminal: isTerminal, chevron: chevron).offset(x: -8, y: density.rowPadding)
        }
    }
}

private struct MemberDot: View {
    let state: RowState?
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        if state == .working {
            WorkingDots(label: "Working")
        } else if case let .needsYou(reason) = state {
            Circle()
                .fill(theme.needsYou)
                .frame(width: 6, height: 6)
                .help("Needs you\(reason.map { ": \($0)" } ?? "")")
                .accessibilityLabel("Needs you")
        } else {
            Circle()
                .fill(theme.unread)
                .frame(width: 6, height: 6)
                .help("Unread")
                .accessibilityLabel("Unread")
        }
    }
}

private struct StatusSlot: View {
    let state: RowState?
    let isUnread: Bool
    var isOpen = false
    var hasBackgroundShell = false
    var isTerminal = false
    var chevron: String?
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        ZStack {
            if let chevron {
                Image(systemName: chevron)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .accessibilityHidden(true)
            } else if case let .needsYou(reason) = state {
                Circle()
                    .fill(theme.needsYou)
                    .frame(width: 8, height: 8)
                    .help("Needs you\(reason.map { ": \($0)" } ?? "")")
                    .accessibilityLabel("Needs you")
            } else if state == .working {
                WorkingDots(label: "Working")
            } else if hasBackgroundShell {
                Circle()
                    .fill(theme.shellAttached)
                    .frame(width: 6, height: 6)
                    .help("Background shell running")
                    .accessibilityLabel("Background shell running")
            } else if isUnread {
                Circle()
                    .fill(theme.unread)
                    .frame(width: 8, height: 8)
                    .help("Unread")
                    .accessibilityLabel("Unread")
            } else if isOpen {
                Circle()
                    .strokeBorder(Color.secondary, lineWidth: 1)
                    .frame(width: 6, height: 6)
                    .help("Open in a tab")
                    .accessibilityLabel("Open in a tab")
            } else if isTerminal {
                Image(systemName: "apple.terminal")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.secondary)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 8, height: 16)
    }
}

struct ContextRing: View {
    let context: SessionContext
    let window: Int
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        let fill = Double(context.tokens) / Double(window)
        ZStack {
            Circle()
                .strokeBorder(Color.primary.opacity(0.2), lineWidth: 2)
            Circle()
                .inset(by: 1)
                .trim(from: 0, to: fill)
                .stroke(fill >= 0.9 ? theme.closed : fill >= 0.7 ? theme.needsYou : Color.secondary, lineWidth: 2)
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 13, height: 13)
        .help("\(tokenCount(context.tokens)) of \(tokenCount(window)) context")
        .accessibilityLabel("Context \(fill.formatted(.wholePercent)) full")
    }
}

func tokenCount(_ tokens: Int) -> String {
    if tokens < 1000 { return "\(tokens)" }
    if tokens < 1_000_000 { return "\((tokens + 500) / 1000)k" }
    return "\((Double(tokens) / 1_000_000).formatted(.number.precision(.fractionLength(0...1))))M"
}

struct PullRequestTag: View {
    let pullRequest: PullRequest
    var more = 0
    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var isHovering = false

    var body: some View {
        let color = pullRequest.state.color(in: theme)
        let checks = [.open, .draft].contains(pullRequest.state) ? pullRequest.checks : nil
        Button {
            openURL(pullRequest.url)
        } label: {
            HStack(spacing: 4) {
                Label {
                    Text(verbatim: "#\(pullRequest.number)")
                } icon: {
                    Image(systemName: "arrow.triangle.pull")
                }
                .labelStyle(CompactLabel())
                if let checks {
                    Rectangle()
                        .fill(color.opacity(0.35))
                        .frame(width: 1, height: 8)
                    Group {
                        if checks == .running {
                            Circle().frame(width: 6, height: 6)
                        } else {
                            Image(systemName: checks == .passed ? "checkmark" : "xmark")
                                .imageScale(.small)
                                .fontWeight(.bold)
                                .frame(width: 7)
                        }
                    }
                    .foregroundStyle(checks == .passed ? theme.working : checks == .failed ? theme.closed : theme.needsYou)
                    .accessibilityLabel("Checks \(checks.rawValue)")
                }
                if more > 0 {
                    Text(verbatim: "+\(more)")
                        .foregroundStyle(Color.secondary)
                }
            }
            .font(.caption.monospaced())
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .frame(height: 16)
            .background(color.opacity(isHovering ? 0.28 : 0.16), in: .rect(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .pointerStyle(.link)
        .help("Open pull request #\(String(pullRequest.number))\(checks.map { ", checks \($0.rawValue)" } ?? "")\(more > 0 ? ", \(more) more on this session" : "")")
    }
}

extension PullRequestState {
    func color(in theme: GhosttyTheme) -> Color {
        if self == .open { return theme.working }
        if self == .merged { return theme.merged }
        if self == .closed { return theme.closed }
        return Color.secondary
    }
}

private struct BranchText: View {
    let branch: String
    @Environment(\.ghosttyTheme) private var theme
    @State private var isHovering = false
    @State private var isCopied = false

    var body: some View {
        let isHighlighted = isHovering || Snapshot.forcedHover.contains(branch)
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(branch, forType: .string)
            isCopied = true
        } label: {
            Label(branch, systemImage: isCopied ? "checkmark" : "arrow.triangle.branch")
                .labelStyle(CompactLabel())
                .font(.caption.monospaced())
                .foregroundStyle(theme.branch.opacity(0.8))
                .truncationMode(.middle)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(isHighlighted ? 0.1 : 0), in: .rect(cornerRadius: 4))
                .padding(.horizontal, -4)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .pointerStyle(.link)
        .help("Copy branch name")
        .task(id: isCopied) {
            guard isCopied else { return }

            try? await Task.sleep(for: .seconds(1))
            isCopied = false
        }
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

func age(since date: Date) -> String {
    let seconds = max(0, Int(Date.now.timeIntervalSince(date)))
    if seconds < 60 { return "now" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    if seconds < 86_400 { return "\(seconds / 3600)h" }
    if seconds < 7 * 86_400 { return "\(seconds / 86_400)d" }
    return "\(seconds / (7 * 86_400))w"
}
