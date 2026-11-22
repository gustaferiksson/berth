import Foundation

public struct ToolResultSummary: Sendable, Equatable {
    public let text: String
    public let moreLines: Int
    public let isError: Bool
}

public extension ToolCall {
    var resultSummary: ToolResultSummary? {
        guard let result else { return nil }

        let lines = result.text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        let first = lines.first.map { String($0.prefix(200)) } ?? ""
        if result.isError { return ToolResultSummary(text: first.isEmpty ? "Failed" : first, moreLines: max(0, lines.count - 1), isError: true) }

        if use.name == "REPL" { return nil }
        if first.hasPrefix("<system>") { return ToolResultSummary(text: "Done", moreLines: 0, isError: false) }

        if use.name == "Edit", let old = use.oldText, let new = use.newText {
            let rows = ToolDiff.rows(old: old, new: new)
            let added = rows.count { $0.kind == .added }
            let removed = rows.count { $0.kind == .removed }
            let parts = [added > 0 ? "Added \(added) \(added == 1 ? "line" : "lines")" : nil, removed > 0 ? "\(added > 0 ? "removed" : "Removed") \(removed) \(removed == 1 ? "line" : "lines")" : nil].compactMap(\.self)
            return ToolResultSummary(text: parts.isEmpty ? "No changes" : parts.joined(separator: ", "), moreLines: 0, isError: false)
        }
        if use.name == "Write", let content = use.newText {
            let count = content.split(separator: "\n", omittingEmptySubsequences: false).count
            return ToolResultSummary(text: "Wrote \(count) \(count == 1 ? "line" : "lines")", moreLines: 0, isError: false)
        }
        if kind == .read {
            if result.imageRefs != nil { return ToolResultSummary(text: "Read image", moreLines: 0, isError: false) }

            return ToolResultSummary(text: "Read \(lines.count) \(lines.count == 1 ? "line" : "lines")", moreLines: 0, isError: false)
        }
        if kind == .search, !first.hasPrefix("Found") {
            return ToolResultSummary(text: lines.isEmpty ? "No matches" : "\(lines.count) \(lines.count == 1 ? "result" : "results")", moreLines: 0, isError: false)
        }
        return ToolResultSummary(text: first.isEmpty ? "Done" : first, moreLines: max(0, lines.count - 1), isError: false)
    }

    var displayName: String {
        let renamed = ["Edit": "Update", "MultiEdit": "Update", "Grep": "Search", "Glob": "Search", "Task": "Agent", "WebFetch": "Fetch", "WebSearch": "Web Search", "SendMessage": "Message"]
        guard let name = use.name else { return "Tool" }

        if name == "REPL" { return use.detail.flatMap { $0.isEmpty ? nil : $0 } ?? "Script" }

        if let renamed = renamed[name] { return renamed }

        let parts = name.components(separatedBy: "__")
        return parts.count > 2 ? "\(parts[1]) \(parts[2])" : name
    }

    var arguments: String {
        if use.name == "REPL" { return "" }
        if let command = use.command { return String(command.prefix { $0 != "\n" }) }
        if let path = use.filePath { return path.replacing(FileManager.default.homeDirectoryForCurrentUser.path, with: "~") }
        return use.detail ?? ""
    }
}
