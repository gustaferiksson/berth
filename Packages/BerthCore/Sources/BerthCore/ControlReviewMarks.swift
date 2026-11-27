import Foundation

public struct ControlReviewMark: Codable, Equatable, Sendable {
    public let path: String
    public let startLine: Int
    public let endLine: Int
    public let note: String

    public init(path: String, startLine: Int, endLine: Int, note: String = "") {
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
        self.note = note
    }
}

public enum ControlReviewMarks {
    public struct ValidationError: Error, Equatable {
        public let message: String
    }

    public static func validate(_ request: ControlRequest) -> Result<[ControlReviewMark], ValidationError> {
        if request.operation == .reviewClearMarks {
            guard request.marks == nil, request.base == nil else { return .failure(.init(message: "Clearing Review marks takes no marks or base")) }

            return .success([])
        }
        guard request.operation == .reviewMark, let marks = request.marks, !marks.isEmpty, marks.count <= 50 else {
            return .failure(.init(message: "Pass between 1 and 50 Review marks"))
        }

        if let base = request.base {
            let disallowed = CharacterSet.whitespacesAndNewlines.union(.controlCharacters).union(CharacterSet(charactersIn: "~^:?*[\\"))
            let components = base.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false)
            guard !base.isEmpty, base.utf8.count <= 255, base.unicodeScalars.first != "-", base != "@", base.unicodeScalars.last != ".",
                  base.range(of: "..", options: .literal) == nil, base.range(of: "@{", options: .literal) == nil,
                  !base.unicodeScalars.contains(where: disallowed.contains),
                  components.allSatisfy({ !$0.isEmpty && $0.first != "." && !$0.suffix(5).elementsEqual(".lock".unicodeScalars) })
            else { return .failure(.init(message: "The Review base must be a Git ref or commit ID of at most 255 bytes")) }
        }

        var validated: [ControlReviewMark] = []
        for (index, mark) in marks.enumerated() {
            let position = index + 1
            let components = mark.path.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false)
            guard !mark.path.utf8.contains(0), components.allSatisfy({ !$0.isEmpty && !$0.elementsEqual(".".unicodeScalars) && !$0.elementsEqual("..".unicodeScalars) }) else {
                return .failure(.init(message: "Review mark \(position) needs a normalized path relative to the session repository"))
            }
            guard mark.startLine >= 1, mark.endLine >= mark.startLine, mark.endLine <= 1_000_000 else {
                return .failure(.init(message: "Review mark \(position) needs an ordered line range between 1 and 1000000"))
            }

            let note = String(mark.note.unicodeScalars.filter { $0 == "\n" || !CharacterSet.controlCharacters.contains($0) }).trimmingCharacters(in: .whitespacesAndNewlines)
            guard note.count <= 500 else { return .failure(.init(message: "Review mark \(position) needs a note of at most 500 characters")) }

            validated.append(ControlReviewMark(path: mark.path, startLine: mark.startLine, endLine: mark.endLine, note: note))
        }
        return .success(validated)
    }
}
