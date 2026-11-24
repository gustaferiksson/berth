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

    static func worktree(containing folder: String) -> (identity: String, folder: String)? {
        guard let repository = enclosingRepository(folder) else { return nil }

        return (repository.mainCheckout ?? repository.root.path, repository.root.path)
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
                group.addTask { await (root, gitHubRepository(at: root)) }
            }
            return await group.reduce(into: [:]) { $0[$1.0] = .some($1.1) }
        }
    }

    public static func gitHubSiblingClones(of roots: Set<String>) async -> [String: [String: String]] {
        let parents = Set(roots.compactMap { root -> String? in
            let folder = URL(filePath: root, directoryHint: .isDirectory).standardizedFileURL
            return hasGitDirectory(folder) ? folder.deletingLastPathComponent().path : nil
        })
        var found: [String: [String: String]] = [:]
        for parent in parents {
            let folder = URL(filePath: parent, directoryHint: .isDirectory)
            let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            var clones: [String: String] = [:]
            for child in children {
                guard hasGitDirectory(child), let repository = await gitHubRepository(at: child.path) else { continue }

                clones[folder.appending(path: child.lastPathComponent).path] = repository.lowercased()
            }
            found[parent] = clones
        }
        return found
    }

    private static func hasGitDirectory(_ folder: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.appending(path: ".git").path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public static func gitHubRepository(at root: String) async -> String? {
        guard let remote = try? await ReviewGit.git(["config", "--get", "remote.origin.url"], in: root) else { return nil }

        return gitHubRepository(remoteURL: String(decoding: remote, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
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
