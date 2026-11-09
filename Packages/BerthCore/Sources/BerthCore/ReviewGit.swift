import Foundation
import os

public struct ReviewFile: Sendable, Hashable {
    public enum Status: String, Sendable {
        case added = "A"
        case modified = "M"
        case deleted = "D"
        case renamed = "R"
    }

    public let path: String
    public let oldPath: String?
    public let status: Status
    public let additions: Int?
    public let deletions: Int?

    public init(path: String, oldPath: String?, status: Status, additions: Int?, deletions: Int?) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
    }
}

public struct ReviewSnapshot: Sendable {
    public let root: String
    public let branch: String
    public let base: String
    public let mergeBase: String
    public let files: [ReviewFile]
    public let fetchedAt: Date?
    public let fetchError: String?
}

public enum ReviewText: Sendable, Equatable {
    case text(String)
    case binary
    case tooLarge(bytes: Int)
}

public struct ReviewContents: Sendable, Equatable {
    public let original: ReviewText?
    public let modified: ReviewText?

    public init(original: ReviewText?, modified: ReviewText?) {
        self.original = original
        self.modified = modified
    }
}

public enum ReviewGitError: Error, Equatable {
    case git(arguments: [String], message: String)
    case pathOutsideRoot(String)
}

public enum ReviewGit {
    private static let maxBytes = 2 * 1024 * 1024
    private static let binaryProbeBytes = 8000
    private static let fetches = FetchThrottle()

    public static func snapshot(in folder: String) async throws -> ReviewSnapshot {
        let root = try await line(["rev-parse", "--show-toplevel"], in: folder)
        let branch = (try? await line(["rev-parse", "--abbrev-ref", "HEAD"], in: root)) ?? "HEAD"
        let base = await base(in: root) ?? "HEAD"
        let baseRefspecs = base.hasPrefix("origin/") ? ["+refs/heads/\(base.dropFirst("origin/".count)):refs/remotes/\(base)"] : []

        let fetch = await (baseRefspecs.isEmpty ? nil : fetches.fetch(baseRefspecs, in: root))
        let mergeBase = try await line(["merge-base", base, "HEAD"], in: root)
        let files = try await workingTreeChanges(from: mergeBase, in: root)
        return ReviewSnapshot(root: root, branch: branch, base: base, mergeBase: mergeBase, files: files, fetchedAt: fetch?.fetchedAt, fetchError: fetch?.error)
    }

    public static func base(in root: String) async -> String? {
        let branch = (try? await line(["rev-parse", "--abbrev-ref", "HEAD"], in: root)) ?? "HEAD"
        let configured = try? await line(["config", "--get", "branch.\(branch).gh-merge-base"], in: root)
        let merge = try? await line(["config", "--get", "branch.\(branch).merge"], in: root)
        let upstream = try? await line(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], in: root)
        let originHead = try? await line(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: root)
        let otherUpstream = merge == "refs/heads/\(branch)" ? nil : upstream
        let candidates = [configured.map { "origin/\($0)" }, configured, otherUpstream, originHead, "origin/main", "origin/master", "main", "master"].compactMap { $0 }

        for candidate in candidates where !candidate.hasPrefix("-") {
            if (try? await git(["rev-parse", "--verify", "--quiet", "\(candidate)^{commit}"], in: root)) != nil { return candidate }
        }
        return nil
    }

    public static func contents(of file: ReviewFile, in snapshot: ReviewSnapshot) async throws -> ReviewContents {
        let original = try await (file.status == .added ? nil : blob(snapshot.mergeBase, path: file.oldPath ?? file.path, in: snapshot.root))

        if file.status == .deleted { return ReviewContents(original: original, modified: nil) }
        return ReviewContents(original: original, modified: try workingTreeText(file.path, in: snapshot.root))
    }

    public static func workingTreeText(_ path: String, in root: String) throws -> ReviewText {
        let url = try contained(path, in: root)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink { return .text(try FileManager.default.destinationOfSymbolicLink(atPath: url.path)) }

        let size = attributes[.size] as? Int ?? 0
        guard size <= maxBytes else { return .tooLarge(bytes: size) }

        let data = try Data(contentsOf: url)
        guard !data.prefix(binaryProbeBytes).contains(0), let text = String(data: data, encoding: .utf8) else { return .binary }
        return .text(text)
    }

    public static func save(_ text: String, to path: String, in root: String) throws {
        let url = try contained(path, in: root)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes?[.type] as? FileAttributeType != .typeSymbolicLink else { throw ReviewGitError.pathOutsideRoot(path) }

        try Data(text.utf8).write(to: url, options: .atomic)
        guard let permissions = attributes?[.posixPermissions] else { return }
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    static func git(_ arguments: [String], in root: String, timeout: TimeInterval? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try runBlocking(arguments, in: root, timeout: timeout) })
            }
        }
    }

    private static func runBlocking(_ arguments: [String], in root: String, timeout: TimeInterval?) throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(filePath: root, directoryHint: .isDirectory)
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"]) { $1 }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        let group = -process.processIdentifier
        let state = OSAllocatedUnfairLock(initialState: (exited: false, timedOut: false))
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { state.withLock { if !$0.exited { $0.timedOut = true; kill(group, SIGTERM) } } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 2) { state.withLock { if !$0.exited { kill(group, SIGKILL) } } }
        }

        let errorHandle = errors.fileHandleForReading
        let errorData = OSAllocatedUnfairLock(initialState: Data())
        let errorRead = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: errorRead) {
            let data = errorHandle.readDataToEndOfFile()
            errorData.withLock { $0 = data }
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let timedOut = state.withLock { $0.exited = true; return $0.timedOut }
        _ = errorRead.wait(timeout: .now() + 2)

        if let timeout, timedOut { throw ReviewGitError.git(arguments: arguments, message: "timed out after \(Int(timeout)) s") }
        let message = String(decoding: errorData.withLock { $0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else { throw ReviewGitError.git(arguments: arguments, message: message) }
        return data
    }

    private static func line(_ arguments: [String], in root: String) async throws -> String {
        String(decoding: try await git(arguments, in: root), as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    private static func contained(_ path: String, in root: String) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !path.contains("\0"), let name = components.last,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.lowercased() == ".git" })
        else { throw ReviewGitError.pathOutsideRoot(path) }

        let rootURL = URL(filePath: root, directoryHint: .isDirectory).resolvingSymlinksInPath()
        let parent = rootURL.appending(path: path).deletingLastPathComponent().resolvingSymlinksInPath()
        let isInside = parent.path == rootURL.path || parent.path.hasPrefix(rootURL.path + "/")
        let isInGitDirectory = parent.path.dropFirst(rootURL.path.count).split(separator: "/").contains { $0.lowercased() == ".git" }
        var isDirectory: ObjCBool = false
        guard isInside, !isInGitDirectory, FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw ReviewGitError.pathOutsideRoot(path) }

        return parent.appending(path: String(name))
    }

    private static func workingTreeChanges(from revision: String, in root: String) async throws -> [ReviewFile] {
        let diff = try await git(["diff", "--raw", "--numstat", "-z", "-M", "--no-ext-diff", "--no-color", revision], in: root)
        let untracked = try await git(["ls-files", "--others", "--exclude-standard", "-z"], in: root)
        let added = untracked.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.filter { !$0.hasSuffix("/") }.map { path in
            let data = try? Data(contentsOf: URL(filePath: root).appending(path: path), options: .alwaysMapped)
            let isCountable = data.map { $0.count <= maxBytes && !$0.prefix(binaryProbeBytes).contains(0) } ?? false
            guard let data, isCountable else { return ReviewFile(path: path, oldPath: nil, status: .added, additions: nil, deletions: nil) }
            let lines = data.reduce(0) { $1 == 10 ? $0 + 1 : $0 } + (data.last == nil || data.last == 10 ? 0 : 1)
            return ReviewFile(path: path, oldPath: nil, status: .added, additions: lines, deletions: 0)
        }
        return (changes(diff) + added).sorted { $0.path < $1.path }
    }

    private static func changes(_ output: Data) -> [ReviewFile] {
        let fields = output.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var entries: [(status: ReviewFile.Status, oldPath: String?, path: String)] = []
        var counts: [String: (additions: Int?, deletions: Int?)] = [:]
        var index = 0

        while index < fields.count {
            let field = fields[index]
            if field.hasPrefix(":") {
                let letter = field.split(separator: " ").last?.first
                let status: ReviewFile.Status = letter == "A" ? .added : letter == "D" ? .deleted : letter == "R" ? .renamed : .modified
                let isPair = letter == "R" || letter == "C"
                guard index + (isPair ? 2 : 1) < fields.count else { break }
                entries.append(isPair ? (status, fields[index + 1], fields[index + 2]) : (status, nil, fields[index + 1]))
                index += isPair ? 3 : 2
                continue
            }

            let parts = field.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            let isPair = parts.count == 3 && parts[2].isEmpty
            guard parts.count == 3, !isPair || index + 2 < fields.count else {
                index += 1
                continue
            }
            counts[isPair ? fields[index + 2] : String(parts[2])] = (Int(parts[0]), Int(parts[1]))
            index += isPair ? 3 : 1
        }
        return entries.map { ReviewFile(path: $0.path, oldPath: $0.oldPath, status: $0.status, additions: counts[$0.path]?.additions, deletions: counts[$0.path]?.deletions) }
    }

    private static func blob(_ revision: String, path: String, in root: String) async throws -> ReviewText {
        let object = "\(revision):\(path)"
        let size = Int(try await line(["cat-file", "-s", object], in: root)) ?? 0
        guard size <= maxBytes else { return .tooLarge(bytes: size) }

        let data = try await git(["cat-file", "blob", object], in: root)
        guard !data.prefix(binaryProbeBytes).contains(0), let text = String(data: data, encoding: .utf8) else { return .binary }
        return .text(text)
    }
}

actor FetchThrottle {
    struct Outcome: Sendable {
        let attemptedAt: Date
        let fetchedAt: Date?
        let error: String?
    }

    private static let interval: TimeInterval = 15
    private static let timeout: TimeInterval = 20
    private var outcomes: [String: Outcome] = [:]

    func fetch(_ refspecs: [String], in root: String) async -> Outcome {
        let key = ([root] + refspecs).joined(separator: "\0")
        let previous = outcomes[key]
        let now = Date.now
        if let previous, now.timeIntervalSince(previous.attemptedAt) < Self.interval { return previous }

        outcomes[key] = Outcome(attemptedAt: now, fetchedAt: previous?.fetchedAt, error: previous?.error)
        let outcome: Outcome
        do {
            _ = try await ReviewGit.git(["fetch", "--quiet", "--no-tags", "--no-auto-gc", "origin"] + refspecs, in: root, timeout: Self.timeout)
            outcome = Outcome(attemptedAt: now, fetchedAt: .now, error: nil)
        } catch ReviewGitError.git(_, let message) {
            outcome = Outcome(attemptedAt: now, fetchedAt: previous?.fetchedAt, error: message)
        } catch {
            outcome = Outcome(attemptedAt: now, fetchedAt: previous?.fetchedAt, error: error.localizedDescription)
        }
        outcomes[key] = outcome
        return outcome
    }
}
