import BerthCore
import Foundation

extension Store {
    func refreshPullRequestWatches() {
        if watchScan != nil {
            watchScanRequested = true
            return
        }
        let live = liveBySession.values.filter { sessionsByID[$0.sessionId]?.agent != .codex }
        guard !live.isEmpty || !transcriptWatches.isEmpty || !watchActivities.isEmpty else { return }

        watchScan = Task { [self] in
            let (activities, watches) = await Task.detached { [index, watchActivities] in
                var activities: [String: (url: URL, activity: TranscriptActivity)] = [:]
                var watches: [String: PullRequestWatch] = [:]
                for session in live {
                    guard let url = index.url(ofSession: session.sessionId) else { continue }

                    var activity = watchActivities[session.sessionId].flatMap { $0.url == url ? $0.activity : nil } ?? TranscriptActivity(watchOnly: true)
                    activity.read(url)
                    activities[session.sessionId] = (url, activity)
                    watches[session.sessionId] = activity.pullRequestWatch(of: session, now: .now)
                }
                return (activities, watches)
            }.value
            watchActivities = activities
            if transcriptWatches != watches { transcriptWatches = watches }
            watchExpiry?.cancel()
            if let expiry = watches.values.map(\.expiresAt).min() {
                watchExpiry = Task { [weak self] in
                    guard await (try? Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow)))) != nil else { return }

                    self?.refreshPullRequestWatches()
                }
            }
            watchScan = nil
            if watchScanRequested {
                watchScanRequested = false
                refreshPullRequestWatches()
            }
        }
    }

    func stopWatching(_ sessionID: String) async -> InputOutcome {
        guard pullRequestWatch(for: sessionID) != nil, tab(forSession: sessionID) != nil, liveBySession[sessionID] != nil else {
            return .refused("Open the running Claude session to stop watching")
        }

        return await submit("/ship stop", files: [], to: sessionID)
    }
}
