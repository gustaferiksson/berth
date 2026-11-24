import SwiftUI

private extension UIColor {
    nonisolated convenience init(light: UInt32, dark: UInt32) {
        self.init { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        }
    }
}

nonisolated enum SyntaxPalette {
    static let keyword = UIColor(light: 0xCF222E, dark: 0xC678DD)
    static let string = UIColor(light: 0x0A3069, dark: 0x98C379)
    static let number = UIColor(light: 0x0550AE, dark: 0xD19A66)
    static let type = UIColor(light: 0x953800, dark: 0xE5C07B)
    static let function = UIColor(light: 0x8250DF, dark: 0x61AFEF)
    static let property = UIColor(light: 0x0550AE, dark: 0xE06C75)
    static let tag = UIColor(light: 0x116329, dark: 0xE06C75)
    static let `operator` = UIColor(light: 0xCF222E, dark: 0x56B6C2)
    static let warning = UIColor(light: 0x953800, dark: 0xE5C07B)
    static let critical = UIColor(light: 0xCF222E, dark: 0xE06C75)
    static let comment = UIColor(light: 0x6E7781, dark: 0x5C6370)
    static let variable = UIColor(light: 0x1F2328, dark: 0xE06C75)
    static let constant = UIColor(light: 0x0550AE, dark: 0xE5C07B)
    static let regexp = UIColor(light: 0x0A3069, dark: 0xE06C75)
    static let brackets = [UIColor(light: 0x0550AE, dark: 0xD19A66), UIColor(light: 0xCF222E, dark: 0xC678DD), UIColor(light: 0x8250DF, dark: 0x56B6C2)]

    static func color(forCapture capture: String) -> UIColor? {
        let kind = String(capture.prefix { $0 != "." })
        if kind == "comment" { return comment }
        if capture == "string.regexp" { return regexp }
        if capture.hasPrefix("punctuation.bracket."), let depth = Int(capture.suffix(1)), brackets.indices.contains(depth) { return brackets[depth] }
        if ["operator", "escape"].contains(kind) || capture == "string.escape" { return `operator` }
        if ["property", "attribute"].contains(kind) || ["string.special.key", "variable.member"].contains(capture) { return property }
        if kind == "tag" { return tag }
        if ["keyword", "charset", "import", "keyframes", "media", "namespace", "supports"].contains(kind) || capture == "text.title" { return keyword }
        if ["string", "character"].contains(kind) || capture == "text.literal" { return string }
        if ["constant", "variable.builtin"].contains(capture) { return constant }
        if ["number", "boolean", "constant"].contains(kind) { return number }
        if ["variable", "variable.parameter"].contains(capture) { return variable }
        if ["type", "constructor"].contains(kind) { return type }
        if kind == "function" || ["text.uri", "text.reference"].contains(capture) { return function }
        return nil
    }
}
