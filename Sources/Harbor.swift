import BerthCore
import SwiftUI

private enum Mooring: Equatable {
    case working
    case needsYou(String?)
    case idle
    case anchored

    var bob: Double {
        switch self {
        case .working: 1.5
        case .needsYou: 3
        case .idle: 0
        case .anchored: 1
        }
    }
}

private struct Boat: Identifiable {
    let session: SessionSummary
    let mooring: Mooring
    let isElsewhere: Bool
    let point: CGPoint

    var id: String { session.id }
    var seed: Double { Double(UInt32(session.id.prefix(8), radix: 16) ?? 0) / Double(UInt32.max) * 2 * .pi }
    var opacity: Double { mooring == .anchored ? 0.35 : isElsewhere ? 0.55 : 1 }

    var status: String {
        let state = switch mooring {
        case .working: "Working"
        case let .needsYou(reason): "Needs you\(reason.map { ": \($0)" } ?? "")"
        case .idle: "Idle"
        case .anchored: "Finished \(max(1, Int(-session.lastActivity.timeIntervalSinceNow / 60))) min ago"
        }
        return isElsewhere ? "\(state) · in another terminal" : state
    }
}

private struct Pier {
    let title: String
    let y: Double
    let end: Double
    let overflow: Int
}

struct Harbor: View {
    @Environment(Store.self) private var store
    @Environment(WorkingPulse.self) private var pulse
    @Environment(\.ghosttyTheme) private var theme
    @State private var hoveredID: String?
    @FocusState private var isFocused: Bool

    private static let shore = 132.0
    private static let slot = 132.0

    var body: some View {
        GeometryReader { geometry in
            let (piers, boats) = layout(in: geometry.size)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    draw(piers: piers, boats: boats.filter { $0.mooring.bob == 0 }, in: context, size: size)
                }
                ForEach(boats.filter { $0.mooring.bob > 0 }) { boat in
                    Bobbing(boat: boat, theme: theme, isRunning: pulse.isRunning)
                        .frame(width: 96, height: 72)
                        .position(x: boat.point.x, y: boat.point.y - 16)
                }
                ForEach(Array(piers.enumerated()), id: \.offset) { _, pier in
                    Text(pier.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(theme.secondary)
                        .lineLimit(1)
                        .frame(width: Self.shore - 24, alignment: .trailing)
                        .position(x: Self.shore / 2 - 4, y: pier.y)
                    if pier.overflow > 0 {
                        Text("+\(pier.overflow)")
                            .font(.caption)
                            .foregroundStyle(theme.secondary)
                            .position(x: pier.end + 20, y: pier.y)
                    }
                }
                ForEach(boats) { boat in
                    Text(boat.session.title)
                        .font(.caption)
                        .foregroundStyle(theme.secondary)
                        .lineLimit(1)
                        .frame(width: Self.slot - 16)
                        .opacity(boat.opacity)
                        .position(x: boat.point.x, y: boat.point.y + 16)
                    Color.clear
                        .contentShape(.rect)
                        .frame(width: 48, height: 56)
                        .pointerStyle(.link)
                        .onHover { hoveredID = $0 ? boat.id : hoveredID == boat.id ? nil : hoveredID }
                        .onTapGesture { store.activate(.session(boat.id)) }
                        .accessibilityElement()
                        .accessibilityLabel(boat.session.title)
                        .accessibilityValue(boat.status)
                        .accessibilityAddTraits(.isButton)
                        .position(x: boat.point.x, y: boat.point.y - 18)
                }
                if let boat = boats.first(where: { $0.id == hoveredID || Snapshot.forcedHover.contains($0.session.title) }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(boat.session.title)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(theme.foreground)
                        Text(boat.status)
                            .font(.caption)
                            .foregroundStyle(boat.mooring == .working ? theme.working : boat.mooring == .idle || boat.mooring == .anchored ? theme.secondary : theme.needsYou)
                    }
                    .lineLimit(1)
                    .frame(maxWidth: 320, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
                    .fixedSize()
                    .position(x: min(max(boat.point.x, 180), geometry.size.width - 180), y: boat.point.y - 76)
                    .allowsHitTesting(false)
                }
                if boats.isEmpty {
                    ContentUnavailableView("Quiet Harbor", systemImage: "sailboat", description: Text("No sessions are open, running or finished in the last hour."))
                }
            }
        }
        .background(theme.background ?? .clear)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onExitCommand { store.isHarborShown = false }
    }

    private func layout(in size: CGSize) -> ([Pier], [Boat]) {
        let groups = ([("Pinned", store.pinnedSessions)] + store.groups.map { ($0.title, $0.sessions) })
            .map { title, sessions in (title, sessions.filter { store.liveBySession[$0.id] != nil || store.tab(forSession: $0.id) != nil }) }
            .filter { !$0.1.isEmpty }
            .prefix(6)
        let driftStart = max(Self.shore + 32 + Self.slot, size.width * 0.7)
        let perPier = max(1, Int((driftStart - Self.shore - 56) / Self.slot))
        let row = min(112, max(80, (size.height - 96) / Double(max(groups.count, 1))))
        let top = max(64, (size.height - row * Double(groups.count)) / 2 - 16)
        let piers = groups.enumerated().map { index, group in
            Pier(title: group.0, y: top + row * (Double(index) + 0.5), end: Self.shore + 24 + Self.slot * Double(min(group.1.count, perPier)), overflow: max(0, group.1.count - perPier))
        }
        let moored = zip(piers, groups).flatMap { pier, group in
            group.1.prefix(perPier).enumerated().map { index, session in
                let live = store.liveBySession[session.id]
                let mooring: Mooring = switch live?.activity {
                case .working: .working
                case let .needsInput(reason): .needsYou(reason)
                default: .idle
                }
                return Boat(session: session, mooring: mooring, isElsewhere: live.map { $0.attachID == nil } ?? false && store.tab(forSession: session.id) == nil, point: CGPoint(x: Self.shore + 24 + Self.slot * (Double(index) + 0.5), y: pier.y - 4))
            }
        }
        let column = (size.width - 40 - driftStart) / 2
        let anchored = store.activeSessions
            .filter { store.liveBySession[$0.id] == nil && store.tab(forSession: $0.id) == nil && $0.lastActivity.timeIntervalSinceNow > -3600 }
            .prefix(max(0, Int((size.height - 120) / 104) * 2))
            .enumerated()
            .map { index, session in
                Boat(session: session, mooring: .anchored, isElsewhere: false, point: CGPoint(x: driftStart + column * (Double(index % 2) + 0.5), y: 120 + 104 * Double(index / 2) + Double(index % 2) * 40))
            }
        return (piers, moored + anchored)
    }

    private func draw(piers: [Pier], boats: [Boat], in context: GraphicsContext, size: CGSize) {
        let ink = theme.foreground
        for index in 0..<24 {
            let x = (Double(index * 383 % 997) / 997) * size.width
            let y = (Double(index * 211 % 503) / 503) * size.height
            guard x > Self.shore + 12 else { continue }
            var wave = Path()
            wave.move(to: CGPoint(x: x, y: y))
            wave.addQuadCurve(to: CGPoint(x: x + 8, y: y), control: CGPoint(x: x + 4, y: y - 3))
            wave.addQuadCurve(to: CGPoint(x: x + 16, y: y), control: CGPoint(x: x + 12, y: y + 3))
            context.stroke(wave, with: .color(ink.opacity(0.07)), lineWidth: 1)
        }
        context.fill(Path(CGRect(x: 0, y: 0, width: Self.shore, height: size.height)), with: .color(ink.opacity(0.04)))
        context.fill(Path(CGRect(x: Self.shore - 1, y: 0, width: 1, height: size.height)), with: .color(ink.opacity(0.12)))
        for pier in piers {
            for offset in [-1.5, 1.5] {
                context.fill(Path(CGRect(x: Self.shore, y: pier.y + offset, width: pier.end - Self.shore, height: 1)), with: .color(ink.opacity(0.22)))
            }
            for post in stride(from: Self.shore + 24, through: pier.end, by: Self.slot) {
                context.fill(Path(ellipseIn: CGRect(x: post - 2, y: pier.y - 1.5, width: 4, height: 4)), with: .color(ink.opacity(0.35)))
            }
        }
        for boat in boats {
            Self.draw(boat, at: boat.point, in: context, theme: theme)
        }
    }

    fileprivate static func draw(_ boat: Boat, at point: CGPoint, in context: GraphicsContext, theme: GhosttyTheme) {
        var context = context
        let ink = theme.foreground
        context.opacity = boat.opacity
        context.translateBy(x: point.x, y: point.y)
        if boat.mooring == .anchored {
            var rode = Path()
            rode.move(to: CGPoint(x: 14, y: -2))
            rode.addQuadCurve(to: CGPoint(x: 26, y: 12), control: CGPoint(x: 24, y: 0))
            context.stroke(rode, with: .color(ink.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        }
        if boat.mooring == .working {
            for index in 0..<3 {
                let x = -24 - Double(index) * 8
                context.fill(Path(CGRect(x: x, y: -0.5, width: 5, height: 1.5)), with: .color(theme.working.opacity(0.8 - Double(index) * 0.25)))
            }
        }
        var hull = Path()
        hull.addLines([CGPoint(x: -18, y: -7), CGPoint(x: 18, y: -7), CGPoint(x: 13, y: 1), CGPoint(x: -13, y: 1)])
        hull.closeSubpath()
        context.fill(hull, with: .color(ink.opacity(0.9)))
        var main = Path()
        main.addLines([CGPoint(x: -0.5, y: -36), CGPoint(x: -0.5, y: -10), CGPoint(x: 15, y: -10)])
        main.closeSubpath()
        context.fill(main, with: .color(ink.opacity(0.75)))
        var jib = Path()
        jib.addLines([CGPoint(x: -3.5, y: -32), CGPoint(x: -3.5, y: -10), CGPoint(x: -14, y: -10)])
        jib.closeSubpath()
        context.fill(jib, with: .color(ink.opacity(0.45)))
        context.fill(Path(CGRect(x: -2.5, y: -44, width: 1.25, height: 37)), with: .color(ink))
        guard case .needsYou = boat.mooring else { return }
        var flag = Path()
        flag.move(to: CGPoint(x: -1.5, y: -44))
        flag.addQuadCurve(to: CGPoint(x: 10, y: -41), control: CGPoint(x: 4, y: -45))
        flag.addQuadCurve(to: CGPoint(x: -1.5, y: -38), control: CGPoint(x: 4, y: -37))
        flag.closeSubpath()
        context.fill(flag, with: .color(theme.needsYou))
    }
}

private struct BoatSprite: View {
    let boat: Boat
    let theme: GhosttyTheme

    var body: some View {
        Canvas { context, _ in
            Harbor.draw(boat, at: CGPoint(x: 48, y: 52), in: context, theme: theme)
        }
    }
}

private struct Bobbing: NSViewRepresentable {
    let boat: Boat
    let theme: GhosttyTheme
    let isRunning: Bool

    func makeNSView(context: Context) -> NSHostingView<BoatSprite> {
        let view = NSHostingView(rootView: BoatSprite(boat: boat, theme: theme))
        view.sizingOptions = []
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSHostingView<BoatSprite>, context: Context) {
        view.rootView = BoatSprite(boat: boat, theme: theme)
        guard let layer = view.layer else { return }
        guard isRunning else {
            layer.removeAllAnimations()
            return
        }
        let motions = [("transform.translation.y", boat.mooring.bob, 2 * .pi / 1.6), ("transform.translation.x", boat.mooring == .anchored ? 8 : 0, 2 * .pi / 0.2)]
        let running = motions.map { keyPath, amplitude, _ in (layer.animation(forKey: keyPath) as? CABasicAnimation)?.toValue as? Double ?? 0 == amplitude }
        guard running.contains(false) else { return }
        layer.removeAllAnimations()
        for (keyPath, amplitude, period) in motions where amplitude > 0 {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = -amplitude
            animation.toValue = amplitude
            animation.duration = period / 2
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animation.timeOffset = boat.seed / (2 * .pi) * period
            layer.add(animation, forKey: keyPath)
        }
    }
}
