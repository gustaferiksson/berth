#if DEBUG
import BerthCore
import Foundation

extension Snapshot {
    static func projectsFixture() -> (list: ProjectList, boards: [String: ProjectBoard], state: ProjectsModel.State)? {
        let defaults = UserDefaults.standard
        guard output != nil || SettingsSnapshot.output != nil, defaults.bool(forKey: "snapshotProjects") else { return nil }

        let listJSON = """
        {"data":{"viewer":{"login":"sam","projectsV2":{"nodes":[
          {"id":"fixture-roadmap","number":1,"title":"Roadmap","closed":false,"url":"https://github.com/users/sam/projects/1"}
        ]},"organizations":{"nodes":[{"login":"acme","projectsV2":{"nodes":[
          {"id":"fixture-platform","number":7,"title":"Platform","closed":false,"url":"https://github.com/orgs/acme/projects/7"}
        ]}}]}}}}
        """
        guard case let .success(list) = ProjectQueries.parseList(Data(listJSON.utf8)) else { return nil }

        typealias Row = (reference: String?, title: String, kind: String, status: Int?, assignees: [String])
        let rows: [[Row]] = [
            [
                ("acme/web#21", "Let billing administrators download usage reports for any closed billing period from the dashboard", "Issue", 0, ["sam"]),
                ("acme/billing#4821", "Reconcile ledger entries", "PullRequest", 2, ["sam", "lee"]),
                ("acme/web#22", "Add the download button", "PullRequest", 1, ["kim"]),
                ("acme/billing#57", "Fix invoice rounding", "Issue", 1, ["sam"]),
                ("acme/web#12", "Fix the flaky login test", "Issue", 3, ["lee"]),
                ("acme/billing#4823", "Export ledger entries", "PullRequest", 3, ["lee"]),
                ("acme/web#1742", "Paginate the audit log", "Issue", nil, []),
            ],
            [
                ("acme/api#10", "Add usage export endpoints", "Issue", 0, ["lee"]),
                ("acme/api#11", "Add the export endpoint", "PullRequest", 2, ["sam"]),
                ("acme/api#22", "Support exports on the API gateway", "PullRequest", 1, ["kim"]),
                ("acme/billing#61", "Add the usage export API", "PullRequest", 3, ["sam"]),
                ("acme/api#25", "Document webhook retries", "Issue", 3, []),
                ("acme/billing#49", "Drop the legacy CSV importer", "Issue", 0, ["kim"]),
                (nil, "Plan the next usage export format", "DraftIssue", 0, ["sam"]),
            ],
        ]
        let names = ["Todo", "In Progress", "In Review", "Done"]
        let options = names.enumerated().map { index, name in
            #"{"id":"status-\#(index)","name":"\#(name)"}"#
        }.joined(separator: ",")
        var boards: [String: ProjectBoard] = [:]
        for (project, entries) in zip(list.projects, rows) {
            let nodes = entries.enumerated().map { index, row in
                let status = row.status.map { #""fieldValueByName":{"name":"\#(names[$0])","optionId":"status-\#($0)"},"# } ?? ""
                let assignees = row.assignees.map { #"{"login":"\#($0)"}"# }.joined(separator: ",")
                let parts = row.reference?.split(separator: "#")
                let link: String
                if let parts {
                    let path = row.kind == "Issue" ? "issues" : "pull"
                    link = #""number":\#(parts[1]),"url":"https://github.com/\#(parts[0])/\#(path)/\#(parts[1])","repository":{"nameWithOwner":"\#(parts[0])"},"#
                } else {
                    link = ""
                }
                return """
                {"id":"\(project.id)-\(index)","isArchived":false,\(status)
                 "content":{"__typename":"\(row.kind)","title":"\(row.title)",\(link)
                 "updatedAt":"2026-11-20T12:\(10 + index):00Z","assignees":{"nodes":[\(assignees)]}}}
                """
            }.joined(separator: ",")
            let boardJSON = """
            {"data":{"node":{"field":{"id":"\(project.id)-status","options":[\(options)]},
            "items":{"nodes":[\(nodes)],"pageInfo":{"hasNextPage":false}}}}}
            """
            guard case let .success(page) = ProjectQueries.parseBoardPage(Data(boardJSON.utf8), projectID: project.id) else { return nil }

            boards[project.id] = ProjectQueries.mergePages(project: project, pages: [page])
        }
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[ProjectsModel.enabledKey] = true
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)

        let state = defaults.string(forKey: "snapshotProjectsState").flatMap(ProjectsModel.State.init(rawValue:)) ?? .ready
        return (list, boards, state)
    }
}
#endif
