import SwiftUI

struct WorkingDots: View {
    let label: String
    @State private var offset = Double.random(in: 0..<1.2)
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: offset), by: 0.4)) { context in
            let phase = Int((context.date.timeIntervalSinceReferenceDate - offset) / 0.4) % 3
            HStack(spacing: 2) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(theme.working.opacity(index == phase ? 1 : 0.35))
                        .frame(width: 4, height: 4)
                }
            }
        }
        .help(label)
        .accessibilityLabel(label)
    }
}
