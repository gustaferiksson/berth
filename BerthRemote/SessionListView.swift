import SwiftUI

enum SessionListLayout {
    static let statusWidth = 14.0
    static let columnSpacing = 6.0
    static let rowInsets = EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
}

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
        let groups = visibleGroups
        let usageGroups = query.isEmpty ? client.usageGroups(at: .now) : []
        let tints: [String: Color] = ["needsYou": .orange, "working": .green, "unread": .blue]
        let searchedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchesTranscripts = client.features.contains(RemoteSearchFeature.name) && searchedQuery.count >= RemoteSearchFeature.minimumQueryLength

        NavigationStack(path: $path) {
            List {
                if let version = updates.available, query.isEmpty {
                    Section {
                        Link(destination: UpdateCheck.installURL) {
                            Label("Install Berth Remote \(version)", systemImage: "arrow.down.circle")
                                .padding(.vertical, 6)
                                .frame(minHeight: 44)
                        }
                        .listRowInsets(SessionListLayout.rowInsets)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                    .listSectionSeparator(.hidden)
                }
                if !usageGroups.isEmpty {
                    let expansion = Binding { expandedGroups["usage", default: true] } set: { expandedGroups["usage"] = $0 }
                    Section {
                        SessionSectionHeader(title: "Usage", isExpanded: expansion)
                        if expansion.wrappedValue {
                            ForEach(usageGroups) { group in
                                UsageCard(group: group) { isShowingUsage = true }
                                    .listRowInsets(SessionListLayout.rowInsets)
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                            }
                        }
                    }
                    .listSectionSeparator(.hidden)
                }
                ForEach(groups) { group in
                    let expansion = Binding { expandedGroups[group.id, default: group.id != "recent:older"] } set: { expandedGroups[group.id] = $0 }
                    let startsList = usageGroups.isEmpty && group.id == groups.first?.id
                    Section {
                        SessionSectionHeader(title: group.title, count: group.sessions.count, tint: tints[group.id], topSpacing: startsList ? 0 : 8, isExpanded: expansion)
                        if expansion.wrappedValue {
                            ForEach(group.sessions) { session in
                                SessionRow(session: session, isPinned: pinned.contains(session.id)) {
                                    path.append(session.id)
                                } didAct: { action in
                                    feedback = ActionFeedback(count: feedback.count + 1, action: action)
                                }
                                .listRowInsets(SessionListLayout.rowInsets)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                            }
                        }
                    }
                    .listSectionSeparator(.hidden)
                }
                if searchesTranscripts {
                    TranscriptSearchSection(query: searchedQuery)
                }
            }
            .listStyle(.plain)
            .listSectionSpacing(0)
            .environment(\.defaultMinListRowHeight, 0)
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

    private var visibleGroups: [RemoteGroup] {
        let matches = { (session: RemoteSession) in
            query.isEmpty || [session.title, session.folder, session.branch ?? ""].contains { $0.localizedStandardContains(query) }
        }
        let sessions = client.groups.flatMap(\.sessions)
        let needsYou = sessions.filter { $0.status == "waiting" }.sorted { $0.lastActivity > $1.lastActivity }
        let working = sessions.filter { $0.status == "busy" }.sorted { $0.lastActivity > $1.lastActivity }
        let unread = sessions.filter { $0.isUnread == true }
        let orderedGroups = [
            RemoteGroup(id: "needsYou", title: "Needs You", sessions: needsYou),
            RemoteGroup(id: "working", title: "Working", sessions: working),
            RemoteGroup(id: "unread", title: "Unread", sessions: unread),
        ] + client.groups.filter { $0.id == "starting" }
            + client.groups.filter { $0.id == "pinned" }
            + client.groups.filter { $0.id != "starting" && $0.id != "pinned" }

        var placed: Set<String> = []
        var groups: [RemoteGroup] = []
        for group in orderedGroups {
            var sessions: [RemoteSession] = []
            for session in group.sessions where matches(session) && placed.insert(session.id).inserted {
                sessions.append(session)
            }
            guard !sessions.isEmpty else { continue }

            groups.append(RemoteGroup(id: group.id, title: group.title, sessions: sessions))
        }
        return groups
    }
}

private struct SessionSectionHeader: View {
    let title: String
    var count: Int?
    var tint: Color?
    var topSpacing = 0.0
    @Binding var isExpanded: Bool

    @ScaledMetric(relativeTo: .body) private var statusWidth = SessionListLayout.statusWidth

    var body: some View {
        let label = if !isExpanded, let count {
            Text("\(title), ^[\(count) session](inflect: true)")
        } else {
            Text(title)
        }

        Button {
            withAnimation { isExpanded.toggle() }
        } label: {
            HStack(spacing: SessionListLayout.columnSpacing) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .imageScale(.small)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: statusWidth)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                if !isExpanded, let count {
                    Text(count, format: .number)
                        .font(.subheadline.monospacedDigit())
                        .fixedSize()
                }
            }
            .foregroundStyle(tint ?? Color.secondary)
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(label)
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
        .padding(.top, topSpacing)
        .listRowInsets(SessionListLayout.rowInsets)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
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
    let open: () -> Void
    let didAct: (RemoteSessionAction) -> Void

    @Environment(RemoteClient.self) private var client
    @State private var isShowingPullRequest = false

    var body: some View {
        let toggleRead = session.isUnread == true ? RemoteSessionAction.markRead : .markUnread
        let toggleRule = isPinned ? RemoteSessionAction.unpin : .pin

        Button(action: open) {
            SessionRowLabel(session: session)
                .foregroundStyle(.primary)
                .contentShape(.rect)
        }
        .accessibilityValue(Text((session.agent ?? .legacyClaude).name))
        .accessibilityHint("Opens the session")
        .swipeActions(edge: .leading) {
            Button(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin") { perform(toggleRule) }
                .tint(.yellow)
        }
        .swipeActions(edge: .trailing) {
            if session.status == nil {
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
            if let pullRequest = session.pullRequest, client.features.contains(RemotePullRequestFeature.name) {
                Button { isShowingPullRequest = true } label: { Label("Pull Request #\(String(pullRequest.number))", image: Octicon.pullRequest.assetName()) }
            } else if let pullRequest = session.pullRequest, pullRequest.url.scheme == "https" {
                Link(destination: pullRequest.url) {
                    Label("Open Pull Request #\(String(pullRequest.number))", image: Octicon.pullRequest.assetName())
                }
            }
            if session.status == nil {
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

private struct SessionRowLabel: View {
    let session: RemoteSession

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var statusWidth = SessionListLayout.statusWidth

    var body: some View {
        let isAccessibility = dynamicTypeSize.isAccessibilitySize
        let titleInset = statusWidth + SessionListLayout.columnSpacing
        let repo = Text(verbatim: URL(filePath: session.folder).lastPathComponent)
        let location = session.branch.map { branch in
            Text("\(repo) · \(Text(verbatim: branch).foregroundStyle(Color.teal.opacity(0.8)))")
        } ?? repo

        let details = Group {
            if let watch = session.pullRequestWatch, session.status == "idle" || session.status == nil {
                Image(systemName: "eye")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(watch.title)
            } else if let pullRequest = session.pullRequest {
                PullRequestTag(pullRequest: pullRequest)
            }
            SessionTime(session: session)
        }

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: SessionListLayout.columnSpacing) {
                SessionStatusSlot(session: session)
                    .frame(width: statusWidth)
                HStack(spacing: 4) {
                    Text(session.title)
                        .font(.body.weight(session.isUnread == true ? .semibold : .medium))
                        .lineLimit(isAccessibility ? 2 : 1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                    if session.isLocked {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Locked")
                    }
                }
                Spacer(minLength: 0)
                if !isAccessibility {
                    HStack(spacing: 8) { details }
                        .fixedSize()
                }
            }
            if isAccessibility {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { details }
                    VStack(alignment: .leading, spacing: 3) { details }
                }
                .padding(.leading, titleInset)
            }
            location
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(isAccessibility ? nil : 1)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, titleInset)
        }
        .padding(.vertical, 6)
        .opacity(session.isLocked ? 0.55 : 1)
        .accessibilityElement(children: .combine)
    }
}

private struct SessionStatusSlot: View {
    let session: RemoteSession

    @ScaledMetric(relativeTo: .body) private var dotSize = 6.0
    @ScaledMetric(relativeTo: .body) private var ringSize = 5.0
    @ScaledMetric(relativeTo: .body) private var ringStroke = 1.0

    var body: some View {
        ZStack {
            if session.status == "waiting" {
                Circle()
                    .fill(.orange)
                    .frame(width: dotSize, height: dotSize)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Needs you")
            } else if session.status == "busy" {
                SessionWorkingDots()
            } else if session.status == "shell" {
                Circle()
                    .fill(.pink)
                    .frame(width: dotSize, height: dotSize)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Background task running")
            } else if session.isUnread == true {
                Circle()
                    .fill(.blue)
                    .frame(width: dotSize, height: dotSize)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Unread")
            } else if session.isOpen {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.5), lineWidth: ringStroke)
                    .frame(width: ringSize, height: ringSize)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Open on Mac")
            }
        }
    }
}

private struct SessionWorkingDots: View {
    @ScaledMetric(relativeTo: .body) private var dotSize = 4.0
    @ScaledMetric(relativeTo: .body) private var spacing = 1.0
    @State private var offset = Double.random(in: 0..<1.2)

    var body: some View {
        TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: offset), by: 0.4)) { context in
            let phase = Int(((context.date.timeIntervalSinceReferenceDate - offset) / 0.4).rounded()) % 3
            HStack(spacing: spacing) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(Color.green.opacity(index == phase ? 1 : 0.35))
                        .frame(width: dotSize, height: dotSize)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Working")
    }
}

private struct PullRequestTag: View {
    let pullRequest: RemotePullRequest

    @ScaledMetric(relativeTo: .caption) private var iconSize = 12.0
    @ScaledMetric(relativeTo: .caption) private var dividerHeight = 8.0
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
            Text(verbatim: "#\(pullRequest.number)")
            if let checks {
                Rectangle()
                    .fill(tint.opacity(0.35))
                    .frame(width: 1, height: dividerHeight)
                Group {
                    if checks == "passed" || checks == "failed" {
                        Image(systemName: checks == "passed" ? "checkmark" : "xmark")
                            .imageScale(.small)
                            .fontWeight(.bold)
                            .accessibilityHidden(true)
                    } else {
                        Circle()
                            .frame(width: checkDotSize, height: checkDotSize)
                    }
                }
                .foregroundStyle(ChecksStyle.color(checks))
            }
        }
        .font(.caption.monospaced())
        .foregroundStyle(tint)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(tint.opacity(0.16), in: .rect(cornerRadius: 4))
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
        .font(.footnote.monospacedDigit())
        .foregroundStyle(.secondary)
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
            .onAppear { if folder.isEmpty { folder = client.folders.first ?? "" } }
        }
    }

    private func start() {
        client.send(.newSession(folder: folder, prompt: prompt))
        dismiss()
    }
}
