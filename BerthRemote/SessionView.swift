import SwiftUI

struct SessionView: View {
    let sessionID: String

    @Environment(RemoteClient.self) private var client
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isAtBottom = true
    @State private var draft = ""
    @State private var attachments: [Attachment] = []
    @State private var isShowingRunning = UserDefaults.standard.bool(forKey: "snapshotRunning")
    @State private var isShowingContext = UserDefaults.standard.bool(forKey: "snapshotContext")

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
                        turn: turn,
                        isFinished: !isLast || !isBusy,
                        isWorking: isLast && session?.status == "busy",
                        liveCall: openCall.flatMap { session?.status == "busy" ? .running($0.id) : session?.status == "waiting" ? .waiting($0.id) : nil }
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
        .onScrollGeometryChange(for: Bool.self) { $0.visibleRect.maxY >= $0.contentSize.height - 80 } action: { isAtBottom = $1 }
        .onChange(of: entries?.last?.id) {
            guard isAtBottom else { return }
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
        .overlay(alignment: .bottomTrailing) {
            if !isAtBottom {
                Button("Scroll to End", systemImage: "arrow.down", action: scrollToEnd)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .padding()
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                if let tasks = activity?.tasks, !tasks.isEmpty {
                    RunningSummary(tasks: tasks) { isShowingRunning = true }
                }
                SessionControls(
                    session: session,
                    sessionID: sessionID,
                    pendingCall: session?.status == "waiting" ? turns.last?.openCall : nil,
                    draft: $draft,
                    attachments: $attachments
                )
            }
        }
        .sheet(isPresented: $isShowingRunning) {
            RunningSheet(tasks: activity?.tasks ?? [])
        }
        .sheet(isPresented: $isShowingContext) {
            if let context = activity?.context {
                ContextSheet(context: context)
            }
        }
        .navigationTitle(session?.title ?? "Session")
        .navigationSubtitle([session.map { URL(filePath: $0.folder).lastPathComponent }, session?.branch].compactMap(\.self).joined(separator: " · "))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if activity?.context != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Context", systemImage: "chart.pie") { isShowingContext = true }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Session Actions", systemImage: "ellipsis") {
                    Button("Open on Mac", systemImage: "macbook", action: openOnMac)
                    if let pullRequest = session?.pullRequest, pullRequest.url.scheme == "https" {
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
