import Foundation

public enum RepositoryRoot {
    public static func resolve(_ folder: String) -> String {
        var directory = URL(filePath: folder, directoryHint: .isDirectory).standardizedFileURL
        while true {
            let dotGit = directory.appending(path: ".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                guard !isDirectory.boolValue else { return directory.path }
                return worktreeRoot(dotGit: dotGit) ?? directory.path
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { return folder }
            directory = parent
        }
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
