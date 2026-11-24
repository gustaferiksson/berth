import Foundation

extension CodexUsage {
    static let rolloutsRead = 8
    static let tailBytes = 256 * 1024

    public static func latest(in codexRoot: URL) -> Self? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let recent = (FileManager.default.enumerator(at: codexRoot.appending(path: "sessions"), includingPropertiesForKeys: keys)?
            .compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-") }
            .compactMap { url -> (url: URL, modified: Date)? in
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true, let modified = values.contentModificationDate else { return nil }

                return (url, modified)
            }
            .sorted { $0.modified > $1.modified }
            .prefix(rolloutsRead)
        return recent.compactMap { record(in: $0.url) }.max { $0.recordedAt < $1.recordedAt }
    }

    static func record(in url: URL) -> Self? {
        guard let handle = try? FileHandle(forReadingFrom: url), let size = try? handle.seekToEnd() else { return nil }

        defer { try? handle.close() }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }

        let marker = Data("\"rate_limits\"".utf8)
        return data.split(separator: UInt8(ascii: "\n"))
            .reversed()
            .lazy
            .filter { $0.range(of: marker) != nil }
            .compactMap { parse(Data($0)) }
            .first
    }

    static func parse(_ line: Data) -> Self? {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              root["type"] as? String == "event_msg",
              let payload = root["payload"] as? [String: Any], payload["type"] as? String == "token_count",
              let limits = payload["rate_limits"] as? [String: Any],
              let recordedAt = (root["timestamp"] as? String).flatMap(CodexRollout.date)
        else { return nil }

        let windows = ["primary", "secondary"].compactMap { key -> UsageWindow? in
            guard let window = limits[key] as? [String: Any],
                  let percent = (window["used_percent"] as? NSNumber)?.doubleValue,
                  let minutes = (window["window_minutes"] as? NSNumber)?.doubleValue, minutes > 0
            else { return nil }

            let resetsAt = (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                ?? (window["resets_in_seconds"] as? NSNumber).map { recordedAt.addingTimeInterval($0.doubleValue) }
            return UsageWindow(id: "codex_\(key)", title: title(minutes: Int(minutes)), length: minutes * 60, used: percent / 100, resetsAt: resetsAt)
        }
        .sorted { $0.length < $1.length }
        return windows.isEmpty ? nil : Self(usage: PlanUsage(windows: windows), recordedAt: recordedAt)
    }

    static func title(minutes: Int) -> String {
        if minutes == 300 { return "Session" }
        if minutes == 10_080 { return "Week" }
        return minutes.isMultiple(of: 1440) ? "\(minutes / 1440)d" : "\(max(minutes / 60, 1))h"
    }
}
