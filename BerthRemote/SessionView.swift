import SwiftUI

struct SessionView: View {
    let sessionID: String

    @Environment(RemoteClient.self) private var client
    @Environment(\.openURL) private var openURL
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
        let headerAction = HeaderAction(pullRequest: session?.pullRequest, context: activity?.context)

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
                        openChanges: isLast && client.features.contains(RemoteChangesFeature.name) ? { isShowingChanges = true } : nil
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
                    pendingCall: session?.status == "waiting" ? turns.last?.openCall : nil,
                    context: activity?.context,
                    openContext: { isShowingContext = true }
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
                Group {
                    switch headerAction {
                    case let .pullRequest(pullRequest, isFailing):
                        Button { openPullRequest(pullRequest) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: isFailing ? "xmark.circle.fill" : "arrow.triangle.pull")
                                Text("#\(String(pullRequest.number))")
                                    .font(.footnote.weight(.medium).monospacedDigit())
                            }
                            .foregroundStyle(isFailing ? .red : .primary)
                        }
                        .accessibilityLabel("Pull Request #\(String(pullRequest.number))\(isFailing ? ", checks failed" : "")")
                        .transition(.blurReplace)

                    case let .context(context):
                        Button { isShowingContext = true } label: {
                            HStack(spacing: 4) {
                                ContextRing(context: context)
                                if let fill = context.fill, fill >= 0.8 {
                                    Text(fill, format: .wholePercent)
                                        .font(.footnote.weight(.medium).monospacedDigit())
                                }
                            }
                        }
                        .transition(.blurReplace)

                    case nil:
                        EmptyView()
                    }
                }
                .animation(.smooth, value: headerAction?.kind)
                Menu("Session Actions", systemImage: "ellipsis") {
                    Section {
                        if client.features.contains(RemoteChangesFeature.name) {
                            Button("Changes", systemImage: "plusminus") { isShowingChanges = true }
                        }
                        if let pullRequest = session?.pullRequest {
                            Button("Pull Request #\(String(pullRequest.number))", systemImage: "arrow.triangle.pull") { openPullRequest(pullRequest) }
                        }
                        if activity?.context != nil {
                            Button("Context", systemImage: "chart.pie") { isShowingContext = true }
                        }
                        if let tasks = activity?.tasks, !tasks.isEmpty {
                            Button("Running Tasks", systemImage: "list.bullet.rectangle") { isShowingRunning = true }
                        }
                    }
                    Section {
                        Button("Open on Mac", systemImage: "macbook", action: openOnMac)
                        Button("Mark as Unread", systemImage: "circle.fill", action: markUnread)
                    }
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

    private func openPullRequest(_ pullRequest: RemotePullRequest) {
        if client.features.contains(RemotePullRequestFeature.name) {
            isShowingPullRequest = true
        } else if pullRequest.url.scheme == "https" {
            openURL(pullRequest.url)
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

private enum HeaderAction {
    case pullRequest(RemotePullRequest, isFailing: Bool)
    case context(RemoteContext)

    init?(pullRequest: RemotePullRequest?, context: RemoteContext?) {
        let openPullRequest = pullRequest.flatMap { $0.state == "Merged" || $0.state == "Closed" ? nil : $0 }
        let isFull = (context?.fill ?? 0) >= 0.8
        if let openPullRequest, openPullRequest.checks == "failed" {
            self = .pullRequest(openPullRequest, isFailing: true)
        } else if let context, isFull {
            self = .context(context)
        } else if let openPullRequest {
            self = .pullRequest(openPullRequest, isFailing: false)
        } else if let context {
            self = .context(context)
        } else {
            return nil
        }
    }

    var kind: String {
        switch self {
        case let .pullRequest(_, isFailing): isFailing ? "failing" : "pullRequest"
        case .context: "context"
        }
    }
}
