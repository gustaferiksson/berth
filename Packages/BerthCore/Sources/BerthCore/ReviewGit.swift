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

public enum ReviewCompare: Sendable, Hashable {
    case uncommitted
    case committed
    case commit(String)

    public var isCommit: Bool {
        if case .commit = self { return true }

        return false
    }
}

public enum ReviewBaseReason: String, Sendable {
    case picked
    case pullRequest = "PR"
    case configured
    case nearest
    case defaultBranch = "default"
}

public struct ReviewBase: Sendable, Hashable {
    public let ref: String
    public let distance: Int
}

public struct ReviewChanges: Sendable {
    public let root: String
    public let branch: String
    public let isDefaultBranch: Bool
    public let defaultBase: String?
    public let base: String?
    public let baseReason: ReviewBaseReason?
    public let bases: [ReviewBase]
    public let head: String
    public let mergeBase: String
    public let uncommitted: [ReviewFile]
    public let committed: [ReviewFile]
    public let total: (additions: Int, deletions: Int)?
    public let fetchedAt: Date?
    public let fetchError: String?
}

public struct ReviewCommit: Sendable, Hashable {
    public let sha: String
    public let subject: String
    public let date: Date
    public let isPushed: Bool
}

public struct ReviewUpstream: Sendable, Hashable {
    public let name: String
    public let ahead: Int
    public let behind: Int
}

public struct ReviewBranchStatus: Sendable, Hashable {
    public let ahead: Int
    public let behind: Int
    public let upstream: ReviewUpstream?
    public let commits: [ReviewCommit]

    public static let unknown = Self(ahead: 0, behind: 0, upstream: nil, commits: [])
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
    case folderNotFound
    case gitNotFound(message: String)
    case notARepository
}

public enum ReviewGit {
    private static let maxBytes = 2 * 1024 * 1024
    private static let binaryProbeBytes = 8000
    private static let fetches = FetchThrottle()

    @preconcurrency
    public static func changes(in folder: String, preferredBase: @Sendable (_ root: String, _ branch: String) -> (picked: String?, pullRequest: String?) = { _, _ in (nil, nil) }) async throws -> ReviewChanges {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else { throw ReviewGitError.folderNotFound }

        let root: String
        do {
            root = try await line(["rev-parse", "--show-toplevel"], in: folder)
        } catch {
            guard case let ReviewGitError.git(_, message) = error else { throw error }

            if await (try? git(["--version"], in: folder)) == nil { throw ReviewGitError.gitNotFound(message: message) }
            if RepositoryRoot.enclosingRepository(folder) == nil { throw ReviewGitError.notARepository }
            throw error
        }
        let branch = await (try? line(["symbolic-ref", "--short", "HEAD"], in: root)) ?? "HEAD"
        let configuredBase = await base(in: root)
        let defaultBase = await defaultBranch(in: root) ?? configuredBase
        let isDefaultBranch = configuredBase == branch || configuredBase == "origin/\(branch)"
        let baseRefspecs = configuredBase.map { $0.hasPrefix("origin/") ? ["+refs/heads/\($0.dropFirst("origin/".count)):refs/remotes/\($0)"] : [] } ?? []

        let fetch = await (baseRefspecs.isEmpty ? nil : fetches.fetch(baseRefspecs, in: root))
        let head = if let head = try? await line(["rev-parse", "--verify", "--quiet", "HEAD"], in: root) { head } else { try await line(["hash-object", "-t", "tree", "/dev/null"], in: root) }
        let comparableBase = isDefaultBranch ? nil : defaultBase
        var bases = if let comparableBase { await bases(of: head, branch: branch, defaultBase: comparableBase, in: root) } else { [ReviewBase]() }

        let preferred = comparableBase == nil ? (picked: nil, pullRequest: nil) : preferredBase(root, branch)
        var chosen: (ref: String, reason: ReviewBaseReason)?
        for case let (ref?, reason) in [(preferred.picked, ReviewBaseReason.picked), (preferred.pullRequest.map { "origin/\($0)" }, .pullRequest), (preferred.pullRequest, .pullRequest), (configuredBase == defaultBase ? nil : configuredBase, .configured)] where !ref.hasPrefix("-") {
            guard await (try? git(["merge-base", ref, head], in: root)) != nil else { continue }

            chosen = (ref, reason)
            break
        }
        if let chosen, !bases.contains(where: { $0.ref == chosen.ref }), let distance = try? await Int(line(["rev-list", "--count", "\(chosen.ref)..\(head)"], in: root)) {
            bases.insert(ReviewBase(ref: chosen.ref, distance: distance), at: bases.firstIndex { $0.distance > distance } ?? bases.count)
        }
        let base = chosen?.ref ?? bases.first?.ref ?? defaultBase
        let baseReason = chosen?.reason ?? (base == nil ? nil : base == defaultBase ? .defaultBranch : .nearest)

        let comparedBase = isDefaultBranch ? nil : base
        let mergeBase = if let comparedBase { try await line(["merge-base", comparedBase, head], in: root) } else { head }

        let committed = try await changes(git(["diff", "--raw", "--numstat", "-z", "-M", "--no-ext-diff", "--no-color", mergeBase, head], in: root)).sorted { $0.path < $1.path }
        let uncommitted = try await workingTreeChanges(from: head, in: root)
        let total = try await comparedBase == nil ? nil : workingTreeChanges(from: mergeBase, in: root).reduce((additions: 0, deletions: 0)) { ($0.additions + ($1.additions ?? 0), $0.deletions + ($1.deletions ?? 0)) }
        return ReviewChanges(root: root, branch: branch, isDefaultBranch: isDefaultBranch, defaultBase: defaultBase, base: base, baseReason: baseReason, bases: bases, head: head, mergeBase: mergeBase, uncommitted: uncommitted, committed: committed, total: total, fetchedAt: fetch?.fetchedAt, fetchError: fetch?.error)
    }

    public static func graph(in root: String, skip: Int, limit: Int) async throws -> [GraphCommit] {
        let head = await (try? git(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], in: root)) == nil ? [] : ["HEAD"]
        let log = try await git(["log", "-z", "--topo-order", "--skip=\(skip)", "--max-count=\(limit)", "--decorate=full", "--no-show-signature", "--no-color", "--format=%H%x1f%P%x1f%an%x1f%at%x1f%D%x1f%s", "--branches", "--remotes", "--tags"] + head + ["--"], in: root)
        return log.split(separator: 0).compactMap(GraphCommit.parse)
    }

    public static func commitFiles(_ sha: String, in root: String) async throws -> [ReviewFile] {
        try validateCommitSHA(sha)
        let revisions = try await line(["rev-list", "--parents", "--max-count=1", "\(sha)^{commit}", "--"], in: root).split(separator: " ")
        let parent = if revisions.count > 1 { String(revisions[1]) } else { try await line(["hash-object", "-t", "tree", "/dev/null"], in: root) }
        return try await changes(git(["diff", "--raw", "--numstat", "-z", "-M", "--no-ext-diff", "--no-color", parent, sha, "--"], in: root)).sorted { $0.path < $1.path }
    }

    private static func validateCommitSHA(_ sha: String) throws {
        guard (7...64).contains(sha.utf8.count), sha.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ReviewGitError.git(arguments: ["rev-parse", sha], message: "Invalid commit SHA")
        }
    }

    public static func branchStatus(of changes: ReviewChanges) async throws -> ReviewBranchStatus {
        let root = changes.root
        let head = changes.head
        let baseCounts = try await line(["rev-list", "--left-right", "--count", "\(changes.base ?? head)...\(head)"], in: root).split(separator: "\t").compactMap { Int($0) }

        let upstream = try? await line(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], in: root)
        let merge = try? await line(["config", "--get", "branch.\(changes.branch).merge"], in: root)
        let ownUpstream = merge == "refs/heads/\(changes.branch)" ? upstream : nil
        let upstreamSides = if let ownUpstream { try await line(["rev-list", "--left-right", "\(ownUpstream)...\(head)"], in: root).split(separator: "\n") } else { [Substring]() }
        let unpushed = Set(upstreamSides.filter { $0.hasPrefix(">") }.map { $0.dropFirst() })

        let range = changes.isDefaultBranch || changes.base == nil ? ["-n", "2", head] : ["-n", "50", "\(changes.mergeBase)..\(head)"]
        let log = try await git(["log", "-z", "--format=%H%x1f%h%x1f%at%x1f%s"] + range, in: root)
        let commits = log.split(separator: 0).compactMap { record -> ReviewCommit? in
            let fields = record.split(separator: 0x1F, maxSplits: 3, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
            guard fields.count == 4, let time = TimeInterval(fields[2]) else { return nil }

            return ReviewCommit(sha: fields[1], subject: fields[3], date: Date(timeIntervalSince1970: time), isPushed: ownUpstream != nil && !unpushed.contains(Substring(fields[0])))
        }

        return ReviewBranchStatus(
            ahead: baseCounts.last ?? 0,
            behind: baseCounts.first ?? 0,
            upstream: ownUpstream.map { ReviewUpstream(name: $0, ahead: unpushed.count, behind: upstreamSides.count - unpushed.count) },
            commits: commits
        )
    }

    public static func gitDirectories(in root: String) async throws -> (directory: String, common: String) {
        let lines = try await line(["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"], in: root).split(separator: "\n").map(String.init)
        guard lines.count == 2 else { throw ReviewGitError.git(arguments: ["rev-parse"], message: "unexpected git directories \(lines)") }

        return (lines[0], lines[1])
    }

    public static func ignoredDirectories(in root: String) async throws -> [String] {
        try await git(["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"], in: root)
            .split(separator: 0)
            .map { "\(root)/\(String(decoding: $0, as: UTF8.self))" }
            .filter { $0.hasSuffix("/") }
    }

    public static func files(in root: String) async throws -> [String] {
        let listed = try await git(["ls-files", "--cached", "--others", "--exclude-standard", "--deduplicate", "-z"], in: root)
        let deleted = try await Set(git(["ls-files", "--deleted", "-z"], in: root).split(separator: 0))
        return listed.split(separator: 0).filter { !deleted.contains($0) && $0.last != UInt8(ascii: "/") }.map { String(decoding: $0, as: UTF8.self) }.sorted()
    }

    public static func base(in root: String) async -> String? {
        let branch = await (try? line(["rev-parse", "--abbrev-ref", "HEAD"], in: root)) ?? "HEAD"
        let configured = try? await line(["config", "--get", "branch.\(branch).gh-merge-base"], in: root)
        let merge = try? await line(["config", "--get", "branch.\(branch).merge"], in: root)
        let upstream = try? await line(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], in: root)
        let otherUpstream = merge == "refs/heads/\(branch)" ? nil : upstream

        for candidate in [configured.map { "origin/\($0)" }, configured, otherUpstream].compactMap(\.self) where !candidate.hasPrefix("-") {
            if await (try? git(["rev-parse", "--verify", "--quiet", "\(candidate)^{commit}"], in: root)) != nil { return candidate }
        }
        return await defaultBranch(in: root)
    }

    private static func defaultBranch(in root: String) async -> String? {
        let originHead = try? await line(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: root)

        for candidate in [originHead, "origin/main", "origin/master", "main", "master"].compactMap(\.self) where !candidate.hasPrefix("-") {
            if await (try? git(["rev-parse", "--verify", "--quiet", "\(candidate)^{commit}"], in: root)) != nil { return candidate }
        }
        return nil
    }

    private static func bases(of head: String, branch: String, defaultBase: String, in root: String) async -> [ReviewBase] {
        guard let mergeBase = try? await line(["merge-base", defaultBase, head], in: root),
              let distance = try? await Int(line(["rev-list", "--count", "\(mergeBase)..\(head)"], in: root)),
              let refs = try? await line(["for-each-ref", "--merged=\(head)", "--contains=\(mergeBase)", "--format=%(objectname) %(refname)", "refs/heads", "refs/remotes/origin"], in: root)
        else { return [] }

        let excluded: Set = [branch, "origin/\(branch)", "origin/HEAD", defaultBase]
        let named = refs.split(separator: "\n").compactMap { entry -> (sha: Substring, name: String)? in
            let parts = entry.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0] != head, parts[0] != mergeBase else { return nil }

            let name = String(parts[1].hasPrefix("refs/heads/") ? parts[1].dropFirst("refs/heads/".count) : parts[1].dropFirst("refs/remotes/".count))
            return excluded.contains(name) ? nil : (parts[0], name)
        }
        let remotes = Set(named.filter { $0.name.hasPrefix("origin/") }.map { "\($0.sha) \($0.name.dropFirst("origin/".count))" })

        var bases: [ReviewBase] = []
        for ref in named where ref.name.hasPrefix("origin/") || !remotes.contains("\(ref.sha) \(ref.name)") {
            guard let distance = try? await Int(line(["rev-list", "--count", "\(ref.sha)..\(head)"], in: root)) else { continue }

            bases.append(ReviewBase(ref: ref.name, distance: distance))
        }
        let nearestFirst = bases.sorted { ($0.distance, $0.ref) < ($1.distance, $1.ref) }
        return nearestFirst.filter { $0.ref.hasPrefix("origin/") } + nearestFirst.filter { !$0.ref.hasPrefix("origin/") } + [ReviewBase(ref: defaultBase, distance: distance)]
    }

    public static func contents(of file: ReviewFile, compare: ReviewCompare, in changes: ReviewChanges) async throws -> ReviewContents {
        let revisions: (original: String, modified: String?)
        switch compare {
        case .uncommitted: revisions = (changes.head, nil)
        case .committed: revisions = (changes.mergeBase, changes.head)
        case let .commit(sha):
            try validateCommitSHA(sha)
            revisions = ("\(sha)^", sha)
        }
        let original = try await (file.status == .added ? nil : blob(revisions.original, path: file.oldPath ?? file.path, in: changes.root))

        if file.status == .deleted { return ReviewContents(original: original, modified: nil) }
        if let modified = revisions.modified { return try await ReviewContents(original: original, modified: blob(modified, path: file.path, in: changes.root)) }
        return try ReviewContents(original: original, modified: workingTreeText(file.path, in: changes.root))
    }

    public static func workingTreeText(_ path: String, in root: String) throws -> ReviewText {
        let url = try contained(path, in: root)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink { return try .text(FileManager.default.destinationOfSymbolicLink(atPath: url.path)) }

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
        try await String(decoding: git(arguments, in: root), as: UTF8.self).trimmingCharacters(in: .newlines)
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
        let size = try await Int(line(["cat-file", "-s", object], in: root)) ?? 0
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
        } catch let ReviewGitError.git(_, message) {
            outcome = Outcome(attemptedAt: now, fetchedAt: previous?.fetchedAt, error: message)
        } catch {
            outcome = Outcome(attemptedAt: now, fetchedAt: previous?.fetchedAt, error: error.localizedDescription)
        }
        outcomes[key] = outcome
        return outcome
    }
}
