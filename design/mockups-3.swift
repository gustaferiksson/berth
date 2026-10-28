// Run: swift design/mockups-3.swift   (writes design/sheet-3.png)
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
enum WorkingStyle { case ellipsis, pulse, spinner }

struct Session {
    let title: String
    let time: String
    var branch: String?
    var pr: (Int, PRState)?
    var status: Status = .none
    var selected = false
    var preview: String?
    var folder = "~"
}

enum SecondLine { case centered, preview, cwd }
enum LockStyle { case trailing, lineTwo, hoverTime }

struct ProjectGroup {
    let name: String
    let count: Int
    var collapsed = false
    let sessions: [Session]
}

let groups = [
    ProjectGroup(name: "Gustaf", count: 36, sessions: [
        Session(title: "Slimline terminal Claude client", time: "now", status: .needsYou, preview: "make the tab bar follow the Ghostty theme"),
        Session(title: "Hermes bots multiplatform SwiftUI app", time: "2m", branch: "feat/glass-dashboard", status: .working, selected: true),
        Session(title: "Accessible SharePoint sites endpoint", time: "22m", status: .elsewhere, preview: "list the sites the signed-in user can open"),
        Session(title: "Open-source Mission Control alternative", time: "48m", preview: "compare yabai, AeroSpace and Rectangle Pro", folder: "spaces"),
    ]),
    ProjectGroup(name: "acme-hub-ui", count: 12, sessions: [
        Session(title: "Acme-hub-ui issue 1381 PR review", time: "41m", branch: "feat/registry-all-partitions-ui", pr: (1381, .open), status: .working),
        Session(title: "Export comparison version", time: "2d", branch: "feat/export-comparison-version", pr: (1378, .draft)),
    ]),
    ProjectGroup(name: "acme-hub", count: 36, sessions: [
        Session(title: "Acme-hub PR 1380", time: "3h", branch: "main", pr: (1380, .merged), status: .needsYou),
        Session(title: "Acme-hub issue 1369 pricelist agent", time: "5h", branch: "feat/registry-lookups", pr: (1362, .closed), status: .elsewhere),
        Session(title: "Registry filters endpoint search design", time: "1d", branch: "revert/registry-experimental-gate"),
    ]),
    ProjectGroup(name: "acme-core", count: 18, collapsed: true, sessions: []),
]

struct Spacing {
    let name: String
    let rowPadding: CGFloat
    let rowGap: CGFloat
}

let medium = Spacing(name: "S1: 8 pt row padding, no gap", rowPadding: 8, rowGap: 0)
let roomy = Spacing(name: "S2: 8 pt row padding, 8 pt gap", rowPadding: 8, rowGap: 8)

struct Variant {
    let letter: String
    let working: WorkingStyle
    let spacing: Spacing
    var branchTag = false
    var secondLine = SecondLine.preview
    var lock = LockStyle.trailing
    var hovered = false
}

let variants = [
    Variant(letter: "Selected while Working", working: .ellipsis, spacing: roomy),
    Variant(letter: "Selected while Needs you", working: .ellipsis, spacing: roomy),
]

struct WorkingIndicator: View {
    let style: WorkingStyle
    var frame = 0

    var body: some View {
        switch style {
        case .ellipsis:
            HStack(spacing: 1.5) {
                ForEach(0..<3) { index in
                    Circle().fill(Palette.green.opacity(index == frame ? 1 : 0.35)).frame(width: 3, height: 3)
                }
            }
        case .pulse:
            Circle()
                .fill(Palette.green)
                .frame(width: 8, height: 8)
                .scaleEffect([0.6, 0.8, 1][frame])
                .opacity([0.4, 0.7, 1][frame])
        case .spinner:
            ZStack {
                ForEach(0..<8) { tick in
                    Capsule()
                        .fill(Palette.green.opacity(Double((tick + 8 - frame * 3) % 8 + 1) / 8))
                        .frame(width: 1.5, height: 3.5)
                        .offset(y: -4)
                        .rotationEffect(.degrees(Double(tick) * 45))
                }
            }
            .frame(width: 12, height: 12)
        }
    }
}

struct StatusSlot: View {
    let status: Status
    let working: WorkingStyle

    var body: some View {
        Group {
            switch status {
            case .needsYou: Circle().fill(Palette.yellow).frame(width: 8, height: 8)
            case .working: WorkingIndicator(style: working, frame: 2)
            default: Color.clear
            }
        }
        .frame(width: 12, height: 18)
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

func selecting(_ session: Session, for variant: Variant) -> Session {
    var copy = session
    copy.selected = variant.letter.hasSuffix("Working") ? session.title.hasPrefix("Hermes") : session.title.hasPrefix("Slimline")
    return copy
}

struct Header: View {
    let group: ProjectGroup

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .rotationEffect(.degrees(group.collapsed ? 0 : 90))
                .foregroundStyle(Palette.faint)
                .frame(width: 12)
            Text(group.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.dim)
            Text("\(group.count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.faint)
            Spacer()
            Image(systemName: "apple.terminal").foregroundStyle(Palette.faint).frame(width: 24, height: 24)
            Image(systemName: "plus").foregroundStyle(Palette.faint).frame(width: 24, height: 24)
        }
        .font(.system(size: 13))
    }
}

struct Row: View {
    let session: Session
    let variant: Variant

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusSlot(status: session.status, working: variant.working)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.title)
                        .font(.system(size: 13))
                        .foregroundStyle(session.status == .elsewhere ? Palette.dim.opacity(0.7) : Palette.foreground)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    let locked = session.status == .elsewhere
                    if variant.lock == .trailing {
                        Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Palette.faint).opacity(locked ? 1 : 0).frame(width: 12)
                    }
                    if variant.lock == .hoverTime, locked, variant.hovered {
                        Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Palette.dim).frame(width: 24, alignment: .trailing)
                    } else {
                        Text(session.time).font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.faint).frame(width: 24, alignment: .trailing)
                    }
                }
                if session.pr == nil, session.branch == nil, variant.secondLine != .centered {
                    Label(variant.secondLine == .preview ? (session.preview ?? "") : session.folder, systemImage: variant.lock == .lineTwo && session.status == .elsewhere ? "lock.fill" : variant.secondLine == .preview ? "text.bubble" : "folder")
                        .labelStyle(CompactLabel())
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.faint)
                        .lineLimit(1)
                }
                if session.pr != nil || session.branch != nil {
                    HStack(spacing: 8) {
                        if let (number, state) = session.pr {
                            Label { Text(verbatim: "#\(number)") } icon: { Image(systemName: "arrow.triangle.pull") }
                                .foregroundStyle(prColor(state))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(prColor(state).opacity(0.16), in: .rect(cornerRadius: 4))
                        }
                        if let branch = session.branch {
                            Label(branch, systemImage: "arrow.triangle.branch")
                                .foregroundStyle(variant.branchTag ? Palette.dim : Palette.cyan.opacity(0.8))
                                .truncationMode(.middle)
                                .padding(.horizontal, variant.branchTag ? 4 : 0)
                                .padding(.vertical, variant.branchTag ? 2 : 0)
                                .background(variant.branchTag ? Palette.dim.opacity(0.12) : .clear, in: .rect(cornerRadius: 4))
                                .layoutPriority(-1)
                        }
                    }
                    .labelStyle(CompactLabel())
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                }
            }
        }
        .frame(minHeight: 36, alignment: variant.secondLine == .centered && session.pr == nil && session.branch == nil ? .center : .top)
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .padding(.vertical, variant.spacing.rowPadding)
        .background(session.selected ? Palette.selection.opacity(0.8) : variant.hovered && session.status == .elsewhere ? Palette.selection.opacity(0.3) : .clear, in: .rect(cornerRadius: 8))
    }
}

struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

struct Window: View {
    let variant: Variant

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(variant.letter)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.black)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        ForEach([Color(hex: 0xFF5F57), Color(hex: 0xFEBC2E), Color(hex: 0x28C840)], id: \.self) { Circle().fill($0).frame(width: 12, height: 12) }
                        Spacer()
                        Image(systemName: "sidebar.left").foregroundStyle(Palette.dim)
                    }
                    .padding(.horizontal, 20)
                    .frame(height: 52)
                    ForEach(groups.indices, id: \.self) { index in
                        Header(group: groups[index])
                            .padding(.horizontal, 12)
                            .padding(.top, index == 0 ? 4 : 20)
                            .padding(.bottom, 4)
                        VStack(spacing: variant.spacing.rowGap) {
                            ForEach(groups[index].sessions.indices, id: \.self) { row in
                                Row(session: selecting(groups[index].sessions[row], for: variant), variant: variant)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 320)
                Rectangle().fill(Color.black.opacity(0.25)).frame(width: 1)
                VStack(alignment: .leading, spacing: 4) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Hermes bots multiplatform SwiftUI app").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.foreground)
                        Text("~/Repos/Gustaf").font(.system(size: 11)).foregroundStyle(Palette.faint)
                    }
                    .frame(height: 52)
                    Text("● Working on DashboardView.swift…").foregroundStyle(Palette.yellow).font(.system(size: 12, design: .monospaced))
                    Spacer()
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 680, height: 760, alignment: .top)
            .background(Palette.background)
            .clipShape(.rect(cornerRadius: 16))
        }
    }
}

struct FrameStrip: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Working indicator, 3 animation frames each (shown at 4× and at 1×)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.black)
            HStack(spacing: 32) {
                ForEach([WorkingStyle.ellipsis, .pulse, .spinner], id: \.self) { style in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(describing: style)).font(.system(size: 13, weight: .semibold)).foregroundStyle(.black)
                        HStack(spacing: 16) {
                            ForEach(0..<3) { frame in
                                VStack(spacing: 12) {
                                    WorkingIndicator(style: style, frame: frame).frame(width: 12, height: 12).scaleEffect(4).frame(width: 64, height: 64)
                                    WorkingIndicator(style: style, frame: frame).frame(width: 12, height: 12)
                                }
                                .padding(12)
                                .background(Palette.background, in: .rect(cornerRadius: 8))
                            }
                        }
                    }
                }
            }
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
        VStack(alignment: .leading, spacing: 32) {
            HStack(alignment: .top, spacing: 32) { ForEach(variants, id: \.letter) { Window(variant: $0) } }
            Text("Rows without a branch or PR: same height in all three").font(.system(size: 15, weight: .semibold)).foregroundStyle(.black)
            HStack(alignment: .top, spacing: 32) {
                ForEach([("(a) fixed height, title centred", SecondLine.centered), ("(b) last prompt preview", .preview), ("(c) folder relative to group", .cwd)], id: \.0) { label, line in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(.black)
                        VStack(spacing: 8) {
                            ForEach([groups[0].sessions[0], groups[0].sessions[2], groups[2].sessions[0], groups[0].sessions[3]].indices, id: \.self) { index in
                                Row(session: [groups[0].sessions[0], groups[0].sessions[2], groups[2].sessions[0], groups[0].sessions[3]][index], variant: Variant(letter: "", working: .ellipsis, spacing: roomy, secondLine: line))
                            }
                        }
                        .padding(8)
                        .frame(width: 320)
                        .background(Palette.background, in: .rect(cornerRadius: 12))
                    }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Locked (running elsewhere) rows").font(.system(size: 15, weight: .semibold)).foregroundStyle(.black)
                HStack(alignment: .top, spacing: 24) {
                    ForEach([("L1 trailing lock slot (wired)", LockStyle.trailing, false), ("L2 lock as line-2 prefix", .lineTwo, false), ("L3 lock replaces time on hover", .hoverTime, true)], id: \.0) { label, lock, hovered in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(.black)
                            VStack(spacing: 8) {
                                Row(session: groups[0].sessions[2], variant: Variant(letter: "", working: .ellipsis, spacing: roomy, lock: lock, hovered: hovered))
                                Row(session: groups[0].sessions[3], variant: Variant(letter: "", working: .ellipsis, spacing: roomy, lock: lock))
                            }
                            .padding(8)
                            .frame(width: 320)
                            .background(Palette.background, in: .rect(cornerRadius: 12))
                        }
                    }
                }
            }
            .offset(y: 260)
        }
        .padding(.bottom, 260)
        .padding(32)
        .background(.white),
        to: "\(directory)/sheet-3.png"
    )
}
