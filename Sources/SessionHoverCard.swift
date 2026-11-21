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

    func show(_ card: some View, isDark: Bool, beside row: NSRect, column: NSRect, in window: NSWindow, trailing: Bool) {
        let host = NSHostingView(rootView: card.glassEffect(.regular, in: .rect(cornerRadius: 12)).environment(\.colorScheme, isDark ? .dark : .light))
        let size = host.fittingSize
        let frame = Self.frame(size: size, row: row, column: column, trailing: trailing, screen: window.screen?.visibleFrame ?? .zero)
        panel.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        panel.contentView = host
        panel.setFrame(frame, display: true)
        window.addChildWindow(panel, ordered: .above)
        monitor = monitor ?? NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            self?.hide()
            return event
        }
    }

    static func frame(size: NSSize, row: NSRect, column: NSRect, trailing: Bool, screen: NSRect) -> NSRect {
        let gap = 8.0
        let x = trailing ? column.maxX + gap : column.minX - gap - size.width
        let y = min(max(row.maxY - size.height, screen.minY), screen.maxY - size.height)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
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
    let pullRequests: [SessionPullRequest]
    let context: SessionContext?
    let isNoticeShown: Bool
    @State private var anchor: NSView?
    @State private var pending: Task<Void, Never>?
    @State private var isDismissed = false
    @AppStorage("sidebarPosition") private var sidebarPosition = SidebarPosition.left
    @Environment(\.ghosttyTheme) private var theme

    func body(content: Content) -> some View {
        content
            .background(ViewAnchor { anchor = $0 })
            .onChange(of: isNoticeShown) { _, isShown in
                guard isShown else { return }

                isDismissed = true
                pending?.cancel()
                HoverCardPanel.shared.hide()
            }
            .onHover { isHovering in
                pending?.cancel()
                HoverCardPanel.shared.hide()
                if !isHovering { isDismissed = false }
                guard isHovering, !isDismissed, Snapshot.output == nil else { return }

                pending = Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled, let anchor, let window = anchor.window else { return }

                    let row = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
                    let column = anchor.enclosingScrollView.map { window.convertToScreen($0.convert($0.bounds, to: nil)) } ?? row
                    HoverCardPanel.shared.show(
                        SessionHoverCard(session: session, pullRequests: pullRequests, context: context).environment(\.ghosttyTheme, theme),
                        isDark: theme.isDark,
                        beside: row,
                        column: column,
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
    let pullRequests: [SessionPullRequest]
    let context: SessionContext?
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.title)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
            Text([URL(filePath: session.checkout).lastPathComponent, session.branch].compactMap(\.self).joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.7))
            ForEach(pullRequests, id: \.self) { item in
                let checks = [.open, .draft].contains(item.state) ? item.pullRequest.checks : nil
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill")
                        .accessibilityHidden(true)
                        .font(.system(size: 7))
                        .foregroundStyle(item.state.color(in: theme))
                    Text(verbatim: "\(item.repository) #\(item.number) \(item.state.rawValue)\(checks.map { ", checks \($0.rawValue)" } ?? "")")
                        .font(.caption)
                }
            }
            Text((session.cwd as NSString).abbreviatingWithTildeInPath)
                .font(.caption.monospaced())
                .foregroundStyle(.primary.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.head)
            HStack(spacing: 10) {
                Text("Last prompt \(session.lastPrompt.formatted(.relative(presentation: .named)))")
                if let context, let window = context.window {
                    Text("Context \(Int((Double(context.tokens) / Double(window) * 100).rounded()))%")
                }
            }
            .font(.caption)
            .foregroundStyle(.primary.opacity(0.7))
        }
        .frame(width: 260, alignment: .leading)
        .padding(12)
    }
}
