@testable import BerthCore
import Foundation
import Testing

struct ProjectBoardTests {
    private let project = ProjectRef(id: "board-web", number: 4, title: "Web", ownerLogin: "acme", url: URL(string: "https://github.com/orgs/acme/projects/4")!, isClosed: false)

    @Test func partialListKeepsPersonalAndOrganizationProjects() throws {
        let output = """
        {
          "data": {"viewer": {
            "login": "dev",
            "projectsV2": {"nodes": [
              {"id":"personal","number":1,"title":"Planning","closed":false,"url":"https://github.com/users/dev/projects/1","owner":{"login":"dev"}},
              {"id":"old","number":2,"title":"Old","closed":true,"url":"https://github.com/users/dev/projects/2","owner":{"login":"dev"}}
            ]},
            "organizations": {"nodes": [
              null,
              {"login":"restricted","projectsV2":null},
              {"login":"acme","projectsV2":{"nodes":[
                {"id":"board-web","number":4,"title":"Web","closed":false,"url":"https://github.com/orgs/acme/projects/4","owner":{"login":"acme"}}
              ]}},
              {"login":"duplicate","projectsV2":{"nodes":[
                null,
                {"id":"board-web","number":4,"title":"Web","closed":false,"url":"https://github.com/orgs/acme/projects/4","owner":{"login":"acme"}}
              ]}}
            ]}
          }},
          "errors": [{"type":"FORBIDDEN","message":"Organization requires SSO"}]
        }
        """
        let list = try ProjectQueries.parseList(Data(output.utf8)).get()
        #expect(list.viewerLogin == "dev")
        #expect(list.projects.map(\.id) == ["personal", "board-web"])
        #expect(list.projects.map(\.ownerLogin) == ["dev", "acme"])
        #expect(list.projects.last == project)
    }

    @Test func distinguishesMissingScopeFromOtherFailures() {
        let structured = Data(#"{"data":{"viewer":null,"node":null},"errors":[{"type":"INSUFFICIENT_SCOPES","message":"Token lacks access"}]}"#.utf8)
        let message = Data(#"{"errors":[{"message":"The read:project scope is required"}]}"#.utf8)
        let forbidden = Data(#"{"errors":[{"type":"FORBIDDEN","message":"Organization requires SSO"}]}"#.utf8)
        #expect(ProjectQueries.parseList(structured) == .failure(.missingScope))
        #expect(ProjectQueries.parseBoardPage(structured, projectID: project.id) == .failure(.missingScope))
        #expect(ProjectQueries.parseList(message) == .failure(.missingScope))
        #expect(ProjectQueries.parseList(Data(), stderr: "gh: requires read:project") == .failure(.missingScope))
        #expect(ProjectQueries.parseList(Data("gh: requires read:project".utf8)) == .failure(.missingScope))
        #expect(ProjectQueries.parseList(forbidden) == .failure(.other))
        #expect(ProjectQueries.refreshScopeCommand == "gh auth refresh -s read:project")
        #expect(ProjectQueries.writeScopeCommand == "gh auth refresh -s project")
    }

    @Test func boardKeepsOpenAndDraftItemsFromPartialData() throws {
        let output = """
        {
          "data":{"node":{
            "field":{"id":"field-status","options":[{"id":"todo","name":"Todo"},{"id":"done","name":"Done"}]},
            "items":{"pageInfo":{"hasNextPage":true,"endCursor":"cursor-1"},"nodes":[
              null,
              {"id":"archived","isArchived":true,"content":{"__typename":"Issue","title":"Archived","state":"OPEN"}},
              {"id":"redacted","isArchived":false,"content":null},
              {"id":"unknown","isArchived":false,"content":{"__typename":"RedactedProjectV2Item"}},
              {"id":"closed-issue","isArchived":false,"content":{"__typename":"Issue","title":"Closed issue","state":"CLOSED"}},
              {"id":"closed-pr","isArchived":false,"content":{"__typename":"PullRequest","title":"Closed PR","state":"CLOSED"}},
              {"id":"merged","isArchived":false,"content":{"__typename":"PullRequest","title":"Merged PR","state":"MERGED"}},
              {"id":"issue","isArchived":false,"fieldValueByName":{"name":"Todo","optionId":"todo"},"content":{
                "__typename":"Issue","title":"Improve navigation","state":"OPEN","number":7,"url":"https://github.com/acme/web/issues/7",
                "updatedAt":"2026-05-04T12:30:00Z","repository":{"nameWithOwner":"Acme/Web"},
                "assignees":{"nodes":[{"login":"dev"},null,{"login":"other"}]}
              }},
              {"id":"pr","isArchived":false,"content":{"__typename":"PullRequest","title":"Update navigation","state":"OPEN","isDraft":true}},
              {"id":"draft","isArchived":false,"content":{"__typename":"DraftIssue","title":"Follow up","assignees":{"nodes":[{"login":"dev"}]}}}
            ]}
          }},
          "errors":[{"type":"FORBIDDEN","message":"Some project items are restricted"}]
        }
        """
        let page = try ProjectQueries.parseBoardPage(Data(output.utf8), projectID: project.id).get()
        #expect(page.statusFieldID == "field-status")
        #expect(page.statusOptions.map(\.id) == ["todo", "done"])
        #expect(page.statusOptions.map(\.name) == ["Todo", "Done"])
        #expect(page.hasNextPage)
        #expect(page.endCursor == "cursor-1")
        #expect(page.items.map(\.id) == ["issue", "pr", "draft"])
        #expect(page.items.map(\.kind) == [.issue, .pullRequest, .draft])
        #expect(page.items.map(\.isDraftPullRequest) == [false, true, false])
        let issue = try #require(page.items.first)
        #expect(issue.projectID == project.id)
        #expect(issue.number == 7)
        #expect(issue.title == "Improve navigation")
        #expect(issue.repository == "Acme/Web")
        #expect(issue.linkKey == "acme/web#7")
        #expect(issue.url?.absoluteString == "https://github.com/acme/web/issues/7")
        #expect(issue.statusName == "Todo")
        #expect(issue.statusOptionID == "todo")
        #expect(issue.assignees == ["dev", "other"])
        #expect(issue.updatedAt?.ISO8601Format() == "2026-05-04T12:30:00Z")
        #expect(page.items.last?.linkKey == nil)
        #expect(page.items.last?.assignees == ["dev"])
    }

    @Test func mergeKeepsPageOrderAndMarksTruncation() throws {
        let pages = try (0..<4).map { pageIndex in
            let nodes = (0..<100).map { itemIndex in
                #"{"id":"item-\#(pageIndex * 100 + itemIndex)","isArchived":false,"content":{"__typename":"DraftIssue","title":"Follow up"}}"#
            }.joined(separator: ",")
            let field = pageIndex == 0 ? #"{"id":"field-status","options":[{"id":"todo","name":"Todo"}]}"# : "null"
            let output = """
            {"data":{"node":{"field":\(field),"items":{"pageInfo":{"hasNextPage":\(pageIndex < 3),"endCursor":"page-\(pageIndex)"},"nodes":[\(nodes)]}}}}
            """
            return try ProjectQueries.parseBoardPage(Data(output.utf8), projectID: project.id).get()
        }
        let firstThree = Array(pages.prefix(3))
        let limited = ProjectQueries.mergePages(project: project, pages: firstThree)
        #expect(limited.project == project)
        #expect(limited.statusFieldID == "field-status")
        #expect(limited.statusOptions.map(\.name) == ["Todo"])
        #expect(limited.items.map(\.id) == (0..<300).map { "item-\($0)" })
        #expect(limited.isTruncated)
        #expect(ProjectQueries.mergePages(project: project, pages: pages).items == limited.items)
        #expect(ProjectQueries.mergePages(project: project, pages: pages).isTruncated)
        #expect(ProjectQueries.mergePages(project: project, pages: [pages[3]]).isTruncated == false)
        #expect(ProjectQueries.mergePages(project: project, pages: [pages[0], pages[1], pages[3]]).isTruncated == false)
    }

    @Test func groupingUsesStatusOrderAndSortsMineFirstThenByDate() {
        let entries: [(title: String, status: String?, assignees: [String], age: Int)] = [
            ("Other active", "working", ["other"], 3),
            ("Older mine", "working", ["DEV"], 6),
            ("Newer mine", "working", ["Dev"], 4),
            ("Completed task", "finished", ["other"], 2),
            ("Older closed", "closed", ["other"], 8),
            ("Unsorted", nil, [], 1),
        ]
        let items = entries.enumerated().map { index, entry in
            ProjectItem(
                id: "item-\(index)", projectID: project.id, kind: .issue, number: index + 10, title: entry.title, repository: "acme/web", url: nil,
                statusName: nil, statusOptionID: entry.status, assignees: entry.assignees, isDraftPullRequest: false,
                updatedAt: Date(timeIntervalSince1970: -Double(entry.age))
            )
        }
        let board = ProjectBoard(project: project, statusFieldID: "status", statusOptions: [
            ProjectStatusOption(id: "empty", name: "Backlog"),
            ProjectStatusOption(id: "closed", name: "Closed"),
            ProjectStatusOption(id: "working", name: "In progress"),
            ProjectStatusOption(id: "finished", name: "Completed"),
        ], items: items, isTruncated: false)

        let groups = board.groups(query: "", mineOnly: false, login: "dev")
        #expect(groups.map(\.statusName) == ["Closed", "In progress", "Completed", "No Status"])
        #expect(groups.map(\.optionID) == ["closed", "working", "finished", nil])
        #expect(groups[1].items.map(\.title) == ["Newer mine", "Older mine", "Other active"])
        #expect(groups.last?.items.map(\.title) == ["Unsorted"])
        let mine = board.groups(query: "", mineOnly: true, login: "dev")
        #expect(mine.map(\.statusName) == ["In progress"])
        #expect(mine.first?.items.map(\.title) == ["Newer mine", "Older mine"])
        #expect(board.groups(query: "web #10", mineOnly: false, login: "dev").flatMap(\.items).map(\.title) == ["Other active"])
        #expect(board.groups(query: "other active", mineOnly: true, login: "dev").isEmpty)
    }

    @Test func capsOnlyTheLastDoneLikeStatusToFiveMostRecentUntilSearching() {
        let statusIDs = ["closed", "finished"]
        let items = statusIDs.flatMap { status in
            (0..<7).map { index in
                ProjectItem(
                    id: "\(status)-\(index)", projectID: project.id, kind: .draft, number: nil, title: "Archived task \(index)", repository: nil, url: nil,
                    statusName: nil, statusOptionID: status, assignees: [0, 3].contains(index) ? ["dev"] : [], isDraftPullRequest: false,
                    updatedAt: Date(timeIntervalSince1970: Double(index))
                )
            }
        }
        let board = ProjectBoard(project: project, statusFieldID: "status", statusOptions: [
            ProjectStatusOption(id: "closed", name: "Closed"),
            ProjectStatusOption(id: "finished", name: "COMPLETE"),
            ProjectStatusOption(id: "ready", name: "Ready"),
        ], items: items, isTruncated: false)
        let groups = board.groups(query: " \n", mineOnly: false, login: "dev")
        #expect(groups.map(\.hiddenCount) == [0, 2])
        #expect(groups.last?.items.map(\.id) == ["finished-3", "finished-6", "finished-5", "finished-4", "finished-2"])
        let search = board.groups(query: "archived", mineOnly: false, login: "dev")
        #expect(search.map(\.hiddenCount) == [0, 0])
        #expect(search.map(\.items.count) == [7, 7])
        let mine = board.groups(query: "", mineOnly: true, login: "DEV")
        #expect(mine.map(\.hiddenCount) == [0, 0])
        #expect(mine.last?.items.map(\.id) == ["finished-3", "finished-0"])
    }

    @Test func passesReadAndWriteIDsOnlyAsGraphQLVariables() {
        let cursor = #"cursor:"quoted""#
        let board = ProjectQueries.boardArguments(projectID: project.id, cursor: cursor)
        #expect(board[3].contains("node(id: $projectID)"))
        #expect(board[3].contains("items(first: 100, after: $cursor)"))
        #expect(!board[3].contains(project.id))
        #expect(!board[3].contains(cursor))
        #expect(board.contains("projectID=\(project.id)"))
        #expect(board.contains("cursor=\(cursor)"))
        #expect(!ProjectQueries.boardArguments(projectID: project.id, cursor: nil).contains { $0.hasPrefix("cursor=") })

        let ids = [#"project"id"#, #"item"id"#, #"field"id"#, #"option"id"#]
        let move = ProjectQueries.moveArguments(projectID: ids[0], itemID: ids[1], fieldID: ids[2], optionID: ids[3])
        let query = move[3]
        #expect(query.contains("updateProjectV2ItemFieldValue"))
        #expect(query.contains("projectId: $projectID, itemId: $itemID, fieldId: $fieldID, value: { singleSelectOptionId: $optionID }"))
        #expect(!ids.contains { query.contains($0) })
        #expect(move.suffix(8) == ["-f", "projectID=\(ids[0])", "-f", "itemID=\(ids[1])", "-f", "fieldID=\(ids[2])", "-f", "optionID=\(ids[3])"])
    }
}
