import SwiftUI

struct SessionView: View {
    let sessionID: String

    @Environment(RemoteClient.self) private var client
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isAtBottom = true
    @State private var hasNewMessages = false
    @State private var isShowingRunning = UserDefaults.standard.bool(forKey: "snapshotRunning")
    @State private var isShowingContext = UserDefaults.standard.bool(forKey: "snapshotContext")
    @State private var isShowingPullRequest = UserDefaults.standard.bool(forKey: "snapshotPullRequest")
    @State private var isShowingChanges = UserDefaults.standard.bool(forKey: "snapshotChanges")

    var body: some View {
        let session = client.groups.lazy.flatMap(\.sessions).first { $0.id == sessionID }
        let entries = client.entries[sessionID]
        let turns = Turn.turns(from: entries ?? [])
        let isBusy = session?.status == "busy" || session?.status == "waiting"
        let queued = session?.status == nil ? [] : client.queued[sessionID] ?? []
        let activity = client.activity[sessionID]

        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                ForEach(turns) { turn in
                    let isLast = turn.id == turns.last?.id
                    let openCall = isLast ? turn.openCall : nil
                    TurnView(
                        sessionID: sessionID,
                        turn: turn,
                        isFinished: !isLast || !isBusy,
                        isWorking: isLast && session?.status == "busy",
                        turnStartedAt: session?.turnStartedAt,
                        liveCall: openCall.flatMap { session?.status == "busy" ? .running($0.id) : session?.status == "waiting" ? .waiting($0.id) : nil },
                        openChanges: client.features.contains(RemoteChangesFeature.name) ? { isShowingChanges = true } : nil
                    )
                }
                if !queued.isEmpty {
                    VStack(alignment: .trailing, spacing: 12) {
                        ForEach(queued.enumerated(), id: \.offset) { _, text in
                            QueuedPrompt(text: text)
                        }
                    }
                }
            }
            .padding()
            .modifier(ConversationStyle())
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: Bool.self) { $0.visibleRect.maxY >= $0.contentSize.height - 80 } action: { _, atBottom in
            isAtBottom = atBottom
            if atBottom { hasNewMessages = false }
        }
        .onChange(of: entries?.last?.id) {
            guard isAtBottom else {
                hasNewMessages = true
                return
            }

            position.scrollTo(edge: .bottom)
        }
        .onChange(of: queued) {
            guard isAtBottom else { return }

            position.scrollTo(edge: .bottom)
        }
        .overlay {
            if entries == nil {
                ProgressView()
            } else if turns.isEmpty, queued.isEmpty {
                ContentUnavailableView("No Messages Yet", systemImage: "text.bubble", description: Text("Messages appear here once Claude starts."))
            }
        }
        .overlay(alignment: .bottom) {
            if !isAtBottom {
                Button(action: scrollToEnd) {
                    if hasNewMessages {
                        Label("New Messages", systemImage: "arrow.down")
                    } else {
                        Image(systemName: "arrow.down")
                    }
                }
                .accessibilityLabel(hasNewMessages ? "New messages, scroll to end" : "Scroll to End")
                .buttonStyle(.glass)
                .buttonBorderShape(hasNewMessages ? .capsule : .circle)
                .controlSize(.large)
                .padding()
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.smooth, value: hasNewMessages)
        .animation(.smooth, value: isAtBottom)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                if let tasks = activity?.tasks, !tasks.isEmpty {
                    RunningStrip(tasks: tasks) { isShowingRunning = true }
                }
                SessionControls(
                    session: session,
                    sessionID: sessionID,
                    pendingCall: session?.status == "waiting" ? turns.last?.openCall : nil
                )
            }
        }
        .sheet(isPresented: $isShowingRunning) {
            RunningSheet(sessionID: sessionID)
        }
        .sheet(isPresented: $isShowingContext) {
            if let context = activity?.context {
                ContextSheet(context: context)
            }
        }
        .sheet(isPresented: $isShowingPullRequest) {
            PullRequestSheet(sessionID: sessionID)
        }
        .sheet(isPresented: $isShowingChanges) {
            ChangesSheet(sessionID: sessionID)
        }
        .navigationTitle(session?.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .subtitle) {
                Text([session.map { URL(filePath: $0.folder).lastPathComponent }, session?.branch].compactMap(\.self).joined(separator: " · "))
                    .font(.footnote)
                    .monospaced()
                    .foregroundStyle(.secondary)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let tasks = activity?.tasks, !tasks.isEmpty {
                    Button { isShowingRunning = true } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "terminal")
                            Text(tasks.count.formatted())
                                .font(.footnote.weight(.semibold).monospacedDigit())
                        }
                    }
                    .accessibilityLabel("Running, \(tasks.count)")
                }
                if client.features.contains(RemoteChangesFeature.name) {
                    Button("Changes", systemImage: "plusminus") { isShowingChanges = true }
                }
                if let pullRequest = session?.pullRequest, client.features.contains(RemotePullRequestFeature.name) {
                    Button("Pull Request #\(String(pullRequest.number))", systemImage: "arrow.triangle.pull") { isShowingPullRequest = true }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Session Actions", systemImage: "ellipsis") {
                    Button("Open on Mac", systemImage: "macbook", action: openOnMac)
                    if activity?.context != nil {
                        Button("Context", systemImage: "chart.pie") { isShowingContext = true }
                    }
                    if let pullRequest = session?.pullRequest, !client.features.contains(RemotePullRequestFeature.name), pullRequest.url.scheme == "https" {
                        Link(destination: pullRequest.url) {
                            Label("Open Pull Request #\(String(pullRequest.number))", systemImage: "arrow.triangle.pull")
                        }
                    }
                    Button("Mark as Unread", systemImage: "circle.fill", action: markUnread)
                }
            }
        }
        .task {
            client.subscribe(to: sessionID)
            client.send(.session(sessionID: sessionID, action: .markRead))
        }
        .alert("Berth", isPresented: Binding { client.notice != nil } set: { if !$0 { client.notice = nil } }) {
            Button("OK") {}
        } message: {
            Text(client.notice ?? "")
        }
    }

    private func scrollToEnd() {
        withAnimation { position.scrollTo(edge: .bottom) }
    }

    private func openOnMac() {
        client.send(.session(sessionID: sessionID, action: .show))
    }

    private func markUnread() {
        client.send(.session(sessionID: sessionID, action: .markUnread))
    }
}
