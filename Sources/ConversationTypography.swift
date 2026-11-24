import AppKit
import SwiftUI

enum ConversationBodyFont: String, CaseIterable {
    case system, monospaced, custom
}

enum ConversationLineSpacing: String, CaseIterable {
    case compact, normal, relaxed

    var multiple: CGFloat {
        switch self {
        case .compact: 0.9
        case .normal: 1
        case .relaxed: 1.3
        }
    }
}

enum ConversationWidth: String, CaseIterable {
    case narrow, normal, full

    var points: CGFloat {
        switch self {
        case .narrow: 680
        case .normal: 860
        case .full: .infinity
        }
    }
}

enum ConversationTypography {
    static let bodyFontKey = "conversationBodyFont"
    static let bodyFamilyKey = "conversationBodyFamily"
    static let bodySizeKey = "conversationBodySize"
    static let lineSpacingKey = "conversationLineSpacing"
    static let codeFamilyKey = "conversationCodeFamily"
    static let codeSizeKey = "conversationCodeSize"
    static let widthKey = "conversationMessageWidth"

    static let terminalSize = GhosttyConfig.appliedValues["font-size"].flatMap(Double.init) ?? 13
}

extension GhosttyTheme {
    func conversationCodeNSFont(_ delta: Double = 0) -> NSFont {
        NSFont(descriptor: codeFont.fontDescriptor, size: codeFont.pointSize + delta) ?? codeFont
    }

    func typeset(bodyFont: ConversationBodyFont, bodyFamily: String, bodySize: Double, lineSpacing: ConversationLineSpacing, codeFamily: String, codeSize: Double, width: ConversationWidth) -> GhosttyTheme {
        var result = self
        let bodyPoints = bodySize > 0 ? bodySize : font.pointSize
        let terminalBody = NSFont(descriptor: font.fontDescriptor, size: bodyPoints) ?? font
        let customBody = NSFontManager.shared.font(withFamily: bodyFamily, traits: [], weight: 5, size: bodyPoints)
        result.font = switch bodyFont {
        case .system: .systemFont(ofSize: bodyPoints)
        case .monospaced: terminalBody
        case .custom: customBody ?? terminalBody
        }
        result.composerFont = bodyFont == .monospaced ? .systemFont(ofSize: bodyPoints) : result.font

        let codePoints = codeSize > 0 ? codeSize : font.pointSize
        result.codeFont = NSFontManager.shared.font(withFamily: codeFamily, traits: [], weight: 5, size: codePoints) ?? NSFont(descriptor: font.fontDescriptor, size: codePoints) ?? font
        result.lineHeightMultiple = lineSpacing.multiple
        result.messageWidth = width.points
        return result
    }
}

private struct ConversationTypographyModifier: ViewModifier {
    @Environment(\.ghosttyTheme) private var theme
    @AppStorage(ConversationTypography.bodyFontKey) private var bodyFont = ConversationBodyFont.monospaced
    @AppStorage(ConversationTypography.bodyFamilyKey) private var bodyFamily = ""
    @AppStorage(ConversationTypography.bodySizeKey) private var bodySize = 0.0
    @AppStorage(ConversationTypography.lineSpacingKey) private var lineSpacing = ConversationLineSpacing.normal
    @AppStorage(ConversationTypography.codeFamilyKey) private var codeFamily = ""
    @AppStorage(ConversationTypography.codeSizeKey) private var codeSize = 0.0
    @AppStorage(ConversationTypography.widthKey) private var width = ConversationWidth.normal

    func body(content: Content) -> some View {
        content.environment(\.ghosttyTheme, theme.typeset(bodyFont: bodyFont, bodyFamily: bodyFamily, bodySize: bodySize, lineSpacing: lineSpacing, codeFamily: codeFamily, codeSize: codeSize, width: width))
    }
}

extension View {
    func conversationTypography() -> some View {
        modifier(ConversationTypographyModifier())
    }
}
