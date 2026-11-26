import BerthCore
import SwiftUI

extension EnvironmentValues {
    @Entry var showsSidebarHeadersAsRows = false
}

struct SidebarSection<Content: View, Header: View>: View {
    let isExpanded: Binding<Bool>
    @ViewBuilder let content: () -> Content
    @ViewBuilder let header: (Binding<Bool>) -> Header
    @Environment(\.showsSidebarHeadersAsRows) private var showsHeadersAsRows

    var body: some View {
        let heading = header(isExpanded).listRowSeparator(.hidden)
        if showsHeadersAsRows {
            heading
                .frame(minHeight: 28)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 2, trailing: 0))
            if isExpanded.wrappedValue { content() }
        } else {
            Section {
                if isExpanded.wrappedValue { content() }
            } header: {
                heading.listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 2, trailing: 0))
            }
            .listSectionSeparator(.hidden)
        }
    }
}

extension SidebarSection where Header == SidebarSectionHeader<EmptyView, EmptyView> {
    init(title: String, help: String, count: Int? = nil, tint: Color? = nil, files: [ReviewFile]? = nil, isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        self.init(isExpanded: isExpanded, content: content) { expansion in
            SidebarSectionHeader<EmptyView, EmptyView>(title: title, help: help, count: count, tint: tint, files: files, isExpanded: expansion, accessory: nil, replacementTitle: nil)
        }
    }
}

struct SidebarSectionHeader<Accessory: View, ReplacementTitle: View>: View {
    let title: String
    let help: String
    let count: Int?
    var tint: Color?
    var files: [ReviewFile]?
    @Binding var isExpanded: Bool
    let accessory: Accessory?
    let replacementTitle: ReplacementTitle?
    @State private var isHovering = false
    private static var listTrailingInset: Double { 2 }

    var body: some View {
        let isHighlighted = isHovering || Snapshot.forcedHover.contains(title)
        let showsAccessory = isHighlighted && accessory != nil
        let chevron = Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .opacity(isHighlighted ? 1 : 0.32)
            .frame(width: 14)
            .accessibilityHidden(true)

        HStack(spacing: 6) {
            if let replacementTitle {
                chevron
                replacementTitle
                Spacer(minLength: 0)
            } else {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        chevron
                        Text(title)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(help)
                .accessibilityValue(isExpanded ? "expanded" : "collapsed")
            }

            if let files {
                ReviewFileStats(files: files)
                    .font(.caption)
            }

            ZStack(alignment: .trailing) {
                if replacementTitle == nil, !isExpanded, let count {
                    Text(count, format: .number)
                        .font(.caption.monospacedDigit())
                        .fixedSize()
                        .onTapGesture { isExpanded.toggle() }
                        .opacity(showsAccessory ? 0 : 1)
                        .allowsHitTesting(!showsAccessory)
                        .accessibilityHidden(showsAccessory)
                }
                if let accessory {
                    accessory
                        .opacity(showsAccessory ? 1 : 0)
                        .allowsHitTesting(showsAccessory)
                        .accessibilityHidden(!showsAccessory)
                }
            }
            .animation(.easeOut(duration: 0.12), value: showsAccessory)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(tint ?? Color.secondary)
        .frame(minHeight: 20)
        .padding(.trailing, files == nil ? SidebarRowLayout.horizontalInset - Self.listTrailingInset : 4.5)
        .contentShape([.interaction, .dragPreview], .rect(cornerRadius: 6))
        .onHover { isHovering = $0 }
    }
}

extension SidebarSectionHeader where ReplacementTitle == EmptyView {
    init(title: String, help: String, count: Int? = nil, tint: Color? = nil, isExpanded: Binding<Bool>, @ViewBuilder accessory: () -> Accessory) {
        self.init(title: title, help: help, count: count, tint: tint, isExpanded: isExpanded, accessory: accessory(), replacementTitle: nil)
    }
}
