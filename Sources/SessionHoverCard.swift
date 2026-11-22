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
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
    }

    func keepsShowing(owner candidate: String) -> Bool {
        guard isShowing, owner == candidate else { return false }

        pendingHide?.cancel()
        return true
    }

    func pointerMoved(insideCard isInside: Bool) {
        if isInside {
            pendingHide?.cancel()
        } else if let owner {
            hideSoon(owner: owner)
        }
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
    @Environment(\.openURL) private var openURL

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
                        SessionHoverCard(session: session, pullRequests: pullRequests, context: context, excerpt: excerpt, store: store)
                            .environment(\.ghosttyTheme, theme)
                            .environment(\.openURL, openURL),
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
    let store: Store
    @State private var copiedBranch = false
    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        let tab = store.tab(forSession: session.id)
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
            actions(tab: tab)
        }
        .frame(width: 260, alignment: .leading)
        .padding(6)
        .onHover { HoverCardPanel.shared.pointerMoved(insideCard: $0) }
    }

    private var branchRow: some View {
        let project = URL(filePath: session.checkout).lastPathComponent
        return Button {
            guard let branch = session.branch else { return }

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(branch, forType: .string)
            copiedBranch = true
            Task {
                try? await Task.sleep(for: .seconds(1))
                copiedBranch = false
            }
        } label: {
            HStack(spacing: 4) {
                Text(copiedBranch ? "Copied" : [project, session.branch].compactMap(\.self).joined(separator: " · "))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if session.branch != nil {
                    Image(systemName: copiedBranch ? "checkmark" : "doc.on.doc")
                        .accessibilityHidden(true)
                        .imageScale(.small)
                        .opacity(copiedBranch ? 1 : 0.6)
                }
            }
            .font(.caption)
            .foregroundStyle(.primary.opacity(0.7))
            .modifier(HoverFill())
        }
        .buttonStyle(.plain)
        .disabled(session.branch == nil)
        .help("Copy branch name")
    }

    private func pullRequestRow(for item: SessionPullRequest) -> some View {
        let isLive = [.open, .draft].contains(item.state)
        let status = [(item.repository as NSString).lastPathComponent, item.state.rawValue]
            + [isLive ? item.pullRequest.checks.map { "Checks \($0.rawValue)" } : nil]
            .compactMap(\.self)
            + [isLive ? item.pullRequest.reviewDecision.flatMap(Self.reviewText) : nil].compactMap(\.self)
        return Button {
            openURL(item.pullRequest.url)
            HoverCardPanel.shared.hide()
        } label: {
            HStack(alignment: .top, spacing: 6) {
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
            .modifier(HoverFill())
        }
        .buttonStyle(.plain)
        .help("Open pull request")
    }

    private static func reviewText(_ decision: InboxPullRequest.ReviewDecision) -> String? {
        if decision == .approved { return "Approved" }
        if decision == .changesRequested { return "Changes requested" }
        return nil
    }

    private var folderRow: some View {
        Button {
            let folder = URL(filePath: session.cwd)
            guard NSEvent.modifierFlags.contains(.command) else {
                NSWorkspace.shared.activateFileViewerSelecting([folder])
                HoverCardPanel.shared.hide()
                return
            }

            store.openShell(cwd: session.cwd)
            store.activate(store.selectedTabID.map(SidebarItem.tab))
            HoverCardPanel.shared.hide()
        } label: {
            Text((session.cwd as NSString).abbreviatingWithTildeInPath)
                .font(.caption.monospaced())
                .foregroundStyle(.primary.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.head)
                .modifier(HoverFill())
        }
        .buttonStyle(.plain)
        .help("Reveal in Finder, ⌘-click for a terminal here")
    }

    private func excerptRow(_ excerpt: HoverExcerpt) -> some View {
        Button {
            store.activate(.session(session.id))
            HoverCardPanel.shared.hide()
        } label: {
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
            .modifier(HoverFill())
        }
        .buttonStyle(.plain)
        .help("Open session")
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

    private func actions(tab: Tab?) -> some View {
        let isPinned = store.pinnedSessions.contains { $0.id == session.id }
        let isFlagged = store.flaggedIDs.contains(session.id)
        return HStack(spacing: 2) {
            HoverAction(symbol: "arrow.up.forward.square", title: "Open") { store.activate(.session(session.id)) }
            HoverAction(symbol: isPinned ? "pin.slash" : "pin", title: isPinned ? "Unpin" : "Pin") {
                if isPinned { store.unpin(session.id) } else { store.pin(session.id) }
            }
            HoverAction(symbol: isFlagged ? "flag.fill" : "flag", title: isFlagged ? "Unflag" : "Flag") {
                if isFlagged { store.unflag(session.id) } else { store.flag(session.id) }
            }
            HoverAction(symbol: "archivebox", title: "Archive") { store.archive(session.id) }
            if let tab {
                HoverAction(symbol: "eject", title: "Unload Session") { store.close(tab.id) }
            }
        }
        .padding(.top, 2)
    }
}

private struct HoverFill: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(isHovering ? 0.1 : 0), in: .rect(cornerRadius: 6))
            .contentShape(.rect)
            .onHover { isHovering = $0 }
    }
}

private struct HoverAction: View {
    let symbol: String
    let title: String
    let perform: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button {
            perform()
            HoverCardPanel.shared.hide()
        } label: {
            Image(systemName: symbol)
                .accessibilityHidden(true)
                .frame(width: 30, height: 24)
                .background(Color.primary.opacity(isHovering ? 0.1 : 0), in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}
