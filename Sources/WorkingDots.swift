import SwiftUI

@Observable
final class WorkingPulse {
    private(set) var phase = 0
    @ObservationIgnored private var timer: Timer?

    var isRunning = false {
        didSet {
            guard isRunning != oldValue else { return }
            timer?.invalidate()
            timer = nil
            guard isRunning else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self.map { $0.phase = ($0.phase + 1) % 3 } }
            }
        }
    }
}

struct WorkingDots: View {
    let label: String
    @Environment(WorkingPulse.self) private var pulse
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(theme.working.opacity(index == pulse.phase ? 1 : 0.35))
                    .frame(width: 4, height: 4)
            }
        }
        .help(label)
        .accessibilityLabel(label)
    }
}
