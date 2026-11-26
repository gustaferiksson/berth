import BerthCore
import Foundation
import GhosttyTerminal
import SwiftUI
import UniformTypeIdentifiers

enum LauncherMode {
    case newSession, search, palette, pullRequests, showPullRequestInReview, issues, projects
}

struct Launcher: View {
    private struct Folder: Hashable {
        let path: String
        let sessions: Int
        let lastActivity: Date?
    }

    private enum PaletteTarget {
        case item(SidebarItem)
        case action(AppAction)
    }

    private struct PaletteRow {
        let item: PaletteItem
        let target: PaletteTarget
        let symbol: String
        let trailing: String
    }

    let mode: LauncherMode

    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme
    @AppStorage(GeneralSettings.worktreeKey) private var startsInWorktree = false
    @AppStorage(ItemPreviewSetting.key) private var richPreviews = false
    @State private var query: String
    @State private var highlighted = 0
    @State private var folders: [Folder] = []
    @State private var hits: [SearchHit] = []
    @State private var searchedQuery = ""
    @State private var resultsHeight = 0.0
    @State private var isBrowsing = false
    @State private var missingCheckout: InboxPullRequest?
    @AppStorage(ProjectsModel.mineOnlyKey) private var mineOnly = false
    @State private var missingProjectItem: ProjectItem?
    @State private var selectedIssue: InboxIssue?
    @State private var issueLookup: (reference: IssueReference, result: Result<[LinkedPullRequest], IssuePullRequests.LookupError>)?
    @State private var issueOpenFailures: Set<PullRequestLink> = []
    @FocusState private var isQueryFocused: Bool
    @Binding private var previousScope: LauncherMode?

    init(mode: LauncherMode, query: String, previousScope: Binding<LauncherMode?>) {
        self.mode = mode
        _previousScope = previousScope
        _query = State(initialValue: query)
    }

    private static let visibleMatches = 6

    private var scopes: [(mode: LauncherMode, title: String)] {
        let base: [(mode: LauncherMode, title: String)] = [(.newSession, "Folders"), (.pullRequests, "Pull Requests"), (.issues, "Issues")]
        return store.projects.isEnabled ? base + [(.projects, "Project")] : base
    }

    private var nextScope: (mode: LauncherMode, title: String)? {
        guard let index = scopes.firstIndex(where: { $0.mode == mode }) else { return nil }

        return scopes[(index + 1) % scopes.count]
    }

    private var issueReference: IssueReference? {
        guard mode == .pullRequests || mode == .issues || (mode == .projects && selectedIssue != nil) else { return nil }

        return IssueReference.parse(selectedIssue?.id ?? query)
    }

    private var issueResult: Result<[LinkedPullRequest], IssuePullRequests.LookupError>? {
        guard let issueReference else { return nil }

        return issueLookup?.reference == issueReference ? issueLookup?.result : nil
    }

    private var rankedIssues: (issues: [InboxIssue], older: Int) {
        guard mode == .issues, issueReference == nil else { return ([], 0) }

        return IssueInbox.rank(query, in: store.issueInbox ?? [], now: .now)
    }

    private var showsPullRequests: Bool { mode == .pullRequests || mode == .showPullRequestInReview }

    private var pastedPullRequest: PullRequestLink? {
        guard mode == .showPullRequestInReview else { return nil }

        return PullRequestLink.parse(query.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var rankedPullRequests: (pullRequests: [InboxPullRequest], older: Int) {
        guard showsPullRequests, issueReference == nil, pastedPullRequest == nil else { return ([], 0) }

        return PullRequestInbox.rank(query, in: (store.inbox ?? []).filter { store.launcherRole == nil || $0.role == store.launcherRole }, now: .now)
    }

    private var projectEntries: [ProjectEntry] {
        guard mode == .projects, issueReference == nil else { return [] }

        let boards = store.projects.selectedBoards
        let login = store.projects.viewerLogin
        let titles = Dictionary(boards.map { ($0.project.id, $0.project.title) }) { first, _ in first }
        let groups = boards.flatMap { $0.groups(query: query, mineOnly: mineOnly, login: login) }
        let names = groups.map(\.statusName).reduce(into: [String]()) { names, name in
            if !names.contains(name) { names.append(name) }
        }
        return (names.filter { $0 != ProjectBoard.noStatusName } + names.filter { $0 == ProjectBoard.noStatusName }).flatMap { name in
            let matching = groups.filter { $0.statusName == name }
            let items = matching.flatMap(\.items).sorted { left, right in
                let leftMine = left.assignees.contains { $0.caseInsensitiveCompare(login) == .orderedSame }
                let rightMine = right.assignees.contains { $0.caseInsensitiveCompare(login) == .orderedSame }
                return leftMine != rightMine ? leftMine : (left.updatedAt ?? .distantPast) > (right.updatedAt ?? .distantPast)
            }
            let total = items.count + matching.reduce(0) { $0 + $1.hiddenCount }
            let title = total > items.count ? "\(name) · latest \(items.count)" : name
            return items.enumerated().map { index, item in
                ProjectEntry(header: index == 0 ? title : nil, count: total, project: boards.count > 1 ? titles[item.projectID] : nil, item: item)
            }
        }
    }

    private var highlightedProject: ProjectItem? {
        let entries = projectEntries
        return entries.indices.contains(highlighted) ? entries[highlighted].item : nil
    }

    private var highlightedIssue: InboxIssue? {
        let issues = rankedIssues.issues
        return issues.indices.contains(highlighted) ? issues[highlighted] : nil
    }

    var body: some View {
        let matches = mode == .newSession ? matches : []
        let rows = mode == .palette ? paletteRows : []
        let target = matches.indices.contains(highlighted) ? matches[highlighted] : nil
        let row = rows.indices.contains(highlighted) ? rows[highlighted] : nil
        let issue = issueReference
        let linked = ((try? issueResult?.get()) ?? []).map { (pullRequest: $0, opening: store.opening(of: $0.link)) }
        let ranked = rankedPullRequests
        let issues = rankedIssues
        let pullRequest = ranked.pullRequests.indices.contains(highlighted) ? ranked.pullRequests[highlighted] : nil
        let issueRow = issues.issues.indices.contains(highlighted) ? issues.issues[highlighted] : nil
        let count = switch mode {
        case .newSession: matches.count
        case .palette: rows.count
        case .pullRequests, .showPullRequestInReview: pastedPullRequest == nil ? ranked.pullRequests.count : 1
        case .issues: issues.issues.count
        case .search: hits.count
        case .projects: projectEntries.count
        }
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ([LauncherMode.newSession: LauncherGlyph.symbol("folder"), .palette: "command", .pullRequests: .octicon(.pullRequest), .showPullRequestInReview: .octicon(.pullRequest), .issues: .octicon(.issueOpened), .projects: "checklist"][mode] ?? "magnifyingglass").image(octiconSize: 18)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                TextField("Query", text: $query, prompt: Text([LauncherMode.newSession: "Search folders or type a path", .palette: "Type a command or session", .pullRequests: "Search pull requests or paste an issue", .showPullRequestInReview: "Search pull requests or paste a PR URL", .issues: "Search or paste an issue", .projects: "Search project items"][mode] ?? "Search all sessions"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 22))
                    .focused($isQueryFocused)
                    .onKeyPress(.downArrow) { move(by: 1, in: count) }
                    .onKeyPress(.upArrow) { move(by: -1, in: count) }
                    .modifier(LauncherItemPreview(url: pullRequest?.url ?? issueRow?.url, highlighted: highlighted, query: query, store: store))
                    .onKeyPress(.tab) {
                        guard let nextScope else { return .ignored }

                        switchScope(to: nextScope.mode)
                        return .handled
                    }
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.option) else { return .ignored }

                        if let url = selectedIssue?.url ?? issueReference?.url ?? highlightedIssue?.url ?? highlightedProject?.url {
                            openOnGitHub(url)
                            return .handled
                        }
                        if let pullRequest, showsPullRequests {
                            if AppAction.showPullRequestInReview.isAvailable(in: store) {
                                showInReview(PullRequestLink(repository: pullRequest.repository, number: pullRequest.number))
                            } else if mode == .pullRequests {
                                openOnGitHub(pullRequest.url)
                            }
                            return .handled
                        }
                        let matches = self.matches
                        guard mode == .newSession, matches.indices.contains(highlighted) else { return .ignored }

                        if press.modifiers.contains(.shift) {
                            guard let other = Store.otherAgent else { return .ignored }

                            start(other, in: matches[highlighted].path)
                            return .handled
                        }
                        start(in: matches[highlighted].path, checkout: .main)
                        return .handled
                    }
                    .onSubmit(submit)
                    .onChange(of: query) {
                        highlighted = 0
                        selectedIssue = nil
                        guard mode == .newSession, query.hasPrefix("#") else { return }

                        previousScope = mode
                        store.launcherQuery = String(query.dropFirst())
                        store.launcherMode = .pullRequests
                    }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            if nextScope != nil {
                HStack(spacing: 8) {
                    LauncherScopePicker(scopes: scopes, selection: mode, previousSelection: previousScope, select: switchScope)
                    Spacer()
                    if let role = store.launcherRole, mode == .pullRequests, issue == nil {
                        Button { store.launcherRole = nil } label: {
                            Label(role.title, systemImage: "xmark")
                                .font(.caption.weight(.medium))
                                .imageScale(.small)
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .background(theme.foreground.opacity(0.09), in: .capsule)
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .help("Show all pull requests")
                    }
                    if mode == .projects, issue == nil { mineChip }
                    if mode == .newSession {
                        Button { isBrowsing = true } label: {
                            Label("Browse…", systemImage: "folder")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .background(theme.foreground.opacity(0.09), in: .capsule)
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut("o")
                        .help("Choose a folder (⌘O)")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            Divider()
            if mode == .newSession {
                folderList(matches)
            } else {
                results(rows, pullRequests: ranked, issues: issues, issue: issue, linked: linked)
            }
            if let pullRequest, missingCheckout == pullRequest {
                Divider()
                checkoutNotice(repository: pullRequest.repository, url: pullRequest.url)
            }
            if mode == .projects { projectNotices }
            Divider()
            HStack(spacing: 8) {
                if mode == .newSession {
                    let other = Store.otherAgent
                    let agent = other == nil ? "" : " \(Store.defaultAgent.name)"
                    LauncherKeyHint("↩", target.map { "Start\(agent) in \(URL(filePath: $0.path).lastPathComponent)" } ?? "Start\(agent)")
                    if startsInWorktree { LauncherKeyHint("⌥↩", "Main Checkout") }
                    if let other { LauncherKeyHint("⌥⇧↩", other.name) }
                    LauncherKeyHint("↑↓", "Folder")
                } else if issue != nil {
                    let openable = linked.count { $0.opening.isOpenable }
                    if openable > 0 { LauncherKeyHint("↩", "Open \(openable) Pull Request\(openable == 1 ? "" : "s")") }
                    LauncherKeyHint("⌥↩", "Open on GitHub")
                } else if mode == .showPullRequestInReview {
                    LauncherKeyHint("↩", "Show in Review")
                } else if mode == .pullRequests {
                    let opening = pullRequest.map { store.opening(of: PullRequestLink(repository: $0.repository, number: $0.number)) }
                    let label = if case let .session(session)? = opening {
                        store.tab(forSession: session.id) == nil ? "Resume Session" : "Switch To Session"
                    } else if case .tab? = opening {
                        "Switch To Session"
                    } else if case let .worktree(folder)? = opening {
                        "New Worktree in \(URL(filePath: folder).lastPathComponent)"
                    } else if case .noCheckout? = opening {
                        "No Local Checkout"
                    } else {
                        "Open"
                    }
                    LauncherKeyHint("↩", label)
                    LauncherKeyHint("⌥↩", AppAction.showPullRequestInReview.isAvailable(in: store) ? "Show in Review" : "Open on GitHub")
                } else if mode == .issues {
                    if let issueRow {
                        LauncherKeyHint("↩", issueRow.openPullRequestCount == 0 ? "Start" : "Open PRs")
                        LauncherKeyHint("⌥↩", "GitHub")
                    }
                    LauncherKeyHint("↑↓", "Issue")
                } else if mode == .projects {
                    if let item = highlightedProject {
                        LauncherKeyHint("↩", item.kind == .draft ? "Draft Item" : item.kind == .issue ? "Open" : "Open Pull Request")
                        if item.url != nil { LauncherKeyHint("⌥↩", "GitHub") }
                    }
                    LauncherKeyHint("↑↓", "Item")
                } else if mode == .palette {
                    LauncherKeyHint("↩", row.map { if case .action = $0.target { "Run" } else if $0.item.section == .openTab { "Switch To" } else { "Resume" } } ?? "Run")
                    LauncherKeyHint("↑↓", "Select")
                } else {
                    LauncherKeyHint("↩", "Open")
                    LauncherKeyHint("↑↓", "Session")
                }
                if richPreviews, showsPullRequests || mode == .issues { LauncherKeyHint("␣", "Preview") }
                if let nextScope { LauncherKeyHint("⇥", nextScope.title) }
                Spacer(minLength: 0)
                if mode == .search, let indexing = store.searchIndexing {
                    Text("Indexing \(indexing.done)/\(indexing.total)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                LauncherKeyHint("esc", mode == .newSession ? "Cancel" : "Close")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: 680)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal, 24)
        .onExitCommand { store.launcherMode = nil }
        .onAppear {
            store.launcherQuery = ""
            isQueryFocused = true
            if mode == .search { store.updateSearchIndex() }
            if showsPullRequests { store.refreshInbox() }
            if mode == .issues { store.refreshIssueInbox() }
            if mode == .projects { store.projects.refresh() }
            if showsPullRequests || mode == .issues || mode == .projects { store.refreshLocalClones() }
            guard mode == .newSession else { return }

            let known = store.knownFolders
            let current = RepositoryRoot.checkout(store.currentCwd)
            let promoted = current == FileManager.default.homeDirectoryForCurrentUser.path ? [] : [known.first { $0.path == current } ?? (path: current, sessions: 0, lastActivity: .distantPast)]
            folders = (promoted + known.filter { $0.path != promoted.first?.path })
                .filter { FileManager.default.fileExists(atPath: $0.path) }
                .map { Folder(path: $0.path, sessions: $0.sessions, lastActivity: $0.sessions > 0 ? $0.lastActivity : nil) }
        }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }

            await search()
        }
        .task(id: issue) {
            guard let issue else { return }

            issueLookup = nil
            issueOpenFailures = []
            guard let result = await lookup(issue), !Task.isCancelled, issueReference == issue else { return }

            let linked = try? result.get()
            if let selectedIssue, let linked {
                let needsCheckout = linked.isEmpty ? store.localCheckout(of: selectedIssue.repository) == nil : linked.contains { !store.opening(of: $0.link).isOpenable }
                if needsCheckout { await store.waitForLocalClones() }
                guard !Task.isCancelled, issueReference == issue else { return }
            }

            issueLookup = (issue, result)
            if selectedIssue != nil, let linked { openIssueResult(linked) }
        }
        .onChange(of: store.searchIndexVersion) { Task { await search() } }
        .onChange(of: store.launcherRole) { highlighted = 0 }
        .onChange(of: mineOnly) { highlighted = 0 }
        .fileImporter(isPresented: $isBrowsing, allowedContentTypes: [.folder]) { result in
            guard case let .success(url) = result else { return }

            start(in: url.path)
        }
    }

    private func folderList(_ matches: [Folder]) -> some View {
        VStack(spacing: 0) {
            if matches.isEmpty {
                LauncherMessage(
                    symbol: "folder",
                    title: folders.isEmpty ? "No session folders yet" : "No matching folders",
                    detail: folders.isEmpty ? "Type a path or browse." : nil
                )
            } else {
                LauncherSectionHeader(query.allSatisfy(\.isWhitespace) ? "Recent Folders" : "Folders")
                ForEach(Array(matches.enumerated()), id: \.element) { index, folder in
                    folderRow(folder, isHighlighted: index == highlighted)
                        .onTapGesture { start(in: folder.path) }
                }
            }
        }
        .padding(8)
    }

    private func results(_ rows: [PaletteRow], pullRequests ranked: (pullRequests: [InboxPullRequest], older: Int), issues rankedIssues: (issues: [InboxIssue], older: Int), issue: IssueReference?, linked: [(pullRequest: LinkedPullRequest, opening: PullRequestOpening)]) -> some View {
        let isBlank = query.allSatisfy(\.isWhitespace)
        let pullRequests = ranked.pullRequests
        let issues = rankedIssues.issues
        let pullRequestGroups = Dictionary(grouping: pullRequests, by: \.role)
        let issueGroups = Dictionary(grouping: issues, by: \.role)

        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if issue != nil {
                        issueRows(linked)
                    } else if let pastedPullRequest {
                        Button { showInReview(pastedPullRequest) } label: {
                            LauncherRowFrame(symbol: .octicon(.pullRequest), tint: .accentColor, title: "\(pastedPullRequest.repository) #\(pastedPullRequest.number)", isHighlighted: true) {
                                EmptyView()
                            }
                        }
                        .buttonStyle(.plain)
                    } else if showsPullRequests {
                        ForEach(Array(pullRequests.enumerated()), id: \.element.id) { index, pullRequest in
                            if index == 0 || pullRequests[index - 1].role != pullRequest.role {
                                LauncherSectionHeader(pullRequest.role.title, count: pullRequestGroups[pullRequest.role]?.count)
                                    .padding(.top, index == 0 ? 0 : 6)
                            }
                            let link = PullRequestLink(repository: pullRequest.repository, number: pullRequest.number)
                            pullRequestRow(pullRequest, isHighlighted: index == highlighted)
                                .modifier(ItemPreviewTrigger(reference: ItemReference(url: pullRequest.url), placement: .launcher, store: store))
                                .id(index)
                                .onTapGesture { open(pullRequest) }
                                .contextMenu {
                                    Button("Show in Review", systemImage: AppAction.showPullRequestInReview.symbol) { showInReview(link) }
                                        .disabled(!AppAction.showPullRequestInReview.isAvailable(in: store))
                                    Button("Open on GitHub", systemImage: "arrow.up.right.square") { openOnGitHub(pullRequest.url) }
                                }
                        }
                        if pullRequests.isEmpty {
                            if store.inbox == nil {
                                LauncherMessage(
                                    symbol: "exclamationmark.circle",
                                    title: store.isInboxLoading ? "Loading pull requests…" : "Couldn’t list pull requests with the GitHub CLI (gh)",
                                    isLoading: store.isInboxLoading
                                )
                            } else {
                                LauncherMessage(symbol: .octicon(.pullRequest), title: isBlank ? "No open pull requests need you" : "No matching pull requests")
                            }
                        }
                    } else if mode == .issues {
                        if !isBlank, !issues.isEmpty {
                            LauncherSectionHeader("Matches", count: issues.count)
                        }
                        ForEach(Array(issues.enumerated()), id: \.element.id) { index, issue in
                            if isBlank, index == 0 || issues[index - 1].role != issue.role {
                                LauncherSectionHeader(issue.role.title, count: issueGroups[issue.role]?.count)
                                    .padding(.top, index == 0 ? 0 : 6)
                            }
                            Button { selectedIssue = issue } label: {
                                issueRow(issue, isHighlighted: index == highlighted)
                            }
                            .buttonStyle(.plain)
                            .modifier(ItemPreviewTrigger(reference: ItemReference(url: issue.url), placement: .launcher, store: store))
                            .id(index)
                        }
                        if issues.isEmpty {
                            if store.issueInbox == nil {
                                LauncherMessage(
                                    symbol: "exclamationmark.circle",
                                    title: store.isIssueInboxLoading ? "Loading issues…" : "Couldn’t list issues with the GitHub CLI (gh)",
                                    isLoading: store.isIssueInboxLoading
                                )
                            } else {
                                LauncherMessage(symbol: .octicon(.issueOpened), title: isBlank ? "No recent open issues" : "No matching issues")
                            }
                        }
                    } else if mode == .projects {
                        projectRows
                    } else if mode == .palette {
                        ForEach(Array(rows.enumerated()), id: \.element.item) { index, row in
                            if isBlank, index == 0 || rows[index - 1].item.section != row.item.section {
                                LauncherSectionHeader(row.item.section == .openTab ? "Sessions" : "Actions")
                                    .padding(.top, index == 0 ? 0 : 6)
                            }
                            paletteRow(row, isHighlighted: index == highlighted)
                                .id(index)
                                .onTapGesture { run(row.target) }
                        }
                    } else {
                        if !hits.isEmpty {
                            LauncherSectionHeader("Sessions", count: hits.count)
                        }
                        ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                            hitRow(hit, isHighlighted: index == highlighted)
                                .id(index)
                                .onTapGesture { open(hit) }
                        }
                        if hits.isEmpty {
                            let isSearching = !isBlank && (store.searchIndexing != nil || searchedQuery != query)
                            LauncherMessage(
                                symbol: "magnifyingglass",
                                title: isBlank ? "Type to search every session’s prompts and replies" : isSearching ? "Searching…" : "No matching sessions",
                                isLoading: isSearching
                            )
                        }
                    }
                    if ranked.older > 0 || rankedIssues.older > 0 {
                        let note: LocalizedStringKey = ranked.older > 0
                            ? "^[\(ranked.older) older pull request](inflect: true) · Type to search"
                            : "^[\(rankedIssues.older) older issue](inflect: true) · Type to search"
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                }
                .padding(8)
                .onGeometryChange(for: Double.self) { $0.size.height } action: { resultsHeight = $0 }
            }
            .frame(height: min(max(resultsHeight, 64), 420))
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: highlighted) { proxy.scrollTo(highlighted) }
        }
    }

    @ViewBuilder
    private func issueRows(_ linked: [(pullRequest: LinkedPullRequest, opening: PullRequestOpening)]) -> some View {
        ForEach(linked, id: \.pullRequest.link) { row in
            Button { openLinkedPullRequests([row.pullRequest]) } label: {
                linkedPullRequestRow(row.pullRequest, opening: row.opening)
            }
            .buttonStyle(.plain)
            .disabled(!row.opening.isOpenable)
        }
        if linked.isEmpty, let selectedIssue, case .success? = issueResult, store.localCheckout(of: selectedIssue.repository) == nil {
            checkoutNotice(repository: selectedIssue.repository, url: selectedIssue.url)
        } else if linked.isEmpty {
            let message = switch issueResult {
            case .none: "Looking up linked pull requests…"
            case let .failure(error): error.message
            case .success: selectedIssue == nil ? "No open linked pull requests" : "Couldn’t start session"
            }
            let symbol: LauncherGlyph = if case .failure? = issueResult { "exclamationmark.circle" } else { .octicon(.pullRequest) }
            LauncherMessage(symbol: symbol, title: message, isLoading: issueResult == nil)
        }
    }

    private var matches: [Folder] {
        let typed = (query.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        let ranked = folders.enumerated()
            .compactMap { index, folder in FuzzyMatch.score(typed, name: URL(filePath: folder.path).lastPathComponent, path: folder.path).map { (index, $0, folder) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .map(\.2)
        var isDirectory: ObjCBool = false
        let isNewPath = typed.hasPrefix("/") && FileManager.default.fileExists(atPath: typed, isDirectory: &isDirectory) && isDirectory.boolValue
        let path = URL(filePath: typed).standardizedFileURL.path
        let typedFolder = isNewPath && !folders.contains { $0.path == path } ? [Folder(path: path, sessions: 0, lastActivity: nil)] : []
        return Array((typedFolder + ranked).prefix(Self.visibleMatches))
    }

    private func folderRow(_ folder: Folder, isHighlighted: Bool) -> some View {
        LauncherRowFrame(
            symbol: "folder.fill",
            tint: .accentColor,
            title: URL(filePath: folder.path).lastPathComponent,
            secondary: [(folder.path as NSString).abbreviatingWithTildeInPath],
            isHighlighted: isHighlighted,
            monospacedSecondary: true
        ) {
            if let activity = folder.lastActivity {
                LauncherBadge("\(folder.sessions) \(folder.sessions == 1 ? "session" : "sessions") · \(age(since: activity))")
            } else {
                LauncherBadge("New folder")
            }
        }
    }

    private func pullRequestRow(_ pullRequest: InboxPullRequest, isHighlighted: Bool) -> some View {
        let sessions = store.sessions(for: PullRequestLink(repository: pullRequest.repository, number: pullRequest.number))
        let state: PullRequestState = pullRequest.isDraft ? .draft : .open
        let tint = !pullRequest.isDraft && pullRequest.reviewDecision == .changesRequested ? theme.closed : state.color(in: theme)
        let author = pullRequest.role == .mine ? nil : pullRequest.author.map { "@\($0)" }
        let secondary = [
            pullRequest.repository,
            "#\(pullRequest.number)",
            author,
            "Updated \(age(since: pullRequest.updatedAt))",
        ].compactMap(\.self)

        return LauncherRowFrame(symbol: .octicon(Octicon(state)), tint: tint, title: pullRequest.title, secondary: secondary, isHighlighted: isHighlighted) {
            HStack(spacing: 5) {
                switch pullRequest.checks {
                case .passed:
                    LauncherBadge("Passed", symbol: "checkmark", tint: theme.working)
                        .accessibilityLabel("Checks passed")

                case .failed:
                    LauncherBadge("Failed", symbol: "xmark", tint: theme.closed)
                        .accessibilityLabel("Checks failed")

                case .running:
                    LauncherBadge("Running", symbol: "circle.fill", tint: theme.needsYou)
                        .accessibilityLabel("Checks running")

                case nil: EmptyView()
                }
                if pullRequest.reviewDecision == .approved {
                    LauncherBadge("Approved", tint: theme.working)
                } else if pullRequest.reviewDecision == .changesRequested {
                    LauncherBadge("Changes requested", tint: theme.closed)
                }
                if pullRequest.isDraft {
                    LauncherBadge("Draft")
                }
                if !sessions.isEmpty {
                    LauncherBadge("\(sessions.count) \(sessions.count == 1 ? "session" : "sessions")")
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func issueRow(_ issue: InboxIssue, isHighlighted: Bool) -> some View {
        let secondary = [
            issue.repository,
            "#\(issue.number)",
            issue.author.map { "@\($0)" },
            age(since: issue.updatedAt),
        ].compactMap(\.self)

        return LauncherRowFrame(symbol: .octicon(.issueOpened), tint: theme.working, title: issue.title, secondary: secondary, isHighlighted: isHighlighted) {
            HStack(spacing: 5) {
                ForEach(Array(issue.labels.prefix(2).enumerated()), id: \.offset) { _, label in
                    LauncherLabelCapsule(name: label.name, hex: label.color)
                }
                if issue.labels.count > 2 {
                    LauncherBadge("+\(issue.labels.count - 2)")
                }
                if issue.openPullRequestCount > 0 {
                    LauncherBadge(String(issue.openPullRequestCount), symbol: .octicon(.pullRequest))
                        .accessibilityLabel(Text(verbatim: "\(issue.openPullRequestCount) linked pull request\(issue.openPullRequestCount == 1 ? "" : "s")"))
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func checkoutNotice(repository: String, url: URL) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.badge.questionmark")
                .font(.headline)
                .foregroundStyle(theme.needsYou)
                .accessibilityHidden(true)
            Text(verbatim: "No local checkout of \(repository)")
                .fontWeight(.medium)
            Spacer(minLength: 8)
            Button { openOnGitHub(url) } label: {
                LauncherBadge("Open on GitHub", symbol: "arrow.up.right", tint: theme.needsYou)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(theme.needsYou.opacity(0.12), in: .rect(cornerRadius: 12))
        .padding(8)
    }

    private func linkedPullRequestRow(_ pullRequest: LinkedPullRequest, opening: PullRequestOpening) -> some View {
        let link = pullRequest.link
        let state: PullRequestState = pullRequest.isDraft ? .draft : .open
        let failed = opening.isOpenable && issueOpenFailures.contains(link)
        let status = failed ? "Couldn’t open session" : store.issuePullRequestStatus(pullRequest, opening: opening)
        let secondary = [link.repository, "#\(link.number)"] + (pullRequest.isDraft ? ["Draft"] : [])

        return LauncherRowFrame(symbol: .octicon(Octicon(state)), tint: state.color(in: theme), title: pullRequest.title, secondary: secondary) {
            LauncherBadge(status, tint: failed ? theme.closed : nil)
        }
        .opacity(opening.isOpenable ? 1 : 0.6)
    }

    private var paletteRows: [PaletteRow] {
        let openTabs = store.sidebarOrderedTabs.map { tab in
            let symbol = if tab.id == store.selectedTabID {
                "checkmark"
            } else if tab.kind == .shell {
                "terminal"
            } else {
                "bubble.left"
            }

            return PaletteRow(
                item: PaletteItem(id: tab.id.uuidString, section: .openTab, title: tab.title(terminalTitle: tab.terminal.title, sessionTitle: store.sessionTitle(of: tab)), detail: tab.folder),
                target: .item(.tab(tab.id)),
                symbol: symbol,
                trailing: URL(filePath: tab.sessionID.flatMap { store.sessionsByID[$0]?.checkout } ?? tab.folder).lastPathComponent
            )
        }
        let actions = AppAction.palette.filter { $0.isAvailable(in: store) }.map { action in
            PaletteRow(
                item: PaletteItem(id: action.title, section: .action, title: action.title(in: store), detail: action.keywords),
                target: .action(action),
                symbol: action.symbol,
                trailing: action.shortcut.map { shortcut in
                    [(EventModifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")].filter { shortcut.modifiers.contains($0.0) }.map(\.1).joined() + String(shortcut.key.character).uppercased()
                } ?? ""
            )
        }
        let open = Set(store.tabs.compactMap(\.sessionID))
        let recents = store.activeSessions.filter { !open.contains($0.id) }.sorted { $0.lastActivity > $1.lastActivity }.map { session in
            PaletteRow(
                item: PaletteItem(id: session.id, section: .recentSession, title: session.title, detail: session.cwd),
                target: .item(.session(session.id)),
                symbol: "clock.arrow.circlepath",
                trailing: "\(URL(filePath: session.checkout).lastPathComponent) · \(age(since: session.lastActivity))"
            )
        }
        let all = openTabs + actions + recents
        let byID = Dictionary(all.map { ($0.item.id, $0) }) { first, _ in first }
        let ranked = CommandPalette.rank(query, items: all.map(\.item), limit: 12).compactMap { byID[$0.id] }
        let typed = query.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, let search = actions.first(where: { $0.item.id == AppAction.searchSessions.title }) else { return ranked }

        let searchRow = PaletteRow(item: PaletteItem(id: search.item.id, section: .action, title: "Search Sessions for “\(typed)”", detail: ""), target: search.target, symbol: search.symbol, trailing: search.trailing)
        return ranked.map { $0.item.id == searchRow.item.id ? searchRow : $0 } + (ranked.contains { $0.item.id == searchRow.item.id } ? [] : [searchRow])
    }

    private func paletteRow(_ row: PaletteRow, isHighlighted: Bool) -> some View {
        LauncherRowFrame(symbol: .symbol(row.symbol), tint: row.item.section == .action ? .accentColor : .secondary, title: row.item.title, isHighlighted: isHighlighted) {
            if !row.trailing.isEmpty {
                Text(verbatim: row.trailing)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func hitRow(_ hit: SearchHit, isHighlighted: Bool) -> some View {
        let snippets = hit.snippets.map { snippet in
            snippet.highlights.reduce(into: AttributedString(snippet.text)) { text, range in
                guard let range = Range(range, in: text) else { return }

                text[range].foregroundColor = theme.foreground
                text[range].font = .caption.weight(.semibold)
            }
        }

        return LauncherRowFrame(symbol: "text.bubble", tint: .accentColor, title: hit.session.title, isHighlighted: isHighlighted, snippets: snippets) {
            Text(verbatim: "\(URL(filePath: hit.session.checkout).lastPathComponent) · \(age(since: hit.session.lastActivity))")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func move(by offset: Int, in count: Int) -> KeyPress.Result {
        guard count > 0 else { return .ignored }

        highlighted = min(max(highlighted + offset, 0), count - 1)
        return .handled
    }

    private func submit() {
        if issueReference != nil {
            if let linked = try? issueResult?.get() { openIssueResult(linked) }
            return
        }
        if mode == .projects {
            if let item = highlightedProject { open(item) }
            return
        }
        if mode == .issues {
            selectedIssue = highlightedIssue
            return
        }
        if let pastedPullRequest { return showInReview(pastedPullRequest) }
        if showsPullRequests {
            let pullRequests = rankedPullRequests.pullRequests
            if pullRequests.indices.contains(highlighted) { open(pullRequests[highlighted]) }
            return
        }
        if mode == .search {
            if hits.indices.contains(highlighted) { open(hits[highlighted]) }
            return
        }
        if mode == .palette {
            let rows = paletteRows
            if rows.indices.contains(highlighted) { run(rows[highlighted].target) }
            return
        }
        let matches = matches
        if matches.indices.contains(highlighted) { start(in: matches[highlighted].path) }
    }

    private func search() async {
        guard mode == .search else { return }

        let query = query
        let index = store.searchIndex
        let version = store.searchIndexVersion
        let sessions = store.activeSessions + store.archivedSessions
        let found = await Task.detached { index.search(query, in: sessions) }.value
        guard query == self.query, version == store.searchIndexVersion else { return }

        hits = found
        searchedQuery = query
        highlighted = min(highlighted, max(found.count - 1, 0))
    }

    private func run(_ target: PaletteTarget) {
        switch target {
        case let .item(item):
            store.activate(item)
            store.launcherMode = nil

        case .action(.searchSessions):
            store.launcherQuery = query.trimmingCharacters(in: .whitespaces)
            store.launcherMode = .search

        case let .action(action):
            action.perform(on: store)
            if store.launcherMode == .palette { store.launcherMode = nil }
        }
    }

    private func open(_ hit: SearchHit) {
        store.activate(.session(hit.id))
        store.launcherMode = nil
    }

    private func switchScope(to scope: LauncherMode) {
        if scope != mode { previousScope = mode }
        store.launcherQuery = query
        store.launcherMode = scope
    }

    private var mineChip: some View {
        Button { mineOnly.toggle() } label: {
            Label("Mine", systemImage: mineOnly ? "checkmark" : "person")
                .font(.caption.weight(.medium))
                .imageScale(.small)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(mineOnly ? Color.accentColor.opacity(0.25) : theme.foreground.opacity(0.09), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityValue(mineOnly ? "On" : "Off")
        .help("Show only items assigned to you")
    }

    @ViewBuilder private var projectNotices: some View {
        if let failure = store.projects.moveFailure {
            Divider()
            ProjectMoveNotice(failure: failure)
        }
        if let item = missingProjectItem, item.id == highlightedProject?.id, let repository = item.repository, let url = item.url {
            Divider()
            checkoutNotice(repository: repository, url: url)
        }
    }

    @ViewBuilder private var projectRows: some View {
        let entries = projectEntries
        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
            if let header = entry.header {
                LauncherSectionHeader(header, count: entry.count)
                    .padding(.top, index == 0 ? 0 : 6)
            }
            Button { open(entry.item) } label: {
                ProjectItemRow(
                    item: entry.item,
                    project: entry.project,
                    sessions: entry.item.kind == .pullRequest ? entry.item.repository.flatMap { repository in entry.item.number.map { store.sessions(for: PullRequestLink(repository: repository, number: $0)).count } } ?? 0 : 0,
                    isHighlighted: index == highlighted
                )
            }
            .buttonStyle(.plain)
            .disabled(entry.item.kind == .draft)
            .contextMenu { projectMenu(entry.item) }
            .id(index)
        }
        if entries.isEmpty {
            ProjectNotice(state: store.projects.state, hasProjects: !store.projects.selectedBoards.isEmpty, isFiltered: mineOnly || !query.allSatisfy(\.isWhitespace))
        }
    }

    @ViewBuilder
    private func projectMenu(_ item: ProjectItem) -> some View {
        if let url = item.url {
            Button("Open on GitHub") { openOnGitHub(url) }
        }
        ProjectMoveToStatusMenu(item: item)
    }

    private func open(_ item: ProjectItem) {
        guard let repository = item.repository, let number = item.number, let url = item.url else { return }
        guard item.kind == .pullRequest else {
            selectedIssue = InboxIssue(repository: repository, number: number, url: url, title: item.title, updatedAt: item.updatedAt ?? .now, openPullRequestCount: 0)
            return
        }

        let link = PullRequestLink(repository: repository, number: number)
        let opening = store.opening(of: link)
        if case .noCheckout = opening { return missingProjectItem = item }

        store.openPullRequest(link, url: url, opening: opening)
        store.launcherMode = nil
    }

    private func open(_ pullRequest: InboxPullRequest) {
        let link = PullRequestLink(repository: pullRequest.repository, number: pullRequest.number)
        if mode == .showPullRequestInReview { return showInReview(link) }

        let opening = store.opening(of: link)
        if case .noCheckout = opening { return missingCheckout = pullRequest }

        store.openPullRequest(link, url: pullRequest.url, opening: opening)
        store.launcherMode = nil
    }

    private func showInReview(_ link: PullRequestLink) {
        guard let tab = store.selectedTabID else { return }

        store.launcherMode = nil
        Task {
            if case let .failure(error) = await store.showPullRequestInReview(number: link.number, repository: link.repository, in: tab) {
                store.showPullRequestFailure = error.message
            }
        }
    }

    private func openLinkedPullRequests(_ pullRequests: [LinkedPullRequest]) {
        guard !pullRequests.isEmpty else { return }

        var selectsTab = true
        for pullRequest in pullRequests {
            let opening = store.opening(of: pullRequest.link)
            guard opening.isOpenable else { continue }

            if store.openPullRequest(pullRequest.link, url: pullRequest.url, opening: opening, selectsTab: selectsTab) {
                selectsTab = false
                issueOpenFailures.remove(pullRequest.link)
            } else {
                issueOpenFailures.insert(pullRequest.link)
            }
        }
        guard !selectsTab, issueOpenFailures.isEmpty, let linked = try? issueResult?.get(),
              linked.allSatisfy({ store.opening(of: $0.link).isOpenable })
        else { return }

        store.launcherMode = nil
    }

    private func lookup(_ issue: IssueReference) async -> Result<[LinkedPullRequest], IssuePullRequests.LookupError>? {
        #if DEBUG
        if Snapshot.output != nil { return Snapshot.linkedPullRequests(for: issue) }
        #endif
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return nil }

        return await Task.detached { PullRequestStatus.linkedPullRequests(issue: issue) }.value
    }

    private func openIssueResult(_ linked: [LinkedPullRequest]) {
        if linked.isEmpty, let selectedIssue {
            store.startIssueSession(repository: selectedIssue.repository, number: selectedIssue.number, url: selectedIssue.url)
        } else {
            openLinkedPullRequests(linked)
        }
    }

    private func openOnGitHub(_ url: URL) {
        store.launcherMode = nil
        #if DEBUG
        if Snapshot.launcherKeys != nil { return store.probeOpenedURLs.append(url) }
        #endif
        store.openLink(url)
    }

    private func start(_ agent: Agent, in path: String) {
        store.openSession(agent, cwd: path)
        store.launcherMode = nil
    }

    private func start(in path: String, checkout: NewSessionCheckout = .preferred) {
        store.openSession(cwd: path, checkout: checkout)
        store.launcherMode = nil
    }
}
