import BerthCore
import SwiftUI

struct ConversationWorking: View {
    let agent: Agent
    let since: Date?

    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let claudeFrames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
    private static let codexFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    var body: some View {
        HStack(spacing: 8) {
            glyph
            label
            if let since {
                Text(verbatim: "·")
                ConversationElapsed(since: since)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var glyph: some View {
        let isClaude = agent == .claude
        let frames = isClaude ? Self.claudeFrames : Self.codexFrames
        let interval = isClaude ? 0.12 : 0.08
        let color = isClaude ? Color.orange.mix(with: .brown, by: theme.isDark ? 0.4 : 0.55) : theme.secondary

        return TimelineView(.animation(minimumInterval: interval, paused: reduceMotion)) { timeline in
            let frame = reduceMotion ? (isClaude ? 4 : 0) : Int(timeline.date.timeIntervalSinceReferenceDate / interval) % frames.count

            Text(verbatim: frames[frame])
                .foregroundStyle(color)
                .frame(width: 14)
        }
        .accessibilityHidden(true)
    }

    private var label: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let sweep = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2

            Text("Working")
                .overlay {
                    if !reduceMotion {
                        Text("Working")
                            .foregroundStyle(theme.foreground)
                            .mask {
                                let center = sweep * 1.6 - 0.3

                                LinearGradient(stops: [.init(color: .clear, location: center - 0.3), .init(color: .white, location: center), .init(color: .clear, location: center + 0.3)], startPoint: .leading, endPoint: .trailing)
                            }
                    }
                }
        }
    }
}
