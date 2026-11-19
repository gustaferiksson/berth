import Foundation
import Observation

@Observable
final class UpdateCheck {
    private static let manifestURL = URL(string: "https://gustaferiksson.github.io/berth/manifest.plist")!
    static let installURL = URL(string: "itms-services://?action=download-manifest&url=\(manifestURL.absoluteString)")!
    private static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    private(set) var available: String?
    @ObservationIgnored private var lastCheck: Date?

    func checkIfDue() async {
        #if DEBUG
        available = UserDefaults.standard.string(forKey: "snapshotUpdateAvailable")
        #else
        guard available == nil, !Self.currentVersion.hasSuffix("-local") else { return }

        if let lastCheck, Date.now.timeIntervalSince(lastCheck) < 24 * 60 * 60 { return }

        let request = URLRequest(url: Self.manifestURL, cachePolicy: .reloadIgnoringLocalCacheData)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let items = plist["items"] as? [[String: Any]],
              let metadata = items.first?["metadata"] as? [String: Any],
              let latest = metadata["bundle-version"] as? String
        else { return }

        lastCheck = .now
        available = latest.compare(Self.currentVersion, options: .numeric) == .orderedDescending ? latest : nil
        #endif
    }
}
