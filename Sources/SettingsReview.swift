import BerthCore
import SwiftUI

struct ReviewSettings: View {
    @Environment(Store.self) private var store
    @AppStorage(GeneralSettings.reviewKey) private var isReviewEnabled = false
    @AppStorage(GeneralSettings.languageServersKey) private var areLanguageServersEnabled = false
    @AppStorage(LanguageServerEntry.storageKey) private var configuredServers = ""
    @State private var editedServer: LanguageServerEntry?
    @AppStorage(ReviewStyle.colorSchemeKey) private var reviewColorScheme = ReviewColorScheme.terminal
    @AppStorage(ReviewStyle.fontFamilyKey) private var reviewFontFamily = ""
    @AppStorage(ReviewStyle.fontSizeKey) private var reviewFontSize = 0.0
    @AppStorage(ReviewStyle.lineHeightKey) private var reviewLineHeight = 1.3
    @AppStorage(ReviewStyle.showsMinimapKey) private var reviewShowsMinimap = true

    var body: some View {
        let style = ReviewStyle(scheme: reviewColorScheme, fontFamily: reviewFontFamily, fontSize: reviewFontSize, lineHeightMultiple: reviewLineHeight, ghostty: store.theme)
        Form {
            Section {
                Toggle("Review changes in Berth", isOn: $isReviewEnabled)
            } header: {
                Text("Review")
            } footer: {
                Text("Experimental. Adds Review Changes (⇧⌘R) to Claude sessions: a diff of the session’s branch and uncommitted work, with line comments sent back to Claude.")
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
                    Text("Diff Style")
                }

                Section {
                    Toggle("Enable language servers", isOn: $areLanguageServersEnabled)
                } header: {
                    Text("Language Servers")
                } footer: {
                    Text("Language servers add go to definition (⌘-click), hover and diagnostics. They and the build scripts they run execute the repository’s code.")
                }
            }
            if isReviewEnabled, areLanguageServersEnabled {
                Section {
                    ForEach(servers) { $server in
                        LabeledContent {
                            Button("Edit…") { editedServer = server }
                            Toggle("Enabled", isOn: $server.isEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        } label: {
                            Text(server.name)
                            Text(([server.command] + server.arguments).joined(separator: " "))
                        }
                    }
                    Button("Add Server…") { editedServer = LanguageServerEntry(name: "", command: "") }
                    let unreadable = LanguageServerEntry.stored(configuredServers).unreadable.count
                    if unreadable > 0 {
                        Label("^[\(unreadable) entry](inflect: true) in languageServers couldn’t be read and won’t run.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Servers")
                } footer: {
                    Text("A server starts in the nearest folder above the file with one of its root markers, or the repository root when it has none. Commands resolve from that folder’s node_modules/.bin, then PATH.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: isReviewEnabled ? 720 : 230)
        .sheet(item: $editedServer) { LanguageServerEditor(server: $0, servers: servers) }
    }

    private var servers: Binding<[LanguageServerEntry]> {
        Binding {
            LanguageServerEntry.configured(configuredServers)
        } set: { entries in
            configuredServers = LanguageServerEntry.storage(entries, keeping: LanguageServerEntry.stored(configuredServers).unreadable)
        }
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
    private static let spans = CodeHighlighter.spans(in: sample, language: "preview.swift")

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
