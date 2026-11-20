import SwiftUI

struct SessionListView: View {
    @Environment(RemoteClient.self) private var client
    @Environment(UpdateCheck.self) private var updates
    @State private var path: [String] = UserDefaults.standard.string(forKey: "remoteSession").map { [$0] } ?? []
    @State private var isStartingSession = false
    @State private var query = ""
    @State private var expandedGroups: [String: Bool] = [:]
    @State private var isShowingSettings = UserDefaults.standard.bool(forKey: "snapshotSettings")

    var body: some View {
        let pinned = Set(client.groups.first { $0.id == "pinned" }?.sessions.map(\.id) ?? [])
        let rank = ["waiting": 0, "busy": 1, "shell": 2]
        let matches = { (session: RemoteSession) in
            query.isEmpty || [session.title, session.folder, session.branch ?? ""].contains { $0.localizedStandardContains(query) }
        }
        let active = client.groups
            .flatMap { group in group.sessions.filter { $0.status != nil || group.id == "starting" } }
            .sorted { (rank[$0.status ?? ""] ?? 3, $1.lastActivity) < (rank[$1.status ?? ""] ?? 3, $0.lastActivity) }
        let activeIDs = Set(active.map(\.id))
        let groups = ([RemoteGroup(id: "active", title: "Active", sessions: active)] + client.groups.filter { $0.id != "starting" })
            .map { group in RemoteGroup(id: group.id, title: group.title, sessions: group.sessions.filter { (group.id == "active" || !activeIDs.contains($0.id)) && matches($0) }) }
            .filter { !$0.sessions.isEmpty }

        NavigationStack(path: $path) {
            List {
                if let version = updates.available, query.isEmpty {
                    Section {
                        Link(destination: UpdateCheck.installURL) {
                            Label("Install Berth Remote \(version)", systemImage: "arrow.down.circle")
                        }
                    }
                }
                ForEach(groups) { group in
                    Section(group.title, isExpanded: Binding { expandedGroups[group.id] ?? true } set: { expandedGroups[group.id] = $0 }) {
                        ForEach(group.sessions) { session in
                            SessionRow(session: session, isPinned: pinned.contains(session.id))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if client.groups.isEmpty, client.state != .connected {
                    ContentUnavailableView("Reconnecting", systemImage: "wifi.slash", description: Text("Berth Remote reconnects when your Mac is reachable."))
                } else if client.groups.isEmpty {
                    ContentUnavailableView("No Sessions", systemImage: "text.bubble", description: Text("Start a session with the + button."))
                } else if groups.isEmpty {
                    ContentUnavailableView.search
                }
            }
            .searchable(text: $query, prompt: "Search Sessions")
            .refreshable { client.send(.refresh) }
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
            .sheet(isPresented: $isShowingSettings) {
                SettingsView()
            }
            .onChange(of: client.openedSessionID) {
                guard let id = client.openedSessionID else { return }

                client.openedSessionID = nil
                path = [id]
            }
        }
    }
}

private struct SessionRow: View {
    let session: RemoteSession
    let isPinned: Bool

    @Environment(RemoteClient.self) private var client
    @State private var isShowingPullRequest = false

    var body: some View {
        NavigationLink(value: session.id) {
            SessionSummaryView(session: session)
        }
        .swipeActions(edge: .leading) {
            Button(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin") { perform(isPinned ? .unpin : .pin) }
                .tint(.yellow)
        }
        .swipeActions(edge: .trailing) {
            if session.status == nil {
                Button("Archive", systemImage: "archivebox") { perform(.archive) }
                    .tint(.indigo)
            }
            Button(session.isUnread == true ? "Mark as Read" : "Mark as Unread", systemImage: session.isUnread == true ? "envelope.open" : "envelope.badge") {
                perform(session.isUnread == true ? .markRead : .markUnread)
            }
            .tint(.blue)
        }
        .sheet(isPresented: $isShowingPullRequest) {
            PullRequestSheet(sessionID: session.id)
        }
        .contextMenu {
            Button("Open on Mac", systemImage: "macbook") { perform(.show) }
            Button(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin") { perform(isPinned ? .unpin : .pin) }
            Button(session.isUnread == true ? "Mark as Read" : "Mark as Unread", systemImage: session.isUnread == true ? "envelope.open" : "envelope.badge") {
                perform(session.isUnread == true ? .markRead : .markUnread)
            }
            if let pullRequest = session.pullRequest, client.features.contains(RemotePullRequestFeature.name) {
                Button("Pull Request #\(String(pullRequest.number))", systemImage: "arrow.triangle.pull") { isShowingPullRequest = true }
            } else if let pullRequest = session.pullRequest, pullRequest.url.scheme == "https" {
                Link(destination: pullRequest.url) {
                    Label("Open Pull Request #\(String(pullRequest.number))", systemImage: "arrow.triangle.pull")
                }
            }
            if session.status == nil {
                Divider()
                Button("Archive", systemImage: "archivebox") { perform(.archive) }
            }
        }
    }

    private func perform(_ action: RemoteSessionAction) {
        client.send(.session(sessionID: session.id, action: action))
    }
}

private struct SessionSummaryView: View {
    let session: RemoteSession

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let isProminent = session.status != nil || session.isUnread == true
        let lock = session.isLocked ? Text("\(Text(Image(systemName: "lock.fill")).accessibilityLabel("Locked")) ") : Text("")
        let branch = session.branch.map { Text("  \(Text(Image(systemName: "arrow.triangle.branch")).accessibilityLabel("Branch")) \($0)") } ?? Text("")
        let titleLayout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))

        VStack(alignment: .leading, spacing: 4) {
            titleLayout {
                Text(session.title)
                    .foregroundStyle(isProminent ? .primary : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                SessionStatus(session: session)
                    .font(.subheadline)
            }
            HStack(spacing: 10) {
                Text("\(lock)\(URL(filePath: session.folder).lastPathComponent)\(branch)")
                    .lineLimit(1)
                if let pullRequest = session.pullRequest {
                    Text("\(Text(Image(systemName: "arrow.triangle.pull")).accessibilityLabel("Pull request")) \(String(pullRequest.number))")
                        .foregroundStyle(pullRequest.state == "Open" ? .green : pullRequest.state == "Merged" ? .purple : pullRequest.state == "Closed" ? .red : .secondary)
                        .fixedSize()
                    if let checks = pullRequest.checks {
                        Image(systemName: ChecksStyle.symbol(checks))
                            .foregroundStyle(ChecksStyle.color(checks))
                            .accessibilityLabel(ChecksStyle.title(checks))
                    }
                }
            }
            .font(.footnote)
            .monospaced()
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct SessionStatus: View {
    let session: RemoteSession

    var body: some View {
        if session.status == "waiting" {
            Text("\(Text(Image(systemName: "exclamationmark.bubble.fill")).accessibilityLabel("Waiting")) Needs you")
                .bold()
                .foregroundStyle(.orange)
        } else if session.status == "busy" {
            Text("\(Text(Image(systemName: "circle.fill")).font(.caption2).accessibilityLabel("Working")) \(Text(session.lastPrompt ?? session.lastActivity, style: .timer))")
                .monospacedDigit()
                .foregroundStyle(.green)
        } else if session.status == "shell" {
            Text("\(Text(Image(systemName: "terminal")).accessibilityLabel("Shell")) Task running")
                .foregroundStyle(.secondary)
        } else {
            TimelineView(.everyMinute) { context in
                Text("\(session.isUnread == true ? Text("\(Text(Image(systemName: "circle.fill")).font(.caption2).accessibilityLabel("Unread")) ").foregroundStyle(.blue) : Text(""))\(age(at: context.date))")
                    .foregroundStyle(session.status == nil ? .tertiary : .secondary)
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
