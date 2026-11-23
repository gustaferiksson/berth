import Foundation

public struct CodexModel: Sendable {
    public let slug: String
    public let displayName: String
    public let defaultEffort: String?
    public let efforts: [String]
}

public enum CodexModels {
    private static let catalog = load(from: CodexIndex.home(environment: ProcessInfo.processInfo.environment, user: FileManager.default.homeDirectoryForCurrentUser))

    public static func load(from codexDirectory: URL) -> [CodexModel] {
        guard let data = try? Data(contentsOf: codexDirectory.appending(path: "models_cache.json")),
              let cache = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = cache["models"] as? [Any]
        else { return [] }

        return entries.compactMap { entry -> (model: CodexModel, priority: Int)? in
            guard let fields = entry as? [String: Any], fields["visibility"] as? String == "list",
                  let slug = fields["slug"] as? String, !slug.isEmpty
            else { return nil }

            let efforts = (fields["supported_reasoning_levels"] as? [Any])?.compactMap { ($0 as? [String: Any])?["effort"] as? String } ?? []
            let model = CodexModel(slug: slug, displayName: fields["display_name"] as? String ?? slug, defaultEffort: fields["default_reasoning_level"] as? String, efforts: efforts)
            return (model, fields["priority"] as? Int ?? .max)
        }
        .sorted { $0.priority < $1.priority }
        .map(\.model)
    }

    static func context(for summary: SessionSummary) -> RemoteContext? {
        guard let model = summary.modelSettings?.model ?? summary.context?.model else { return nil }

        return RemoteContext(model: displayName(for: model), tokens: summary.context?.tokens, window: summary.context?.window, date: summary.lastActivity, compactions: 0, lastCompaction: nil, effort: summary.modelSettings?.effort ?? summary.context?.effort)
    }

    public static func displayName(for slug: String) -> String {
        catalog.first { $0.slug == slug }?.displayName ?? slug
    }
}
