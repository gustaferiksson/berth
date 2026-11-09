import AppKit
import SwiftUI

struct AppearanceSettings: View {
    @Environment(Store.self) private var store
    @AppStorage(GeneralSettings.reviewKey) private var isReviewEnabled = false
    @AppStorage(ReviewStyle.colorSchemeKey) private var reviewColorScheme = ReviewColorScheme.oneDark
    @AppStorage(ReviewStyle.fontFamilyKey) private var reviewFontFamily = ""
    @AppStorage(ReviewStyle.fontSizeKey) private var reviewFontSize = 0.0
    @AppStorage(ReviewStyle.lineHeightKey) private var reviewLineHeight = 1.3
    @AppStorage(ReviewStyle.showsMinimapKey) private var reviewShowsMinimap = true

    var body: some View {
        let configFile = GhosttyConfig.configFiles.last
        let style = ReviewStyle(scheme: reviewColorScheme, fontFamily: reviewFontFamily, fontSize: reviewFontSize, lineHeightMultiple: reviewLineHeight, ghostty: store.theme)
        Form {
            Section {
                LabeledContent("Config", value: configFile.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "None")
                LabeledContent("Theme", value: GhosttyConfig.themeName ?? "Default")
                if let configFile {
                    HStack {
                        Spacer()
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: configFile)])
                        }
                    }
                }
            } header: {
                Text("Ghostty")
            } footer: {
                Text("Berth takes its colours and terminal settings from your Ghostty config. Edits apply right away.")
            }
            if isReviewEnabled {
                Section {
                    Picker("Color Scheme", selection: $reviewColorScheme) {
                        ForEach(ReviewColorScheme.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Font", selection: $reviewFontFamily) {
                        Text("Terminal Font").tag("")
                        Divider()
                        ForEach(ReviewStyle.monospacedFamilies, id: \.self) { Text($0).tag($0) }
                    }
                    LabeledContent("Size") {
                        Stepper("\(Int(style.font.pointSize)) pt", value: Binding(get: { Double(style.font.pointSize) }, set: { reviewFontSize = $0 }), in: 9...24)
                    }
                    LabeledContent("Line Height") {
                        Stepper(reviewLineHeight.formatted(.number.precision(.fractionLength(1))), value: $reviewLineHeight, in: 1...2, step: 0.1)
                    }
                    Toggle("Show minimap", isOn: $reviewShowsMinimap)
                    ReviewStylePreview(style: style)
                } header: {
                    Text("Review")
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: isReviewEnabled ? 640 : 260)
    }
}

private struct ReviewStylePreview: View {
    let style: ReviewStyle

    private static let sample = #"""
        func greet(_ name: String) -> String {
            // Say hello
            let greeting = "Hi"
            let greeting = "Hello, \(name)!"
            return greeting.uppercased()
        }
        """#
    private static let lines = sample.split(separator: "\n").map { NSRange($0.startIndex..<$0.endIndex, in: sample) }
    private static let numbers = ["1", "2", "3", "3", "4", "5"]
    private static let spans = ReviewHighlighter.spans(in: sample, path: "preview.swift")

    var body: some View {
        var code = AttributedString(Self.sample)
        code.font = Font(style.font)
        code.foregroundColor = Color(nsColor: style.foreground)
        for span in Self.spans {
            guard let range = Range(span.range, in: code) else { continue }
            code[range].foregroundColor = Color(nsColor: style.color(forCapture: span.capture))
            code[range].font = Font(style.font(forCapture: span.capture))
        }
        for (word, color) in [("\"Hi\"", style.removedWord), (#""Hello, \(name)!""#, style.addedWord)] {
            guard let range = code.range(of: word) else { continue }
            code[range].backgroundColor = Color(nsColor: color)
        }

        return VStack(spacing: 0) {
            ForEach(Self.lines.indices, id: \.self) { index in
                HStack(spacing: 12) {
                    Text(Self.numbers[index])
                        .font(Font(style.font))
                        .foregroundStyle(Color(nsColor: style.gutterForeground))
                        .frame(width: 20, alignment: .trailing)
                    Text(Range(Self.lines[index], in: code).map { AttributedString(code[$0]) } ?? "")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: style.lineHeight)
                .background(Color(nsColor: index == 2 ? style.removedLine : index == 3 ? style.addedLine : .clear))
            }
        }
        .padding(.vertical, 8)
        .background(Color(nsColor: style.background), in: .rect(cornerRadius: 6))
    }
}
