import BerthCore
import Foundation

@Observable
@MainActor
final class ProjectsModel {
    enum State: String {
        case off, loading, ready, needsScope, noCLI, failed
    }

    private struct Selection: Decodable {
        let ids: [String]

        init(from decoder: some Decoder) throws {
            let stored = try decoder.singleValueContainer().decode([String].self)
            var seen: Set<String> = []
            ids = stored.filter { seen.insert($0).inserted }
        }
    }

    static let enabledKey = "projectsEnabled"
    static let selectedKey = "projectsSelected"
    static let mineOnlyKey = "projectsMineOnly"
    static let allowsEditingKey = "projectsAllowsEditing"

    private(set) var availableProjects: [ProjectRef] = []
    private(set) var viewerLogin = ""
    private(set) var boards: [String: ProjectBoard] = [:]
    private(set) var selectedIDs: [String] = {
        let stored = UserDefaults.standard.string(forKey: selectedKey) ?? "[]"
        return (try? JSONDecoder().decode(Selection.self, from: Data(stored.utf8)))?.ids ?? []
    }()

    enum MoveFailure {
        case needsScope, failed
    }

    private(set) var moveFailure: MoveFailure?
    private var launcherColumns: [String: String] = [:]

    var launcherColumn: String? {
        get { launcherColumns[selectedIDs.joined(separator: ",")] }
        set { launcherColumns[selectedIDs.joined(separator: ",")] = newValue }
    }

    private var fetchState = State.off
    @ObservationIgnored private var fetchedAt = Date.distantPast

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    var state: State { isEnabled ? fetchState : .off }

    var selectedBoards: [ProjectBoard] {
        guard isEnabled else { return [] }

        return selectedIDs.compactMap { boards[$0] }
    }

    init() {
        #if DEBUG
        if let fixture = Snapshot.projectsFixture() {
            availableProjects = fixture.list.projects
            viewerLogin = fixture.list.viewerLogin
            boards = fixture.boards
            selectedIDs = availableProjects.map(\.id)
            fetchState = fixture.state
        }
        #endif
    }

    func status(forRepository repository: String, number: Int) -> (statusName: String, projectTitle: String)? {
        guard isEnabled else { return nil }

        let key = "\(repository.lowercased())#\(number)"
        for id in selectedIDs {
            guard let board = boards[id],
                  let statusName = board.items.first(where: { $0.linkKey == key && $0.statusName != nil })?.statusName
            else { continue }

            return (statusName, board.project.title)
        }
        return nil
    }

    func statusLabels(for pullRequests: [SessionPullRequest]) -> [String: String] {
        let labels = pullRequests.compactMap { pullRequest in
            status(forRepository: pullRequest.repository, number: pullRequest.number).map { ("\(pullRequest.repository.lowercased())#\(pullRequest.number)", "\($0.statusName) · \($0.projectTitle)") }
        }
        return Dictionary(labels) { first, _ in first }
    }

    func move(_ item: ProjectItem, to option: ProjectStatusOption) {
        guard UserDefaults.standard.bool(forKey: Self.allowsEditingKey), item.statusOptionID != option.id,
              let board = boards[item.projectID], let fieldID = board.statusFieldID
        else { return }

        moveFailure = nil
        boards[item.projectID] = board.moving(itemID: item.id, to: option)
        guard Snapshot.output == nil else { return }

        let arguments = ProjectQueries.moveArguments(projectID: item.projectID, itemID: item.id, fieldID: fieldID, optionID: option.id)
        Task {
            let failure = await Task.detached { PullRequestStatus.moveProjectItem(arguments) }.value
            guard let failure else {
                fetchedAt = .distantPast
                return
            }

            boards[item.projectID] = board
            moveFailure = failure == .needsScope ? .needsScope : .failed
        }
    }

    func select(_ id: String, isSelected: Bool, persists: Bool) {
        guard selectedIDs.contains(id) != isSelected else { return }

        if isSelected {
            selectedIDs.append(id)
        } else {
            selectedIDs.removeAll { $0 == id }
        }
        if persists, let data = try? JSONEncoder().encode(selectedIDs) {
            UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: Self.selectedKey)
        }
        if isSelected { refreshList() }
    }

    func refresh() {
        guard fetchedAt.timeIntervalSinceNow < -60 else { return }

        refreshList()
    }

    func refreshList() {
        #if DEBUG
        guard SettingsSnapshot.output == nil else { return }

        #endif
        guard isEnabled, Snapshot.output == nil, fetchState != .loading else { return }

        fetchedAt = .now
        fetchState = .loading
        let selection = Set(selectedIDs)
        Task {
            var nextState = State.off
            defer {
                fetchState = nextState
                if !Set(selectedIDs).isSubset(of: selection) { refreshList() }
            }
            let result = await Task.detached { PullRequestStatus.projectList() }.value
            guard isEnabled else { return }

            switch result {
            case let .failure(error):
                nextState = State(error)
            case let .success(list):
                availableProjects = list.projects
                viewerLogin = list.viewerLogin
                nextState = await withTaskGroup(of: Result<ProjectBoard, PullRequestStatus.ProjectFailure>.self) { group in
                    for project in list.projects where selection.contains(project.id) && selectedIDs.contains(project.id) {
                        group.addTask { PullRequestStatus.projectBoard(project) }
                    }
                    var state = State.ready
                    for await result in group {
                        guard isEnabled else {
                            group.cancelAll()
                            return .off
                        }

                        switch result {
                        case let .success(board): boards[board.project.id] = board
                        case let .failure(error):
                            if state == .ready || error == .needsScope { state = State(error) }
                        }
                    }
                    return state
                }
            }
        }
    }
}

private extension ProjectsModel.State {
    init(_ failure: PullRequestStatus.ProjectFailure) {
        switch failure {
        case .noCLI: self = .noCLI
        case .needsScope: self = .needsScope
        case .failed: self = .failed
        }
    }
}
