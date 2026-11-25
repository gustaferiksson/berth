import SwiftUI

enum PillKind {
    case pullRequest
    case issue

    var shape: AnyShape {
        self == .pullRequest ? AnyShape(.rect(cornerRadius: 4)) : AnyShape(.capsule)
    }
}
