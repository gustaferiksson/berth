#if DEBUG
import BerthCore
import Foundation

extension Snapshot {
    static func preparePalette(store: Store) {
        let defaults = UserDefaults.standard
        let context = defaults.string(forKey: "snapshotPaletteContext").flatMap(PaletteContext.init(rawValue:))
        let query = defaults.string(forKey: "snapshotPalette")
        guard context != nil || query != nil else { return }

        store.paletteContext = context ?? .terminal
        if context == .session, store.sidebarCursor == nil, store.selection == nil, let session = store.activeSessions.first {
            store.sidebarCursor = .session(session.id)
        }
        store.launcherQuery = query ?? ""
        store.launcherMode = .palette
    }
}
#endif
