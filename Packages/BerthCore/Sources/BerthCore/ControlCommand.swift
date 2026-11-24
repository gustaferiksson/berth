import Foundation

public enum ControlCommand {
    public static let usage = """
    usage: berth ls [--json]
           berth open-terminal [--cwd <dir>] [--background] [--json] [--] [<command>...]
           berth open-session [--cwd <dir>] [--background] [--json] [-- <prompt words>]
           berth open <path> [--background] [--json]
           berth show-pr <number|url> [--repo <path>] [--json]
           berth send <tab> <text> [--no-enter]
           berth capture <tab>
           berth close <tab>
           berth wait <tab> [--timeout <seconds>]
    """

    public struct Invocation: Equatable {
        public let request: ControlRequest
        public let socketPath: String
        public let json: Bool
    }

    public struct UsageError: Error, Equatable {
        public let message: String
    }

    public static func parse(_ arguments: [String], environment: [String: String], currentDirectory: String) throws -> Invocation {
        guard let socketPath = environment[ControlEnvironment.socket], let token = environment[ControlEnvironment.token], let caller = environment[ControlEnvironment.tab] else {
            throw UsageError(message: "Not inside a Berth tab, or Agent Control is off in Berth's Settings > General")
        }
        guard let name = arguments.first, let operation = [ControlOp.list, .openSession, .showPullRequest, .send, .capture, .close, .wait].first(where: { $0.rawValue == name }) ?? (name == "open-terminal" ? .open : name == "open" ? .openPath : nil) else {
            throw UsageError(message: usage)
        }

        let opensTab = operation == .open || operation == .openSession || operation == .openPath
        var request = ControlRequest(token: token, caller: caller, operation: operation)
        var json = false
        var positional: [String] = []
        var rest = Array(arguments.dropFirst())
        while let argument = rest.first {
            rest.removeFirst()
            switch argument {
            case "--json": json = true

            case "--no-enter" where operation == .send: request.enter = false

            case "--background" where opensTab: request.background = true

            case "--cwd" where operation == .open || operation == .openSession:
                guard let folder = rest.first, operation == .open || !folder.hasPrefix("--") else { throw UsageError(message: "--cwd needs a folder") }

                rest.removeFirst()
                request.cwd = URL(filePath: folder, relativeTo: URL(filePath: currentDirectory, directoryHint: .isDirectory)).standardizedFileURL.path

            case "--repo" where operation == .showPullRequest:
                guard let folder = rest.first, !folder.isEmpty, !folder.hasPrefix("--") else { throw UsageError(message: "--repo needs a folder") }

                rest.removeFirst()
                request.repositoryPath = URL(filePath: folder, relativeTo: URL(filePath: currentDirectory, directoryHint: .isDirectory)).standardizedFileURL.path

            case "--timeout" where operation == .wait:
                guard !rest.isEmpty, let seconds = Double(rest.removeFirst()), seconds >= 0 else { throw UsageError(message: "--timeout needs a number of seconds") }

                request.timeout = seconds

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
        switch operation {
        case .list, .openSession:
            guard positional.isEmpty else { throw UsageError(message: usage) }

        case .open:
            request.command = positional.count > 1 ? positional.map(shellQuoted).joined(separator: " ") : positional.first

        case .send:
            guard positional.count >= 2 else { throw UsageError(message: usage) }

            request.tab = positional[0]
            request.text = positional.dropFirst().joined(separator: " ")

        case .openPath:
            guard positional.count == 1 else { throw UsageError(message: usage) }

            request.path = URL(filePath: positional[0], relativeTo: URL(filePath: currentDirectory, directoryHint: .isDirectory)).standardizedFileURL.path

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
        return Invocation(request: request, socketPath: socketPath, json: json)
    }

    public static func render(_ response: ControlResponse, json: Bool) -> String {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return (try? String(decoding: encoder.encode(response), as: UTF8.self)) ?? ""
        }
        if let tabs = response.tabs {
            return tabs.map { "\($0.openedByYou ? "*" : " ") \($0.id)  \($0.kind)  \($0.status ?? "-")  \($0.title)  \($0.cwd)" }.joined(separator: "\n")
        }
        return response.text ?? response.tab ?? ""
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
