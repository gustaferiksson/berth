import SwiftUI

enum AgentTint {
    private static let palette: [Color] = [.blue, .indigo, .purple, .pink, .orange, .teal, .mint, .cyan]

    static func color(for title: String) -> Color {
        let hash = title.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }

        return palette[Int(hash % UInt32(palette.count))]
    }
}
