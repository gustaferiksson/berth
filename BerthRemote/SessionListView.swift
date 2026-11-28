import SwiftUI

struct SessionListView: View {
    @Environment(RemoteClient.self) private var client
    @Environment(UpdateCheck.self) private var updates
    @State private var selection: String? = {
        #if DEBUG
        if RemoteClient.isDemo, RemoteClient.showsDemoList { return UserDefaults.standard.bool(forKey: "snapshotDemoOpen") ? "demo" : nil }
        #endif
        return UserDefaults.standard.string(forKey: "remoteSession")
    }()

    @State private var columnVisibility: NavigationSplitViewVisibility = {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "snapshotRegularWidth") { return .all }
        #endif
        return .automatic
    }()

    @FocusState private var isSearching: Bool

    @State private var isStartingSession = false
    @State private var query = UserDefaults.standard.string(forKey: "snapshotQuery") ?? ""
    @State private var expandedGroups: [String: Bool] = [:]
    @State private var groupsShowingAll: Set<String> = []
    @State private var isShowingSettings = UserDefaults.standard.bool(forKey: "snapshotSettings")
    @State private var isShowingUsage = UserDefaults.standard.bool(forKey: "snapshotUsageSheet")
    @State private var feedback = ActionFeedback(count: 0, action: nil)

    var body: some View {
        let pinned = Set(client.groups.first { $0.id == "pinned" }?.sessions.map(\.id) ?? [])
        let groups = visibleGroups
        let searchedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchesTranscripts = client.features.contains(RemoteSearchFeature.name) && searchedQuery.count >= RemoteSearchFeature.minimumQueryLength

        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selection) {
                if let version = updates.available, query.isEmpty {
                    Section {
                        Link(destination: UpdateCheck.installURL) {
                            Label("Install Berth Remote \(version)", systemImage: "arrow.down.circle")
                        }
                    }
                }
                if query.isEmpty {
                    let usageGroups = client.usageGroups(at: .now)
                    if !usageGroups.isEmpty {
                        Section {
                            ForEach(usageGroups) { group in
                                UsageCard(group: group) { isShowingUsage = true }
                            }
                        }
                    }
                }
                ForEach(groups) { group in
                    let isCollapsed = group.isCollapsed ?? (group.id == "recent:older")
                    let expansion = if query.isEmpty {
                        Binding { expandedGroups[group.id, default: !isCollapsed] } set: { expandedGroups[group.id] = $0 }
                    } else {
                        Binding.constant(true)
                    }
                    let count = group.sessions.count
                    let limit = query.isEmpty ? max(0, group.visibleCount ?? count) : count
                    let hiddenCount = max(0, count - limit)
                    let showsAll = groupsShowingAll.contains(group.id)
                    Section {
                        if expansion.wrappedValue {
                            ForEach(listedSessions(in: group)) { session in
                                SessionRow(session: session, groupID: group.id, isPinned: session.isPinned ?? pinned.contains(session.id)) {
                                    selection = session.id
                                } didAct: { action in
                                    feedback = ActionFeedback(count: feedback.count + 1, action: action)
                                }
                            }
                            if hiddenCount > 0 {
                                Button {
                                    withAnimation {
                                        if showsAll {
                                            groupsShowingAll.remove(group.id)
                                        } else {
                                            groupsShowingAll.insert(group.id)
                                        }
                                    }
                                } label: {
                                    Text(showsAll ? "Show Less" : "Show More (\(hiddenCount))")
                                        .font(.subheadline)
                                        .foregroundStyle(Color.accentColor)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(.rect)
                                        .hoverEffect()
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        if query.isEmpty {
                            SessionSectionHeader(title: group.title, count: count, isExpanded: expansion)
                        } else {
                            Text(group.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.secondary)
                                .textCase(nil)
                        }
                    }
                }
                if searchesTranscripts {
                    TranscriptSearchSection(query: searchedQuery)
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .sensoryFeedback(trigger: feedback) { _, new in
                new.action == .archive ? .warning : .impact(weight: .light)
            }
            .overlay {
                if client.groups.isEmpty, client.state != .connected {
                    ContentUnavailableView("Reconnecting", systemImage: "wifi.slash", description: Text("Berth Remote reconnects when your Mac is reachable."))
                } else if client.groups.isEmpty {
                    ContentUnavailableView("No Sessions", systemImage: "text.bubble", description: Text("Start a session with the + button."))
                } else if groups.isEmpty, !searchesTranscripts {
                    ContentUnavailableView.search
                }
            }
            .searchable(text: $query, prompt: "Search Sessions")
            .searchFocused($isSearching)
            .refreshable { await client.refresh() }
            .navigationTitle("Sessions")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { isShowingSettings = true }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("New Session", systemImage: "plus") { isStartingSession = true }
                        .disabled(client.folders.isEmpty || client.state != .connected)
                }
            }
            .sheet(isPresented: $isStartingSession) {
                NewSessionView()
            }
            .sheet(isPresented: $isShowingUsage) {
                UsageSheet()
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsView()
            }
            .onChange(of: selection) {
                UserDefaults.standard.set(selection, forKey: "remoteSession")
            }
            .onChange(of: client.openedSessionID, initial: true) {
                guard let id = client.openedSessionID else { return }

                client.openedSessionID = nil
                selection = id
            }
        } detail: {
            if let selection {
                SessionView(sessionID: selection)
                    .id(selection)
            } else {
                ContentUnavailableView("No Session Selected", systemImage: "text.bubble", description: Text("Choose a session from the sidebar."))
            }
        }
        .focusedSceneValue(\.sessionListActions, SessionListActions(
            canStartSession: !client.folders.isEmpty && client.state == .connected,
            newSession: { isStartingSession = true },
            search: {
                columnVisibility = .all
                isSearching = true
            },
            refresh: { Task { await client.refresh() } },
            selectPrevious: { moveSelection(by: -1) },
            selectNext: { moveSelection(by: 1) }
        ))
    }

    private func listedSessions(in group: RemoteGroup) -> [RemoteSession] {
        let isCollapsed = group.isCollapsed ?? (group.id == "recent:older")
        guard !query.isEmpty || expandedGroups[group.id, default: !isCollapsed] else { return [] }

        let count = group.sessions.count
        let limit = query.isEmpty ? max(0, group.visibleCount ?? count) : count
        return Array(group.sessions.prefix(groupsShowingAll.contains(group.id) ? count : limit))
    }

    private func moveSelection(by offset: Int) {
        let ids = visibleGroups.flatMap { listedSessions(in: $0).map(\.id) }
        guard !ids.isEmpty else { return }

        let current = selection.flatMap { ids.firstIndex(of: $0) }
        let target = current.map { min(max($0 + offset, 0), ids.count - 1) } ?? (offset > 0 ? 0 : ids.count - 1)
        selection = ids[target]
    }

    private var visibleGroups: [RemoteGroup] {
        guard !query.isEmpty else { return client.groups.filter { !$0.sessions.isEmpty } }

        let matches = { (session: RemoteSession) in
            [session.title, session.folder, session.branch ?? ""].contains { $0.localizedStandardContains(query) }
        }
        return client.groups.compactMap { group in
            let sessions = group.sessions.filter(matches)
            guard !sessions.isEmpty else { return nil }

            return RemoteGroup(id: group.id, title: group.title, sessions: sessions, isCollapsed: group.isCollapsed, visibleCount: group.visibleCount)
        }
    }
}

private struct SessionSectionHeader: View {
    let title: String
    let count: Int
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation { isExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Text(title)
                Spacer(minLength: 0)
                if !isExpanded {
                    Text(count, format: .number)
                }
                Image(systemName: isExpanded ? "chevron.down" : "chevron.forward")
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.secondary)
            .contentShape(.rect)
            .hoverEffect()
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(isExpanded ? Text(title) : Text("\(title), ^[\(count) session](inflect: true)"))
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
    }
}

private struct ActionFeedback: Equatable {
    let count: Int
    let action: RemoteSessionAction?
}

struct ConnectionStatus: View {
    @Environment(RemoteClient.self) private var client

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Reconnecting…")
                .font(.footnote.weight(.medium))
            Button("Retry Now") { client.retryNow() }
                .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .contain)
    }
}

private struct SessionRow: View {
    let session: RemoteSession
    let groupID: String
    let isPinned: Bool
    let open: () -> Void
    let didAct: (RemoteSessionAction) -> Void

    @Environment(RemoteClient.self) private var client
    @State private var isShowingPullRequest = false

    var body: some View {
        let toggleRead = session.isUnread == true ? RemoteSessionAction.markRead : .markUnread
        let toggleRule = isPinned ? RemoteSessionAction.unpin : .pin
        let agent = (session.agent ?? .legacyClaude).name
        let hasTriage = client.features.contains(RemoteTriageFeature.name)
        let isDone = groupID == RemoteTriageFeature.doneGroupID
        let isSnoozed = groupID == RemoteTriageFeature.snoozedGroupID
        let toggleFlag = session.isFlagged == true ? RemoteSessionAction.unflag : .flag

        Button(action: open) {
            SessionRowLabel(session: session)
                .contentShape(.rect)
                .hoverEffect()
        }
        .buttonStyle(.plain)
        .listRowInsets(.vertical, 0)
        .accessibilityValue(session.isOpen ? Text("\(agent), Open on Mac") : Text(agent))
        .accessibilityHint("Opens the session")
        .swipeActions(edge: .leading) {
            Button(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin") { perform(toggleRule) }
                .tint(.yellow)
            if hasTriage {
                Button(session.isFlagged == true ? "Unflag" : "Flag", systemImage: session.isFlagged == true ? "flag.slash" : "flag") { perform(toggleFlag) }
                    .tint(.orange)
            }
        }
        .swipeActions(edge: .trailing) {
            if isDone, hasTriage {
                Button("Mark as Not Done", systemImage: "arrow.uturn.backward") { perform(.unarchive) }
                    .tint(.green)
            } else if session.status == nil {
                Button("Mark as Done", systemImage: "checkmark") { perform(.archive) }
                    .tint(.green)
            }
            Button(session.isUnread == true ? "Mark as Read" : "Mark as Unread", systemImage: session.isUnread == true ? "envelope.open" : "envelope.badge") { perform(toggleRead) }
                .tint(.blue)
        }
        .sheet(isPresented: $isShowingPullRequest) {
            PullRequestSheet(sessionID: session.id)
        }
        .contextMenu {
            Button("Open on Mac", systemImage: "macbook") { perform(.show) }
            Button(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin") { perform(toggleRule) }
            Button(session.isUnread == true ? "Mark as Read" : "Mark as Unread", systemImage: session.isUnread == true ? "envelope.open" : "envelope.badge") { perform(toggleRead) }
            if hasTriage {
                Button(session.isFlagged == true ? "Unflag" : "Flag", systemImage: session.isFlagged == true ? "flag.slash" : "flag") { perform(toggleFlag) }
                if isSnoozed {
                    Button("Unsnooze", systemImage: "moon.zzz.fill") { perform(.unsnooze) }
                } else if !isDone {
                    Menu("Snooze", systemImage: "moon.zzz") {
                        Button("1 Hour") { perform(.snoozeOneHour) }
                        Button("Tomorrow") { perform(.snoozeTomorrow) }
                        Button("Until It Needs You") { perform(.snoozeUntilNeedsYou) }
                    }
                }
            }
            if let pullRequest = session.pullRequest, client.features.contains(RemotePullRequestFeature.name) {
                Button { isShowingPullRequest = true } label: { Label("Pull Request #\(String(pullRequest.number))", image: Octicon.pullRequest.assetName()) }
            } else if let pullRequest = session.pullRequest, pullRequest.url.scheme == "https" {
                Link(destination: pullRequest.url) {
                    Label("Open Pull Request #\(String(pullRequest.number))", image: Octicon.pullRequest.assetName())
                }
            }
            if isDone, hasTriage {
                Divider()
                Button("Mark as Not Done", systemImage: "arrow.uturn.backward") { perform(.unarchive) }
            } else if session.status == nil {
                Divider()
                Button("Mark as Done", systemImage: "checkmark", role: .destructive) { perform(.archive) }
            }
        } preview: {
            SessionPreview(session: session)
        }
    }

    private func perform(_ action: RemoteSessionAction) {
        didAct(action)
        client.send(.session(sessionID: session.id, action: action))
    }
}

private struct SessionPreview: View {
    let session: RemoteSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.title)
                .font(.headline)
            Text(session.folder)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let branch = session.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let pullRequest = session.pullRequest {
                PullRequestTag(pullRequest: pullRequest)
            }
        }
        .padding()
        .frame(width: 320, alignment: .leading)
    }
}

private struct SessionRowLabel: View {
    let session: RemoteSession

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var unreadDotSize = 10.0

    var body: some View {
        let isAccessibility = dynamicTypeSize.isAccessibilitySize
        let isUnread = session.isUnread == true
        let repo = Text(verbatim: URL(filePath: session.folder).lastPathComponent)
        let location = session.branch.map { branch in
            Text("\(repo) · \(Text(verbatim: branch))")
        } ?? repo

        let subtitle = location
            .font(.subheadline)
            .foregroundStyle(Color.secondary)
            .lineLimit(isAccessibility ? nil : 1)
            .truncationMode(.middle)

        let pullRequest = Group {
            if let watch = session.pullRequestWatch, session.status == "idle" || session.status == nil {
                Image(systemName: "eye")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(watch.title)
            } else if let pullRequest = session.pullRequest {
                PullRequestTag(pullRequest: pullRequest)
            }
        }

        let time = HStack(spacing: 6) {
            SessionStatusSlot(session: session)
            SessionTime(session: session)
        }
        .fixedSize(horizontal: true, vertical: false)

        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(isUnread ? Color.blue : Color.clear)
                .frame(width: unreadDotSize, height: unreadDotSize)
                .padding(.top, unreadDotSize / 2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Unread")
                .accessibilityHidden(!isUnread)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    HStack(spacing: 4) {
                        Text(session.title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.primary)
                            .lineLimit(isAccessibility ? 2 : 1)
                            .fixedSize(horizontal: false, vertical: true)
                        if session.isFlagged == true {
                            Image(systemName: "flag.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .accessibilityLabel("Flagged")
                        }
                        if session.isLocked {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Locked")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !isAccessibility {
                        time
                    }
                }
                if isAccessibility {
                    subtitle
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            time
                            pullRequest
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            time
                            pullRequest
                        }
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        subtitle
                            .frame(maxWidth: .infinity, alignment: .leading)
                        pullRequest
                    }
                }
            }
        }
        .padding(.vertical, 10)
        .opacity(session.isLocked ? 0.55 : 1)
        .accessibilityElement(children: .combine)
    }
}

private struct SessionStatusSlot: View {
    let session: RemoteSession

    var body: some View {
        Group {
            if session.status == "waiting" {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Needs you")
            } else if session.status == "busy" {
                Image(systemName: "circle.fill")
                    .imageScale(.small)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Working")
            } else if session.status == "shell" {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Background task running")
            }
        }
        .font(.caption2)
    }
}

private struct PullRequestTag: View {
    let pullRequest: RemotePullRequest

    @ScaledMetric(relativeTo: .caption) private var iconSize = 12.0
    @ScaledMetric(relativeTo: .caption) private var checkDotSize = 5.0

    var body: some View {
        let tint: Color = switch pullRequest.state {
        case "Open": .green
        case "Merged": .purple
        case "Closed": .red
        default: .secondary
        }
        let checks = ["Open", "Draft"].contains(pullRequest.state) ? pullRequest.checks : nil

        HStack(spacing: 4) {
            OcticonImage(Octicon(pullRequestState: pullRequest.state), size: iconSize)
                .imageScale(.small)
                .foregroundStyle(tint)
            Text(verbatim: "#\(pullRequest.number)")
            if let checks {
                Group {
                    if checks == "passed" || checks == "failed" {
                        Image(systemName: checks == "passed" ? "checkmark" : "xmark")
                            .imageScale(.small)
                            .fontWeight(.semibold)
                            .accessibilityHidden(true)
                    } else {
                        Circle()
                            .frame(width: checkDotSize, height: checkDotSize)
                    }
                }
                .foregroundStyle(ChecksStyle.color(checks))
            }
        }
        .font(.caption)
        .foregroundStyle(Color.secondary)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pull request \(String(pullRequest.number)), \(pullRequest.state)\(checks.map { ", " + ChecksStyle.title($0) } ?? "")")
    }
}

private struct SessionTime: View {
    let session: RemoteSession

    var body: some View {
        Group {
            if session.status == "busy" {
                let since = session.turnStartedAt ?? session.lastPrompt ?? session.lastActivity
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = Duration.seconds(max(0, context.date.timeIntervalSince(since)).rounded(.down))
                    Text(elapsed.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 1)))
                }
            } else {
                TimelineView(.everyMinute) { context in
                    Text(age(at: context.date))
                }
            }
        }
        .font(.subheadline)
        .foregroundStyle(Color.secondary)
    }

    private func age(at now: Date) -> String {
        let shown = session.lastPrompt ?? session.lastActivity
        let seconds = now.timeIntervalSince(shown)
        if seconds < 60 { return "Now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 6 * 3600 || Calendar.current.isDateInToday(shown) { return "\(Int(seconds / 3600))h" }
        if Calendar.current.isDateInYesterday(shown) { return "Yesterday" }
        if seconds < 6 * 86_400 { return shown.formatted(.dateTime.weekday(.wide)) }
        return shown.formatted(.dateTime.day().month(.abbreviated))
    }
}

private struct NewSessionView: View {
    @Environment(RemoteClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var folder = ""
    @State private var prompt = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Folder", selection: $folder) {
                    ForEach(client.folders, id: \.self) { folder in
                        VStack(alignment: .leading) {
                            Text(URL(filePath: folder).lastPathComponent)
                            Text(folder)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .monospaced()
                        .tag(folder)
                    }
                }
                .pickerStyle(.navigationLink)
                TextField("What should Claude do?", text: $prompt, axis: .vertical)
                    .lineLimit(3...8)
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start", action: start)
                        .disabled(folder.isEmpty)
                }
            }
            .onAppear { if folder.isEmpty { folder = client.folders.first ?? "" } }
        }
    }

    private func start() {
        client.send(.newSession(folder: folder, prompt: prompt))
        dismiss()
    }
}
