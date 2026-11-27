#if DEBUG
import AppKit
import BerthCore
import GhosttyTerminal
import os
import SwiftUI

extension Snapshot {
    static func conversationPerfFailure(_ message: String) -> Never {
        FileHandle.standardError.write(Data("perf conversation error: \(message)\n".utf8))
        ProcessAncestry.hangUpDescendants()
        exit(1)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let elapsed = duration.components
        return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }

    private static func flushDisplay(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    private static func mainThreadMilliseconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000
    }

    private static func cpuMilliseconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let seconds = { (time: timeval) in Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return (seconds(usage.ru_utime) + seconds(usage.ru_stime)) * 1000
    }

    static func sidebarSplitController(in view: NSView) -> NSSplitViewController? {
        let controller = (view as? NSSplitView)?.delegate as? NSSplitViewController
        if let controller, controller.splitViewItems.contains(where: { $0.behavior == .sidebar }) { return controller }

        return view.subviews.lazy.compactMap(sidebarSplitController).first
    }

    private static func tallestScrollView(in window: NSWindow) -> NSScrollView? {
        guard let content = window.contentView else { return nil }

        var views = [content]
        var tallest: NSScrollView?
        while let view = views.popLast() {
            guard !view.isHidden, view.alphaValue > 0 else { continue }

            if let scroll = view as? NSScrollView, let document = scroll.documentView,
               document.frame.height > (tallest?.documentView?.frame.height ?? 0) { tallest = scroll }
            views.append(contentsOf: view.subviews)
        }
        return tallest
    }

    static func scrollEndpoints(_ scroll: NSScrollView) -> (top: CGFloat, bottom: CGFloat)? {
        guard let document = scroll.documentView else { return nil }

        let clip = scroll.contentView
        let bounds = clip.bounds
        let rect = clip.documentRect
        let low = clip.constrainBoundsRect(bounds.offsetBy(dx: 0, dy: rect.minY - bounds.maxY - clip.contentInsets.top)).minY
        let high = clip.constrainBoundsRect(bounds.offsetBy(dx: 0, dy: rect.maxY - bounds.minY + clip.contentInsets.bottom)).minY
        return document.isFlipped ? (low, high) : (high, low)
    }

    private static func reportPerformance(_ label: String, _ times: [Double], _ cpu: Double) {
        let sorted = times.sorted()
        print("perf \(label): \(sorted.count) steps, main thread median \(String(format: "%.1f", sorted[sorted.count / 2])) ms, max \(String(format: "%.1f", sorted.last ?? 0)) ms, total \(String(format: "%.0f", sorted.reduce(0, +))) ms, process CPU \(String(format: "%.0f", cpu)) ms")
    }

    private static func scrollPerformance(window: NSWindow, conversation: Bool = false) async {
        flushDisplay(window)
        guard let scroll = tallestScrollView(in: window) else {
            if conversation { conversationPerfFailure("could not find the transcript scroll view") }
            return
        }

        let clip = scroll.contentView
        let cpuStart = cpuMilliseconds()
        let mainStart = mainThreadMilliseconds()
        let wallStart = ContinuousClock.now
        var times: [Double] = []
        for step in 0...80 {
            guard let ends = scrollEndpoints(scroll) else { break }

            let fraction = Double(abs(40 - step)) / 40
            let start = ContinuousClock.now
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: ends.top + (ends.bottom - ends.top) * fraction))
            scroll.reflectScrolledClipView(clip)
            flushDisplay(window)
            times.append(milliseconds(ContinuousClock.now - start))
            if conversation { try? await Task.sleep(for: .milliseconds(5)) } else { await Task.yield() }
            if conversation, step == 40 || step == 80 {
                _ = await waitForConversationDisplay(window: window, label: "scroll endpoint \(step)") {
                    guard let ends = scrollEndpoints(scroll) else { return false }

                    let target = step == 40 ? ends.top : ends.bottom
                    if abs(clip.bounds.minY - target) <= 2 { return true }

                    clip.scroll(to: NSPoint(x: clip.bounds.minX, y: target))
                    scroll.reflectScrolledClipView(clip)
                    return false
                }
            }
        }
        guard !times.isEmpty else { return }

        let label = "\(conversation ? "conversation " : "")scroll bottom to top and back"
        reportPerformance(label, times, cpuMilliseconds() - cpuStart)
        if conversation {
            print("perf conversation scroll sweep: wall \(String(format: "%.1f", milliseconds(ContinuousClock.now - wallStart))) ms, main thread CPU \(String(format: "%.1f", mainThreadMilliseconds() - mainStart)) ms (includes work between steps)")
        }
    }

    @MainActor
    static func measurePerformance(window: NSWindow, store: Store, requestedSteps: [Substring]? = nil) async {
        let rounds = max(UserDefaults.standard.integer(forKey: "snapshotPerfRounds"), 1)
        let height = window.contentLayoutRect.height
        let startWidth = Double(window.contentLayoutRect.width)
        let steps = requestedSteps ?? (UserDefaults.standard.string(forKey: "snapshotPerfSteps") ?? "resize,sidebar,panel").split(separator: ",")
        let sidebarSplit = window.contentView.flatMap(sidebarSplitController)

        func timed(_ action: () -> Void) -> Double {
            let start = ContinuousClock.now
            action()
            flushDisplay(window)
            return milliseconds(ContinuousClock.now - start)
        }
        func sweep(_ label: String, _ widths: [Double]) async {
            try? await Task.sleep(for: .milliseconds(150))
            let cpuStart = cpuMilliseconds()
            var times: [Double] = []
            for width in widths {
                times.append(timed { window.setContentSize(NSSize(width: width, height: height)) })
                await Task.yield()
            }
            try? await Task.sleep(for: .milliseconds(150))
            reportPerformance(label, times, cpuMilliseconds() - cpuStart)
        }
        func toggle(_ label: String, _ action: () -> Void) async {
            try? await Task.sleep(for: .milliseconds(150))
            let cpuStart = cpuMilliseconds()
            var times: [Double] = []
            for _ in 0..<rounds * 2 {
                times.append(timed(action))
                try? await Task.sleep(for: .milliseconds(600))
            }
            reportPerformance(label, times, cpuMilliseconds() - cpuStart)
        }

        print("perf setup: sidebar split controller \(sidebarSplit == nil ? "not found" : "found")")
        for step in (UserDefaults.standard.string(forKey: "snapshotPerfSetup") ?? "").split(separator: ",") {
            if step == "closeDiff" { store.closeDiff() }
            if step == "hidePanel" { AppAction.hideChanges.perform(on: store) }
            if step == "hideSessions" { sidebarSplit?.toggleSidebar(nil) }
            try? await Task.sleep(for: .seconds(1))
        }

        if steps.contains("resize") {
            let wide = Array(stride(from: startWidth, through: 900, by: -(startWidth - 900) / 24))
            await sweep("resize \(Int(startWidth)) to 900 (live resize steps, 25 widths)", wide)
            await sweep("resize 900 to \(Int(startWidth)) (25 widths)", wide.reversed())
            await sweep("resize across the 801 pt sidebar yield (1100 to 1000 in 2 pt steps)", Array(stride(from: 1100.0, through: 1000, by: -2)))
            window.setContentSize(NSSize(width: startWidth, height: height))
        }
        if steps.contains("scroll") { await scrollPerformance(window: window) }
        for step in ["refresh", "live"] where steps.contains(Substring(step)) {
            flushDisplay(window)
            try? await Task.sleep(for: .milliseconds(300))
            let ticks = rounds * 10
            var costs: [Double] = []
            for _ in 0..<ticks {
                let mainStart = mainThreadMilliseconds()
                if step == "refresh" { store.refresh(); await store.waitForScan() } else { store.refreshLive() }
                try? await Task.sleep(for: .milliseconds(100))
                costs.append(mainThreadMilliseconds() - mainStart)
            }
            costs.sort()
            print("perf store \(step): \(ticks) ticks, main thread CPU per tick median \(String(format: "%.2f", costs[ticks / 2])) ms, min \(String(format: "%.2f", costs[0])) ms")
        }
        if steps.contains("layout") {
            let calls = rounds * 10
            var start = mainThreadMilliseconds()
            for _ in 0..<calls { _ = store.sidebarLayout }
            let layout = (mainThreadMilliseconds() - start) / Double(calls)
            start = mainThreadMilliseconds()
            for _ in 0..<calls { _ = store.sidebarOrderedTabs }
            let ordered = (mainThreadMilliseconds() - start) / Double(calls)
            print("perf store layout: \(calls) calls, sidebarLayout \(String(format: "%.2f", layout)) ms, sidebarOrderedTabs \(String(format: "%.2f", ordered)) ms")
        }
        if steps.contains("sidebar") {
            await toggle("toggle session sidebar (\(rounds * 2) toggles)") { sidebarSplit?.toggleSidebar(nil) }
        }
        if steps.contains("panel") {
            await toggle("toggle Review panel (\(rounds * 2) toggles)") {
                (AppAction.hideChanges.isAvailable(in: store) ? AppAction.hideChanges : .showChanges).perform(on: store)
            }
        }
    }

    private static let conversationSignposter = OSSignposter(subsystem: "com.berth.snapshot", category: "Conversation Performance")

    private static func waitForConversation(_ label: String, until ready: () -> Bool) async -> ContinuousClock.Instant {
        let deadline = ContinuousClock.now + .seconds(30)
        while !ready() {
            guard ContinuousClock.now < deadline else { conversationPerfFailure("timed out waiting for \(label)") }

            try? await Task.sleep(for: .milliseconds(5))
        }
        return .now
    }

    private static func waitForConversationDisplay(window: NSWindow, label: String, until ready: () -> Bool) async -> ContinuousClock.Instant {
        try? await Task.sleep(for: .milliseconds(5))
        return await waitForConversation(label) {
            flushDisplay(window)
            return ready()
        }
    }

    private static func reportConversation(_ label: String, start: ContinuousClock.Instant, model: ContinuousClock.Instant, display: ContinuousClock.Instant, mainStart: Double) {
        let wall = milliseconds(display - start)
        let modelWall = milliseconds(model - start)
        let main = mainThreadMilliseconds() - mainStart
        print("perf conversation \(label): wall \(String(format: "%.1f", wall)) ms, model \(String(format: "%.1f", modelWall)) ms, main thread CPU \(String(format: "%.1f", main)) ms")
    }

    static func measureConversationPerformance(store: Store, tab: Tab, window: NSWindow, canStream: Bool) async {
        let defaults = UserDefaults.standard
        let defaultSteps = heavyConversationTurns > 0 ? "switch,stream,scroll" : "resize,sidebar,panel"
        let steps = (defaults.string(forKey: "snapshotPerfSteps") ?? defaultSteps).split(separator: ",")
        let rounds = steps.contains("switch") ? max(defaults.integer(forKey: "snapshotPerfRounds"), 1) : 0
        for index in 0...rounds {
            if index > 0 {
                AppAction.showTerminal.perform(on: store)
                _ = await waitForConversationDisplay(window: window, label: "terminal") {
                    tab.terminal.isSurfaceVisible && store.conversationModels[tab.id] == nil
                }
            }
            let label = index == 0 ? "switch cold" : "switch reopen \(index)"
            let interval = conversationSignposter.beginInterval("Show Conversation", id: conversationSignposter.makeSignpostID(), "\(label)")
            let mainStart = mainThreadMilliseconds()
            let start = ContinuousClock.now
            AppAction.showConversation.perform(on: store)
            let model = await waitForConversation("loaded turns") {
                guard let model = store.conversationModels[tab.id] else { return false }

                return model.hasLoaded && !model.turns.isEmpty
            }
            let display = await waitForConversationDisplay(window: window, label: "conversation visible at bottom") {
                guard store.selectedConversationIsVisible, !tab.terminal.isSurfaceVisible,
                      let scroll = tallestScrollView(in: window), let ends = scrollEndpoints(scroll) else { return false }

                let hasScrollableHistory = abs(ends.top - ends.bottom) > 2
                return (heavyConversationTurns == 0 || hasScrollableHistory) && abs(scroll.contentView.bounds.minY - ends.bottom) <= 2
            }
            conversationSignposter.endInterval("Show Conversation", interval)
            reportConversation(label, start: start, model: model, display: display, mainStart: mainStart)
        }

        guard let model = store.conversationModels[tab.id] else { conversationPerfFailure("conversation model is missing") }

        let images = model.turns.reduce(0) { $0 + ($1.prompt?.images?.count ?? 0) }
        print("perf conversation loaded: \(model.turns.count) turns, \(model.entryCount) entries, \(images) prompt images")
        if steps.contains("stream") {
            guard canStream else { conversationPerfFailure("stream requires the Claude conversation fixture") }

            do { try await measureConversationStream(model: model, window: window) } catch { conversationPerfFailure("stream fixture: \(error)") }
        }
        if steps.contains("scroll") { await scrollPerformance(window: window, conversation: true) }
        let otherSteps = steps.filter { ["resize", "sidebar", "panel"].contains($0) }
        if !otherSteps.isEmpty { await measurePerformance(window: window, store: store, requestedSteps: otherSteps) }
    }

    private static func measureConversationStream(model: ConversationModel, window: NSWindow) async throws {
        let transcript = conversationTranscript.resolvingSymlinksInPath()
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              transcript.path.hasPrefix(URL(filePath: home).resolvingSymlinksInPath().path + "/.claude/projects/") else {
            conversationPerfFailure("stream requires a transcript inside the fixture home")
        }

        let handle = try FileHandle(forWritingTo: transcript)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let isWatching = model.isWatchingTranscript
        print("perf conversation stream source: \(isWatching ? "FSEvents" : "explicit refresh (FSEvents unavailable)")")

        func append(_ label: String, type: String = "assistant", block: [String: Any], matches: (Turn) -> Bool) async throws {
            let data = try conversationRecord(id: "perf-stream-\(model.entryCount)", type: type, date: .now, blocks: [block])
            let entryCount = model.entryCount
            let interval = conversationSignposter.beginInterval("Transcript Append", id: conversationSignposter.makeSignpostID(), "\(label)")
            let mainStart = mainThreadMilliseconds()
            let start = ContinuousClock.now
            try handle.write(contentsOf: data)
            model.refresh()
            let reflected = await waitForConversation(label) {
                model.entryCount == entryCount + 1 && model.turns.last.map(matches) == true
            }
            let display = await waitForConversationDisplay(window: window, label: "\(label) display") {
                tallestScrollView(in: window) != nil
            }
            conversationSignposter.endInterval("Transcript Append", interval)
            reportConversation(label, start: start, model: reflected, display: display, mainStart: mainStart)
        }

        let prompt = "Verify one more invented batch and show the export result."
        try await append("stream prompt", type: "user", block: ["type": "text", "text": prompt]) { $0.prompt?.text == prompt }
        let reply = heavyConversationReply(turn: heavyConversationTurns + 1)
        for length in [480, 1500, reply.count] {
            let text = String(reply.prefix(length))
            try await append("stream reply \(text.count) chars", block: ["type": "text", "text": text]) { turn in
                guard case let .reply(entry)? = turn.parts.last else { return false }

                return entry.text == text
            }
        }
        let toolID = "perf-stream-bash"
        let tool: [String: Any] = ["type": "tool_use", "id": toolID, "name": "Bash", "input": ["command": "swift test --filter LedgerExportTests"]]
        try await append("stream tool_use", block: tool) { $0.openCall?.use.toolID == toolID }
        let result = "Executed 12 tests, with 0 failures."
        try await append("stream tool_result", type: "user", block: ["type": "tool_result", "tool_use_id": toolID, "content": result]) { turn in
            guard case let .work(calls)? = turn.parts.last, let call = calls.last else { return false }

            return call.use.toolID == toolID && call.result?.text == result
        }
    }
}
#endif
