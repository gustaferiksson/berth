#if DEBUG
import SwiftUI
import WidgetKit

struct WidgetsSnapshot: ViewModifier {
    func body(content: Content) -> some View {
        if UserDefaults.standard.bool(forKey: "snapshotWidgets") {
            WidgetPreviewHost()
        } else {
            content
        }
    }
}

private struct WidgetPreviewHost: View {
    private let full = WidgetSnapshot(needsYou: [
        .init(id: "1", title: "Repair the import checks"),
        .init(id: "2", title: "Update the tide charts"),
        .init(id: "3", title: "Rebuild the search index"),
        .init(id: "4", title: "Trim the logs"),
    ])
    private let empty = WidgetSnapshot(needsYou: [])

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 16) {
                    tile(.systemSmall, full, size: CGSize(width: 158, height: 158))
                    tile(.systemSmall, empty, size: CGSize(width: 158, height: 158))
                }
                tile(.systemMedium, full, size: CGSize(width: 338, height: 158))
                tile(.systemMedium, empty, size: CGSize(width: 338, height: 158))
                HStack(spacing: 16) {
                    tile(.accessoryCircular, full, size: CGSize(width: 76, height: 76), isAccessory: true)
                    tile(.accessoryInline, full, size: CGSize(width: 180, height: 24), isAccessory: true)
                }
                tile(.accessoryRectangular, full, size: CGSize(width: 172, height: 76), isAccessory: true)
            }
            .padding()
        }
    }

    private func tile(_ family: WidgetFamily, _ snapshot: WidgetSnapshot, size: CGSize, isAccessory: Bool = false) -> some View {
        NeedsYouWidgetView(snapshot: snapshot, family: family)
            .padding(isAccessory ? 4 : 16)
            .frame(width: size.width, height: size.height)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: isAccessory ? 12 : 22))
    }
}
#endif
