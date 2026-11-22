import AppIntents
import SwiftUI

extension RemoteClient {
    static let shared = RemoteClient()

    func connected() async -> Bool {
        resume()
        for _ in 0..<50 {
            if state == .connected { return true }
            if case .disconnected = state { return false }

            try? await Task.sleep(for: .milliseconds(100))
        }
        return state == .connected
    }

    func allSessions() async -> [RemoteSession] {
        if groups.isEmpty { _ = await connected() }

        var seen = Set<String>()
        return groups.flatMap(\.sessions).filter { seen.insert($0.id).inserted }
    }
}

enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case notConnected
    case unknownSession
    case locked(String)
    case waiting(String)
    case emptyPrompt
    case unknownFolder

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notConnected: "Berth Remote can’t reach Berth on your Mac. Open the app to check the connection."
        case .unknownSession: "Berth no longer lists that session."
        case let .locked(title): "\(title) is running in another terminal, so it is read-only here."
        case let .waiting(title): "\(title) is waiting for an answer. Answer it before sending a prompt."
        case .emptyPrompt: "The prompt is empty."
        case .unknownFolder: "Berth doesn’t know that folder."
        }
    }
}

struct SessionEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Session"
    static let defaultQuery = SessionQuery()

    let id: String

    @Property(title: "Title") var title: String

    @Property(title: "Project") var project: String

    @Property(title: "Branch") var branch: String?

    @Property(title: "Status") var status: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(project)", image: .init(systemName: status == "Needs you" ? "exclamationmark.bubble.fill" : "text.bubble"))
    }

    init(_ session: RemoteSession) {
        id = session.id
        title = session.title
        project = URL(filePath: session.folder).lastPathComponent
        branch = session.branch
        status = ["waiting": "Needs you", "busy": "Working", "shell": "Task running", "idle": "Idle"][session.status ?? ""] ?? "Not running"
    }
}

struct SessionQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async -> [SessionEntity] {
        await RemoteClient.shared.allSessions().filter { identifiers.contains($0.id) }.map(SessionEntity.init)
    }

    func entities(matching string: String) async -> [SessionEntity] {
        await RemoteClient.shared.allSessions()
            .filter { [$0.title, $0.folder, $0.branch ?? ""].contains { $0.localizedStandardContains(string) } }
            .map(SessionEntity.init)
    }

    func suggestedEntities() async -> [SessionEntity] {
        await RemoteClient.shared.allSessions().sorted { $0.lastActivity > $1.lastActivity }.prefix(20).map(SessionEntity.init)
    }
}

struct FolderOptions: DynamicOptionsProvider {
    func results() async -> [String] {
        let client = RemoteClient.shared
        if client.folders.isEmpty { _ = await client.connected() }

        return client.folders
    }
}

struct OpenSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Session"
    static let description = IntentDescription("Opens a session in Berth Remote.")
    static let openAppWhenRun = true

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$session)")
    }

    @Parameter(title: "Session") var session: SessionEntity

    @MainActor
    func perform() async -> some IntentResult {
        RemoteClient.shared.openedSessionID = session.id
        return .result()
    }
}

struct SendPromptIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Prompt to Session"
    static let description = IntentDescription("Sends a prompt to a session that isn’t waiting for an answer.")

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$prompt) to \(\.$session)")
    }

    @Parameter(title: "Session") var session: SessionEntity

    @Parameter(title: "Prompt") var prompt: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw IntentFailure.emptyPrompt }

        let client = RemoteClient.shared
        guard await client.connected() else { throw IntentFailure.notConnected }
        guard let current = client.groups.flatMap(\.sessions).first(where: { $0.id == session.id }) else { throw IntentFailure.unknownSession }
        guard !current.isLocked else { throw IntentFailure.locked(current.title) }
        guard current.status != "waiting" else { throw IntentFailure.waiting(current.title) }

        client.send(.prompt(sessionID: current.id, text: text, attachments: nil))
        try? await Task.sleep(for: .seconds(1))
        return .result(dialog: "Sent to \(current.title).")
    }
}

struct SessionsThatNeedMeIntent: AppIntent {
    static let title: LocalizedStringResource = "Sessions That Need Me"
    static let description = IntentDescription("Lists the sessions that are waiting for an answer.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[SessionEntity]> & ProvidesDialog {
        let client = RemoteClient.shared
        guard await client.connected() else { throw IntentFailure.notConnected }

        let waiting = await client.allSessions().filter { $0.status == "waiting" }
        guard !waiting.isEmpty else { return .result(value: [], dialog: "No sessions need you.") }

        let names = waiting.map(\.title).formatted(.list(type: .and))
        let dialog: IntentDialog = waiting.count == 1 ? "\(names) needs you." : "\(waiting.count) sessions need you: \(names)."
        return .result(value: waiting.map(SessionEntity.init), dialog: dialog)
    }
}

struct NewSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "New Session"
    static let description = IntentDescription("Starts a Claude session in a folder on your Mac.")
    static let openAppWhenRun = true

    static var parameterSummary: some ParameterSummary {
        Summary("Start a session in \(\.$folder) with \(\.$prompt)")
    }

    @Parameter(title: "Folder", optionsProvider: FolderOptions()) var folder: String

    @Parameter(title: "Prompt") var prompt: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let client = RemoteClient.shared
        guard await client.connected() else { throw IntentFailure.notConnected }
        guard client.folders.contains(folder) else { throw IntentFailure.unknownFolder }

        client.send(.newSession(folder: folder, prompt: prompt))
        return .result(dialog: "Starting a session in \(URL(filePath: folder).lastPathComponent).")
    }
}

struct BerthRemoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SessionsThatNeedMeIntent(), phrases: ["What needs me in \(.applicationName)", "Which \(.applicationName) sessions need me"], shortTitle: "Needs Me", systemImageName: "exclamationmark.bubble")
        AppShortcut(intent: OpenSessionIntent(), phrases: ["Open \(\.$session) in \(.applicationName)", "Open a session in \(.applicationName)"], shortTitle: "Open Session", systemImageName: "text.bubble")
        AppShortcut(intent: SendPromptIntent(), phrases: ["Send a prompt in \(.applicationName)", "Send \(\.$session) a prompt in \(.applicationName)"], shortTitle: "Send Prompt", systemImageName: "arrow.up.message")
        AppShortcut(intent: NewSessionIntent(), phrases: ["Start a session in \(.applicationName)", "New \(.applicationName) session"], shortTitle: "New Session", systemImageName: "plus.bubble")
    }
}

#if DEBUG
func runSnapshotIntent() async {
    setvbuf(stdout, nil, _IOLBF, 0)
    let defaults = UserDefaults.standard
    let client = RemoteClient.shared
    if let connect = defaults.string(forKey: "snapshotIntentConnect")?.split(separator: "|").map(String.init), connect.count == 2, let url = RemoteClient.url(from: connect[0]) {
        client.connect(to: url, token: connect[1])
    }
    guard let spec = defaults.string(forKey: "snapshotIntent")?.split(separator: "|", omittingEmptySubsequences: false).map(String.init) else { return }

    let sessions = await client.allSessions()
    print("snapshotIntent sessions: \(sessions.map { "\($0.title) [\($0.status ?? "-")\($0.isLocked ? " locked" : "")]" })")
    let match = sessions.first { spec.count > 1 && $0.title.localizedStandardContains(spec[1]) }.map(SessionEntity.init)
    do {
        if spec[0] == "needs" {
            let result = try await SessionsThatNeedMeIntent().perform()
            print("snapshotIntent needs: \(result)")
        } else if spec[0] == "send", let match, spec.count > 2 {
            let intent = SendPromptIntent()
            intent.session = match
            intent.prompt = spec[2]
            let result = try await intent.perform()
            print("snapshotIntent send: \(result)")
        } else if spec[0] == "open", let match {
            let intent = OpenSessionIntent()
            intent.session = match
            let result = await intent.perform()
            print("snapshotIntent open: \(result)")
        } else {
            print("snapshotIntent: nothing to run")
        }
    } catch {
        print("snapshotIntent error: \((error as? IntentFailure).map { String(localized: $0.localizedStringResource) } ?? "\(error)")")
    }
}
#endif
