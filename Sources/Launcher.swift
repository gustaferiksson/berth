import BerthCore
import GhosttyTerminal
import SwiftUI
import UniformTypeIdentifiers

enum LauncherMode {
    case newSession, search, palette, pullRequests, issues
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
        let icon: Image
        let trailing: String
    }

    let mode: LauncherMode

    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.openURL) private var openURL
    @AppStorage(GeneralSettings.worktreeKey) private var startsInWorktree = false
    @State private var query: String
    @State private var highlighted = 0
    @State private var folders: [Folder] = []
    @State private var hits: [SearchHit] = []
    @State private var searchedQuery = ""
    @State private var resultsHeight = 0.0
    @State private var isBrowsing = false
    @State private var missingCheckout: InboxPullRequest?
    @State private var selectedIssue: InboxIssue?
    @State private var issueLookup: (reference: IssueReference, result: Result<[LinkedPullRequest], IssuePullRequests.LookupError>)?
    @State private var issueOpenFailures: Set<PullRequestLink> = []
    @FocusState private var isQueryFocused: Bool

    init(mode: LauncherMode, query: String) {
        self.mode = mode
        _query = State(initialValue: query)
    }

    private static let visibleMatches = 6

    private static let scopes: [(mode: LauncherMode, title: String)] = [(.newSession, "Folders"), (.pullRequests, "Pull Requests"), (.issues, "Issues")]

    private var nextScope: (mode: LauncherMode, title: String)? {
        guard let index = Self.scopes.firstIndex(where: { $0.mode == mode }) else { return nil }

        return Self.scopes[(index + 1) % Self.scopes.count]
    }

    private var issueReference: IssueReference? {
        guard mode == .pullRequests || mode == .issues else { return nil }

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

    private var rankedPullRequests: (pullRequests: [InboxPullRequest], older: Int) {
        guard mode == .pullRequests, issueReference == nil else { return ([], 0) }

        return PullRequestInbox.rank(query, in: (store.inbox ?? []).filter { store.launcherRole == nil || $0.role == store.launcherRole }, now: .now)
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
        case .pullRequests: ranked.pullRequests.count
        case .issues: issues.issues.count
        case .search: hits.count
        }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: [LauncherMode.newSession: "chevron.right", .palette: "command", .pullRequests: "arrow.triangle.pull", .issues: "exclamationmark.circle"][mode] ?? "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                TextField("Query", text: $query, prompt: Text([LauncherMode.newSession: "Search folders or type a path", .palette: "Type a command or session", .pullRequests: "Search pull requests or paste an issue", .issues: "Search or paste an issue"][mode] ?? "Search all sessions"))
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isQueryFocused)
                    .onKeyPress(.downArrow) { move(by: 1, in: count) }
                    .onKeyPress(.upArrow) { move(by: -1, in: count) }
                    .onKeyPress(.tab) {
                        guard let nextScope else { return .ignored }

                        switchScope(to: nextScope.mode)
                        return .handled
                    }
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.option) else { return .ignored }

                        if let url = selectedIssue?.url ?? issueReference?.url ?? highlightedIssue?.url {
                            openOnGitHub(url)
                            return .handled
                        }
                        let pullRequests = rankedPullRequests.pullRequests
                        if mode == .pullRequests, pullRequests.indices.contains(highlighted) {
                            openOnGitHub(pullRequests[highlighted].url)
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

                        store.launcherQuery = String(query.dropFirst())
                        store.launcherMode = .pullRequests
                    }
                if let role = store.launcherRole, mode == .pullRequests, issue == nil {
                    Button { store.launcherRole = nil } label: {
                        Label(role.title, systemImage: "xmark")
                            .font(.subheadline)
                            .imageScale(.small)
                            .padding(.horizontal, 8)
                            .frame(height: 20)
                            .background(theme.foreground.opacity(0.1), in: .capsule)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .help("Show all pull requests")
                }
                if nextScope != nil {
                    HStack(spacing: 0) {
                        ForEach(Self.scopes, id: \.mode) { scope, title in
                            Button { switchScope(to: scope) } label: {
                                Text(title)
                                    .font(.subheadline)
                                    .padding(.horizontal, 8)
                                    .frame(height: 20)
                                    .background(theme.foreground.opacity(scope == mode ? 0.15 : 0), in: .capsule)
                                    .contentShape(.capsule)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(theme.foreground.opacity(0.1), in: .capsule)
                    .help("Switch launcher scope (⇥)")
                }
                if mode == .newSession {
                    Button { isBrowsing = true } label: {
                        Text("Browse…")
                            .font(.subheadline)
                            .padding(.horizontal, 8)
                            .frame(height: 20)
                            .background(theme.foreground.opacity(0.1), in: .capsule)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("o")
                    .help("Choose a folder (⌘O)")
                }
            }
            .padding(16)
            Divider()
            if mode == .newSession {
                folderList(matches)
            } else {
                results(rows, pullRequests: ranked.pullRequests, issues: issues.issues, issue: issue, linked: linked)
            }
            if let pullRequest, missingCheckout == pullRequest {
                Divider()
                checkoutNotice(repository: pullRequest.repository, url: pullRequest.url)
            }
            Divider()
            HStack(spacing: 16) {
                if mode == .newSession {
                    let other = Store.otherAgent
                    let agent = other == nil ? "" : " \(Store.defaultAgent.name)"
                    hint("↩", target.map { "Start\(agent) in \(URL(filePath: $0.path).lastPathComponent)" } ?? "Start\(agent)")
                    if startsInWorktree { hint("⌥↩", "Main Checkout") }
                    if let other { hint("⌥⇧↩", other.name) }
                    hint("↑↓", "Folder")
                } else if issue != nil {
                    let openable = linked.count { $0.opening.isOpenable }
                    if openable > 0 { hint("↩", "Open \(openable) Pull Request\(openable == 1 ? "" : "s")") }
                    hint("⌥↩", "Open on GitHub")
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
                    hint("↩", label)
                    hint("⌥↩", "Open on GitHub")
                } else if mode == .issues {
                    if let issueRow {
                        hint("↩", issueRow.openPullRequestCount == 0 ? "Start" : "Open PRs")
                        hint("⌥↩", "GitHub")
                    }
                    hint("↑↓", "Issue")
                } else if mode == .palette {
                    hint("↩", row.map { if case .action = $0.target { "Run" } else if $0.item.section == .openTab { "Switch To" } else { "Resume" } } ?? "Run")
                    hint("↑↓", "Select")
                } else {
                    hint("↩", "Open")
                    hint("↑↓", "Session")
                }
                if let nextScope { hint("⇥", nextScope.title) }
                Spacer()
                if ranked.older > 0 {
                    Text("^[\(ranked.older) older pull request](inflect: true) · Type to search")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if issues.older > 0 {
                    Text("^[\(issues.older) older issue](inflect: true) · Type to search")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if mode == .search, let indexing = store.searchIndexing {
                    Text("Indexing \(indexing.done)/\(indexing.total)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                hint("esc", mode == .newSession ? "Cancel" : "Close")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: mode == .newSession ? 560 : 640)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .padding(.horizontal, 24)
        .onExitCommand { store.launcherMode = nil }
        .onAppear {
            store.launcherQuery = ""
            isQueryFocused = true
            if mode == .search { store.updateSearchIndex() }
            if mode == .pullRequests { store.refreshInbox() }
            if mode == .issues { store.refreshIssueInbox() }
            if mode == .pullRequests || mode == .issues { store.refreshLocalClones() }
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
        .fileImporter(isPresented: $isBrowsing, allowedContentTypes: [.folder]) { result in
            guard case let .success(url) = result else { return }

            start(in: url.path)
        }
    }

    private func folderList(_ matches: [Folder]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(matches.enumerated()), id: \.element) { index, folder in
                folderRow(folder, isHighlighted: index == highlighted)
                    .onTapGesture { start(in: folder.path) }
            }
            if matches.isEmpty {
                Text(folders.isEmpty ? "No session folders yet. Type a path or browse." : "No matching folders")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
        }
        .padding(8)
    }

    private func results(_ rows: [PaletteRow], pullRequests: [InboxPullRequest], issues: [InboxIssue], issue: IssueReference?, linked: [(pullRequest: LinkedPullRequest, opening: PullRequestOpening)]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if issue != nil {
                        issueRows(linked)
                    } else if mode == .pullRequests {
                        ForEach(Array(pullRequests.enumerated()), id: \.element.id) { index, pullRequest in
                            if index == 0 || pullRequests[index - 1].role != pullRequest.role {
                                Text(pullRequest.role.title)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.top, index == 0 ? 4 : 12)
                                    .padding(.bottom, 4)
                            }
                            pullRequestRow(pullRequest, isHighlighted: index == highlighted)
                                .id(index)
                                .onTapGesture { open(pullRequest) }
                        }
                        if pullRequests.isEmpty {
                            Text(store.inbox == nil ? store.isInboxLoading ? "Loading pull requests…" : "Couldn’t list pull requests with the GitHub CLI (gh)" : query.allSatisfy(\.isWhitespace) ? "No open pull requests need you" : "No matching pull requests")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                    } else if mode == .issues {
                        ForEach(Array(issues.enumerated()), id: \.element.id) { index, issue in
                            Button { selectedIssue = issue } label: {
                                issueRow(issue, isHighlighted: index == highlighted)
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                        if issues.isEmpty {
                            Text(store.issueInbox == nil ? store.isIssueInboxLoading ? "Loading issues…" : "Couldn’t list issues with the GitHub CLI (gh)" : query.allSatisfy(\.isWhitespace) ? "No recent open issues" : "No matching issues")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                    } else if mode == .palette {
                        ForEach(Array(rows.enumerated()), id: \.element.item) { index, row in
                            if query.allSatisfy(\.isWhitespace), index == 0 || rows[index - 1].item.section != row.item.section {
                                Text(row.item.section == .openTab ? "Sessions" : "Actions")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.top, index == 0 ? 4 : 12)
                                    .padding(.bottom, 4)
                            }
                            paletteRow(row, isHighlighted: index == highlighted)
                                .id(index)
                                .onTapGesture { run(row.target) }
                        }
                    } else {
                        ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                            hitRow(hit, isHighlighted: index == highlighted)
                                .id(index)
                                .onTapGesture { open(hit) }
                        }
                    }
                    if mode == .search, hits.isEmpty {
                        Text(query.allSatisfy(\.isWhitespace) ? "Type to search every session’s prompts and replies" : store.searchIndexing == nil && searchedQuery == query ? "No matching sessions" : "Searching…")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                }
                .padding(8)
                .onGeometryChange(for: Double.self) { $0.size.height } action: { resultsHeight = $0 }
            }
            .frame(height: min(max(resultsHeight, 64), 480))
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
            Text(message)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 48)
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
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(filePath: folder.path).lastPathComponent)
                    .fontWeight(.medium)
                Text((folder.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            (folder.lastActivity.map { Text("^[\(folder.sessions) session](inflect: true) · \(age(since: $0))") } ?? Text("New folder"))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(minHeight: 44)
        .background(theme.foreground.opacity(isHighlighted ? 0.1 : 0), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
    }

    private func pullRequestRow(_ pullRequest: InboxPullRequest, isHighlighted: Bool) -> some View {
        let sessions = store.sessions(for: PullRequestLink(repository: pullRequest.repository, number: pullRequest.number))
        return Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
            GridRow(alignment: .firstTextBaseline) {
                Text(pullRequest.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Color.clear.gridCellUnsizedAxes(.vertical)
                (sessions.first.map { Text("^[\(sessions.count) session](inflect: true) · \(age(since: $0.lastActivity))") } ?? Text("No session"))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(sessions.isEmpty ? theme.secondary : theme.foreground)
                    .gridColumnAlignment(.trailing)
            }
            GridRow(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    Text((pullRequest.repository as NSString).lastPathComponent)
                    PullRequestTag(pullRequest: PullRequest(number: pullRequest.number, url: pullRequest.url, title: pullRequest.title, state: pullRequest.isDraft ? .draft : .open, checks: pullRequest.checks))
                    if pullRequest.isDraft { Text("Draft") }
                    if pullRequest.reviewDecision == .approved { Text("Approved") }
                    if pullRequest.reviewDecision == .changesRequested { Text("Changes requested") }
                    if let author = pullRequest.author, pullRequest.role != .mine { Text(verbatim: "@\(author)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                Color.clear.gridCellUnsizedAxes(.vertical)
                Text("Updated \(age(since: pullRequest.updatedAt))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(theme.foreground.opacity(isHighlighted ? 0.1 : 0), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
    }

    private func issueRow(_ issue: InboxIssue, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text("\(issue.repository) #\(issue.number)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(issue.openPullRequestCount == 0 ? "Start Issue Session" : issue.openPullRequestCount == 1 ? "1 PR" : "\(issue.openPullRequestCount) PRs")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(theme.foreground.opacity(isHighlighted ? 0.1 : 0), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
    }

    private func checkoutNotice(repository: String, url: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.badge.questionmark")
                .foregroundStyle(.secondary)
            Text("No local checkout of \(repository)")
            Spacer(minLength: 8)
            Button("Open on GitHub") { openOnGitHub(url) }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func linkedPullRequestRow(_ pullRequest: LinkedPullRequest, opening: PullRequestOpening) -> some View {
        let link = pullRequest.link
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pullRequest.title)
                    .fontWeight(.medium)
                Text("\(link.repository)#\(link.number)\(pullRequest.isDraft ? " · Draft" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(opening.isOpenable && issueOpenFailures.contains(link) ? "Couldn’t open session" : store.issuePullRequestStatus(pullRequest, opening: opening))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(.rect)
    }

    private var paletteRows: [PaletteRow] {
        let openTabs = store.sidebarOrderedTabs.map { tab in
            let icon = if tab.id == store.selectedTabID {
                Image(systemName: "checkmark")
            } else if tab.kind == .shell {
                Image(systemName: "terminal")
            } else {
                Image(systemName: "bubble.left")
            }

            return PaletteRow(
                item: PaletteItem(id: tab.id.uuidString, section: .openTab, title: tab.title(terminalTitle: tab.terminal.title, sessionTitle: store.sessionTitle(of: tab)), detail: tab.folder),
                target: .item(.tab(tab.id)),
                icon: icon,
                trailing: URL(filePath: tab.sessionID.flatMap { store.sessionsByID[$0]?.checkout } ?? tab.folder).lastPathComponent
            )
        }
        let actions = AppAction.palette.filter { $0.isAvailable(in: store) }.map { action in
            PaletteRow(
                item: PaletteItem(id: action.title, section: .action, title: action.title(in: store), detail: action.keywords),
                target: .action(action),
                icon: Image(systemName: action.symbol),
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
                icon: Image(systemName: "clock.arrow.circlepath"),
                trailing: "\(URL(filePath: session.checkout).lastPathComponent) · \(age(since: session.lastActivity))"
            )
        }
        let all = openTabs + actions + recents
        let byID = Dictionary(all.map { ($0.item.id, $0) }) { first, _ in first }
        let ranked = CommandPalette.rank(query, items: all.map(\.item), limit: 12).compactMap { byID[$0.id] }
        let typed = query.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, let search = actions.first(where: { $0.item.id == AppAction.searchSessions.title }) else { return ranked }

        let searchRow = PaletteRow(item: PaletteItem(id: search.item.id, section: .action, title: "Search Sessions for “\(typed)”", detail: ""), target: search.target, icon: search.icon, trailing: search.trailing)
        return ranked.map { $0.item.id == searchRow.item.id ? searchRow : $0 } + (ranked.contains { $0.item.id == searchRow.item.id } ? [] : [searchRow])
    }

    private func paletteRow(_ row: PaletteRow, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            row.icon
                .scaledToFit()
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 13)
            Text(row.item.title)
            Spacer(minLength: 8)
            Text(row.trailing)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .truncationMode(.middle)
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(minHeight: 32)
        .background(theme.foreground.opacity(isHighlighted ? 0.1 : 0), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
    }

    private func hitRow(_ hit: SearchHit, isHighlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(hit.session.title)
                    .fontWeight(.medium)
                Spacer(minLength: 8)
                Text("\(URL(filePath: hit.session.checkout).lastPathComponent) · \(age(since: hit.session.lastActivity))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
            }
            ForEach(hit.snippets, id: \.self) { snippet in
                Text(snippet.highlights.reduce(into: AttributedString(snippet.text)) { text, range in
                    guard let range = Range(range, in: text) else { return }

                    text[range].foregroundColor = theme.foreground
                    text[range].font = .caption.weight(.semibold)
                })
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.foreground.opacity(isHighlighted ? 0.1 : 0), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption.monospaced())
                .padding(.horizontal, 4)
                .frame(minWidth: 20, minHeight: 16)
                .background(theme.foreground.opacity(0.1), in: .rect(cornerRadius: 4))
            Text(label)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
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
        if mode == .issues {
            selectedIssue = highlightedIssue
            return
        }
        if mode == .pullRequests {
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
        store.launcherQuery = query
        store.launcherMode = scope
    }

    private func open(_ pullRequest: InboxPullRequest) {
        let link = PullRequestLink(repository: pullRequest.repository, number: pullRequest.number)
        let opening = store.opening(of: link)
        if case .noCheckout = opening { return missingCheckout = pullRequest }

        store.openPullRequest(link, url: pullRequest.url, opening: opening)
        store.launcherMode = nil
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
            startIssueSession(selectedIssue)
        } else {
            openLinkedPullRequests(linked)
        }
    }

    private func startIssueSession(_ issue: InboxIssue) {
        guard let folder = store.localCheckout(of: issue.repository),
              store.openSession(cwd: folder, checkout: .worktree, pasting: "Work on issue #\(issue.number) (\(issue.url.absoluteString)).") != nil
        else { return }

        store.isHarborShown = false
        store.launcherMode = nil
    }

    private func openOnGitHub(_ url: URL) {
        store.launcherMode = nil
        #if DEBUG
        if Snapshot.launcherKeys != nil { return store.probeOpenedURLs.append(url) }
        #endif
        openURL(url)
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
