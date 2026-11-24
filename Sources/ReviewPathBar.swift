import BerthCore
import SwiftUI
import UniformTypeIdentifiers

struct ReviewPathBar: View {
    let model: ReviewModel
    let document: ReviewDocument
    let style: ReviewStyle

    var body: some View {
        let folders = document.path.split(separator: "/").dropLast().enumerated().map { index, name in
            (name: String(name), children: children(of: document.path.split(separator: "/").prefix(index + 1).joined(separator: "/")))
        }
        ViewThatFits(in: .horizontal) {
            bar(folders)
            bar(folders.isEmpty ? [] : [(name: "…", children: [])])
        }
        .font(.caption)
        .foregroundStyle(Color(nsColor: style.secondary))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 22)
    }

    private func bar(_ folders: [(name: String, children: [ReviewFileTree])]) -> some View {
        let name = (document.path as NSString).lastPathComponent
        let title = document.pullRequestNumber.map { "PR #\($0):\(name)" } ?? name
        return HStack(spacing: 4) {
            if model.isSessionFiles {
                Text(sessionFolder)
            } else {
                segment((RepositoryRoot.checkout(model.changes?.root ?? model.folder) as NSString).lastPathComponent, children: model.tree)
                ForEach(Array(folders.enumerated()), id: \.offset) { _, folder in
                    chevron
                    segment(folder.name, children: folder.children)
                }
            }
            chevron
            segment(title, children: children(of: (document.path as NSString).deletingLastPathComponent), icon: NSImage(size: NSSize(width: 13, height: 13), flipped: false) { NSWorkspace.shared.icon(for: UTType(filenameExtension: (name as NSString).pathExtension) ?? .data).draw(in: $0); return true })
            Spacer(minLength: 8)
            switch document.compare {
            case .uncommitted: Text("Uncommitted")

            case .committed: Text("Committed")

            case let .commit(sha): Text("Commit \(sha.prefix(7))")

            case .range, nil: EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private var sessionFolder: String {
        let folder = "/" + (document.path as NSString).deletingLastPathComponent
        return folder.hasPrefix(Store.resolvedHome + "/") ? "~" + folder.dropFirst(Store.resolvedHome.count) : folder
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .semibold))
            .accessibilityHidden(true)
    }

    private func segment(_ title: String, children: [ReviewFileTree], icon: NSImage? = nil) -> some View {
        Menu {
            ReviewTreeMenuItems(nodes: children, model: model)
        } label: {
            HStack(spacing: 4) {
                if let icon {
                    Image(nsImage: icon)
                        .accessibilityHidden(true)
                }
                Text(title)
            }
            .foregroundStyle(Color(nsColor: icon == nil ? style.secondary : style.foreground))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(children.isEmpty)
    }

    private func children(of folder: String) -> [ReviewFileTree] {
        folder.split(separator: "/").reduce(model.tree) { nodes, name in nodes.first { $0.name == name && $0.children != nil }?.children ?? [] }
    }
}

private struct ReviewTreeMenuItems: View {
    let nodes: [ReviewFileTree]
    let model: ReviewModel

    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children {
                Menu(node.name) { Self(nodes: children, model: model) }
            } else {
                Button(node.name) { model.open(model.workingDocument(node.path)) }
            }
        }
    }
}
