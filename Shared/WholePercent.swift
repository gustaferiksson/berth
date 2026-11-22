import Foundation

struct WholePercent: FormatStyle {
    func format(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

extension FormatStyle where Self == WholePercent {
    static var wholePercent: WholePercent { WholePercent() }
}
