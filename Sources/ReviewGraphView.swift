import BerthCore
import SwiftUI

struct ReviewGraphRows: View {
    let model: ReviewModel
    let changes: ReviewChanges
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        let gutterWidth = CGFloat(min(model.graphRows.map(\.laneCount).max() ?? 1, 4)) * ReviewGraphCommitRow.laneWidth
        ForEach(Array(zip(model.graphCommits.prefix(model.graphShown), model.graphRows)), id: \.0.sha) { commit, row in
            ReviewGraphCommitRow(commit: commit, row: row, gutterWidth: gutterWidth, model: model, changes: changes)
                .id(commit.sha)
                .reviewRow()
        }
        if model.graphHasLoaded, model.graphCommits.isEmpty, model.graphError == nil, !model.isLoadingGraph {
            Text("No Commits")
                .font(.caption)
                .foregroundStyle(theme.secondary)
                .reviewRow(top: 6, bottom: 6)
        }
        if let error = model.graphError, !model.isLoadingGraph {
            VStack(alignment: .leading, spacing: 4) {
                Text("Couldn’t Load Commits").font(.callout.weight(.semibold))
                Text(error).font(.caption).foregroundStyle(theme.secondary).lineLimit(3)
                Button("Try Again") { Task { await model.loadGraph() } }
            }
            .reviewRow(top: 6, bottom: 6)
        }
        if !model.graphHasLoaded, model.graphError == nil || model.isLoadingGraph {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Loading Commits")
                .frame(maxWidth: .infinity, minHeight: 36)
                .reviewRow()
        }
        if model.graphShown < model.graphCommits.count || model.graphHasMore {
            Button("Show More") { Task { await model.showMoreGraph() } }
                .buttonStyle(.plain)
                .foregroundStyle(theme.secondary)
                .frame(minHeight: 32)
                .disabled(model.isLoadingGraph)
                .reviewRow()
        }
    }
}

private struct ReviewGraphCommitRow: View {
    let commit: GraphCommit
    let row: GraphRow
    let gutterWidth: CGFloat
    let model: ReviewModel
    let changes: ReviewChanges
    @Environment(\.ghosttyTheme) private var theme
    @State private var isHovering = false

    static let laneWidth: CGFloat = 8
    private static let relativeDate: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter
    }()

    var body: some View {
        let isSelected = model.selectedCommit == commit.sha
        let refs = commit.refs.sorted { rank($0) < rank($1) }
        let visibleRefs = refs.prefix(2).prefix { rank($0) < 2 }
        let hiddenRefs = refs.dropFirst(visibleRefs.count)
        let byline = "\(commit.author), \(Self.relativeDate.localizedString(for: commit.date, relativeTo: .now))"
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Task { await model.openCommit(commit.sha) }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(commit.subject)
                            .font(.callout)
                            .lineLimit(1)
                        ForEach(Array(visibleRefs.enumerated()), id: \.offset) { _, ref in
                            tag(ref)
                        }
                        if !hiddenRefs.isEmpty {
                            Text("+\(hiddenRefs.count)")
                                .font(.caption2)
                                .foregroundStyle(theme.secondary)
                                .fixedSize()
                                .help(hiddenRefs.map(\.name).joined(separator: "\n"))
                        }
                    }
                    Text(byline)
                        .font(.caption2)
                        .foregroundStyle(theme.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 3)
                .padding(.leading, gutterWidth + 5)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(commit.subject))
            .accessibilityValue(Text(([byline] + refs.map(\.name)).joined(separator: ", ")))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            if isSelected {
                VStack(alignment: .leading, spacing: 0) {
                    if let files = model.commitFiles[commit.sha] {
                        ForEach(files, id: \.path) { file in
                            ReviewHistoricalFileButton(file: file, document: ReviewDocument(path: file.path, compare: .commit(commit.sha)), model: model)
                        }
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Loading Changed Files")
                            .frame(height: 24)
                    }
                }
                .padding(.leading, gutterWidth + 5)
            }
        }
        .overlay(alignment: .leading) {
            lanes
                .frame(width: gutterWidth)
                .clipped()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .listRowBackground(RowFill(opacity: isSelected ? 0.1 : isHovering ? 0.05 : 0, cornerRadius: 4))
        .help("\(commit.sha)\n\(commit.subject)")
    }

    private func rank(_ ref: GraphRef) -> Int {
        if ref.kind == .head || ref.kind == .branch, ref.name == changes.branch { return 0 }
        if ref.kind == .tag { return 1 }

        return 2
    }

    private func tag(_ ref: GraphRef) -> some View {
        let isCurrent = rank(ref) == 0
        return HStack(spacing: 2) {
            if ref.kind == .tag {
                Image(systemName: "tag")
                    .accessibilityHidden(true)
            }
            Text(ref.name)
                .lineLimit(1)
                .frame(maxWidth: 90)
        }
        .fixedSize()
        .font(.caption2.weight(.medium))
        .foregroundStyle(isCurrent ? Color.white : theme.foreground)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(isCurrent ? Color.accentColor : theme.foreground.opacity(0.09), in: .rect(cornerRadius: 4))
    }

    private var lanes: some View {
        Canvas { context, size in
            let y: CGFloat = 12
            let laneWidth = Self.laneWidth
            let center = CGPoint(x: (CGFloat(row.lane) + 0.5) * laneWidth, y: y)
            let visible = Int(size.width / laneWidth)
            let palette = theme.series

            for lane in row.through where lane < visible {
                let x = (CGFloat(lane) + 0.5) * laneWidth
                let line = Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(line, with: .color(palette[lane % 6]), lineWidth: 1.5)
            }

            let incoming = row.entersFromAbove ? [row.lane] + row.merges : row.merges
            for lane in incoming where min(lane, row.lane) < visible {
                let x = (CGFloat(lane) + 0.5) * laneWidth
                let line = Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addCurve(to: center, control1: CGPoint(x: x, y: y / 2), control2: CGPoint(x: center.x, y: y / 2))
                }
                context.stroke(line, with: .color(palette[lane % 6]), lineWidth: 1.5)
            }

            for lane in row.parentLanes where min(lane, row.lane) < visible {
                let x = (CGFloat(lane) + 0.5) * laneWidth
                let join = y + 16
                let line = Path { path in
                    path.move(to: center)
                    if lane != row.lane {
                        path.addCurve(to: CGPoint(x: x, y: join), control1: CGPoint(x: center.x, y: y + 8), control2: CGPoint(x: x, y: y + 8))
                    }
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(line, with: .color(palette[lane % 6]), lineWidth: 1.5)
            }

            if row.lane < visible {
                let dotDiameter: CGFloat = 6
                context.fill(Path(ellipseIn: CGRect(x: center.x - dotDiameter / 2, y: y - dotDiameter / 2, width: dotDiameter, height: dotDiameter)), with: .color(palette[row.lane % 6]))
            }
        }
    }
}

extension ReviewFile.Status {
    func color(in theme: GhosttyTheme) -> Color {
        switch self {
        case .added, .untracked: theme.working
        case .modified: theme.needsYou
        case .deleted: theme.closed
        case .renamed: theme.branch
        }
    }
}

struct ReviewHistoricalFileButton: View {
    let file: ReviewFile
    let document: ReviewDocument
    let model: ReviewModel
    var openFile: (() -> Void)?
    @State private var isHovering = false
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        let isSelected = model.selectedDocument == document && !model.isPreviewSelected
        let status = switch file.status {
        case .added, .untracked: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        }
        return Button {
            if let openFile, NSEvent.modifierFlags.contains(.command) { return openFile() }

            model.open(document)
            if NSApp.currentEvent?.clickCount == 2 { model.selectedTabID.map(model.keep) }
        } label: {
            HStack(spacing: 5) {
                Text(file.status.rawValue)
                    .font(.caption2.weight(.medium).monospaced())
                    .foregroundStyle(file.status.color(in: theme))
                    .frame(width: 12)
                    .accessibilityLabel(status)
                Text((file.path as NSString).lastPathComponent)
                    .monospaced()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel(file.path)
                Spacer(minLength: 0)
                ReviewFileStats(file: file)
            }
            .font(.caption)
            .padding(.horizontal, 4)
            .frame(minHeight: 22)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .listRowBackground(RowFill(opacity: isSelected ? 0.18 : isHovering ? 0.06 : 0, color: isSelected ? .accentColor : .primary, cornerRadius: 6, verticalInset: 1))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
    }
}
