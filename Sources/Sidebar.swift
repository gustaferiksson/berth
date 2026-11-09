import BerthCore
import GhosttyTerminal
import SwiftUI
import UniformTypeIdentifiers

struct SidebarLayout: Equatable {
    struct Group: Equatable, Identifiable {
        let source: SessionGroup
        let tabIDs: [Tab.ID]
        let sessionIDs: [String]
        let folders: [String]
        var id: String { source.id }
    }

    let terminalIDs: [Tab.ID]
    let pinnedIDs: [String]
    let groups: [Group]
    let archivedIDs: [String]
    let isEmpty: Bool
}

struct Sidebar: View, Equatable {
    @Environment(Store.self) private var store

    static let collapsedByDefault: Set = ["recent:older"]
    static let terminalsID = "terminals"

    // Its property wrappers never compare equal, so SwiftUI would re-render it on every ContentView update.
    static func == (_: Self, _: Self) -> Bool { true }

    var body: some View {
        ScrollViewReader { proxy in
            SidebarList(layout: layout)
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
    }

    private var layout: SidebarLayout {
        SidebarLayout(
            terminalIDs: store.terminals.map(\.id),
            pinnedIDs: store.pinnedSessions.map(\.id),
            groups: store.sidebarGroups.map { group, tabs in
                SidebarLayout.Group(
                    source: SessionGroup(kind: group.kind, sessions: []),
                    tabIDs: tabs.map(\.id),
                    sessionIDs: group.sessions.map(\.id),
                    folders: group.folder.map { Array(Set(group.sessions.map(\.cwd)).union([$0])).sorted() } ?? []
                )
            },
            archivedIDs: store.archivedSessions.map(\.id),
            isEmpty: store.hasScanned && store.groups.isEmpty && store.pinnedSessions.isEmpty && store.tabs.isEmpty
        )
    }
}

private struct SidebarList: View, Equatable {
    let layout: SidebarLayout
    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme
    @AppStorage("collapsedGroups") private var collapsedGroups = ""
    @AppStorage("archivedExpanded") private var isArchiveExpanded = false
    @State private var expandedGroups = Snapshot.expandedGroups
    @State private var renaming: CustomGroup?
    @State private var browseRoot: String?
    @FocusState private var isFocused: Bool

    private static let visibleSessions = 5
    private static let pinnedID = "pinned"

    private struct Group {
        let layout: SidebarLayout.Group
        let sessionIDs: [String]
        let hiddenSessions: Int
        var id: String { layout.id }
        var count: Int { layout.tabIDs.count + layout.sessionIDs.count }
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.layout == rhs.layout }

    private var groups: [Group] {
        layout.groups.map { group in
            let sessionIDs = expandedGroups.contains(group.id) ? group.sessionIDs : Array(group.sessionIDs.prefix(Self.visibleSessions))
            return Group(layout: group, sessionIDs: sessionIDs, hiddenSessions: group.sessionIDs.count - sessionIDs.count)
        }
    }

    private var items: [SidebarItem] {
        (isCollapsed(Sidebar.terminalsID) ? [] : layout.terminalIDs).map(SidebarItem.tab)
            + (isCollapsed(Self.pinnedID) ? [] : layout.pinnedIDs).map(SidebarItem.session)
            + groups.filter { !isCollapsed($0.id) }.flatMap { $0.layout.tabIDs.map(SidebarItem.tab) + $0.sessionIDs.map(SidebarItem.session) }
            + (isArchiveExpanded ? layout.archivedIDs : []).map(SidebarItem.session)
    }

    var body: some View {
        let groups = groups
        List {
            if !layout.terminalIDs.isEmpty {
                terminalsSection
            }
            if !layout.pinnedIDs.isEmpty {
                Section(isExpanded: expansion(of: Self.pinnedID)) {
                    ForEach(Array(layout.pinnedIDs.enumerated()), id: \.element) { index, id in
                        SessionItem(id: id, place: .pinned, select: select)
                            .id(SidebarItem.session(id))
                            .draggable(PinDrag(id: id))
                            .modifier(GroupDropTarget<PinDrag>(indicatorOffset: 0) { movePin($0, onto: index) })
                    }
                } header: {
                    GroupHeader(title: "Pinned", help: "Pinned sessions", count: layout.pinnedIDs.count, menu: { EmptyView() }) { _ in EmptyView() }
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
            if !layout.archivedIDs.isEmpty {
                Section(isExpanded: $isArchiveExpanded) {
                    ForEach(layout.archivedIDs, id: \.self) { id in
                        SessionItem(id: id, place: .archived, select: select)
                            .id(SidebarItem.session(id))
                    }
                } header: {
                    GroupHeader(title: "Archived", help: "Archived sessions", count: layout.archivedIDs.count, menu: { EmptyView() }) { _ in EmptyView() }
                }
            }
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { move(by: 1, in: items) }
        .onKeyPress(.upArrow) { move(by: -1, in: items) }
        .onKeyPress(.return) {
            guard let item = store.sidebarCursor ?? store.selection else { return .ignored }
            store.activate(item)
            return .handled
        }
        .onKeyPress(.leftArrow) { setExpanded(false, in: groups) }
        .onKeyPress(.rightArrow) { setExpanded(true, in: groups) }
        .onHover { store.isPointerInSidebar = $0 }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(OverlayScroller())
        .fileImporter(isPresented: Binding(get: { browseRoot != nil }, set: { if !$0 { browseRoot = nil } }), allowedContentTypes: [.folder]) { result in
            guard case let .success(url) = result else { return }
            store.openClaude(cwd: url.path)
        }
        .fileDialogDefaultDirectory(browseRoot.map { URL(filePath: $0) })
        .overlay {
            if layout.isEmpty {
                ContentUnavailableView("No Claude Sessions", systemImage: "bubble.left.and.text.bubble.right", description: Text("Sessions you start with claude show up here, grouped by project."))
            }
        }
    }

    private func move(by offset: Int, in items: [SidebarItem]) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }

        let current = (store.sidebarCursor ?? store.selection).flatMap(items.firstIndex(of:))
        let next = items[min(max((current ?? (offset > 0 ? -1 : items.count)) + offset, 0), items.count - 1)]
        let tab: Tab? = switch next {
        case let .tab(id): store.tabs.first { $0.id == id }
        case let .session(id): store.tab(forSession: id)
        }
        guard let tab else {
            store.sidebarCursor = next
            return .handled
        }

        store.selectedTabID = tab.id
        store.isHarborShown = false
        return .handled
    }

    private func setExpanded(_ expanded: Bool, in groups: [Group]) -> KeyPress.Result {
        let item = store.sidebarCursor ?? store.selection
        if layout.terminalIDs.contains(where: { .tab($0) == item }) {
            expansion(of: Sidebar.terminalsID).wrappedValue = expanded
            return .handled
        }
        if case let .session(id) = item, layout.pinnedIDs.contains(id) {
            expansion(of: Self.pinnedID).wrappedValue = expanded
            return .handled
        }
        guard let item, let group = groups.first(where: { group in
            group.layout.tabIDs.contains { .tab($0) == item } || group.sessionIDs.contains { .session($0) == item }
        }) else { return .ignored }

        expansion(of: group.id).wrappedValue = expanded
        return .handled
    }

    private func select(_ item: SidebarItem) {
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
                    .id(SidebarItem.tab(id))
            }
        } header: {
            GroupHeader(title: "Terminals", help: "Terminals", count: layout.terminalIDs.count, menu: { EmptyView() }) { isHovering in
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
            ForEach(group.sessionIDs, id: \.self) { id in
                SessionItem(id: id, place: .group(folder: group.layout.source.folder), select: select)
                    .id(SidebarItem.session(id))
            }
            if group.hiddenSessions > 0 || expandedGroups.contains(group.id) && group.sessionIDs.count > Self.visibleSessions {
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
            }
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
    private func customGroupMenu(_ custom: CustomGroup, at index: Int, of count: Int, singleFolder: String?) -> some View {
        if let singleFolder {
            Button("New Session") { store.openClaude(cwd: singleFolder) }
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

    private func isCollapsed(_ id: String) -> Bool {
        collapsedGroups.split(separator: "\n").contains { $0 == id } != Sidebar.collapsedByDefault.contains(id)
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

private struct TabItem: View {
    let id: Tab.ID
    let select: (SidebarItem) -> Void
    @Environment(Store.self) private var store

    var body: some View {
        let tab = store.tabs.first { $0.id == id }
        // A layout container makes the row one static view, so List builds only the visible rows.
        HStack(spacing: 0) {
            if let tab, tab.kind == .shell {
                TabRow(tab: tab, live: nil, terminal: tab.terminal) { store.close(tab.id) }
            } else if let tab {
                TabRow(tab: tab, live: tab.sessionID.flatMap { store.liveBySession[$0] }, terminal: tab.terminal)
            }
        }
        .modifier(RowChrome(item: .tab(id), hoverID: id.uuidString, isLocked: false) { select(.tab(id)) })
        .contextMenu {
            if tab?.kind == .shell {
                Button("Close Terminal") { store.close(id) }
            } else {
                Button("Unload Session") { store.close(id) }
                if let sessionID = tab?.sessionID { CopySessionIDButton(sessionID: sessionID) }
            }
        }
    }
}

private struct SessionItem: View {
    enum Place: Equatable {
        case pinned
        case group(folder: String?)
        case archived
    }

    let id: String
    let place: Place
    let select: (SidebarItem) -> Void
    @Environment(Store.self) private var store

    var body: some View {
        let session = store.sessionsByID[id]
        let tab = store.tab(forSession: id)
        let live = store.liveBySession[id]
        // A layout container makes the row one static view, so List builds only the visible rows.
        HStack(spacing: 0) {
            if let session {
                SessionRow(
                    session: session,
                    projectName: place == .archived || place == .group(folder: session.cwd) ? nil : URL(filePath: session.cwd).lastPathComponent,
                    live: live,
                    isOpen: tab != nil,
                    hasBackgroundShell: store.backgroundShellIDs.contains(id),
                    isUnread: store.isUnread(session),
                    isFlagged: store.flaggedIDs.contains(id),
                    pullRequestState: session.pullRequest.flatMap { store.pullRequestStates[$0.url] },
                    showsLockedNotice: Binding(get: { store.lockedSessionID == id }, set: { if !$0 { store.lockedSessionID = nil } })
                )
            }
        }
        .modifier(RowChrome(item: .session(id), hoverID: session?.title ?? id, isLocked: tab == nil && live.map { $0.attachID == nil } ?? false) {
            select(.session(id))
        })
        .contextMenu {
            if place == .archived {
                Button("Unarchive") { store.unarchive(id) }
                flagButton
                Divider()
                CopySessionIDButton(sessionID: id)
            } else if let session {
                menu(session, tab: tab)
            }
        }
    }

    @ViewBuilder
    private func menu(_ session: SessionSummary, tab: Tab?) -> some View {
        if let tab { Button("Unload Session") { store.close(tab.id) } }
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
        Button("Archive") { store.archive(id) }
        Divider()
        CopySessionIDButton(sessionID: id)
    }

    @ViewBuilder
    private var flagButton: some View {
        if store.flaggedIDs.contains(id) {
            Button("Unflag") { store.unflag(id) }
        } else {
            Button("Flag") { store.flag(id) }
        }
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
    }
}

private struct GroupHeader<Menu: View, Accessory: View>: View {
    let title: String
    let help: String
    let count: Int
    var renaming: Binding<CustomGroup?>?
    var commitRename: (CustomGroup) -> Void = { _ in }
    var dragID: String?
    var drop: ((String) -> Bool)?
    @ViewBuilder let menu: () -> Menu
    @ViewBuilder let accessory: (Bool) -> Accessory
    @State private var isHovering = false
    @State private var name = ""
    @FocusState private var isNameFocused: Bool
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        Group {
            if let dragID, renaming == nil {
                label.draggable(GroupDrag(id: dragID))
            } else {
                label
            }
        }
        .font(.system(size: 11))
        .padding(.top, 16)
        .padding(.leading, -6)
        .padding(.trailing, 6)
        .modifier(GroupDropTarget<GroupDrag>(indicatorOffset: 4, drop: drop))
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 4, trailing: 8))
        .onHover { isHovering = $0 }
        .onAppear { isHovering = Snapshot.forcedHover.contains(title) }
    }

    private var label: some View {
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
                    .foregroundStyle(theme.secondary)
                    .lineLimit(1)
                    .help(help)
                Text(count, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(theme.secondary.opacity(0.6))
            }
            Spacer(minLength: 4)
            accessory(isHovering)
        }
        // While hovered, the system disclosure chevron takes this much of the header's trailing edge.
        .padding(.trailing, isHovering ? 2 : 25)
        .frame(height: 24)
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
            } isTargeted: {
                isTargeted = drop != nil && $0
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
                .foregroundStyle(theme.secondary.opacity(isHeaderHovered ? 1 : 0.6))
                .frame(width: 24, height: 24)
                .background(theme.foreground.opacity(configuration.isPressed ? 0.12 : isHovering ? 0.06 : 0), in: .rect(cornerRadius: 8))
                .contentShape(.rect)
                .onHover { isHovering = $0 }
        }
    }
}

private struct RowChrome: ViewModifier {
    let item: SidebarItem
    let hoverID: String
    let isLocked: Bool
    let select: () -> Void
    @State private var isHovering = false
    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme

    private var isSelected: Bool {
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
        case .idle, .shell: return nil
        }
    }
}

private struct SessionRow: View {
    let session: SessionSummary
    let projectName: String?
    let live: LiveSession?
    let isOpen: Bool
    let hasBackgroundShell: Bool
    let isUnread: Bool
    let isFlagged: Bool
    let pullRequestState: PullRequestState?
    @Binding var showsLockedNotice: Bool
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        let isLocked = !isOpen && live.map { $0.attachID == nil } ?? false
        CardRow(
            title: session.title,
            state: RowState(live: live),
            isLocked: isLocked,
            isLoaded: isOpen,
            modified: session.lastPrompt,
            lastActivity: session.lastActivity,
            hasBackgroundShell: hasBackgroundShell,
            isUnread: isUnread,
            isFlagged: isFlagged,
            detail: {
                if session.pullRequest != nil || session.branch != nil || projectName != nil {
                    HStack(spacing: 8) {
                        HStack(spacing: 8) {
                            if let projectName {
                                HStack(spacing: 4) {
                                    ZStack(alignment: .leading) {
                                        Text(verbatim: projectName.count > 4 ? "\(projectName.prefix(4))…" : projectName)
                                            .fixedSize()
                                            .hidden()
                                        Text(projectName)
                                            .foregroundStyle(theme.secondary)
                                            .truncationMode(.tail)
                                    }
                                    if session.branch != nil {
                                        Text(verbatim: "·")
                                            .foregroundStyle(theme.secondary.opacity(0.6))
                                            .fixedSize()
                                    }
                                }
                                .font(.caption)
                                .layoutPriority(1)
                            }
                            if let branch = session.branch {
                                BranchText(branch: branch)
                                    .frame(minWidth: 72, alignment: .leading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if let pullRequest = session.pullRequest {
                            PullRequestTag(link: pullRequest, state: pullRequestState)
                                .fixedSize()
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
    var close: (() -> Void)?
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        let title = tab.title(terminalTitle: terminal.title, sessionTitle: nil)
        if tab.kind == .claude {
            CardRow(title: title, state: RowState(live: live), isLocked: false, isLoaded: true, modified: nil) {
                Text(verbatim: "–").font(.caption.monospaced()).foregroundStyle(theme.secondary)
            }
        } else {
            CardRow(title: title, state: title == terminal.title ? .working : nil, isLocked: false, isLoaded: false, modified: nil, close: close) {
                Text((tab.folder as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(theme.secondary)
                    .truncationMode(.middle)
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
    var lastActivity: Date?
    var hasBackgroundShell = false
    var isUnread = false
    var isFlagged = false
    var close: (() -> Void)?
    @ViewBuilder let detail: Detail
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let close {
                    Button("Close Terminal", systemImage: "xmark", action: close)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(.rect)
                        .help("Close terminal")
                }
                if isFlagged {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.closed)
                        .help("Flagged")
                        .accessibilityLabel("Flagged")
                }
                if let modified {
                    Text(age(since: modified))
                        .font(.caption)
                        .monospacedDigit()
                        .fixedSize()
                        .foregroundStyle(theme.secondary)
                        .padding(.leading, hasBackgroundShell || isLoaded && lastActivity != nil ? 10 : 0)
                        .overlay(alignment: .leading) {
                            if hasBackgroundShell {
                                Circle()
                                    .fill(theme.shellAttached)
                                    .frame(width: 6, height: 6)
                                    .help("Background shell running")
                                    .accessibilityLabel("Background shell running")
                            } else if isLoaded, let lastActivity {
                                let inactiveFrom = lastActivity.addingTimeInterval(15 * 60)
                                TimelineView(.explicit([inactiveFrom])) { _ in
                                    let isActive = state == .working || Date.now < inactiveFrom
                                    Circle()
                                        .strokeBorder(theme.working, lineWidth: 1.25)
                                        .background(Circle().fill(isActive ? theme.working : .clear))
                                        .frame(width: 6, height: 6)
                                        .help(isActive ? "Active" : "Inactive for 15 minutes")
                                        .accessibilityLabel(isActive ? "Active" : "Inactive")
                                }
                            }
                        }
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
            StatusSlot(state: state, isUnread: isUnread).offset(x: -8, y: 8)
        }
    }
}

private struct StatusSlot: View {
    let state: RowState?
    let isUnread: Bool
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
            } else if state == nil, isUnread {
                Circle()
                    .fill(theme.unread)
                    .frame(width: 8, height: 8)
                    .help("Unread")
                    .accessibilityLabel("Unread")
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
                .background(theme.foreground.opacity(isHighlighted ? 0.1 : 0), in: .rect(cornerRadius: 4))
                .padding(.horizontal, -4)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
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
