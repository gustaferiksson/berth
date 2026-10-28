// Run: swift design/mockups-4.swift   (writes design/sheet-4.png)
import AppKit
import SwiftUI

enum Palette {
    static let background = Color(hex: 0x282C34)
    static let foreground = Color(hex: 0xFFFFFF)
    static let secondary = Color(hex: 0xFFFFFF).opacity(0.6)
    static let red = Color(hex: 0xE06C75)
    static let green = Color(hex: 0x98C379)
    static let yellow = Color(hex: 0xE5C07B)
    static let magenta = Color(hex: 0xC678DD)
    static let cyan = Color(hex: 0x56B6C2)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

enum Presence { case loaded, elsewhere, history }
enum Activity { case none, needsYou, working }
enum PRState { case open, merged, closed }
enum Treatment { case gutterMark, openSection, glyphs }

struct Session {
    let title: String
    let time: String
    var presence: Presence
    var activity: Activity = .none
    var branch: String?
    var pr: (Int, PRState)?
    var selected = false
    var hovered = false
}

let gustaf = [
    Session(title: "Hermes bots multiplatform SwiftUI app", time: "now", presence: .loaded, activity: .working, pr: (63, .merged), selected: true),
    Session(title: "Slimline terminal Claude client", time: "now", presence: .elsewhere, activity: .needsYou),
    Session(title: "Accessible SharePoint sites endpoint", time: "now", presence: .loaded),
    Session(title: "macOS menubar screen and audio recorder", time: "15m", presence: .history, pr: (9, .merged), hovered: true),
    Session(title: "Open-source Mission Control alternative", time: "49m", presence: .elsewhere, pr: (3, .open)),
]
let acmeHub = [
    Session(title: "Acme-hub PR 1380", time: "now", presence: .history, branch: "main", pr: (1381, .merged)),
    Session(title: "Acme-hub issue 1369 pricelist agent", time: "1m", presence: .elsewhere, branch: "main"),
    Session(title: "Registry filters endpoint search design", time: "24m", presence: .loaded, activity: .needsYou, branch: "main"),
    Session(title: "Acme-hub issue 1369 PRs", time: "22h", presence: .history, branch: "revert/registry-experimental-gate", pr: (1382, .open)),
]

func prColor(_ state: PRState) -> Color {
    switch state {
    case .open: Palette.green
    case .merged: Palette.magenta
    case .closed: Palette.red
    }
}

struct Header: View {
    let name: String
    let count: Int
    var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).frame(width: 12)
            HStack(spacing: 4) {
                Text(name).fontWeight(.semibold)
                Text("\(count)").monospacedDigit().opacity(0.6)
            }
            Spacer()
            Image(systemName: "apple.terminal").frame(width: 24, height: 24)
                .background(hovered ? Palette.foreground.opacity(0.06) : .clear, in: .rect(cornerRadius: 8))
            Image(systemName: "plus").frame(width: 24, height: 24)
        }
        .font(.system(size: 11))
        .foregroundStyle(Palette.secondary.opacity(hovered ? 1 : 0.8))
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

struct Row: View {
    let session: Session
    let treatment: Treatment

    var body: some View {
        let dimmed = session.presence == .elsewhere
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(session.title)
                    .font(.system(size: 13))
                    .foregroundStyle(dimmed ? Palette.secondary : Palette.foreground)
                    .lineLimit(1)
                if treatment == .glyphs, session.presence == .loaded {
                    Image(systemName: "apple.terminal").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                }
                Spacer(minLength: 8)
                if treatment == .glyphs, session.presence == .history, session.hovered {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.secondary)
                }
                Text(session.time).font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.secondary)
            }
            HStack(spacing: 8) {
                if let (number, state) = session.pr {
                    Label { Text(verbatim: "#\(number)") } icon: { Image(systemName: "arrow.triangle.pull").imageScale(.small) }
                        .labelStyle(Compact())
                        .foregroundStyle(prColor(state))
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(prColor(state).opacity(0.16), in: .rect(cornerRadius: 4))
                }
                if let branch = session.branch {
                    Label(branch, systemImage: "arrow.triangle.branch").labelStyle(Compact()).foregroundStyle(Palette.cyan.opacity(0.8)).truncationMode(.middle)
                }
                if session.pr == nil, session.branch == nil {
                    Text(verbatim: "–").foregroundStyle(Palette.secondary)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(1)
            .frame(height: 16)
        }
        .padding(.leading, 24)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .topLeading) { gutter.frame(width: 8, height: 16).padding(.leading, 8).padding(.top, 9) }
        .background(
            session.selected ? Palette.foreground.opacity(0.1) : session.hovered ? Palette.foreground.opacity(0.05) : .clear,
            in: .rect(cornerRadius: 8)
        )
        .padding(.horizontal, 8)
    }

    @ViewBuilder private var gutter: some View {
        if session.activity == .needsYou {
            Circle().fill(Palette.yellow).frame(width: 8, height: 8)
        } else if session.activity == .working {
            HStack(spacing: 1) { ForEach(0..<3) { Circle().fill(Palette.green.opacity($0 == 2 ? 1 : 0.4)).frame(width: 2.5, height: 2.5) } }
                .frame(width: 10)
        } else if treatment == .gutterMark, session.presence == .loaded {
            Circle().strokeBorder(Palette.foreground.opacity(0.7), lineWidth: 1.5).frame(width: 8, height: 8)
        }
    }
}

struct Compact: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon; configuration.title }
    }
}

struct Sidebar: View {
    let treatment: Treatment
    let label: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 15, weight: .semibold)).foregroundStyle(.black)
            Text(note).font(.system(size: 12)).foregroundStyle(.black.opacity(0.7)).frame(width: 340, alignment: .leading).fixedSize(horizontal: false, vertical: true).frame(height: 48, alignment: .top)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    ForEach([Color(hex: 0xFF5F57), Color(hex: 0xFEBC2E), Color(hex: 0x28C840)], id: \.self) { Circle().fill($0).frame(width: 12, height: 12) }
                }
                .padding(.horizontal, 20)
                .frame(height: 44)
                if treatment == .openSection {
                    Header(name: "Open", count: 3)
                    ForEach(Array((gustaf + acmeHub).filter { $0.presence == .loaded }.enumerated()), id: \.offset) { Row(session: $0.element, treatment: treatment) }
                    Rectangle().fill(Palette.foreground.opacity(0.08)).frame(height: 1).padding(.horizontal, 16).padding(.top, 12)
                    Header(name: "Gustaf", count: 36, hovered: true)
                    ForEach(Array(gustaf.filter { $0.presence != .loaded }.enumerated()), id: \.offset) { Row(session: $0.element, treatment: treatment) }
                    Header(name: "acme-hub", count: 36)
                    ForEach(Array(acmeHub.filter { $0.presence != .loaded }.enumerated()), id: \.offset) { Row(session: $0.element, treatment: treatment) }
                } else {
                    Header(name: "Gustaf", count: 36, hovered: true)
                    ForEach(Array(gustaf.enumerated()), id: \.offset) { Row(session: $0.element, treatment: treatment) }
                    Header(name: "acme-hub", count: 36)
                    ForEach(Array(acmeHub.enumerated()), id: \.offset) { Row(session: $0.element, treatment: treatment) }
                }
                Spacer(minLength: 16)
            }
            .frame(width: 340, height: 900, alignment: .top)
            .background(Palette.background, in: .rect(cornerRadius: 16))
        }
    }
}

@MainActor
func write<V: View>(_ view: V, to path: String) {
    let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
    renderer.scale = 2
    guard let image = renderer.cgImage,
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { fatalError("render failed for \(path)") }
    try! png.write(to: URL(filePath: path))
    print("wrote \(path)")
}

let directory = URL(filePath: #filePath).deletingLastPathComponent().path
MainActor.assumeIsolated {
    write(
        HStack(alignment: .top, spacing: 32) {
            Sidebar(treatment: .gutterMark, label: "T1  Gutter ring for loaded", note: "Loaded: hollow ring in the gutter (yellow dot / green ellipsis replace it). History: normal. Elsewhere: title in secondary colour, line 2 untouched.")
            Sidebar(treatment: .openSection, label: "T2  Open section on top", note: "Loaded sessions gather in one Open section; projects below hold history and elsewhere. Same gutter for status.")
            Sidebar(treatment: .glyphs, label: "T3  Glyphs", note: "Loaded: small terminal glyph after the title. History: ↻ resume glyph on hover (row 4). Elsewhere: secondary title only.")
        }
        .padding(32)
        .background(.white),
        to: "\(directory)/sheet-4.png"
    )
}
