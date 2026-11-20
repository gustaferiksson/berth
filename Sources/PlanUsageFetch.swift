import BerthCore
import Foundation

nonisolated enum PlanUsageFetch {
    static let enabledKey = "showsPlanUsage"

    static func fetch() async -> PlanUsage? {
        guard let token = accessToken() else { return nil }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }

        return PlanUsage.parse(data)
    }

    private static func accessToken() -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let credentials = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = credentials["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { return nil }

        if let expiresAt = (oauth["expiresAt"] as? NSNumber)?.doubleValue, Date(timeIntervalSince1970: expiresAt / 1000) <= .now { return nil }
        return token
    }
}
