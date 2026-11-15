import SwiftUI

struct SessionView: View {
    let sessionID: String

    @Environment(RemoteClient.self) private var client
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isAtBottom = true
    @State private var draft = ""

    var body: some View {
        let session = client.groups.lazy.flatMap(\.sessions).first { $0.id == sessionID }
        let entries = client.entries[sessionID]
        let turns = Turn.turns(from: entries ?? [])
        let isBusy = session?.status == "busy" || session?.status == "waiting"

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                ForEach(turns) { turn in
                    let isLast = turn.id == turns.last?.id
                    let openCall = isLast ? turn.openCall : nil
                    TurnView(turn: turn, isFinished: !isLast || !isBusy, liveCall: openCall.flatMap { session?.status == "busy" ? .running($0.id) : session?.status == "waiting" ? .waiting($0.id) : nil })
                }
            }
            .padding()
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: Bool.self) { $0.visibleRect.maxY >= $0.contentSize.height - 80 } action: { isAtBottom = $1 }
        .onChange(of: entries?.last?.id) {
            guard isAtBottom else { return }
            position.scrollTo(edge: .bottom)
        }
        .overlay {
            if entries == nil {
                ProgressView()
            } else if turns.isEmpty {
                ContentUnavailableView("No Messages Yet", systemImage: "text.bubble", description: Text("Messages appear here once Claude starts."))
            }
        }
        .safeAreaInset(edge: .bottom) {
            SessionControls(
                session: session,
                sessionID: sessionID,
                turnStart: turns.last?.prompt?.date ?? session?.lastPrompt,
                pendingCall: session?.status == "waiting" ? turns.last?.openCall : nil,
                isAtBottom: isAtBottom,
                draft: $draft,
                scrollToEnd: scrollToEnd
            )
        }
        .navigationTitle(session?.title ?? "Session")
        .navigationSubtitle([session.map { URL(filePath: $0.folder).lastPathComponent }, session?.branch].compactMap(\.self).joined(separator: " · "))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Session Actions", systemImage: "ellipsis") {
                    Button("Open on Mac", systemImage: "macbook", action: openOnMac)
                    if let pullRequest = session?.pullRequest, pullRequest.url.scheme == "https" {
                        Link(destination: pullRequest.url) {
                            Label("Open Pull Request #\(String(pullRequest.number))", systemImage: "arrow.triangle.pull")
                        }
                    }
                    Button("Mark as Unread", systemImage: "circle.fill", action: markUnread)
                    Divider()
                    Button("Disconnect", systemImage: "xmark.circle", role: .destructive) { client.disconnect() }
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
