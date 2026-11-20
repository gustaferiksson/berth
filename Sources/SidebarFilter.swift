import BerthCore
import Foundation
import GhosttyTerminal

enum SidebarStatus: String, CaseIterable, Identifiable {
    case all
    case working
    case needsYou
    case unread
    case flagged

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .working: "Working"
        case .needsYou: "Needs You"
        case .unread: "Unread"
        case .flagged: "Flagged"
        }
    }

    var symbol: String {
        switch self {
        case .all: "tray.full"
        case .working: "ellipsis.circle"
        case .needsYou: "exclamationmark.circle"
        case .unread: "circle.fill"
        case .flagged: "flag"
        }
    }
}

extension Store {
    func matchesStatus(_ status: SidebarStatus, _ session: SessionSummary) -> Bool {
        switch status {
        case .all: true
        case .working: liveBySession[session.id]?.activity == .working
        case .needsYou: if case .needsInput = liveBySession[session.id]?.activity { true } else { false }
        case .unread: isUnread(session)
        case .flagged: flaggedIDs.contains(session.id)
        }
    }

    func sidebarCount(_ status: SidebarStatus) -> Int {
        let archived = Set(archivedSessions.map(\.id))
        return sessionsByID.values.count(where: { !archived.contains($0.id) && matchesStatus(status, $0) })
    }

    var sidebarLayout: SidebarLayout {
        let words = sidebarFilter.split(whereSeparator: \.isWhitespace).map(String.init)
        let matches = { (fields: [String]) in words.allSatisfy { word in fields.contains { $0.localizedStandardContains(word) } } }
        let matchesSession = { (session: SessionSummary) in
            self.matchesStatus(self.sidebarStatus, session) && (words.isEmpty || matches([session.title, URL(filePath: session.checkout).lastPathComponent] + session.branches + (self.pullRequest(for: session).map { ["#\($0.number)"] } ?? []) + session.issueRefs.map { "#\($0.number)" }))
        }
        let isFiltering = !words.isEmpty || sidebarStatus != .all
        let matchesTab = { (tab: Tab) in
            self.sidebarStatus == .all && (words.isEmpty || matches([tab.title(terminalTitle: tab.terminal.title, sessionTitle: self.sessionTitle(of: tab)), URL(filePath: tab.folder).lastPathComponent]))
        }
        let sidebarGroups = sidebarGroups.compactMap { group, tabs, entries -> SidebarLayout.Group? in
            let tabs = tabs.filter(matchesTab)
            let entries = entries.compactMap { entry -> SidebarLayout.Entry? in
                switch entry {
                case let .session(id):
                    return sessionsByID[id].map(matchesSession) == false ? nil : .session(id)

                case let .task(id):
                    let task = sessionTasks.first { $0.id == id }
                    let isTaskMatch = words.isEmpty || task.map { matches([$0.title] + ($0.issue.map { ["#\($0.number)"] } ?? [])) } == true
                    let members = task?.sessions.filter { matchesStatus(sidebarStatus, $0) && (isTaskMatch || matchesSession($0)) }.map(\.id) ?? []
                    return members.isEmpty ? nil : .task(id: id, memberIDs: members)
                }
            }
            guard !isFiltering || !tabs.isEmpty || !entries.isEmpty else { return nil }

            return SidebarLayout.Group(
                source: SessionGroup(kind: group.kind, sessions: []),
                tabIDs: tabs.map(\.id),
                entries: entries,
                folders: group.folder.map { Array(Set(group.sessions.map(\.checkout)).union([$0])).sorted() } ?? []
            )
        }
        let terminalIDs = terminals.filter(matchesTab).map(\.id)
        let pinnedIDs = pinnedSessions.filter(matchesSession).map(\.id)
        let archivedIDs = archivedSessions.filter(matchesSession).map(\.id)
        return SidebarLayout(
            terminalIDs: terminalIDs,
            pinnedIDs: pinnedIDs,
            groups: sidebarGroups,
            archivedIDs: archivedIDs,
            isEmpty: hasScanned && groups.isEmpty && pinnedSessions.isEmpty && tabs.isEmpty,
            filter: sidebarFilter,
            status: sidebarStatus,
            hasNoMatches: isFiltering && terminalIDs.isEmpty && pinnedIDs.isEmpty && sidebarGroups.isEmpty && archivedIDs.isEmpty
        )
    }
}
