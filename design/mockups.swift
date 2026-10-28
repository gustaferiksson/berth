// Run: swift design/mockups.swift   (writes design/sheet-1.png and design/parts-1.png)
import AppKit
import SwiftUI

enum Palette {
    static let background = Color(hex: 0x282C34)
    static let foreground = Color(hex: 0xFFFFFF)
    static let dim = Color(hex: 0xABB2BF)
    static let faint = Color(hex: 0x767676)
    static let red = Color(hex: 0xE06C75)
    static let green = Color(hex: 0x98C379)
    static let yellow = Color(hex: 0xE5C07B)
    static let blue = Color(hex: 0x61AFEF)
    static let magenta = Color(hex: 0xC678DD)
    static let cyan = Color(hex: 0x56B6C2)
    static let selection = Color(hex: 0x3E4451)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

enum Status { case none, needsYou, working, elsewhere }
enum PRState { case open, draft, merged, closed }

struct Session {
    let title: String
    let time: String
    var branch: String?
    var pr: (Int, PRState)?
    var status: Status = .none
    var selected = false
}

struct ProjectGroup {
    let name: String
    let count: Int
    var collapsed = false
    let sessions: [Session]
}

let groups = [
    ProjectGroup(name: "Gustaf", count: 36, sessions: [
        Session(title: "Slimline terminal Claude client", time: "now", branch: "main", status: .needsYou),
        Session(title: "Hermes bots multiplatform SwiftUI app", time: "2m", branch: "feat/glass-dashboard", status: .working, selected: true),
        Session(title: "Accessible SharePoint sites endpoint", time: "22m", status: .elsewhere),
        Session(title: "Open-source Mission Control alternative", time: "48m"),
    ]),
    ProjectGroup(name: "acme-hub-ui", count: 12, sessions: [
        Session(title: "Acme-hub-ui issue 1381 PR review", time: "41m", branch: "feat/registry-all-partitions-ui", pr: (1381, .open)),
        Session(title: "Export comparison version", time: "2d", branch: "feat/export-comparison-version", pr: (1378, .draft)),
    ]),
    ProjectGroup(name: "acme-hub", count: 36, sessions: [
        Session(title: "Acme-hub PR 1380", time: "3h", branch: "main", pr: (1380, .merged)),
        Session(title: "Acme-hub issue 1369 pricelist agent", time: "5h", branch: "feat/registry-lookups", pr: (1362, .closed), status: .elsewhere),
        Session(title: "Registry filters endpoint search design", time: "1d", branch: "revert/registry-experimental-gate"),
    ]),
    ProjectGroup(name: "acme-core", count: 18, collapsed: true, sessions: []),
]

enum RowLayout { case trailingTime, timePill }
enum PillStyle { case tinted, rounded, outline, text }
enum HeaderStyle { case chevronCount, chevronOnly, caps, large }
enum StatusStyle { case pill, dot, glyph }

struct Design {
    let letter: String
    let summary: String
    var layout: RowLayout
    var pills: PillStyle
    var header: HeaderStyle
    var airy: Bool
    var status: StatusStyle
}

let designs = [
    Design(letter: "A", summary: "Trailing time · tinted capsules · chevron + count · airy · status pill", layout: .trailingTime, pills: .tinted, header: .chevronCount, airy: true, status: .pill),
    Design(letter: "B", summary: "Trailing time · outline pills · chevron only · medium · leading dot", layout: .trailingTime, pills: .outline, header: .chevronOnly, airy: false, status: .dot),
    Design(letter: "C", summary: "Time pill · tinted capsules · small caps header · airy · trailing glyph", layout: .timePill, pills: .tinted, header: .caps, airy: true, status: .glyph),
    Design(letter: "D", summary: "Trailing time · plain coloured text · chevron + count · medium · trailing glyph", layout: .trailingTime, pills: .text, header: .chevronCount, airy: false, status: .glyph),
    Design(letter: "E", summary: "Time pill · outline pills · large header · airy · leading dot", layout: .timePill, pills: .outline, header: .large, airy: true, status: .dot),
    Design(letter: "F", summary: "Trailing time · 4 pt tinted tags · small caps, no count · medium · status pill", layout: .trailingTime, pills: .rounded, header: .caps, airy: false, status: .pill),
]

struct Pill: View {
    let text: String
    var symbol: String?
    let color: Color
    let style: PillStyle
    var monospaced = false

    var body: some View {
        let label = HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 11, weight: .medium, design: monospaced ? .monospaced : .default))
        .foregroundStyle(color)
        switch style {
        case .text:
            label
        case .tinted:
            label.padding(.horizontal, 8).padding(.vertical, 2).background(color.opacity(0.16), in: .capsule)
        case .rounded:
            label.padding(.horizontal, 4).padding(.vertical, 2).background(color.opacity(0.16), in: .rect(cornerRadius: 4))
        case .outline:
            label.padding(.horizontal, 8).padding(.vertical, 2).overlay(Capsule().strokeBorder(color.opacity(0.5), lineWidth: 1))
        }
    }
}

func prColor(_ state: PRState) -> Color {
    switch state {
    case .open: Palette.green
    case .draft: Palette.faint
    case .merged: Palette.magenta
    case .closed: Palette.red
    }
}

struct Header: View {
    let group: ProjectGroup
    let style: HeaderStyle

    var body: some View {
        HStack(spacing: 4) {
            if style != .caps {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(group.collapsed ? 0 : 90))
                    .foregroundStyle(Palette.faint)
                    .frame(width: 12)
            }
            switch style {
            case .caps:
                Text(group.name.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(Palette.dim)
            case .large:
                Text(group.name).font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.foreground)
            default:
                Text(group.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.foreground)
            }
            if style == .chevronCount || style == .large {
                Text("\(group.count)").font(.system(size: 12)).monospacedDigit().foregroundStyle(Palette.faint)
            }
            Spacer()
            Image(systemName: "apple.terminal").foregroundStyle(Palette.faint)
                .frame(width: 24, height: 24)
            Image(systemName: "plus").foregroundStyle(Palette.faint)
                .frame(width: 24, height: 24)
        }
        .font(.system(size: 13))
    }
}

struct Row: View {
    let session: Session
    let design: Design

    var body: some View {
        let titleColor = session.status == .elsewhere ? Palette.dim.opacity(0.7) : Palette.foreground
        HStack(alignment: .top, spacing: 8) {
            if design.status == .dot {
                Circle()
                    .fill(statusColor ?? .clear)
                    .frame(width: 8, height: 8)
                    .padding(.top, design.airy ? 6 : 4)
            }
            VStack(alignment: .leading, spacing: design.airy ? 8 : 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.title)
                        .font(.system(size: design.airy ? 14 : 13, weight: session.status == .needsYou ? .semibold : .regular))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if design.layout == .trailingTime {
                        Text(session.time).font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.faint)
                    }
                    if design.status == .glyph, let glyph = statusGlyph {
                        glyph
                    }
                }
                let pills = pillViews
                if !pills.isEmpty {
                    HStack(spacing: 4) { ForEach(pills.indices, id: \.self) { pills[$0] } }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, design.airy ? 8 : 4)
        .background(session.selected ? Palette.selection.opacity(0.8) : .clear, in: .rect(cornerRadius: 8))
    }

    private var statusColor: Color? {
        switch session.status {
        case .needsYou: Palette.yellow
        case .working: Palette.green
        default: nil
        }
    }

    private var statusGlyph: AnyView? {
        switch session.status {
        case .needsYou: AnyView(Image(systemName: "hand.raised.fill").font(.system(size: 13)).foregroundStyle(Palette.yellow))
        case .working: AnyView(Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.green))
        default: nil
        }
    }

    private var pillViews: [AnyView] {
        var views: [AnyView] = []
        if design.status == .pill || design.status == .dot, session.status == .needsYou || session.status == .working {
            let needs = session.status == .needsYou
            let symbol = design.status == .pill ? (needs ? "hand.raised.fill" : "ellipsis") : nil
            views.append(AnyView(Pill(text: needs ? "Needs you" : "Working", symbol: symbol, color: needs ? Palette.yellow : Palette.green, style: design.pills)))
        }
        if design.layout == .timePill {
            views.append(AnyView(Pill(text: session.time, symbol: "clock", color: Palette.dim, style: design.pills)))
        }
        if let (number, state) = session.pr {
            views.append(AnyView(Pill(text: "#\(number)", symbol: "arrow.triangle.pull", color: prColor(state), style: design.pills)))
        }
        if let branch = session.branch {
            views.append(AnyView(Pill(text: branch, symbol: "arrow.triangle.branch", color: Palette.cyan, style: design.pills, monospaced: true).layoutPriority(-1)))
        }
        return views
    }
}

struct Sidebar: View {
    let design: Design

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color(hex: 0xFF5F57), Color(hex: 0xFEBC2E), Color(hex: 0x28C840)], id: \.self) { Circle().fill($0).frame(width: 12, height: 12) }
                Spacer()
                Image(systemName: "sidebar.left").foregroundStyle(Palette.dim)
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
            ForEach(groups.indices, id: \.self) { index in
                Header(group: groups[index], style: design.header)
                    .padding(.horizontal, 12)
                    .padding(.top, index == 0 ? 4 : design.airy ? 20 : 16)
                    .padding(.bottom, 4)
                ForEach(groups[index].sessions.indices, id: \.self) { row in
                    Row(session: groups[index].sessions[row], design: design)
                        .padding(.horizontal, 8)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 320)
    }
}

struct Terminal: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Hermes bots multiplatform SwiftUI app").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.foreground)
                Text("~/Repos/Gustaf").font(.system(size: 11)).foregroundStyle(Palette.faint)
            }
            .frame(height: 52)
            Group {
                Text("● Saved: from now on I'll write documents as local markdown files.").foregroundStyle(Palette.foreground)
                Text("✻ Cogitated for 11s · done Sunday, Oct 18 at 3:28 PM").foregroundStyle(Palette.faint)
                Text("❯ build the dashboard tab next").foregroundStyle(Palette.dim)
                Text("● Working on DashboardView.swift…").foregroundStyle(Palette.yellow)
            }
            .font(.system(size: 12, design: .monospaced))
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Window: View {
    let design: Design

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(design.letter)  \(design.summary)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.black)
            HStack(spacing: 0) {
                Sidebar(design: design)
                Rectangle().fill(Color.black.opacity(0.25)).frame(width: 1)
                Terminal()
            }
            .frame(width: 920, height: 720, alignment: .top)
            .background(Palette.background)
            .clipShape(.rect(cornerRadius: 16))
        }
    }
}

struct Labeled<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.dim)
            content
                .padding(12)
                .frame(width: 344, alignment: .leading)
                .background(Palette.background, in: .rect(cornerRadius: 12))
        }
    }
}

struct Parts: View {
    let base = Design(letter: "", summary: "", layout: .trailingTime, pills: .tinted, header: .chevronCount, airy: true, status: .pill)
    let samples = [groups[0].sessions[0], groups[1].sessions[0], groups[2].sessions[1]]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Headers").font(.system(size: 17, weight: .bold)).foregroundStyle(.black)
            HStack(alignment: .top, spacing: 16) {
                ForEach(Array(zip(["H1 chevron + count", "H2 chevron only", "H3 small caps", "H4 large + count"], [HeaderStyle.chevronCount, .chevronOnly, .caps, .large])), id: \.0) { label, style in
                    Labeled(label: label) {
                        VStack(alignment: .leading, spacing: 12) {
                            Header(group: groups[0], style: style)
                            Header(group: groups[3], style: style)
                        }
                    }
                }
            }
            Text("Rows").font(.system(size: 17, weight: .bold)).foregroundStyle(.black)
            HStack(alignment: .top, spacing: 16) {
                let rows: [(String, Design)] = [
                    ("R1 trailing time, status pill", base),
                    ("R2 trailing time, leading dot", Design(letter: "", summary: "", layout: .trailingTime, pills: .tinted, header: .chevronCount, airy: true, status: .dot)),
                    ("R3 time pill, trailing glyph", Design(letter: "", summary: "", layout: .timePill, pills: .tinted, header: .chevronCount, airy: true, status: .glyph)),
                    ("R4 medium density, trailing glyph", Design(letter: "", summary: "", layout: .trailingTime, pills: .tinted, header: .chevronCount, airy: false, status: .glyph)),
                ]
                ForEach(rows, id: \.0) { label, design in
                    Labeled(label: label) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(samples.indices, id: \.self) { Row(session: samples[$0], design: design) }
                        }
                    }
                }
            }
            Text("Pills").font(.system(size: 17, weight: .bold)).foregroundStyle(.black)
            HStack(alignment: .top, spacing: 16) {
                ForEach(Array(zip(["P1 tinted capsule", "P2 tinted 4 pt tag", "P3 outline capsule", "P4 plain coloured text"], [PillStyle.tinted, .rounded, .outline, .text])), id: \.0) { label, style in
                    Labeled(label: label) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 4) {
                                Pill(text: "Needs you", symbol: "hand.raised.fill", color: Palette.yellow, style: style)
                                Pill(text: "Working", symbol: "ellipsis", color: Palette.green, style: style)
                            }
                            HStack(spacing: 4) {
                                Pill(text: "#1381", symbol: "arrow.triangle.pull", color: prColor(.open), style: style)
                                Pill(text: "#1378", symbol: "arrow.triangle.pull", color: prColor(.draft), style: style)
                                Pill(text: "#1380", symbol: "arrow.triangle.pull", color: prColor(.merged), style: style)
                                Pill(text: "#1362", symbol: "arrow.triangle.pull", color: prColor(.closed), style: style)
                            }
                            HStack(spacing: 4) {
                                Pill(text: "feat/tenant-metric-settings", symbol: "arrow.triangle.branch", color: Palette.cyan, style: style, monospaced: true)
                                Pill(text: "48m", symbol: "clock", color: Palette.dim, style: style)
                            }
                        }
                    }
                }
            }
        }
        .padding(32)
        .background(.white)
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
        Grid(horizontalSpacing: 32, verticalSpacing: 32) {
            GridRow { ForEach(designs[0..<3], id: \.letter) { Window(design: $0) } }
            GridRow { ForEach(designs[3..<6], id: \.letter) { Window(design: $0) } }
        }
        .padding(32)
        .background(.white),
        to: "\(directory)/sheet-1.png"
    )
    write(Parts(), to: "\(directory)/parts-1.png")
}
