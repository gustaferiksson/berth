import SwiftUI

struct SessionListView: View {
    @Environment(RemoteClient.self) private var client
    @State private var path: [String] = UserDefaults.standard.string(forKey: "remoteSession").map { [$0] } ?? []
    @State private var isStartingSession = false
    @State private var query = ""
    @State private var expandedGroups: [String: Bool] = [:]

    var body: some View {
        let pinned = Set(client.groups.first { $0.id == "pinned" }?.sessions.map(\.id) ?? [])
        let groups = query.isEmpty ? client.groups : client.groups.compactMap { group in
            let sessions = group.sessions.filter { session in
                [session.title, session.folder, session.branch ?? ""].contains { $0.localizedStandardContains(query) }
            }
            return sessions.isEmpty ? nil : RemoteGroup(id: group.id, title: group.title, sessions: sessions)
        }

        NavigationStack(path: $path) {
            List {
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
                    Menu("Berth", systemImage: "ellipsis") {
                        Button("Disconnect", systemImage: "xmark.circle", role: .destructive) { client.disconnect() }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("New Session", systemImage: "plus") { isStartingSession = true }
                        .disabled(client.folders.isEmpty || client.state != .connected)
                }
            }
            .sheet(isPresented: $isStartingSession) {
                NewSessionView()
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
        .contextMenu {
            Button("Open on Mac", systemImage: "macbook") { perform(.show) }
            Button(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin") { perform(isPinned ? .unpin : .pin) }
            Button(session.isUnread == true ? "Mark as Read" : "Mark as Unread", systemImage: session.isUnread == true ? "envelope.open" : "envelope.badge") {
                perform(session.isUnread == true ? .markRead : .markUnread)
            }
            if let pullRequest = session.pullRequest, pullRequest.url.scheme == "https" {
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
        let project = Text(URL(filePath: session.folder).lastPathComponent)
        let branch = session.branch.map { Text(" · \($0)") } ?? Text("")
        let titleLayout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))

        VStack(alignment: .leading, spacing: 3) {
            titleLayout {
                Text(session.title)
                    .lineLimit(2)
                Spacer(minLength: 0)
                SessionStatus(session: session)
                    .font(.subheadline)
            }
            HStack(spacing: 0) {
                Text("\(session.isLocked ? Text("\(Image(systemName: "lock.fill")) ") : Text(""))\(project)\(branch)")
                    .lineLimit(1)
                if let pullRequest = session.pullRequest {
                    Text(" · #\(String(pullRequest.number))")
                        .foregroundStyle(pullRequest.state == "Open" ? .green : pullRequest.state == "Merged" ? .purple : pullRequest.state == "Closed" ? .red : .secondary)
                        .fixedSize()
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SessionStatus: View {
    let session: RemoteSession

    var body: some View {
        if session.status == "waiting" {
            Text("\(Image(systemName: "exclamationmark.bubble.fill")) Needs You")
                .bold()
                .foregroundStyle(.orange)
        } else if session.status == "busy" {
            Text("\(Text(Image(systemName: "circle.fill")).font(.caption2)) \(Text(session.lastPrompt ?? session.lastActivity, style: .timer))")
                .monospacedDigit()
                .foregroundStyle(.green)
        } else {
            Text("\(session.isUnread == true ? Text("\(Text(Image(systemName: "circle.fill")).font(.caption2).accessibilityLabel("Unread")) ").foregroundStyle(.blue) : Text(""))\(Text(session.lastActivity, format: .relative(presentation: .numeric, unitsStyle: .narrow)))")
                .foregroundStyle(.secondary)
        }
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
