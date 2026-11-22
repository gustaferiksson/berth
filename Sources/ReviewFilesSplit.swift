import SwiftUI

enum ReviewBottomPane: String, CaseIterable {
    case files
    case graph
}

struct ReviewFilesSplit<Changes: View, Bottom: View>: View {
    @Binding var isExpanded: Bool
    @Binding var pane: ReviewBottomPane
    @ViewBuilder let changes: Changes
    @ViewBuilder let bottom: Bottom
    @AppStorage("reviewFilesRatio") private var storedRatio = defaultRatio
    @State private var draggedRatio: Double?
    @State private var available = 0.0
    @Environment(\.ghosttyTheme) private var theme

    private static var defaultRatio: Double { 0.45 }
    private static var minimum: Double { 96 }
    private static var headerHeight: Double { 32 }

    var body: some View {
        let ratio = draggedRatio ?? storedRatio
        let bottomHeight = isExpanded ? min(max(ratio * available, Self.minimum), max(available - Self.minimum, Self.minimum)) : Self.headerHeight
        VStack(spacing: 0) {
            changes
                .frame(maxHeight: .infinity)
            VStack(spacing: 0) {
                header
                if isExpanded {
                    bottom
                }
            }
            .frame(height: bottomHeight, alignment: .top)
            .overlay(alignment: .top) { Divider() }
            .overlay(alignment: .top) { grip }
        }
        .onGeometryChange(for: Double.self) { $0.size.height } action: { available = $1 }
        .coordinateSpace(.named("reviewFilesSplit"))
        .animation(.snappy(duration: 0.2), value: isExpanded)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ForEach(ReviewBottomPane.allCases, id: \.self) { title in
                Button {
                    pane = title
                    isExpanded = true
                } label: {
                    Text(title == .files ? "Files" : "Graph")
                        .fontWeight(pane == title ? .semibold : .regular)
                        .foregroundStyle(pane == title ? theme.foreground : theme.secondary)
                        .frame(height: Self.headerHeight)
                        .contentShape(.rect)
                }
                .accessibilityAddTraits(pane == title ? .isSelected : [])
            }
            Spacer(minLength: 4)
            Button { isExpanded.toggle() } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.secondary)
                    .frame(width: 22, height: Self.headerHeight)
                    .contentShape(.rect)
            }
            .accessibilityLabel(isExpanded ? "Collapse Bottom Pane" : "Expand Bottom Pane")
        }
        .font(.subheadline)
        .padding(.horizontal, ReviewInset.content)
        .frame(height: Self.headerHeight)
        .buttonStyle(.plain)
    }

    @ViewBuilder private var grip: some View {
        if isExpanded {
            Color.clear
                .frame(height: 8)
                .contentShape(.rect)
                .offset(y: -4)
                .pointerStyle(.rowResize)
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .named("reviewFilesSplit"))
                        .onChanged { draggedRatio = (available - $0.location.y) / available }
                        .onEnded { _ in
                            storedRatio = min(max(draggedRatio ?? storedRatio, Self.minimum / available), 1 - Self.minimum / available)
                            draggedRatio = nil
                        }
                )
                .onTapGesture(count: 2) { storedRatio = Self.defaultRatio }
        }
    }
}
