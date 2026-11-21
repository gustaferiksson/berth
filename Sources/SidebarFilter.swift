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
        case .all: "tray"
        case .working: "ellipsis.circle"
        case .needsYou: "exclamationmark.circle"
        case .unread: "circlebadge"
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

    func attentionRank(_ session: SessionSummary) -> Int? {
        if case .needsInput = liveBySession[session.id]?.activity { return 0 }

        if let pullRequest = pullRequest(for: session), [.open, .draft].contains(pullRequest.state), pullRequest.checks == .failed { return 1 }

        return isUnread(session) ? 2 : nil
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
        let source = (sidebarActive.map { [$0] } ?? []) + sidebarGroups
        let attentionIDs = source
            .flatMap(\.entries)
            .compactMap { entry -> (session: SessionSummary, rank: Int)? in
                guard case let .session(id) = entry, let session = sessionsByID[id], matchesSession(session), let rank = attentionRank(session) else { return nil }

                return (session, rank)
            }
            .sorted { ($0.rank, $1.session.lastActivity) < ($1.rank, $0.session.lastActivity) }
            .map(\.session.id)
        let attention = Set(attentionIDs)
        let sidebarGroups = source.compactMap { group, tabs, entries -> SidebarLayout.Group? in
            let tabs = tabs.filter(matchesTab)
            let entries = entries.compactMap { entry -> SidebarLayout.Entry? in
                switch entry {
                case let .session(id):
                    return attention.contains(id) || sessionsByID[id].map(matchesSession) == false ? nil : .session(id)

                case let .task(id):
                    let task = sessionTasks.first { $0.id == id }
                    let isTaskMatch = words.isEmpty || task.map { matches([$0.title] + ($0.issue.map { ["#\($0.number)"] } ?? [])) } == true
                    let members = task?.sessions.filter { matchesStatus(sidebarStatus, $0) && (isTaskMatch || matchesSession($0)) }.map(\.id) ?? []
                    return members.isEmpty ? nil : .task(id: id, memberIDs: members)
                }
            }
            guard !tabs.isEmpty || !entries.isEmpty || (group.custom != nil && !isFiltering) else { return nil }

            let lastInUse = entries.lastIndex { entry in
                guard case let .session(id) = entry else { return false }

                return tab(forSession: id) != nil || (liveBySession[id]?.activity ?? .idle) != .idle
            }
            let visibleLimit = switch group.kind {
            case .flat: 15
            case .active: max(5, (lastInUse ?? -1) + 1)
            default: 5
            }

            return SidebarLayout.Group(
                source: SessionGroup(kind: group.kind, sessions: []),
                tabIDs: tabs.map(\.id),
                entries: entries,
                visibleLimit: visibleLimit,
                folders: group.folder.map { Array(Set(group.sessions.map(\.checkout)).union([$0])).sorted() } ?? []
            )
        }
        let terminalIDs = terminals.filter(matchesTab).map(\.id)
        let liveIDs = Set(liveSessions.map(\.id))
        let pinnedIDs = pinnedSessions.filter { !liveIDs.contains($0.id) && matchesSession($0) }.map(\.id)
        let archivedIDs = archivedSessions.filter(matchesSession).map(\.id)
        return SidebarLayout(
            terminalIDs: terminalIDs,
            attentionIDs: attentionIDs,
            pinnedIDs: pinnedIDs,
            active: sidebarGroups.first { $0.source.kind == .active },
            groups: sidebarGroups.filter { $0.source.kind != .active },
            archivedIDs: archivedIDs,
            isEmpty: hasScanned && groups.isEmpty && pinnedSessions.isEmpty && tabs.isEmpty,
            filter: sidebarFilter,
            status: sidebarStatus,
            hasNoMatches: isFiltering && terminalIDs.isEmpty && attentionIDs.isEmpty && pinnedIDs.isEmpty && sidebarGroups.isEmpty && archivedIDs.isEmpty
        )
    }
}
