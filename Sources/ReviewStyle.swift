import AppKit
import SwiftUI

enum ReviewColorScheme: String, CaseIterable {
    case oneDark, oneLight, gitHubDark, gitHubLight, terminal

    var title: String {
        if self == .oneDark { return "One Dark" }
        if self == .oneLight { return "One Light" }
        if self == .gitHubDark { return "GitHub Dark" }
        if self == .gitHubLight { return "GitHub Light" }
        return "Match Terminal"
    }
}

struct ReviewStyle: Equatable {
    static let colorSchemeKey = "reviewColorScheme"
    static let fontFamilyKey = "reviewFontFamily"
    static let fontSizeKey = "reviewFontSize"
    static let lineHeightKey = "reviewLineHeight"
    static let showsMinimapKey = "reviewShowsMinimap"
    static let monospacedFamilies = Set((NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []).compactMap { NSFont(name: $0, size: 12)?.familyName }).sorted()

    private struct Syntax: Equatable {
        let keyword: NSColor
        let string: NSColor
        let number: NSColor
        let type: NSColor
        let function: NSColor
        let property: NSColor
        let tag: NSColor
        let `operator`: NSColor
        let comment: NSColor
    }

    let isDark: Bool
    let font: NSFont
    let lineHeight: CGFloat
    let background: NSColor
    let foreground: NSColor
    let secondary: NSColor
    let gutterForeground: NSColor
    let currentLineNumber: NSColor
    let selection: NSColor
    let removedLine: NSColor
    let addedLine: NSColor
    let removedWord: NSColor
    let addedWord: NSColor
    let filler: NSColor
    let commentBackground: NSColor
    let commentBorder: NSColor
    private let commentFont: NSFont
    private let syntax: Syntax

    init(scheme: ReviewColorScheme, fontFamily: String, fontSize: Double, lineHeightMultiple: Double, ghostty: GhosttyTheme) {
        let size = fontSize > 0 ? fontSize : ghostty.font.pointSize
        let font = (fontFamily.isEmpty ? nil : NSFontManager.shared.font(withFamily: fontFamily, traits: [], weight: 5, size: size)) ?? ghostty.font.withSize(size)
        let lineHeight = ((font.ascender - font.descender + font.leading) * lineHeightMultiple).rounded(.up)
        let hex = { (rgba: UInt32) in NSColor(srgbRed: CGFloat(rgba >> 24) / 255, green: CGFloat(rgba >> 16 & 0xFF) / 255, blue: CGFloat(rgba >> 8 & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255) }

        if scheme == .oneDark {
            self.init(
                isDark: true, font: font, lineHeight: lineHeight, italicComments: true,
                background: hex(0x282C34FF), foreground: hex(0xABB2BFFF), gutterForeground: hex(0x495162FF), selection: hex(0x67769660),
                removedLine: hex(0x9A353D40), addedLine: hex(0x10986833), removedWord: hex(0x9A353D80), addedWord: hex(0x10986866),
                syntax: Syntax(keyword: hex(0xC678DDFF), string: hex(0x98C379FF), number: hex(0xD19A66FF), type: hex(0xE5C07BFF), function: hex(0x61AFEFFF), property: hex(0xE06C75FF), tag: hex(0xE06C75FF), operator: hex(0x56B6C2FF), comment: hex(0x5C6370FF))
            )
            return
        }
        if scheme == .oneLight {
            self.init(
                isDark: false, font: font, lineHeight: lineHeight, italicComments: true,
                background: hex(0xFAFAFAFF), foreground: hex(0x383A42FF), gutterForeground: hex(0x9D9D9FFF), selection: hex(0xE5E5E6FF),
                removedLine: hex(0xE4564926), addedLine: hex(0x50A14F26), removedWord: hex(0xE456494D), addedWord: hex(0x50A14F4D),
                syntax: Syntax(keyword: hex(0xA626A4FF), string: hex(0x50A14FFF), number: hex(0x986801FF), type: hex(0xC18401FF), function: hex(0x4078F2FF), property: hex(0xE45649FF), tag: hex(0xE45649FF), operator: hex(0x0184BCFF), comment: hex(0xA0A1A7FF))
            )
            return
        }
        if scheme == .gitHubDark {
            self.init(
                isDark: true, font: font, lineHeight: lineHeight, italicComments: false,
                background: hex(0x0D1117FF), foreground: hex(0xE6EDF3FF), gutterForeground: hex(0x6E7681FF), selection: hex(0x264F78FF),
                removedLine: hex(0xDA363326), addedLine: hex(0x23863626), removedWord: hex(0xFF7B724D), addedWord: hex(0x3FB9504D),
                syntax: Syntax(keyword: hex(0xFF7B72FF), string: hex(0xA5D6FFFF), number: hex(0x79C0FFFF), type: hex(0xFFA657FF), function: hex(0xD2A8FFFF), property: hex(0x79C0FFFF), tag: hex(0x7EE787FF), operator: hex(0xFF7B72FF), comment: hex(0x8B949EFF))
            )
            return
        }
        if scheme == .gitHubLight {
            self.init(
                isDark: false, font: font, lineHeight: lineHeight, italicComments: false,
                background: hex(0xFFFFFFFF), foreground: hex(0x1F2328FF), gutterForeground: hex(0x8C959FFF), selection: hex(0xADD6FFFF),
                removedLine: hex(0xFFCECB4D), addedLine: hex(0xACEEBB4D), removedWord: hex(0xFF818266), addedWord: hex(0x6FDD8B80),
                syntax: Syntax(keyword: hex(0xCF222EFF), string: hex(0x0A3069FF), number: hex(0x0550AEFF), type: hex(0x953800FF), function: hex(0x8250DFFF), property: hex(0x0550AEFF), tag: hex(0x116329FF), operator: hex(0xCF222EFF), comment: hex(0x6E7781FF))
            )
            return
        }
        self.init(
            isDark: ghostty.isDark, font: font, lineHeight: lineHeight, italicComments: false,
            background: ghostty.background.map(NSColor.init) ?? .textBackgroundColor, foreground: NSColor(ghostty.foreground), gutterForeground: NSColor(ghostty.secondary), selection: NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35),
            removedLine: NSColor(ghostty.closed).withAlphaComponent(0.2), addedLine: NSColor(ghostty.working).withAlphaComponent(0.2), removedWord: NSColor(ghostty.closed).withAlphaComponent(0.35), addedWord: NSColor(ghostty.working).withAlphaComponent(0.35),
            syntax: Syntax(keyword: NSColor(ghostty.merged), string: NSColor(ghostty.working), number: NSColor(ghostty.needsYou), type: NSColor(ghostty.branch), function: NSColor(ghostty.unread), property: NSColor(ghostty.closed), tag: NSColor(ghostty.branch), operator: NSColor(ghostty.foreground), comment: NSColor(ghostty.secondary))
        )
    }

    private init(isDark: Bool, font: NSFont, lineHeight: CGFloat, italicComments: Bool, background: NSColor, foreground: NSColor, gutterForeground: NSColor, selection: NSColor, removedLine: NSColor, addedLine: NSColor, removedWord: NSColor, addedWord: NSColor, syntax: Syntax) {
        self.isDark = isDark
        self.font = font
        self.lineHeight = lineHeight
        self.background = background
        self.foreground = foreground
        self.gutterForeground = gutterForeground
        secondary = foreground.withAlphaComponent(0.6)
        currentLineNumber = foreground
        self.selection = selection
        self.removedLine = removedLine
        self.addedLine = addedLine
        self.removedWord = removedWord
        self.addedWord = addedWord
        filler = foreground.withAlphaComponent(0.05)
        commentBackground = foreground.withAlphaComponent(0.06)
        commentBorder = foreground.withAlphaComponent(0.15)
        commentFont = italicComments ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) : font
        self.syntax = syntax
    }

    func color(forCapture capture: String) -> NSColor {
        let kind = String(capture.prefix { $0 != "." })
        if kind == "comment" { return syntax.comment }
        if ["operator", "escape"].contains(kind) || ["string.escape", "string.regexp"].contains(capture) { return syntax.operator }
        if ["property", "attribute"].contains(kind) || ["string.special.key", "variable.member"].contains(capture) { return syntax.property }
        if kind == "tag" { return syntax.tag }
        if ["keyword", "charset", "import", "keyframes", "media", "namespace", "supports"].contains(kind) || capture == "text.title" { return syntax.keyword }
        if ["string", "character"].contains(kind) || capture == "text.literal" { return syntax.string }
        if ["number", "boolean", "constant"].contains(kind) { return syntax.number }
        if ["type", "constructor"].contains(kind) { return syntax.type }
        if kind == "function" || ["text.uri", "text.reference"].contains(capture) { return syntax.function }
        return foreground
    }

    func font(forCapture capture: String) -> NSFont {
        capture.hasPrefix("comment") ? commentFont : font
    }
}
