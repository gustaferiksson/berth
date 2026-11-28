import SwiftUI
import WidgetKit

private struct NeedsYouEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

private struct NeedsYouProvider: TimelineProvider {
    func placeholder(in _: Context) -> NeedsYouEntry {
        NeedsYouEntry(date: .now, snapshot: WidgetSnapshot(needsYou: [.init(id: "1", title: "Repair the import checks")]))
    }

    func getSnapshot(in context: Context, completion: @escaping (NeedsYouEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : NeedsYouEntry(date: .now, snapshot: WidgetSnapshot.load() ?? WidgetSnapshot(needsYou: [])))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<NeedsYouEntry>) -> Void) {
        completion(Timeline(entries: [NeedsYouEntry(date: .now, snapshot: WidgetSnapshot.load() ?? WidgetSnapshot(needsYou: []))], policy: .never))
    }
}

private struct NeedsYouEntryView: View {
    let entry: NeedsYouEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        NeedsYouWidgetView(snapshot: entry.snapshot, family: family)
    }
}

private struct NeedsYouWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.widgetKind, provider: NeedsYouProvider()) { entry in
            NeedsYouEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Needs You")
        .description("Sessions waiting on you.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}

@main
struct BerthWidgetBundle: WidgetBundle {
    var body: some Widget {
        NeedsYouWidget()
        SessionLiveActivity()
    }
}
