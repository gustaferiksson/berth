import BerthCore
import Foundation

extension Store {
    func dismissReviewMark(_ mark: ControlReviewMark) {
        guard let sessionID = selectedSessionID, let marks = reviewMarks[sessionID] else { return }

        let kept = marks.filter { $0 != mark }
        reviewMarks[sessionID] = kept.isEmpty ? nil : kept
    }

    func clearReviewMarks(path: String? = nil) {
        guard let sessionID = selectedSessionID else { return }

        let kept = path.map { path in (reviewMarks[sessionID] ?? []).filter { $0.path != path } } ?? []
        reviewMarks[sessionID] = kept.isEmpty ? nil : kept
    }

    func updateReviewMarks(_ marks: [ControlReviewMark], in tabID: Tab.ID) async -> ControlResponse {
        guard UserDefaults.standard.bool(forKey: GeneralSettings.reviewKey) else { return .failure("Enable Review in Settings to mark changes") }
        guard let caller = tabs.first(where: { $0.id == tabID }),
              let target = caller.kind == .claude ? caller : tabs.first(where: { $0.id == caller.parentTabID && $0.kind == .claude }),
              let sessionID = target.sessionID
        else { return .failure("Run berth review from a session or its terminal") }

        if marks.isEmpty {
            reviewMarks[sessionID] = nil
            return ControlResponse(text: "Cleared Review marks")
        }
        guard selectedSessionID == sessionID else { return .failure("Show this session in Berth to mark its changes") }

        showsReviewPanel = true
        isHarborShown = false
        prepareReviewModel()
        guard let model = reviewModels[sessionID] else { return .failure("Review couldn’t open for this session tab") }

        await model.load()
        let root = URL(filePath: model.changes?.root ?? model.folder).resolvingSymlinksInPath().path
        let paths = marks.reduce(into: [String]()) { if !$0.contains($1.path) { $0.append($1.path) } }
        let missing = paths.filter { path in
            var isDirectory: ObjCBool = false
            let resolved = URL(filePath: root).appending(path: path).resolvingSymlinksInPath().path
            return !resolved.hasPrefix(root + "/") || !FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory) || isDirectory.boolValue
        }
        guard missing.isEmpty else { return .failure("Not files in the session repository: " + missing.joined(separator: ", ")) }
        guard selectedSessionID == sessionID, reviewModels[sessionID] === model else { return .failure("The session changed while opening Review. Try again") }

        reviewMarks[sessionID] = (reviewMarks[sessionID] ?? []).filter { old in !marks.contains { $0.path == old.path && $0.startLine == old.startLine && $0.endLine == old.endLine } } + marks
        let documents = paths.map { model.changedDocument(at: $0) ?? model.workingDocument($0) }
        for document in documents {
            model.open(document)
            if let id = model.selectedTabID { model.keep(id) }
        }
        model.open(documents[0])
        model.revealLine = (documents[0], marks[0].startLine, .modified)
        return ControlResponse(text: "Marked \(marks.count) \(marks.count == 1 ? "range" : "ranges") in \(paths.count) \(paths.count == 1 ? "file" : "files")")
    }
}
