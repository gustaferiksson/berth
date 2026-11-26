import AppKit
import BerthCore
import Foundation
import SwiftUI

enum ItemPreviewSetting {
    static let key = "richPreviews"
}

nonisolated struct ItemReference: Hashable, Sendable {
    let repository: String
    let number: Int
    let isPullRequest: Bool

    init?(url: URL) {
        guard let match = url.absoluteString.wholeMatch(of: /https:\/\/github\.com\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)\/(pull|issues)\/([0-9]+)/),
              let number = Int(match.4), number > 0, match.1 != ".", match.1 != "..", match.2 != ".", match.2 != ".."
        else { return nil }

        repository = "\(match.1)/\(match.2)"
        self.number = number
        isPullRequest = match.3 == "pull"
    }
}

@MainActor
final class ItemPreviewCache {
    static let shared = ItemPreviewCache()

    private struct Entry {
        let preview: ItemPreview?
        let expires: ContinuousClock.Instant
    }

    private var entries: [ItemReference: Entry] = [:]
    private var inFlight: [ItemReference: Task<ItemPreview?, Never>] = [:]

    func preview(for reference: ItemReference) async -> ItemPreview? {
        #if DEBUG
        if Snapshot.output != nil || Snapshot.launcherKeys != nil {
            let fixtures: [ItemPreview?] = [.fixtureRoundingPullRequest, .fixtureStartupIssue, Snapshot.showsReviewIssue ? .fixtureReviewIssue : nil, .fixtureReviewPullRequest]
            return fixtures.compactMap(\.self).first { ItemReference(url: $0.url) == reference }
        }
        #endif
        let now = ContinuousClock.now
        if let entry = entries[reference], entry.expires > now { return entry.preview }
        if let request = inFlight[reference] { return await request.value }

        entries = entries.filter { $0.value.expires > now }
        let request = Task.detached(priority: .utility) { () -> ItemPreview? in
            guard let preview = PullRequestStatus.preview(repository: reference.repository, number: reference.number),
                  (preview.kind == .pullRequest) == reference.isPullRequest
            else { return nil }

            return preview
        }
        inFlight[reference] = request
        let preview = await request.value
        entries[reference] = Entry(preview: preview, expires: .now + .seconds(preview == nil ? 30 : 120))
        inFlight[reference] = nil
        return preview
    }
}

enum ItemPreviewPlacement {
    case sidebar, launcher, review
}

@MainActor
final class ItemPreviewPanel {
    static let shared = ItemPreviewPanel()

    enum Presentation {
        case hover, immediate
    }

    enum Side {
        case leading, trailing
    }

    struct Anchor {
        let row: NSRect
        let column: NSRect
        weak var window: NSWindow?
        let side: Side

        init?(view: NSView, side: Side) {
            guard let window = view.window else { return nil }

            row = window.convertToScreen(view.convert(view.bounds, to: nil))
            column = view.enclosingScrollView.map { window.convertToScreen($0.convert($0.bounds, to: nil)) } ?? row
            self.window = window
            self.side = side
        }
    }

    private struct Registration {
        weak var view: NSView?
        let placement: ItemPreviewPlacement
    }

    private struct Request {
        let id = UUID()
        let reference: ItemReference
        let owner: UUID
        let placement: ItemPreviewPlacement
    }

    private lazy var panel: ItemPreviewWindow = {
        let panel = ItemPreviewWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        return panel
    }()

    private var anchors: [ItemReference: [UUID: Registration]] = [:]
    private var monitor: Any?
    private var request: Request?
    private var displayID: UUID?
    private var pendingPreview: Task<Void, Never>?
    private var pendingHide: Task<Void, Never>?
    private var hoveringOwner: UUID?
    private var isPointerInside = false

    var isShowing: Bool { displayID != nil && panel.parent != nil }
    var claimsHover: Bool { hoveringOwner != nil }

    func register(_ view: NSView, for reference: ItemReference, owner: UUID, placement: ItemPreviewPlacement) {
        anchors[reference, default: [:]][owner] = Registration(view: view, placement: placement)
    }

    func unregister(_ reference: ItemReference, owner: UUID) {
        anchors[reference]?[owner] = nil
        if anchors[reference]?.isEmpty == true { anchors[reference] = nil }
        releaseHover(owner: owner)
        if request?.owner == owner { hide() }
    }

    func claimHover(owner: UUID) {
        hoveringOwner = owner
        HoverCardPanel.shared.hide()
        if request?.owner == owner { pendingHide?.cancel() }
    }

    func releaseHover(owner: UUID) {
        if hoveringOwner == owner { hoveringOwner = nil }
        hideSoon(owner: owner)
    }

    func show(reference: ItemReference, owner: UUID, store: Store, beside anchor: Anchor, theme: GhosttyTheme, presentation: Presentation) {
        guard let placement = anchors[reference]?[owner]?.placement else { return }

        pendingHide?.cancel()
        if request?.owner == owner, presentation == .hover { return }

        pendingPreview?.cancel()
        let request = Request(reference: reference, owner: owner, placement: placement)
        self.request = request
        if presentation == .immediate { display(nil, beside: anchor, theme: theme, store: store) }
        monitor = monitor ?? NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }

            return handle(event)
        }
        pendingPreview = Task { @MainActor in
            let preview = await ItemPreviewCache.shared.preview(for: reference)
            guard !Task.isCancelled, self.request?.id == request.id else { return }
            guard let preview, let view = anchors[reference]?[owner]?.view,
                  let currentAnchor = Anchor(view: view, side: anchor.side)
            else { return hide() }

            let actions = store.previewActions(for: preview, dismiss: hide)
            display(ItemPreviewView(preview: preview, actions: actions), beside: currentAnchor, theme: theme, store: store)
        }
    }

    func showInLauncher(reference: ItemReference, store: Store, theme: GhosttyTheme) {
        guard let registrations = anchors[reference],
              let row = registrations.first(where: { $0.value.placement == .launcher && $0.value.view?.window?.isKeyWindow == true }),
              let view = row.value.view, let anchor = Anchor(view: view, side: .trailing)
        else { return hideInLauncher() }

        show(reference: reference, owner: row.key, store: store, beside: anchor, theme: theme, presentation: .immediate)
    }

    var showsLauncherPreview: Bool { isShowing && request?.placement == .launcher }
    var shownReference: ItemReference? { isShowing ? request?.reference : nil }

    func hideInLauncher() {
        if request?.placement == .launcher { hide() }
    }

    private func display(_ card: ItemPreviewView?, beside anchor: Anchor, theme: GhosttyTheme, store: Store) {
        guard let window = anchor.window, let screen = (window.screen ?? NSScreen.main)?.visibleFrame else { return hide() }

        let displayID = UUID()
        self.displayID = displayID
        let host = ItemPreviewHostingView(rootView: ItemPreviewHost(
            card: card,
            maxHeight: max(1, min(screen.height - 32, 680)),
            theme: theme,
            onHover: { [weak self] inside in
                guard let self, self.displayID == displayID else { return }

                isPointerInside = inside
                if inside { pendingHide?.cancel() } else if let owner = request?.owner { hideSoon(owner: owner) }
            },
            onResize: { [weak self] height in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.displayID == displayID else { return }

                    let size = NSSize(width: ItemPreviewView.width, height: height)
                    panel.setFrame(Self.frame(size: size, beside: anchor, screen: screen), display: true)
                }
            }
        ).environment(\.openURL, store.linkOpeningAction))
        host.sizingOptions = [.intrinsicContentSize]
        if let parent = panel.parent, parent !== window { parent.removeChildWindow(panel) }
        panel.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        panel.contentView = host
        panel.setFrame(Self.frame(size: host.fittingSize, beside: anchor, screen: screen), display: true)
        isPointerInside = panel.frame.contains(NSEvent.mouseLocation)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
    }

    private static func frame(size: NSSize, beside anchor: Anchor, screen: NSRect) -> NSRect {
        let gap = 8.0
        let leading = anchor.column.minX - gap - size.width
        let trailing = anchor.column.maxX + gap
        let preferred = anchor.side == .trailing ? trailing : leading
        let opposite = anchor.side == .trailing ? leading : trailing
        let horizontal = preferred < screen.minX || preferred + size.width > screen.maxX ? opposite : preferred
        let x = max(screen.minX, min(horizontal, screen.maxX - size.width))
        let y = max(screen.minY, min(anchor.row.maxY - size.height, screen.maxY - size.height))
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.type == .keyDown else {
            if event.window !== panel, !panel.frame.contains(NSEvent.mouseLocation) { hide() }
            return event
        }

        let key = event.charactersIgnoringModifiers
        if key == String(KeyEquivalent.upArrow.character) || key == String(KeyEquivalent.downArrow.character) { return event }

        let consumesKey = isShowing && (key == String(KeyEquivalent.escape.character) || key == " ")
        hide()
        return consumesKey ? nil : event
    }

    func hideSoon(owner: UUID) {
        guard request?.owner == owner else { return }

        pendingHide?.cancel()
        pendingHide = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, !isPointerInside, hoveringOwner != owner else { return }

            hide()
        }
    }

    func hide() {
        pendingPreview?.cancel()
        pendingHide?.cancel()
        request = nil
        isPointerInside = false
        if displayID != nil {
            displayID = nil
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentView = nil
        }
        monitor.map(NSEvent.removeMonitor)
        monitor = nil
    }
}

private final class ItemPreviewWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ItemPreviewHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
}

private struct ItemPreviewHost: View {
    let card: ItemPreviewView?
    let maxHeight: CGFloat
    let theme: GhosttyTheme
    let onHover: (Bool) -> Void
    let onResize: (CGFloat) -> Void
    @State private var contentHeight: CGFloat = 120

    var body: some View {
        Group {
            if let card { card } else { ItemPreviewPlaceholder() }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            contentHeight = height
            onResize(min(height, maxHeight))
        }
        .frame(width: ItemPreviewView.width, height: min(contentHeight, maxHeight))
        .clipShape(.rect(cornerRadius: 14))
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .environment(\.ghosttyTheme, theme)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .onHover(perform: onHover)
    }
}

struct ItemPreviewTrigger: ViewModifier {
    let reference: ItemReference?
    let placement: ItemPreviewPlacement
    let store: Store
    @AppStorage(ItemPreviewSetting.key) private var richPreviews = false
    @AppStorage("sidebarPosition") private var sidebarPosition = SidebarPosition.left
    @Environment(\.ghosttyTheme) private var theme
    @State private var owner = UUID()
    @State private var anchor: NSView?
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        if richPreviews, let reference {
            content
                .background(ViewAnchor { anchor = $0 })
                .onChange(of: anchor, initial: true) {
                    if let anchor { ItemPreviewPanel.shared.register(anchor, for: reference, owner: owner, placement: placement) }
                }
                .onHover { hover($0, reference: reference) }
                .onChange(of: reference) { previous, current in
                    pending?.cancel()
                    ItemPreviewPanel.shared.unregister(previous, owner: owner)
                    if let anchor { ItemPreviewPanel.shared.register(anchor, for: current, owner: owner, placement: placement) }
                }
                .onDisappear {
                    pending?.cancel()
                    ItemPreviewPanel.shared.unregister(reference, owner: owner)
                    anchor = nil
                }
        } else {
            content
        }
    }

    private func hover(_ inside: Bool, reference: ItemReference) {
        guard Snapshot.output == nil else { return }

        let panel = ItemPreviewPanel.shared
        pending?.cancel()
        guard inside else { return panel.releaseHover(owner: owner) }

        panel.claimHover(owner: owner)
        pending = Task { @MainActor in
            if !panel.isShowing { try? await Task.sleep(for: .milliseconds(600)) }
            let side: ItemPreviewPanel.Side = switch placement {
            case .launcher: .trailing
            case .sidebar: sidebarPosition == .left ? .trailing : .leading
            case .review: sidebarPosition == .left ? .leading : .trailing
            }
            guard !Task.isCancelled, let anchor, let position = ItemPreviewPanel.Anchor(view: anchor, side: side) else { return }

            panel.show(reference: reference, owner: owner, store: store, beside: position, theme: theme, presentation: .hover)
        }
    }
}

struct LauncherItemPreview: ViewModifier {
    let url: URL?
    let highlighted: Int
    let query: String
    let store: Store
    @AppStorage(ItemPreviewSetting.key) private var richPreviews = false
    @Environment(\.ghosttyTheme) private var theme

    func body(content: Content) -> some View {
        if richPreviews {
            content
                .onKeyPress(.space) {
                    guard query.isEmpty, let url, let reference = ItemReference(url: url) else { return .ignored }

                    let panel = ItemPreviewPanel.shared
                    if panel.shownReference == reference {
                        panel.hide()
                    } else {
                        panel.showInLauncher(reference: reference, store: store, theme: theme)
                    }
                    return .handled
                }
                .onChange(of: highlighted) {
                    let panel = ItemPreviewPanel.shared
                    guard panel.showsLauncherPreview else { return }
                    guard let url, let reference = ItemReference(url: url) else { return panel.hideInLauncher() }

                    panel.showInLauncher(reference: reference, store: store, theme: theme)
                }
                .onChange(of: store.launcherMode) { ItemPreviewPanel.shared.hideInLauncher() }
                .onDisappear { ItemPreviewPanel.shared.hideInLauncher() }
        } else {
            content
        }
    }
}

extension Store {
    func previewActions(for preview: ItemPreview, dismiss: @escaping () -> Void) -> ItemPreviewActions {
        var actions = ItemPreviewActions(copyLink: {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(preview.url.absoluteString, forType: .string)
        }, openOnGitHub: {
            #if DEBUG
            if Snapshot.launcherKeys != nil { self.probeOpenedURLs.append(preview.url) }
            #endif
            if Snapshot.launcherKeys != nil {
                print("snapshot openURL \(preview.url.absoluteString)")
            } else {
                self.openLink(preview.url)
            }
            dismiss()
        })
        let noCheckout = "This repository has no local checkout."
        if preview.kind == .issue {
            guard localCheckout(of: preview.repository) != nil else {
                actions.openInBerthDisabledReason = noCheckout
                return actions
            }

            actions.openInBerthTitle = "Start Issue Session"
            actions.openInBerth = {
                self.startIssueSession(repository: preview.repository, number: preview.number, url: preview.url, title: preview.title)
                dismiss()
            }
            return actions
        }

        let link = PullRequestLink(repository: preview.repository, number: preview.number)
        let opening = opening(of: link)
        guard opening.isOpenable else {
            actions.openInBerthDisabledReason = noCheckout
            return actions
        }

        actions.openInBerthTitle = switch opening {
        case let .session(session): tab(forSession: session.id) == nil ? "Resume Session" : "Switch To Session"
        case .tab: "Switch To Session"
        case .worktree: "Open in New Worktree"
        case .noCheckout: "Open in Berth"
        }
        actions.openInBerth = {
            self.openPullRequest(link, url: preview.url, opening: opening)
            self.launcherMode = nil
            dismiss()
        }
        return actions
    }

    func startIssueSession(repository: String, number: Int, url: URL, title: String) {
        let prompt = (UserDefaults.standard.string(forKey: GeneralSettings.issuePromptKey) ?? GeneralSettings.defaultIssuePrompt)
            .replacing("{number}", with: String(number))
            .replacing("{url}", with: url.absoluteString)
            .replacing("{repo}", with: repository)
            .replacing("{title}", with: title)

        let checkout = UserDefaults.standard.string(forKey: GeneralSettings.issueCheckoutKey).flatMap(NewSessionCheckout.init(rawValue:)) ?? .preferred

        guard let folder = localCheckout(of: repository),
              openSession(cwd: folder, checkout: checkout, pasting: prompt.isEmpty ? nil : prompt) != nil
        else { return }

        isHarborShown = false
        launcherMode = nil
    }
}
