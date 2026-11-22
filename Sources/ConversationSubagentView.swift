import AppKit
import BerthCore
import Observation
import SwiftUI

@Observable
final class ConversationSubagentModel {
    private(set) var subagent: Subagent
    private(set) var turns: [Turn] = []
    private(set) var details: [String: ToolCallDetails] = [:]
    private(set) var started: Date?
    private(set) var ended: Date?
    @ObservationIgnored private var entries: [RemoteEntry] = []
    @ObservationIgnored private var end: Int?
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var read: Task<Void, Never>?
    @ObservationIgnored private var needsRead = false

    init(subagent: Subagent) {
        self.subagent = subagent
    }

    func start() {
        watcher = FileWatcher(paths: [subagent.url.deletingLastPathComponent().path], latency: 0.3) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func stop() {
        watcher = nil
        read?.cancel()
        read = nil
    }

    private func refresh() {
        guard read == nil else {
            needsRead = true
            return
        }

        needsRead = false
        let url = subagent.url
        let offset = end
        let queue = queue
        let id = subagent.id
        read = Task {
            let (chunk, updated) = await Task.detached {
                let chunk = TranscriptTail.read(url, after: offset, queue: queue, includeSidechain: true)
                let session = url.deletingLastPathComponent().deletingLastPathComponent().appendingPathExtension("jsonl")
                return (chunk, Subagent.locate(session: session, agentID: id, toolUseID: nil))
            }.value
            guard !Task.isCancelled else { return }

            if let updated { subagent = updated }
            if let chunk {
                end = chunk.end
                self.queue = chunk.queue
                if !chunk.isContinuation || !chunk.entries.isEmpty {
                    entries = (chunk.isContinuation ? entries : []) + chunk.entries
                    turns = Turn.turns(from: entries)
                    details = Dictionary(
                        turns.flatMap(\.parts).flatMap { part -> [ToolCall] in
                            switch part {
                            case let .work(calls), let .cards(calls): calls
                            case .reply: []
                            }
                        }.map { ($0.id, $0.details) },
                        uniquingKeysWith: { $1 }
                    )
                    started = entries.first?.date
                    ended = entries.last?.date
                }
            }
            read = nil
            if needsRead { refresh() }
        }
    }
}

struct ConversationSubagentView: View {
    @State private var model: ConversationSubagentModel
    let back: () -> Void

    @Environment(\.ghosttyTheme) private var theme

    init(subagent: Subagent, back: @escaping () -> Void) {
        _model = State(initialValue: ConversationSubagentModel(subagent: subagent))
        self.back = back
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Button(action: back) {
                    Label("Back", systemImage: "chevron.left")
                }
                .keyboardShortcut(.escape, modifiers: [])
                .help("Back to conversation")
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: model.subagent.description)
                        .font(.headline)
                        .textSelection(.enabled)
                    Text(verbatim: model.subagent.agentType)
                        .font(.subheadline)
                        .foregroundStyle(theme.secondary)
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Text(model.subagent.isFinished ? "Finished" : "Running")
                    if let started = model.started {
                        if model.subagent.isFinished {
                            if let ended = model.ended {
                                Text(Duration.seconds(max(0, ended.timeIntervalSince(started))).formatted(elapsedFormat))
                            }
                        } else {
                            ConversationElapsed(since: started)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(theme.secondary)
            }
            .padding(18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(model.turns) { turn in
                        let isCurrent = turn.id == model.turns.last?.id
                        ConversationTurnView(
                            turn: turn,
                            isFinished: model.subagent.isFinished || !isCurrent,
                            isWorking: !model.subagent.isFinished && isCurrent,
                            waitingFor: nil,
                            since: turn.prompt?.date,
                            tasks: [],
                            details: model.details,
                            reviewChanges: nil
                        )
                    }
                }
                .frame(maxWidth: 860, alignment: .leading)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .defaultScrollAnchor(.bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(theme.foreground)
        .background(theme.background ?? Color(nsColor: .textBackgroundColor))
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}
