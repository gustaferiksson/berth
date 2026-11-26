import AppKit
import SwiftUI

enum ConversationBodyFont: String, CaseIterable {
    case system, monospaced, custom
}

enum ConversationLineSpacing: String, CaseIterable {
    case compact, normal, comfortable, relaxed, spacious

    var multiple: CGFloat {
        switch self {
        case .compact: 0.9
        case .normal: 1
        case .comfortable: 1.15
        case .relaxed: 1.3
        case .spacious: 1.45
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

struct ConversationTypeset: Equatable {
    var bodyFont: ConversationBodyFont
    var bodyFamily: String
    var bodySize: Double
    var lineSpacing: ConversationLineSpacing
    var width: ConversationWidth

    static let standard = ConversationStyle.clean.typeset
}

enum ConversationStyle: String, CaseIterable {
    case clean, spacious, reading, terminal

    var title: String {
        switch self {
        case .clean: "Clean"
        case .spacious: "Spacious"
        case .reading: "Reading"
        case .terminal: "Terminal"
        }
    }

    var typeset: ConversationTypeset {
        switch self {
        case .clean: ConversationTypeset(bodyFont: .system, bodyFamily: "", bodySize: 16, lineSpacing: .relaxed, width: .narrow)
        case .spacious: ConversationTypeset(bodyFont: .system, bodyFamily: "", bodySize: 17, lineSpacing: .spacious, width: .narrow)
        case .reading: ConversationTypeset(bodyFont: .custom, bodyFamily: "Charter", bodySize: 17, lineSpacing: .relaxed, width: .narrow)
        case .terminal: ConversationTypeset(bodyFont: .monospaced, bodyFamily: "", bodySize: 0, lineSpacing: .normal, width: .normal)
        }
    }
}

enum ConversationTypography {
    static let bodyFontKey = "conversationBodyFont"
    static let bodyFamilyKey = "conversationBodyFamily"
    static let bodySizeKey = "conversationBodySize"
    static let lineSpacingKey = "conversationLineSpacing"
    static let widthKey = "conversationMessageWidth"

    static let terminalSize = GhosttyConfig.appliedValues["font-size"].flatMap(Double.init) ?? 13

    static let familyGroups: [(title: String, families: [String])] = {
        let manager = NSFontManager.shared
        let titles = ["Monospaced", "Sans Serif", "Serif", "Other"]
        let kinds = manager.availableFontFamilies.map { family -> (family: String, title: String) in
            let traits = manager.font(withFamily: family, traits: [], weight: 5, size: 12)?.fontDescriptor.symbolicTraits ?? []
            let styleClass = traits.intersection(.classMask).rawValue >> 28
            if traits.contains(.monoSpace) { return (family, titles[0]) }
            if styleClass == 8 { return (family, titles[1]) }
            if (1...7).contains(styleClass) { return (family, titles[2]) }
            return (family, titles[3])
        }
        return titles.map { title in (title, kinds.filter { $0.title == title }.map(\.family)) }.filter { !$0.families.isEmpty }
    }()
}

extension GhosttyTheme {
    var code: ReviewStyle { codeStyle ?? ReviewStyle.stored(ghostty: self) }

    func conversationCodeNSFont(_ delta: Double = 0) -> NSFont {
        NSFont(descriptor: codeFont.fontDescriptor, size: codeFont.pointSize + delta) ?? codeFont
    }

    func typeset(_ typeset: ConversationTypeset, codeStyle: ReviewStyle) -> GhosttyTheme {
        var result = self
        let bodyPoints = typeset.bodySize > 0 ? typeset.bodySize : font.pointSize
        let terminalBody = NSFont(descriptor: font.fontDescriptor, size: bodyPoints) ?? font
        let customBody = NSFontManager.shared.font(withFamily: typeset.bodyFamily, traits: [], weight: 5, size: bodyPoints)
        result.font = switch typeset.bodyFont {
        case .system: .systemFont(ofSize: bodyPoints)
        case .monospaced: terminalBody
        case .custom: customBody ?? terminalBody
        }
        if typeset.bodyFont != .monospaced { result.foreground = foreground.opacity(0.88) }
        result.composerFont = typeset.bodyFont == .monospaced ? .systemFont(ofSize: bodyPoints) : result.font

        result.codeStyle = codeStyle
        result.codeFont = codeStyle.font
        result.lineHeightMultiple = typeset.lineSpacing.multiple
        result.messageWidth = typeset.width.points
        return result
    }
}

private struct ConversationTypographyModifier: ViewModifier {
    @Environment(\.ghosttyTheme) private var theme
    @AppStorage(ConversationTypography.bodyFontKey) private var bodyFont = ConversationTypeset.standard.bodyFont
    @AppStorage(ConversationTypography.bodyFamilyKey) private var bodyFamily = ConversationTypeset.standard.bodyFamily
    @AppStorage(ConversationTypography.bodySizeKey) private var bodySize = ConversationTypeset.standard.bodySize
    @AppStorage(ConversationTypography.lineSpacingKey) private var lineSpacing = ConversationTypeset.standard.lineSpacing
    @AppStorage(ConversationTypography.widthKey) private var width = ConversationTypeset.standard.width
    @AppStorage(ReviewStyle.colorSchemeKey) private var reviewScheme = ReviewColorScheme.terminal
    @AppStorage(ReviewStyle.syntaxColorsKey) private var syntaxColors = SyntaxColorSource.terminal
    @AppStorage(ReviewStyle.fontFamilyKey) private var reviewFontFamily = ""
    @AppStorage(ReviewStyle.fontSizeKey) private var reviewFontSize = 0.0
    @AppStorage(ReviewStyle.lineHeightKey) private var reviewLineHeight = 1.3

    func body(content: Content) -> some View {
        let codeStyle = ReviewStyle(scheme: reviewScheme, fontFamily: reviewFontFamily, fontSize: reviewFontSize, lineHeightMultiple: reviewLineHeight, ghostty: theme).withSyntaxColors(syntaxColors)
        content.environment(\.ghosttyTheme, theme.typeset(ConversationTypeset(bodyFont: bodyFont, bodyFamily: bodyFamily, bodySize: bodySize, lineSpacing: lineSpacing, width: width), codeStyle: codeStyle))
    }
}

extension View {
    func conversationTypography() -> some View {
        modifier(ConversationTypographyModifier())
    }
}
