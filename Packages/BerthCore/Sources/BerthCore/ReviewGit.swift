import Foundation
import os

public struct ReviewFile: Sendable, Hashable {
    public enum Status: String, Sendable {
        case added = "A"
        case modified = "M"
        case deleted = "D"
        case untracked = "U"
        case renamed = "R"

        public var hasOriginal: Bool { self != .added && self != .untracked }
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
    case range(base: String, head: String)

    public var isHistorical: Bool {
        switch self {
        case .commit, .range: true
        case .uncommitted, .committed: false
        }
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

public struct ReviewBranchSummary: Sendable, Equatable {
    public let branch: String
    public let ahead: Int
    public let behind: Int
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

        let fetch = await (baseRefspecs.isEmpty ? nil : FetchThrottle.shared.fetch(baseRefspecs, in: root))
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

        let committed = try await changedFiles(from: mergeBase, to: head, in: root)
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
        return try await changedFiles(from: parent, to: sha, in: root)
    }

    public static func pullRequestFiles(number: Int, repository: String, base: String?, in root: String) async throws -> (base: String, head: String, files: [ReviewFile]) {
        let remoteArguments = ["config", "--get", "remote.origin.url"]
        guard !repository.isEmpty, await RepositoryRoot.gitHubRepository(at: root)?.lowercased() == repository.lowercased() else {
            throw ReviewGitError.git(arguments: remoteArguments, message: "Origin does not point to \(repository).")
        }

        let head = try await FetchThrottle.shared.pullRequestHead(number, in: root)
        let remoteBase = base.map { "refs/remotes/origin/\($0)" }
        let target: String
        if let remoteBase, await (try? line(["rev-parse", "--verify", "--quiet", "\(remoteBase)^{commit}"], in: root)) != nil {
            target = remoteBase
        } else if let base, let fetched = try? await FetchThrottle.shared.fetchHead("refs/heads/\(base)", record: "branch '\(base)'", in: root) {
            target = fetched
        } else if let fallback = await defaultBranch(in: root) {
            target = fallback
        } else if let fallback = await Self.base(in: root) {
            target = fallback
        } else {
            throw ReviewGitError.git(arguments: ["merge-base"], message: "No base branch found for PR #\(number).")
        }
        let mergeBase = try await line(["merge-base", "--", target, head], in: root)
        return try await (mergeBase, head, changedFiles(from: mergeBase, to: head, in: root))
    }

    private static func changedFiles(from base: String, to head: String, in root: String) async throws -> [ReviewFile] {
        try await changes(git(["diff", "--raw", "--numstat", "-z", "-M", "--no-ext-diff", "--no-color", base, head, "--"], in: root)).sorted { $0.path < $1.path }
    }

    fileprivate static func validateCommitSHA(_ sha: String) throws {
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

        return ReviewBranchStatus(
            ahead: baseCounts.last ?? 0,
            behind: baseCounts.first ?? 0,
            upstream: ownUpstream.map { ReviewUpstream(name: $0, ahead: unpushed.count, behind: upstreamSides.count - unpushed.count) },
            commits: try await commits(range, isPushed: { ownUpstream != nil && !unpushed.contains(Substring($0)) }, in: root)
        )
    }

    private static func commits(_ range: [String], isPushed: (String) -> Bool, in root: String) async throws -> [ReviewCommit] {
        let log = try await git(["log", "-z", "--format=%H%x1f%h%x1f%at%x1f%s"] + range, in: root)
        return log.split(separator: 0).compactMap { record -> ReviewCommit? in
            let fields = record.split(separator: 0x1F, maxSplits: 3, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
            guard fields.count == 4, let time = TimeInterval(fields[2]) else { return nil }

            return ReviewCommit(sha: fields[1], subject: fields[3], date: Date(timeIntervalSince1970: time), isPushed: isPushed(fields[0]))
        }
    }

    public static func branchSummary(in folder: String) async -> ReviewBranchSummary? {
        guard let root = try? await line(["rev-parse", "--show-toplevel"], in: folder) else { return nil }

        let named = try? await line(["symbolic-ref", "--short", "HEAD"], in: root)
        let detached = try? await line(["rev-parse", "--short", "HEAD"], in: root)
        guard let branch = named ?? detached else { return nil }

        let upstream = try? await line(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], in: root)
        let fallback = await base(in: root)
        guard let target = upstream ?? fallback, let counts = try? await line(["rev-list", "--left-right", "--count", "\(target)...HEAD"], in: root).split(separator: "\t").compactMap({ Int($0) }) else {
            return ReviewBranchSummary(branch: branch, ahead: 0, behind: 0)
        }

        return ReviewBranchSummary(branch: branch, ahead: counts.last ?? 0, behind: counts.first ?? 0)
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

    public static func ignored(_ paths: [String], in root: String) async -> Set<String> {
        var found: Set<String> = []
        for start in stride(from: 0, to: paths.count, by: 200) {
            let input = Pipe()
            input.fileHandleForWriting.write(Data(paths[start..<min(start + 200, paths.count)].joined(separator: "\0").utf8 + [0]))
            input.fileHandleForWriting.closeFile()
            let output = await (try? git(["check-ignore", "--stdin", "-z"], in: root, input: input.fileHandleForReading)) ?? Data()
            found.formUnion(output.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
        }
        return found
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

        case let .range(base, head):
            return try await contents(of: file, base: base, head: head, in: changes.root)
        }
        return try await contents(of: file, revisions: revisions, in: changes.root)
    }

    public static func contents(of file: ReviewFile, base: String, head: String, in root: String) async throws -> ReviewContents {
        try validateCommitSHA(base)
        try validateCommitSHA(head)
        return try await contents(of: file, revisions: (base, head), in: root)
    }

    private static func contents(of file: ReviewFile, revisions: (original: String, modified: String?), in root: String) async throws -> ReviewContents {
        let original = try await (file.status.hasOriginal ? blob(revisions.original, path: file.oldPath ?? file.path, in: root) : nil)

        if file.status == .deleted { return ReviewContents(original: original, modified: nil) }
        if let modified = revisions.modified { return try await ReviewContents(original: original, modified: blob(modified, path: file.path, in: root)) }
        return try ReviewContents(original: original, modified: workingTreeText(file.path, in: root))
    }

    public static func workingTreeText(_ path: String, in root: String) throws -> ReviewText {
        try plainText(at: contained(path, in: root))
    }

    public static func plainText(at url: URL) throws -> ReviewText {
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

    public static func blame(_ path: String, at head: String, text: String, in root: String) async -> (entries: [Int: ReviewBlame], lineCount: Int)? {
        guard !text.isEmpty, text.utf8.count <= maxBytes else { return nil }

        let newlines = text.utf8.count(where: { $0 == 0x0A })
        let fileLineCount = newlines + (text.utf8.last == 0x0A ? 0 : 1)
        guard fileLineCount <= 20_000 else { return nil }

        do {
            try validateCommitSHA(head)
            _ = try contained(path, in: root)
            let inputURL = FileManager.default.temporaryDirectory.appending(path: "berth-blame-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: inputURL) }
            guard FileManager.default.createFile(atPath: inputURL.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else { return nil }

            let input = try FileHandle(forReadingFrom: inputURL)
            defer { try? input.close() }
            let data = try await git(["blame", "--porcelain", "--encoding=UTF-8", "--no-textconv", "--contents", "-", head, "--", path], in: root, timeout: 15, input: input)
            let entries = ReviewBlame.parse(String(decoding: data, as: UTF8.self))
            guard entries.count == fileLineCount else { return nil }

            return (entries, newlines + 1)
        } catch {
            return nil
        }
    }

    public static func userName(in root: String) async -> String? {
        // swiftlint:disable:next git_identity_override - reads the configured name for "You", never writes it
        guard let data = try? await git(["config", "user.name"], in: root, timeout: 5) else { return nil }

        let name = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    public static func blameMessage(_ hash: String, in root: String) async -> String? {
        guard (try? validateCommitSHA(hash)) != nil, let data = try? await git(["show", "-s", "--format=%B", "--encoding=UTF-8", hash, "--"], in: root, timeout: 5) else { return nil }

        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    static func git(_ arguments: [String], in root: String, timeout: TimeInterval? = nil, input: FileHandle = .nullDevice, executable: String = "/usr/bin/git", environment: [String: String] = [:]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try runBlocking(arguments, in: root, timeout: timeout, input: input, executable: executable, environment: environment) })
            }
        }
    }

    private static func runBlocking(_ arguments: [String], in root: String, timeout: TimeInterval?, input: FileHandle, executable: String, environment: [String: String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(filePath: root, directoryHint: .isDirectory)
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"].merging(environment) { $1 }) { $1 }
        process.standardInput = input
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

    fileprivate static func line(_ arguments: [String], in root: String) async throws -> String {
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
            guard let data, isCountable else { return ReviewFile(path: path, oldPath: nil, status: .untracked, additions: nil, deletions: nil) }

            let lines = data.reduce(0) { $1 == 10 ? $0 + 1 : $0 } + (data.last == nil || data.last == 10 ? 0 : 1)
            return ReviewFile(path: path, oldPath: nil, status: .untracked, additions: lines, deletions: 0)
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

    static let shared = FetchThrottle()
    private static let interval: TimeInterval = 15
    private static let timeout: TimeInterval = 20
    private var outcomes: [String: Outcome] = [:]
    private var pullRequestFetches: [String: Task<String, any Error>] = [:]

    func pullRequestHead(_ number: Int, in root: String, timeout: TimeInterval = FetchThrottle.timeout) async throws -> String {
        let ref = "refs/pull/\(number)/head"
        return try await fetchHead(ref, record: "'\(ref)'", in: root, timeout: timeout)
    }

    func fetchHead(_ ref: String, record: String, in root: String, timeout: TimeInterval = FetchThrottle.timeout) async throws -> String {
        _ = try await ReviewGit.git(["check-ref-format", ref], in: root)
        while let previous = pullRequestFetches[root] { _ = await previous.result }

        let task = Task {
            defer { pullRequestFetches[root] = nil }
            let arguments = ["fetch", "--quiet", "--no-tags", "--no-auto-gc", "--no-prune", "--no-prune-tags", "--no-recurse-submodules", "--refmap=", "origin", ref]
            _ = try await ReviewGit.git(arguments, in: root, timeout: timeout)
            let head = try await ReviewGit.line(["rev-parse", "FETCH_HEAD"], in: root)
            try ReviewGit.validateCommitSHA(head)
            let path = try await ReviewGit.line(["rev-parse", "--path-format=absolute", "--git-path", "FETCH_HEAD"], in: root)
            let entries = try String(contentsOf: URL(filePath: path), encoding: .utf8)
            guard entries.split(separator: "\n").contains(where: { $0.hasPrefix("\(head)\t\t\(record) of ") }) else {
                throw ReviewGitError.git(arguments: arguments, message: "Another fetch replaced FETCH_HEAD. Try again.")
            }

            return head
        }
        pullRequestFetches[root] = task
        return try await task.value
    }

    func fetch(_ refspecs: [String], in root: String) async -> Outcome {
        let key = ([root] + refspecs).joined(separator: "\0")
        let previous = outcomes[key]
        let now = Date.now
        if let previous, now.timeIntervalSince(previous.attemptedAt) < Self.interval { return previous }

        outcomes[key] = Outcome(attemptedAt: now, fetchedAt: previous?.fetchedAt, error: previous?.error)
        let outcome: Outcome
        do {
            _ = try await ReviewGit.git(["fetch", "--quiet", "--no-tags", "--no-auto-gc", "--no-write-fetch-head", "origin"] + refspecs, in: root, timeout: Self.timeout)
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
