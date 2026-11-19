import Foundation

public struct ReviewFileTree: Sendable, Hashable, Identifiable {
    public let path: String
    public let name: String
    public let children: [Self]?

    public var id: String { path }

    public static func nodes(_ paths: [String]) -> [Self] {
        nodes(paths.map { $0.split(separator: "/").map(String.init) }, under: "")
    }

    public static func compactNodes(_ paths: [String]) -> [ReviewFileTree] {
        nodes(paths).map(\.compacted)
    }

    private var compacted: ReviewFileTree {
        guard let children else { return self }
        if children.count == 1, let only = children.first, only.children != nil {
            return ReviewFileTree(path: only.path, name: name + "/" + only.name, children: only.children).compacted
        }
        return ReviewFileTree(path: path, name: name, children: children.map(\.compacted))
    }

    private static func nodes(_ paths: [[String]], under folder: String) -> [ReviewFileTree] {
        let nodes = Dictionary(grouping: paths.filter { !$0.isEmpty }, by: \.[0]).map { name, members in
            let path = folder + name
            let isFolder = members.contains { $0.count > 1 }
            return Self(path: path, name: name, children: isFolder ? nodes(members.map { Array($0.dropFirst()) }, under: path + "/") : nil)
        }

        return nodes.sorted { left, right in
            if (left.children == nil) != (right.children == nil) { return left.children != nil }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }
}
