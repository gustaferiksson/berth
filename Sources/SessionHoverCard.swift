import BerthCore
import SwiftUI

@MainActor
final class HoverCardPanel {
    static let shared = HoverCardPanel()

    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private var monitor: Any?

    init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
    }

    func show(_ card: some View, beside row: NSRect, in window: NSWindow, trailing: Bool) {
        let host = NSHostingView(rootView: card.glassEffect(.regular, in: .rect(cornerRadius: 12)))
        let size = host.fittingSize
        let screen = window.screen?.visibleFrame ?? .zero
        let x = trailing ? row.maxX + 8 : row.minX - 8 - size.width
        let y = max(row.maxY - size.height, screen.minY)
        panel.contentView = host
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        window.addChildWindow(panel, ordered: .above)
        monitor = monitor ?? NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            self?.hide()
            return event
        }
    }

    func hide() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        monitor.map(NSEvent.removeMonitor)
        monitor = nil
    }
}

struct SessionHoverTrigger: ViewModifier {
    let session: SessionSummary
    let pullRequest: PullRequest?
    let context: SessionContext?
    @State private var anchor: NSView?
    @State private var pending: Task<Void, Never>?
    @AppStorage("sidebarPosition") private var sidebarPosition = SidebarPosition.left
    @Environment(\.ghosttyTheme) private var theme

    func body(content: Content) -> some View {
        content
            .background(ViewAnchor { anchor = $0 })
            .onHover { isHovering in
                pending?.cancel()
                HoverCardPanel.shared.hide()
                guard isHovering, Snapshot.output == nil else { return }

                pending = Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled, let anchor, let window = anchor.window else { return }

                    let row = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
                    HoverCardPanel.shared.show(
                        SessionHoverCard(session: session, pullRequest: pullRequest, context: context).environment(\.ghosttyTheme, theme),
                        beside: row,
                        in: window,
                        trailing: sidebarPosition == .left
                    )
                }
            }
    }
}

private struct ViewAnchor: NSViewRepresentable {
    let resolve: (NSView) -> Void

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { resolve(view) }
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}
}

struct SessionHoverCard: View {
    let session: SessionSummary
    let pullRequest: PullRequest?
    let context: SessionContext?
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.title)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
            Text([URL(filePath: session.checkout).lastPathComponent, session.branch].compactMap(\.self).joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(theme.secondary)
            if let pullRequest {
                let checks = [.open, .draft].contains(pullRequest.state) ? pullRequest.checks : nil
                Text("#\(pullRequest.number) \(pullRequest.state.rawValue)\(checks.map { ", checks \($0.rawValue)" } ?? "")")
                    .font(.caption)
                    .foregroundStyle(pullRequest.state.color(in: theme))
            }
            Text((session.cwd as NSString).abbreviatingWithTildeInPath)
                .font(.caption.monospaced())
                .foregroundStyle(theme.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            HStack(spacing: 10) {
                Text("Last prompt \(session.lastPrompt.formatted(.relative(presentation: .named)))")
                if let context, let window = context.window {
                    Text("Context \((Double(context.tokens) / Double(window)).formatted(.percent.precision(.fractionLength(0))))")
                }
            }
            .font(.caption)
            .foregroundStyle(theme.secondary)
        }
        .foregroundStyle(theme.foreground)
        .frame(width: 260, alignment: .leading)
        .padding(12)
    }
}
