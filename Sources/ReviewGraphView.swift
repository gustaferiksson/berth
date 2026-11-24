import BerthCore
import SwiftUI

struct ReviewGraphView<Leading: View>: View {
    let model: ReviewModel
    let changes: ReviewChanges
    let showsHistory: Bool?
    @ViewBuilder let leading: Leading
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        Group {
            if showsHistory == nil, isEmpty {
                ContentUnavailableView("No Commits", systemImage: "point.3.connected.trianglepath.dotted")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List {
                        leading
                        if showsHistory != false {
                            if isEmpty {
                                Text("No Commits")
                                    .font(.caption)
                                    .foregroundStyle(theme.secondary)
                                    .reviewRow(top: 6, bottom: 6)
                            } else {
                                graphRows
                            }
                        }
                    }
                    .listStyle(.plain)
                    .environment(\.sidebarRowSize, .small)
                    .scrollContentBackground(.hidden)
                    .scrollEdgeEffectStyle(.soft, for: .top)
                    .onChange(of: model.selectedCommit, initial: true) { _, sha in
                        if showsHistory != false, let sha { proxy.scrollTo(sha) }
                    }
                }
            }
        }
        .foregroundStyle(theme.foreground)
        .task(id: showsHistory) {
            guard showsHistory != false, !model.graphHasLoaded, model.graphError == nil else { return }

            await model.loadGraph()
        }
    }

    private var isEmpty: Bool {
        model.graphHasLoaded && model.graphCommits.isEmpty && model.graphError == nil && !model.isLoadingGraph
    }

    @ViewBuilder private var graphRows: some View {
        let gutterWidth = CGFloat(min(model.graphRows.map(\.laneCount).max() ?? 1, 8)) * 12
        ForEach(Array(zip(model.graphCommits, model.graphRows)), id: \.0.sha) { commit, row in
            ReviewGraphCommitRow(commit: commit, row: row, gutterWidth: gutterWidth, model: model, changes: changes)
                .id(commit.sha)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
        }
        if let error = model.graphError, !model.isLoadingGraph {
            VStack(alignment: .leading, spacing: 4) {
                Text("Couldn’t Load Commits").font(.callout.weight(.semibold))
                Text(error).font(.caption).foregroundStyle(theme.secondary).lineLimit(3)
                Button("Try Again") { Task { await model.loadGraph() } }
            }
            .padding(.vertical, 6)
            .listRowSeparator(.hidden)
        }
        if !model.graphHasLoaded, model.graphError == nil || model.isLoadingGraph {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Loading Commits")
                .frame(maxWidth: .infinity, minHeight: 36)
                .listRowSeparator(.hidden)
        }
        if model.graphHasMore {
            Button("Load More") { Task { await model.loadGraph(more: true) } }
                .buttonStyle(.plain)
                .foregroundStyle(theme.secondary)
                .frame(minHeight: 32)
                .disabled(model.isLoadingGraph)
                .listRowSeparator(.hidden)
        }
    }
}

extension ReviewGraphView where Leading == EmptyView {
    init(model: ReviewModel, changes: ReviewChanges) {
        self.init(model: model, changes: changes, showsHistory: nil) { EmptyView() }
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

    private static let relativeDate: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter
    }()

    var body: some View {
        let isSelected = model.selectedCommit == commit.sha
        let refs = commit.refs.sorted { rank($0) < rank($1) }
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
                        ForEach(Array(refs.prefix(3).enumerated()), id: \.offset) { _, ref in
                            tag(ref)
                        }
                        if refs.count > 3 {
                            Text("+\(refs.count - 3)")
                                .font(.caption2)
                                .foregroundStyle(theme.secondary)
                                .fixedSize()
                        }
                    }
                    Text(byline)
                        .font(.caption2)
                        .foregroundStyle(theme.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 3)
                .padding(.leading, gutterWidth + 5)
                .padding(.trailing, ReviewInset.content)
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
                .padding(.trailing, ReviewInset.content)
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
        .listRowBackground(RowFill(opacity: isSelected ? 0.1 : isHovering ? 0.05 : 0))
        .help("\(commit.sha)\n\(commit.subject)")
    }

    private func rank(_ ref: GraphRef) -> Int {
        if ref.kind == .head || ref.kind == .branch, ref.name == changes.branch { return 0 }
        if ref.kind == .branch || ref.kind == .remote, ref.name == changes.base { return 1 }

        return 2
    }

    private func tag(_ ref: GraphRef) -> some View {
        let rank = rank(ref)
        let symbol = rank == 1 ? "arrow.triangle.branch" : ref.kind == .tag ? "tag" : nil
        return HStack(spacing: 2) {
            if let symbol {
                Image(systemName: symbol)
                    .accessibilityHidden(true)
            }
            Text(ref.name)
                .lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(rank == 0 ? Color.white : theme.foreground)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(rank == 0 ? Color.accentColor : rank == 1 ? Color.clear : theme.foreground.opacity(0.09), in: .rect(cornerRadius: 4))
        .overlay {
            if rank == 1 {
                RoundedRectangle(cornerRadius: 4).strokeBorder(theme.secondary)
            }
        }
    }

    private var lanes: some View {
        Canvas { context, size in
            let y: CGFloat = 12
            let center = CGPoint(x: CGFloat(row.lane) * 12 + 6, y: y)
            let visible = Int(size.width / 12)
            let palette = theme.series

            for lane in row.through where lane < visible {
                let x = CGFloat(lane) * 12 + 6
                let line = Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(line, with: .color(palette[lane % 6]), lineWidth: 1.5)
            }

            let incoming = row.entersFromAbove ? [row.lane] + row.merges : row.merges
            for lane in incoming where min(lane, row.lane) < visible {
                let x = CGFloat(lane) * 12 + 6
                let line = Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addCurve(to: center, control1: CGPoint(x: x, y: y / 2), control2: CGPoint(x: center.x, y: y / 2))
                }
                context.stroke(line, with: .color(palette[lane % 6]), lineWidth: 1.5)
            }

            for lane in row.parentLanes where min(lane, row.lane) < visible {
                let x = CGFloat(lane) * 12 + 6
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
                context.fill(Path(ellipseIn: CGRect(x: center.x - 4, y: y - 4, width: 8, height: 8)), with: .color(palette[row.lane % 6]))
            }
        }
    }
}

extension ReviewFile.Status {
    func color(in theme: GhosttyTheme) -> Color {
        switch self {
        case .added: theme.working
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
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        let isSelected = model.selectedDocument == document && !model.isPreviewSelected
        let status = switch file.status {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        }
        return Button {
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
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel(file.path)
                Spacer(minLength: 0)
                if let additions = file.additions, additions > 0 {
                    Text("+\(additions)").foregroundStyle(theme.working).accessibilityLabel("\(additions) additions")
                }
                if let deletions = file.deletions, deletions > 0 {
                    Text("−\(deletions)").foregroundStyle(theme.closed).accessibilityLabel("\(deletions) deletions")
                }
            }
            .font(.caption)
            .monospacedDigit()
            .padding(.horizontal, 4)
            .frame(minHeight: 22)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(theme.foreground.opacity(isSelected ? 0.1 : 0), in: .rect(cornerRadius: 4))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
    }
}
