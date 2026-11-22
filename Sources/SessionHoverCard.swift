import BerthCore
import SwiftUI

@MainActor
final class HoverCardPanel {
    static let shared = HoverCardPanel()

    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private var monitor: Any?
    private var owner: String?
    private var pendingHide: Task<Void, Never>?

    var isShowing: Bool { panel.parent != nil }

    init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
    }

    func keepsShowing(owner candidate: String) -> Bool {
        guard isShowing, owner == candidate else { return false }

        pendingHide?.cancel()
        return true
    }

    func show(_ card: some View, owner: String, isDark: Bool, beside row: NSRect, column: NSRect, in window: NSWindow, trailing: Bool) {
        pendingHide?.cancel()
        self.owner = owner
        let host = NSHostingView(rootView: card.glassEffect(.regular, in: .rect(cornerRadius: 12)).environment(\.colorScheme, isDark ? .dark : .light))
        let size = host.fittingSize
        let frame = Self.frame(size: size, row: row, column: column, trailing: trailing, screen: window.screen?.visibleFrame ?? .zero)
        panel.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        panel.contentView = host
        panel.setFrame(frame, display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        monitor = monitor ?? NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            if event.window !== self?.panel { self?.hide() }
            return event
        }
    }

    static func frame(size: NSSize, row: NSRect, column: NSRect, trailing: Bool, screen: NSRect) -> NSRect {
        let gap = 8.0
        let x = trailing ? column.maxX + gap : column.minX - gap - size.width
        let y = min(max(row.maxY - size.height, screen.minY), screen.maxY - size.height)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    func hideSoon(owner leaving: String) {
        guard owner == leaving else { return }

        pendingHide = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }

            hide()
        }
    }

    func hide() {
        pendingHide?.cancel()
        owner = nil
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
    let store: Store
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
                guard isHovering else {
                    isDismissed = false
                    HoverCardPanel.shared.hideSoon(owner: session.id)
                    return
                }
                guard !isDismissed, Snapshot.output == nil else { return }

                pending = Task {
                    if !HoverCardPanel.shared.isShowing { try? await Task.sleep(for: .milliseconds(600)) }
                    guard !Task.isCancelled, !HoverCardPanel.shared.keepsShowing(owner: session.id) else { return }

                    let excerpt = await HoverExcerpt.load(sessionID: session.id, index: store.index)
                    guard !Task.isCancelled, let anchor, let window = anchor.window else { return }

                    let row = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
                    let column = anchor.enclosingScrollView.map { window.convertToScreen($0.convert($0.bounds, to: nil)) } ?? row
                    HoverCardPanel.shared.show(
                        SessionHoverCard(session: session, pullRequests: pullRequests, context: context, excerpt: excerpt)
                            .environment(\.ghosttyTheme, theme),
                        owner: session.id,
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

struct HoverExcerpt: Sendable {
    let prompt: String
    let reply: String?

    static func load(sessionID: String, index: TranscriptIndex) async -> Self? {
        guard let url = index.url(ofSession: sessionID) else { return nil }

        return await Task.detached {
            let entries = TranscriptTail.read(url, after: nil)?.entries ?? []
            guard let prompt = entries.last(where: { $0.kind == .prompt }) else { return nil }

            let reply = entries.last { $0.kind == .reply }
            return Self(prompt: String(prompt.text.prefix(400)), reply: reply.map { String($0.text.prefix(400)) })
        }.value
    }
}

struct SessionHoverCard: View {
    let session: SessionSummary
    let pullRequests: [SessionPullRequest]
    let context: SessionContext?
    let excerpt: HoverExcerpt?
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .padding(.horizontal, 6)
                branchRow
            }
            if !pullRequests.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(pullRequests, id: \.self) { pullRequestRow(for: $0) }
                }
            }
            folderRow
            if let excerpt { excerptRow(excerpt) }
            footer
        }
        .frame(width: 260, alignment: .leading)
        .padding(6)
    }

    private var branchRow: some View {
        let project = URL(filePath: session.checkout).lastPathComponent
        return Text([session.agent.harness.isOptIn ? session.agent.harness.name : nil, project, session.branch].compactMap(\.self).joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.primary.opacity(0.7))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 6)
    }

    private func pullRequestRow(for item: SessionPullRequest) -> some View {
        let isLive = [.open, .draft].contains(item.state)
        let status = [(item.repository as NSString).lastPathComponent, item.state.rawValue]
            + [isLive ? item.pullRequest.checks.map { "Checks \($0.rawValue)" } : nil]
            .compactMap(\.self)
            + [isLive ? item.pullRequest.reviewDecision.flatMap(Self.reviewText) : nil].compactMap(\.self)
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: "circle.fill")
                .accessibilityHidden(true)
                .font(.system(size: 7))
                .foregroundStyle(item.state.color(in: theme))
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "#\(item.number) \(item.pullRequest.title)")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(verbatim: status.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.primary.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }

    private static func reviewText(_ decision: InboxPullRequest.ReviewDecision) -> String? {
        if decision == .approved { return "Approved" }
        if decision == .changesRequested { return "Changes requested" }
        return nil
    }

    private var folderRow: some View {
        Text((session.cwd as NSString).abbreviatingWithTildeInPath)
            .font(.caption.monospaced())
            .foregroundStyle(.primary.opacity(0.7))
            .lineLimit(1)
            .truncationMode(.head)
            .padding(.horizontal, 6)
    }

    private func excerptRow(_ excerpt: HoverExcerpt) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(excerpt.prompt)
                .font(.caption)
                .lineLimit(3)
            if let reply = excerpt.reply {
                Text(reply)
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.7))
                    .lineLimit(3)
            }
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("Last prompt \(session.lastPrompt.formatted(.relative(presentation: .named)))")
            if let context, let window = context.window {
                ContextRing(context: context, window: window)
                Text("\(Int((Double(context.tokens) / Double(window) * 100).rounded()))%")
            }
        }
        .font(.caption)
        .foregroundStyle(.primary.opacity(0.7))
        .padding(.horizontal, 6)
    }
}
