import SwiftUI

struct SessionListView: View {
    @Environment(RemoteClient.self) private var client
    @Environment(UpdateCheck.self) private var updates
    @State private var path: [String] = UserDefaults.standard.string(forKey: "remoteSession").map { [$0] } ?? []
    @State private var isStartingSession = false
    @State private var query = UserDefaults.standard.string(forKey: "snapshotQuery") ?? ""
    @State private var expandedGroups: [String: Bool] = [:]
    @State private var isShowingSettings = UserDefaults.standard.bool(forKey: "snapshotSettings")
    @State private var isShowingUsage = UserDefaults.standard.bool(forKey: "snapshotUsageSheet")
    @State private var feedback = ActionFeedback(count: 0, action: nil)

    var body: some View {
        let pinned = Set(client.groups.first { $0.id == "pinned" }?.sessions.map(\.id) ?? [])
        let rank = ["waiting": 0, "busy": 1, "shell": 2]
        let matches = { (session: RemoteSession) in
            query.isEmpty || [session.title, session.folder, session.branch ?? ""].contains { $0.localizedStandardContains(query) }
        }
        let running = client.groups
            .flatMap { group in group.sessions.filter { $0.status != nil || group.id == "starting" } }
            .sorted { (rank[$0.status ?? ""] ?? 3, $1.lastActivity) < (rank[$1.status ?? ""] ?? 3, $0.lastActivity) }
        let runningIDs = Set(running.map(\.id))
        let waitingCount = running.count(where: { $0.status == "waiting" })
        let groups = ([RemoteGroup(id: "active", title: "Active", sessions: running)] + client.groups.filter { $0.id != "starting" })
            .map { group in RemoteGroup(id: group.id, title: group.title, sessions: group.sessions.filter { (group.id == "active" || !runningIDs.contains($0.id)) && matches($0) }) }
            .filter { !$0.sessions.isEmpty }

        let searchedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchesTranscripts = client.features.contains(RemoteSearchFeature.name) && searchedQuery.count >= RemoteSearchFeature.minimumQueryLength

        NavigationStack(path: $path) {
            List {
                if let version = updates.available, query.isEmpty {
                    Section {
                        Link(destination: UpdateCheck.installURL) {
                            Label("Install Berth Remote \(version)", systemImage: "arrow.down.circle")
                        }
                    }
                }
                if let usage = client.usage, query.isEmpty {
                    Section {
                        UsageSummary(usage: usage) { isShowingUsage = true }
                    }
                }
                ForEach(groups) { group in
                    Section(isExpanded: Binding { expandedGroups[group.id] ?? true } set: { expandedGroups[group.id] = $0 }) {
                        ForEach(group.sessions) { session in
                            SessionRow(session: session, isPinned: pinned.contains(session.id)) { action in
                                feedback = ActionFeedback(count: feedback.count + 1, action: action)
                            }
                        }
                    } header: {
                        HStack {
                            Text(group.title)
                            if group.id == "active", waitingCount > 0 {
                                Label("\(waitingCount) \(waitingCount == 1 ? "needs" : "need") you", systemImage: "exclamationmark.bubble.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.orange)
                                    .textCase(nil)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                            }
                        }
                    }
                }
                if searchesTranscripts {
                    TranscriptSearchSection(query: searchedQuery)
                }
            }
            .listStyle(.sidebar)
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
            .refreshable { await client.refresh() }
            .navigationTitle("Sessions")
            .navigationDestination(for: String.self) { SessionView(sessionID: $0) }
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
            .onChange(of: client.openedSessionID, initial: true) {
                guard let id = client.openedSessionID else { return }

                client.openedSessionID = nil
                path = [id]
            }
        }
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
    let isPinned: Bool
    let didAct: (RemoteSessionAction) -> Void

    @Environment(RemoteClient.self) private var client
    @State private var isShowingPullRequest = false

    var body: some View {
        let toggleRead = session.isUnread == true ? RemoteSessionAction.markRead : .markUnread
        let toggleRule = isPinned ? RemoteSessionAction.unpin : .pin

        NavigationLink(value: session.id) {
            SessionSummaryView(session: session)
        }
        .swipeActions(edge: .leading) {
            Button(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin") { perform(toggleRule) }
                .tint(.yellow)
        }
        .swipeActions(edge: .trailing) {
            if session.status == nil {
                Button("Archive", systemImage: "archivebox", role: .destructive) { perform(.archive) }
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
            if let pullRequest = session.pullRequest, client.features.contains(RemotePullRequestFeature.name) {
                Button("Pull Request #\(String(pullRequest.number))", systemImage: "arrow.triangle.pull") { isShowingPullRequest = true }
            } else if let pullRequest = session.pullRequest, pullRequest.url.scheme == "https" {
                Link(destination: pullRequest.url) {
                    Label("Open Pull Request #\(String(pullRequest.number))", systemImage: "arrow.triangle.pull")
                }
            }
            if session.status == nil {
                Divider()
                Button("Archive", systemImage: "archivebox", role: .destructive) { perform(.archive) }
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
                .monospaced()
                .foregroundStyle(.secondary)
            if let branch = session.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(.footnote)
                    .monospaced()
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

private struct SessionSummaryView: View {
    let session: RemoteSession

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric private var gutterWidth = 14

    var body: some View {
        let isProminent = session.status != nil || session.isUnread == true
        let folder = URL(filePath: session.folder).lastPathComponent
        let isAccessibility = dynamicTypeSize.isAccessibilitySize

        let title = Text(session.title)
            .font(.body.weight(isProminent ? .semibold : .regular))
            .foregroundStyle(isProminent ? .primary : .secondary)
            .lineLimit(isAccessibility ? 2 : 1, reservesSpace: true)
        let time = SessionTime(session: session)
            .font(.footnote)
            .foregroundStyle(.secondary)
        let branch = session.branch.map { Text("  \(Text(Image(systemName: "arrow.triangle.branch")).accessibilityLabel("Branch")) \($0)") }
        let location = Text("\(session.isLocked ? Text(Image(systemName: "lock.fill")).accessibilityLabel("Locked") : Text(""))\(session.isLocked ? " " : "")\(folder)\(branch ?? Text(""))")
            .font(.footnote)
            .monospaced()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)

        HStack(alignment: .top, spacing: 4) {
            Image(systemName: "circle.fill")
                .font(.caption2)
                .foregroundStyle(.blue)
                .opacity(session.isUnread == true ? 1 : 0)
                .frame(width: gutterWidth, height: 22)
                .accessibilityLabel("Unread")
                .accessibilityHidden(session.isUnread != true)
            VStack(alignment: .leading, spacing: 3) {
                if isAccessibility {
                    title
                    time
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        title
                        Spacer(minLength: 0)
                        time
                    }
                }
                location
                if let pullRequest = session.pullRequest {
                    PullRequestTag(pullRequest: pullRequest)
                }
            }
        }
        .padding(.vertical, 2)
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + gutterWidth + 4 }
        .opacity(session.isLocked ? 0.55 : 1)
        .accessibilityElement(children: .combine)
    }
}

private struct PullRequestTag: View {
    let pullRequest: RemotePullRequest

    var body: some View {
        let color: Color = pullRequest.state == "Open" ? .green : pullRequest.state == "Merged" ? .purple : pullRequest.state == "Closed" ? .red : .secondary
        let icon = pullRequest.state == "Merged" ? "arrow.triangle.merge" : "arrow.triangle.pull"

        HStack(spacing: 3) {
            Image(systemName: icon)
            Text("#\(String(pullRequest.number))")
                .monospaced()
            if let checks = pullRequest.checks {
                Image(systemName: ChecksStyle.symbol(checks))
                    .foregroundStyle(ChecksStyle.color(checks))
                    .accessibilityLabel(ChecksStyle.title(checks))
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .background { Capsule().fill(color.opacity(0.15)).padding(.vertical, -2) }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pull request \(String(pullRequest.number)), \(pullRequest.state)\(pullRequest.checks.map { ", " + ChecksStyle.title($0) } ?? "")")
    }
}

private struct SessionTime: View {
    let session: RemoteSession

    var body: some View {
        if session.status == "waiting" {
            Text("Needs you")
                .bold()
                .foregroundStyle(.orange)
        } else if session.status == "busy" {
            let since = session.turnStartedAt ?? session.lastPrompt ?? session.lastActivity
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Working \(Duration.seconds(max(0, context.date.timeIntervalSince(since)).rounded(.down)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 1)))")
                    .monospacedDigit()
            }
            .foregroundStyle(.green)
        } else if session.status == "shell" {
            Text("Task running")
                .foregroundStyle(.teal)
        } else {
            TimelineView(.everyMinute) { context in
                Text(age(at: context.date))
            }
        }
    }

    private func age(at now: Date) -> String {
        let seconds = now.timeIntervalSince(session.lastActivity)
        if seconds < 60 { return "Now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 6 * 3600 || Calendar.current.isDateInToday(session.lastActivity) { return "\(Int(seconds / 3600))h" }
        if Calendar.current.isDateInYesterday(session.lastActivity) { return "Yesterday" }
        if seconds < 6 * 86_400 { return session.lastActivity.formatted(.dateTime.weekday(.wide)) }
        return session.lastActivity.formatted(.dateTime.day().month(.abbreviated))
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
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start", action: start)
                        .disabled(folder.isEmpty)
                }
            }
            .onAppear { folder = client.folders.first ?? "" }
        }
    }

    private func start() {
        client.send(.newSession(folder: folder, prompt: prompt))
        dismiss()
    }
}
