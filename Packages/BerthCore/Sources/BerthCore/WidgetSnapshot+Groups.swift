import Foundation

public extension WidgetSnapshot {
    init(groups: [RemoteGroup]) {
        var seen = Set<String>()
        let waiting = groups.flatMap(\.sessions).filter { $0.status == "waiting" && seen.insert($0.id).inserted }
        self.init(needsYou: waiting.map { Item(id: $0.id, title: $0.title) })
    }
}
