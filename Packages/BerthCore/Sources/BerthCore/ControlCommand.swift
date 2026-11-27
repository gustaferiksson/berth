import Foundation

public enum ControlCommand {
    public static let usage = """
    usage: berth ls [--json]
           berth open-terminal [--cwd <dir>] [--background] [--json] [--] [<command>...]
           berth open-session [--cwd <dir>] [--background] [--json] [-- <prompt words>]
           berth open <path> [--background] [--json]
           berth open-url <url> [--background] [--json]
           berth browser tabs [--json]
           berth browser screenshot [--tab <id>] [--out <path>] [--full-page] [--json]
           berth browser console [--tab <id>] [--since <n>] [--follow] [--json]
           berth browser url [--tab <id>] [--json]
           berth browser reload [--tab <id>] [--json]
           berth browser navigate <url> [--tab <id>] [--json]
           berth browser text [--tab <id>] [--json]
           berth browser html [--tab <id>] [--selector <css>] [--json]
           berth browser snapshot [--tab <id>] [--json]
           berth browser open [<url>] [--background] [--json]
           berth browser click <target> [--tab <id>] [--json]
           berth browser fill <target> <text> [--tab <id>] [--json]
           berth browser type <text> [--tab <id>] [--json]
           berth browser press <key> [--tab <id>] [--json]
           berth browser select <target> <value> [--tab <id>] [--json]
           berth browser hover <target> [--tab <id>] [--json]
           berth browser scroll (<target> | --to top|bottom | --by <px>) [--tab <id>] [--json]
           berth browser wait (<selector> | --text <text> | --url <substring> | --load | --ms <n>) [--timeout <seconds>] [--tab <id>] [--json]
           berth browser back [--tab <id>] [--json]
           berth browser forward [--tab <id>] [--json]
           berth browser eval <js> [--tab <id>] [--json]
           berth show-pr <number|url> [--repo <path>] [--json]
           berth review mark <path>:<start>[-<end>] [--note <text>] ... [--json]
           berth review marks clear [--json]
           berth send <tab> <text> [--no-enter]
           berth capture <tab>
           berth close <tab>
           berth wait <tab> [--timeout <seconds>]
    """

    public struct Invocation: Equatable {
        public let request: ControlRequest
        public let socketPath: String
        public let json: Bool
        public let follow: Bool
    }

    public struct UsageError: Error, Equatable {
        public let message: String
    }

    public static func parse(_ arguments: [String], environment: [String: String], currentDirectory: String) throws -> Invocation {
        guard let socketPath = environment[ControlEnvironment.socket], let token = environment[ControlEnvironment.token], let caller = environment[ControlEnvironment.tab] else {
            throw UsageError(message: "Not inside a Berth tab, or Agent Control is off in Berth's Settings > General")
        }

        if arguments.first == "review" {
            return try parseReview(arguments.dropFirst(), token: token, caller: caller, socketPath: socketPath)
        }

        let operation: ControlOp
        if arguments.first == "browser" {
            guard arguments.count > 1, let browser = ControlOp(rawValue: "browser-" + arguments[1]) else {
                throw UsageError(message: usage)
            }

            operation = browser
        } else {
            guard let name = arguments.first, let command = [ControlOp.list, .openSession, .openURL, .showPullRequest, .send, .capture, .close, .wait].first(where: { $0.rawValue == name }) ?? (name == "open-terminal" ? .open : name == "open" ? .openPath : nil) else {
                throw UsageError(message: usage)
            }

            operation = command
        }

        let opensTab = operation == .open || operation == .openSession || operation == .openPath || operation == .openURL || operation == .browserOpen
        var request = ControlRequest(token: token, caller: caller, operation: operation)
        var json = false
        var follow = false
        var positional: [String] = []
        var rest = Array(arguments.dropFirst(operation.isBrowser ? 2 : 1))
        while let argument = rest.first {
            rest.removeFirst()
            switch argument {
            case "--json": json = true

            case "--no-enter" where operation == .send: request.enter = false

            case "--background" where opensTab: request.background = true

            case "--tab" where operation.isBrowser && operation != .browserTabs && operation != .browserOpen:
                guard let id = rest.first, !id.isEmpty, !id.hasPrefix("--") else { throw UsageError(message: "--tab needs a browser tab id") }

                request.tab = id
                rest.removeFirst()

            case "--out" where operation == .browserScreenshot:
                guard let path = rest.first, !path.isEmpty, !path.hasPrefix("--") else { throw UsageError(message: "--out needs a path") }

                request.path = URL(filePath: path, relativeTo: URL(filePath: currentDirectory, directoryHint: .isDirectory)).standardizedFileURL.path
                rest.removeFirst()

            case "--full-page" where operation == .browserScreenshot: request.fullPage = true

            case "--selector" where operation == .browserHTML:
                guard let selector = rest.first, !selector.isEmpty, !selector.hasPrefix("--") else { throw UsageError(message: "--selector needs a CSS selector") }

                request.selector = selector
                rest.removeFirst()

            case "--since" where operation == .browserConsole:
                guard let value = rest.first, let sequence = Int(value), sequence >= 0 else { throw UsageError(message: "--since needs a nonnegative sequence number") }

                request.since = sequence
                rest.removeFirst()

            case "--follow" where operation == .browserConsole: follow = true

            case "--cwd" where operation == .open || operation == .openSession:
                guard let folder = rest.first, operation == .open || !folder.hasPrefix("--") else { throw UsageError(message: "--cwd needs a folder") }

                rest.removeFirst()
                request.cwd = URL(filePath: folder, relativeTo: URL(filePath: currentDirectory, directoryHint: .isDirectory)).standardizedFileURL.path

            case "--repo" where operation == .showPullRequest:
                guard let folder = rest.first, !folder.isEmpty, !folder.hasPrefix("--") else { throw UsageError(message: "--repo needs a folder") }

                rest.removeFirst()
                request.repositoryPath = URL(filePath: folder, relativeTo: URL(filePath: currentDirectory, directoryHint: .isDirectory)).standardizedFileURL.path

            case "--timeout" where operation == .wait || operation == .browserWait:
                guard !rest.isEmpty, let seconds = Double(rest.removeFirst()), seconds.isFinite, seconds >= 0 else { throw UsageError(message: "--timeout needs a nonnegative number of seconds") }

                request.timeout = seconds

            case "--to" where operation == .browserScroll:
                guard request.scrollTo == nil, let edge = rest.first, ["top", "bottom"].contains(edge) else { throw UsageError(message: "--to needs one of top or bottom") }

                request.scrollTo = edge
                rest.removeFirst()

            case "--by" where operation == .browserScroll:
                guard request.scrollBy == nil, let value = rest.first, let pixels = Int(value) else { throw UsageError(message: "--by needs one integer pixel offset") }

                request.scrollBy = pixels
                rest.removeFirst()

            case let option where operation == .browserWait && ["--text", "--url"].contains(option):
                guard let value = rest.first, !value.isEmpty, !value.hasPrefix("--") else { throw UsageError(message: "\(argument) needs a value") }
                guard request.text == nil, request.url == nil else { throw UsageError(message: usage) }

                if argument == "--text" {
                    request.text = value
                } else {
                    request.url = value
                }
                rest.removeFirst()

            case "--load" where operation == .browserWait:
                guard request.load == nil else { throw UsageError(message: usage) }

                request.load = true

            case "--ms" where operation == .browserWait:
                guard request.milliseconds == nil, let value = rest.first, let milliseconds = Int(value), milliseconds >= 0 else {
                    throw UsageError(message: "--ms needs one nonnegative integer number of milliseconds")
                }

                request.milliseconds = milliseconds
                rest.removeFirst()

            case "--" where operation.isBrowser && operation != .browserOpen:
                positional += rest
                rest = []

            case "--" where operation == .open:
                positional += rest
                rest = []

            case "--" where operation == .openSession:
                request.text = rest.isEmpty ? nil : rest.joined(separator: " ")
                rest = []

            default:
                guard !argument.hasPrefix("--") else { throw UsageError(message: "Unknown option \(argument)\n\(usage)") }

                positional.append(argument)
            }
        }
        try applyPositionals(positional, to: &request, currentDirectory: currentDirectory)
        return Invocation(request: request, socketPath: socketPath, json: json, follow: follow)
    }

    private static func parseReview(_ arguments: ArraySlice<String>, token: String, caller: String, socketPath: String) throws -> Invocation {
        var rest = arguments
        let operation: ControlOp
        switch rest.popFirst() {
        case "mark": operation = .reviewMark

        case "marks":
            guard rest.popFirst() == "clear" else { throw UsageError(message: usage) }

            operation = .reviewClearMarks

        default: throw UsageError(message: usage)
        }

        var json = false
        var marks: [ControlReviewMark] = []
        while let argument = rest.popFirst() {
            if argument == "--json" {
                json = true
                continue
            }
            guard operation == .reviewMark, let separator = argument.lastIndex(of: ":"), separator != argument.startIndex,
                  let range = argument[argument.index(after: separator)...].wholeMatch(of: /([0-9]+)(?:-([0-9]+))?/),
                  let start = Int(range.1), let end = Int(range.2 ?? range.1)
            else { throw UsageError(message: usage) }

            var note = ""
            if rest.first == "--note" {
                rest.removeFirst()
                guard let text = rest.popFirst(), !text.hasPrefix("--") else { throw UsageError(message: "--note needs text after the mark") }

                note = text
            }
            marks.append(ControlReviewMark(path: String(argument[..<separator]), startLine: start, endLine: end, note: note))
        }

        let request = ControlRequest(token: token, caller: caller, operation: operation, marks: operation == .reviewMark ? marks : nil)
        if case let .failure(error) = ControlReviewMarks.validate(request) {
            throw UsageError(message: error.message)
        }
        return Invocation(request: request, socketPath: socketPath, json: json, follow: false)
    }

    private static func applyPositionals(_ positional: [String], to request: inout ControlRequest, currentDirectory: String) throws {
        switch request.operation {
        case .reviewMark, .reviewClearMarks:
            throw UsageError(message: usage)

        case .list, .openSession, .browserTabs, .browserConsole, .browserURL, .browserReload, .browserText, .browserHTML, .browserSnapshot, .browserBack, .browserForward:
            guard positional.isEmpty else { throw UsageError(message: usage) }

        case .browserScreenshot:
            guard positional.isEmpty else { throw UsageError(message: usage) }

            if request.path == nil {
                request.path = FileManager.default.temporaryDirectory.appending(path: "berth-screenshot-\(UUID().uuidString.lowercased().prefix(8)).png").path
            }

        case .open:
            request.command = positional.count > 1 ? positional.map(shellQuoted).joined(separator: " ") : positional.first

        case .send:
            guard positional.count >= 2 else { throw UsageError(message: usage) }

            request.tab = positional[0]
            request.text = positional.dropFirst().joined(separator: " ")

        case .openPath:
            guard positional.count == 1 else { throw UsageError(message: usage) }

            request.path = URL(filePath: positional[0], relativeTo: URL(filePath: currentDirectory, directoryHint: .isDirectory)).standardizedFileURL.path

        case .browserOpen where positional.isEmpty: break

        case .openURL, .browserOpen, .browserNavigate:
            guard positional.count == 1, let url = URL(string: positional[0]), WebAddress.allows(url) else { throw UsageError(message: "Pass one http or https URL") }

            request.url = url.absoluteString

        case .browserClick, .browserHover:
            guard positional.count == 1, let target = positional.first, !target.isEmpty else { throw UsageError(message: usage) }

            request.target = target

        case .browserFill, .browserSelect:
            guard positional.count == 2, !positional[0].isEmpty else { throw UsageError(message: usage) }

            request.target = positional[0]
            request.text = positional[1]

        case .browserType, .browserPress, .browserEval:
            guard positional.count == 1, request.operation != .browserPress || !positional[0].isEmpty else { throw UsageError(message: usage) }

            request.text = positional[0]

        case .browserScroll:
            let modes = [request.scrollTo != nil, request.scrollBy != nil]
            guard positional.count + modes.count(where: { $0 }) == 1, positional.first?.isEmpty != true else {
                throw UsageError(message: usage)
            }

            request.target = positional.first

        case .browserWait:
            let conditions = [request.text != nil, request.url != nil, request.load == true, request.milliseconds != nil]
            guard positional.count + conditions.count(where: { $0 }) == 1, positional.first?.isEmpty != true else { throw UsageError(message: usage) }

            request.selector = positional.first

        case .showPullRequest:
            guard positional.count == 1, let target = positional.first else { throw UsageError(message: usage) }

            if let number = Int(target), number > 0 {
                request.pullRequest = number
            } else if let link = PullRequestLink.parse(target) {
                request.pullRequest = link.number
                request.repository = link.repository
            } else {
                throw UsageError(message: "Pass a positive PR number or a GitHub pull request URL")
            }

        case .capture, .close, .wait:
            guard positional.count == 1 else { throw UsageError(message: usage) }

            request.tab = positional[0]
        }
    }

    public static func render(_ response: ControlResponse, json: Bool) -> String {
        if json {
            return encode(response)
        }
        if let tabs = response.tabs {
            return tabs.map { "\($0.openedByYou ? "*" : " ") \($0.id)  \($0.kind)  \($0.status ?? "-")  \($0.title)  \($0.cwd)" }.joined(separator: "\n")
        }
        if let tabs = response.browserTabs {
            return tabs.map { "\($0.active ? "*" : " ") \($0.id)  \($0.loading ? "loading" : "-")  \($0.title)  \($0.url ?? "-")" }.joined(separator: "\n")
        }
        if let entries = response.console {
            return entries.map { render($0, json: false) }.joined(separator: "\n")
        }
        return response.text ?? response.tab ?? ""
    }

    public static func render(_ entry: ControlConsoleEntry, json: Bool) -> String {
        if json { return encode(entry) }

        let text = entry.text.replacing("\r", with: "\\r").replacing("\n", with: "\\n")
        return "\(entry.sequence) \(entry.level) \(text)"
    }

    private static func encode(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? ""
    }

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacing("'", with: "'\\''") + "'"
    }
}

public enum ControlExitStatus {
    /// Runs the command in a child shell and records its status in `file` before the tab's process ends.
    public static func wrapping(_ command: String, recordingIn file: String) -> String {
        let quote = { (text: String) in "'" + text.replacing("'", with: "'\\''") + "'" }
        return "/bin/sh -c \(quote(command)); status=$?; printf '%s' $status > \(quote(file)); exit $status"
    }
}

public enum TerminalText {
    /// Raw pty output as plain lines: escape sequences dropped, a carriage return rewinds its line.
    public static func plain(_ bytes: [UInt8]) -> String {
        var text: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            guard byte == 0x1B, index < bytes.count else {
                if byte != 0x08, byte != 0x07 { text.append(byte) }
                continue
            }

            let introducer = bytes[index]
            index += 1
            if introducer == 0x5B {
                while index < bytes.count, !(0x40...0x7E).contains(bytes[index]) { index += 1 }
                index += 1
            } else if introducer == 0x5D {
                while index < bytes.count {
                    if bytes[index] == 0x07 {
                        index += 1
                        break
                    }
                    if bytes[index] == 0x1B {
                        index += 2
                        break
                    }
                    index += 1
                }
            }
        }
        return String(decoding: text, as: UTF8.self)
            .replacing("\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.split(separator: "\r", omittingEmptySubsequences: false).last.map(String.init) ?? "" }
            .joined(separator: "\n")
    }
}
