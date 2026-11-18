import Foundation

public enum RepositoryRoot {
    public static func resolve(_ folder: String) -> String {
        guard let repository = enclosingRepository(folder) else { return folder }
        return repository.mainCheckout ?? repository.root.path
    }

    public static func checkout(_ folder: String) -> String {
        guard let repository = enclosingRepository(folder), let main = repository.mainCheckout else { return folder }
        return main + URL(filePath: folder, directoryHint: .isDirectory).standardizedFileURL.path.dropFirst(repository.root.path.count)
    }

    static func enclosingRepository(_ folder: String) -> (root: URL, mainCheckout: String?)? {
        var directory = URL(filePath: folder, directoryHint: .isDirectory).standardizedFileURL
        while true {
            let dotGit = directory.appending(path: ".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                return (directory, isDirectory.boolValue ? nil : worktreeRoot(dotGit: dotGit))
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { return nil }
            directory = parent
        }
    }

    public static func gitHubRepositories(of roots: Set<String>) async -> [String: String?] {
        await withTaskGroup(of: (String, String?).self) { group in
            for root in roots {
                group.addTask {
                    let remote = try? await ReviewGit.git(["remote", "get-url", "origin"], in: root)
                    return (root, remote.flatMap { gitHubRepository(remoteURL: String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) })
                }
            }
            return await group.reduce(into: [:]) { $0[$1.0] = .some($1.1) }
        }
    }

    static func gitHubRepository(remoteURL: String) -> String? {
        let match = remoteURL.wholeMatch(of: /(?:https:\/\/(?:[^@\/]+@)?github\.com\/|(?:ssh:\/\/)?git@github\.com[:\/])([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+?)(?:\.git)?\/?/)
        return match.map { "\($0.1)/\($0.2)" }
    }

    private static func worktreeRoot(dotGit: URL) -> String? {
        guard let contents = try? String(contentsOf: dotGit, encoding: .utf8),
              let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
        else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let gitDirectory = URL(filePath: path, directoryHint: .isDirectory, relativeTo: dotGit.deletingLastPathComponent()).standardizedFileURL
        guard let common = try? String(contentsOf: gitDirectory.appending(path: "commondir"), encoding: .utf8) else { return nil }
        let commonDirectory = URL(filePath: common.trimmingCharacters(in: .whitespacesAndNewlines), directoryHint: .isDirectory, relativeTo: gitDirectory).standardizedFileURL
        guard commonDirectory.lastPathComponent == ".git" else { return nil }
        return commonDirectory.deletingLastPathComponent().path
    }
}
