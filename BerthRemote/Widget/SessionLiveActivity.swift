import ActivityKit
import SwiftUI
import WidgetKit

struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            SessionActivityLockScreenView(title: context.attributes.title, state: context.state, isStale: context.isStale)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.status.symbol)
                        .font(.title2)
                        .foregroundStyle(context.state.status.color)
                        .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    SessionActivityStatusText(state: context.state)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: context.state.status.symbol)
                    .foregroundStyle(context.state.status.color)
                    .accessibilityHidden(true)
            } compactTrailing: {
                if context.state.status == .working {
                    Text(Date(timeIntervalSince1970: context.state.since), style: .timer)
                        .monospacedDigit()
                        .frame(maxWidth: 56)
                } else {
                    Text(context.state.status.label)
                }
            } minimal: {
                Image(systemName: context.state.status.symbol)
                    .foregroundStyle(context.state.status.color)
                    .accessibilityHidden(true)
            }
        }
    }
}
