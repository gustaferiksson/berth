import ActivityKit
import SwiftUI

nonisolated struct SessionActivityAttributes: ActivityAttributes {
    typealias ContentState = LiveActivityState

    let sessionID: String
    let title: String
}

extension LiveActivityState.Status {
    var label: LocalizedStringKey {
        switch self {
        case .working: "Working"
        case .waiting: "Needs you"
        case .finished: "Finished"
        }
    }

    var symbol: String {
        switch self {
        case .working: "waveform"
        case .waiting: "bell.badge"
        case .finished: "checkmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .working: .blue
        case .waiting: .orange
        case .finished: .green
        }
    }
}

struct SessionActivityStatusText: View {
    let state: LiveActivityState

    var body: some View {
        if state.status == .working {
            Text("\(Text(state.status.label)) · \(Text(Date(timeIntervalSince1970: state.since), style: .timer))")
                .monospacedDigit()
        } else {
            Text(state.status.label)
        }
    }
}

struct SessionActivityLockScreenView: View {
    let title: String
    let state: LiveActivityState
    let isStale: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.status.symbol)
                .font(.title2)
                .foregroundStyle(state.status.color)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                SessionActivityStatusText(state: state)
                    .font(.subheadline)
                    .foregroundStyle(state.status == .waiting ? state.status.color : .secondary)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .opacity(isStale ? 0.6 : 1)
    }
}
