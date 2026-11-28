import SwiftUI
import WidgetKit

struct NeedsYouWidgetView: View {
    let snapshot: WidgetSnapshot
    let family: WidgetFamily

    private var count: Int { snapshot.needsYou.count }

    var body: some View {
        switch family {
        case .accessoryInline: inline
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .systemMedium: medium
        default: small
        }
    }

    private var inline: some View {
        Label(count == 0 ? "All clear" : "\(count) need you", systemImage: count == 0 ? "checkmark.circle" : "bell.badge")
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Text(count, format: .number)
                    .font(.title2.bold())
                    .widgetAccentable()
                Image(systemName: "bell.badge")
                    .font(.caption2)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(count == 0 ? "All clear" : "\(count) need you", systemImage: count == 0 ? "checkmark.circle" : "bell.badge")
                .font(.headline)
                .widgetAccentable()
            ForEach(snapshot.needsYou.prefix(2)) { item in
                Text(item.title)
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Needs you", systemImage: "bell.badge")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(count, format: .number)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(count == 0 ? Color.secondary : Color.orange)
                .contentTransition(.numericText())
            Spacer(minLength: 0)
            Text(snapshot.needsYou.first?.title ?? "Nothing is waiting")
                .font(.footnote)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Needs you", systemImage: "bell.badge")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(count, format: .number)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(count == 0 ? Color.secondary : Color.orange)
            }
            VStack(alignment: .leading, spacing: 8) {
                if snapshot.needsYou.isEmpty {
                    Text("Nothing is waiting")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(snapshot.needsYou.prefix(3)) { item in
                    Text(item.title)
                        .font(.subheadline)
                        .lineLimit(1)
                }
                if count > 3 {
                    Text("+\(count - 3) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
