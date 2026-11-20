#if DEBUG
import AppKit
import SwiftUI

extension Snapshot {
    private static func cpuMilliseconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let seconds = { (time: timeval) in Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return (seconds(usage.ru_utime) + seconds(usage.ru_stime)) * 1000
    }

    private static func sidebarSplitController(in view: NSView) -> NSSplitViewController? {
        let controller = (view as? NSSplitView)?.delegate as? NSSplitViewController
        if let controller, controller.splitViewItems.contains(where: { $0.behavior == .sidebar }) { return controller }

        return view.subviews.lazy.compactMap(sidebarSplitController).first
    }

    @MainActor
    static func measurePerformance(window: NSWindow, store: Store) async {
        let rounds = max(UserDefaults.standard.integer(forKey: "snapshotPerfRounds"), 1)
        let height = window.contentLayoutRect.height
        let startWidth = Double(window.contentLayoutRect.width)
        let steps = (UserDefaults.standard.string(forKey: "snapshotPerfSteps") ?? "resize,sidebar,panel").split(separator: ",")
        let sidebarSplit = window.contentView.flatMap(sidebarSplitController)

        func report(_ label: String, _ milliseconds: [Double], _ cpu: Double) {
            let sorted = milliseconds.sorted()
            print("perf \(label): \(sorted.count) steps, main thread median \(String(format: "%.1f", sorted[sorted.count / 2])) ms, max \(String(format: "%.1f", sorted.last ?? 0)) ms, total \(String(format: "%.0f", sorted.reduce(0, +))) ms, process CPU \(String(format: "%.0f", cpu)) ms")
        }
        func timed(_ action: () -> Void) -> Double {
            let start = ContinuousClock.now
            action()
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            let elapsed = (ContinuousClock.now - start).components
            return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
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
            report(label, times, cpuMilliseconds() - cpuStart)
        }
        func toggle(_ label: String, _ action: () -> Void) async {
            try? await Task.sleep(for: .milliseconds(150))
            let cpuStart = cpuMilliseconds()
            var times: [Double] = []
            for _ in 0..<rounds * 2 {
                times.append(timed(action))
                try? await Task.sleep(for: .milliseconds(600))
            }
            report(label, times, cpuMilliseconds() - cpuStart)
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
        if steps.contains("sidebar") {
            await toggle("toggle session sidebar (\(rounds * 2) toggles)") { sidebarSplit?.toggleSidebar(nil) }
        }
        if steps.contains("panel") {
            await toggle("toggle Review panel (\(rounds * 2) toggles)") {
                (AppAction.hideChanges.isAvailable(in: store) ? AppAction.hideChanges : .showChanges).perform(on: store)
            }
        }
    }
}
#endif
