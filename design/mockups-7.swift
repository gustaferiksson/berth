// Run: swift design/mockups-7.swift   (writes design/sheet-7.png, sheet-8.png, sheet-9.png)
import AppKit
import SwiftUI

enum Palette {
    static let background = Color(hex: 0x282C34)
    static let foreground = Color.white
    static let secondary = Color.white.opacity(0.6)
    static let tertiary = Color.white.opacity(0.35)
    static let green = Color(hex: 0x98C379)
    static let yellow = Color(hex: 0xE5C07B)
    static let magenta = Color(hex: 0xC678DD)
    static let cyan = Color(hex: 0x56B6C2)
    static let red = Color(hex: 0xE06C75)
    static let dim = Color(hex: 0xABB2BF)
    static let hairline = Color(hex: 0x3D4148)
    static let menu = Color(hex: 0x30343C)
    static let accent = Color(hex: 0x0A84FF)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: Sidebar pieces (values from Sources/Sidebar.swift)

enum Status { case working, needsYou }

enum LineStyle { case dotted, prFirst }

private struct LineStyleKey: EnvironmentKey { static let defaultValue = LineStyle.dotted }
extension EnvironmentValues {
    var lineStyle: LineStyle {
        get { self[LineStyleKey.self] }
        set { self[LineStyleKey.self] = newValue }
    }
}

struct WorkingDots: View {
    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<3) { Circle().fill(Palette.green.opacity($0 == 0 ? 1 : 0.35)).frame(width: 3, height: 3) }
        }
    }
}

struct PRTag: View {
    let number: Int
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.pull").imageScale(.small)
            Text(verbatim: "#\(number)")
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(color)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(color.opacity(0.16), in: .rect(cornerRadius: 4))
    }
}

struct Branch: View {
    let name: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch").imageScale(.small)
            Text(name).truncationMode(.middle)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Palette.cyan.opacity(0.8))
        .layoutPriority(-1)
    }
}

struct Row: View {
    let title: String
    let time: String
    var project: String?
    var pr: (Int, Color)?
    var branch: String?
    var status: Status?
    var loaded = false
    var elsewhere = false
    var selected = false
    @Environment(\.lineStyle) private var style

    var body: some View {
        let showsBranch = !(style == .prFirst && project != nil && pr != nil)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 13)).foregroundStyle(Palette.foreground).lineLimit(1)
                Spacer(minLength: 0)
                Text(time)
                    .font(.system(size: 11, weight: loaded ? .medium : .regular))
                    .monospacedDigit()
                    .foregroundStyle(loaded ? Palette.green : Palette.secondary)
            }
            HStack(spacing: style == .dotted && project != nil ? 4 : 8) {
                if let project {
                    Text(project).font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize()
                    if style == .dotted, pr != nil || branch != nil { Text("·").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.tertiary) }
                }
                if let pr { PRTag(number: pr.0, color: pr.1).fixedSize().padding(.trailing, style == .dotted && project != nil ? 4 : 0) }
                if let branch, showsBranch { Branch(name: branch) }
                if project == nil, pr == nil, branch == nil {
                    Text("–").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondary)
                }
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .frame(height: 16)
        }
        .opacity(elsewhere ? 0.55 : 1)
        .padding(.leading, 24)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .topLeading) {
            ZStack {
                if status == .working { WorkingDots() }
                if status == .needsYou { Circle().fill(Palette.yellow).frame(width: 8, height: 8) }
            }
            .frame(width: 8, height: 16)
            .padding(.leading, 8)
            .padding(.top, 8)
        }
        .background(selected ? Palette.foreground.opacity(0.1) : .clear, in: .rect(cornerRadius: 8))
        .padding(.horizontal, 8)
    }
}

struct Header: View {
    let name: String
    let count: Int
    var collapsed = false
    var plus = true
    var plusActive = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .frame(width: 16)
                .padding(.trailing, 4)
            Text(name).fontWeight(.semibold).lineLimit(1)
            Text("\(count)").monospacedDigit().opacity(0.6)
            Spacer(minLength: 4)
            if plus {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .opacity(plusActive ? 1 : 0.6)
                    .frame(width: 24, height: 24)
                    .background(Palette.foreground.opacity(plusActive ? 0.1 : 0), in: .rect(cornerRadius: 8))
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Palette.secondary)
        .frame(height: 24)
        .padding(.top, 16)
        .padding(.bottom, 4)
        .padding(.leading, 12)
        .padding(.trailing, 16)
    }
}

struct GroupDivider: View {
    var body: some View {
        Rectangle().fill(Palette.hairline).frame(height: 1).padding(.horizontal, 16).padding(.top, 12)
    }
}

struct Lights: View {
    var body: some View {
        HStack(spacing: 8) {
            ForEach([Color(hex: 0xFF5F57), Color(hex: 0xFEBC2E), Color(hex: 0x28C840)], id: \.self) { Circle().fill($0).frame(width: 12, height: 12) }
        }
    }
}

struct Glass<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.system(size: 13))
            .foregroundStyle(Palette.foreground.opacity(0.85))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Palette.foreground.opacity(0.08), in: .capsule)
            .overlay(Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
    }
}

struct GroupByButton: View {
    let mode: String

    var body: some View {
        Glass {
            HStack(spacing: 4) {
                Text(mode)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.secondary)
            }
        }
    }
}

struct ComposeButton: View {
    var active = false

    var body: some View {
        Image(systemName: "square.and.pencil")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Palette.foreground.opacity(0.85))
            .frame(width: 32, height: 32)
            .background(Palette.foreground.opacity(active ? 0.18 : 0.08), in: .circle)
            .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
    }
}

let terminalLines: [(String, Color)] = [
    ("● Added the filter endpoint and its tests.", Palette.foreground),
    ("✻ Worked for 2m 10s", Palette.secondary),
    ("❯ run the dev server and check /registry", Palette.dim),
    ("● Starting it in your shell…", Palette.yellow),
]

struct Terminal: View {
    var title = "Registry filters endpoint search design"
    var path = "~/Repos/Work/acme-hub"
    var lines = terminalLines

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.foreground).lineLimit(1)
                Text(path).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines.indices, id: \.self) { Text(lines[$0].0).foregroundStyle(lines[$0].1).lineLimit(1) }
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(16)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct Window<Side: View, Toolbar: View>: View {
    var width: CGFloat = 400
    var height: CGFloat = 600
    var terminal = Terminal()
    @ViewBuilder let toolbar: Toolbar
    @ViewBuilder let side: Side

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Lights()
                    Spacer()
                    toolbar
                }
                .padding(.leading, 20)
                .padding(.trailing, 12)
                .frame(height: 52)
                side
                Spacer(minLength: 0)
            }
            .frame(width: 300)
            Rectangle().fill(Palette.hairline).frame(width: 1)
            terminal
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .background(Palette.background)
        .clipShape(.rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.hairline, lineWidth: 1))
    }
}

extension Window where Toolbar == EmptyView {
    init(width: CGFloat = 400, height: CGFloat = 600, terminal: Terminal = Terminal(), @ViewBuilder side: () -> Side) {
        self.init(width: width, height: height, terminal: terminal, toolbar: { EmptyView() }, side: side)
    }
}

// MARK: Menus, fields, buttons (hand-drawn: ImageRenderer draws no native controls)

struct MI: Identifiable {
    enum Kind { case item, divider, header }
    let id = UUID()
    var title = ""
    var note: String?
    var check = false
    var key: String?
    var sub = false
    var open = false
    var destructive = false
    var kind = Kind.item

    static let divider = MI(kind: .divider)
    static func header(_ title: String) -> MI { MI(title: title, kind: .header) }
}

struct Menu: View {
    let items: [MI]
    var width: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                if item.kind == .divider {
                    Rectangle().fill(Palette.foreground.opacity(0.1)).frame(height: 1).padding(.horizontal, 12).padding(.vertical, 4)
                } else if item.kind == .header {
                    Text(item.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.secondary)
                        .padding(.horizontal, 12).frame(height: 24)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).frame(width: 12).opacity(item.check ? 1 : 0)
                        Text(item.title).foregroundStyle(item.destructive ? Palette.red : Palette.foreground).lineLimit(1).layoutPriority(1)
                        if let note = item.note {
                            Text(note).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.tertiary).lineLimit(1).truncationMode(.middle).padding(.leading, 4)
                        }
                        Spacer(minLength: 12)
                        if let key = item.key { Text(key).foregroundStyle(Palette.tertiary) }
                        if item.sub { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.secondary) }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.foreground)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Palette.foreground.opacity(item.open ? 0.12 : 0), in: .rect(cornerRadius: 6))
                    .padding(.horizontal, 4)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(width: width)
        .background(Palette.menu, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.foreground.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 20, y: 10)
    }
}

struct Field: View {
    let text: String
    var placeholder = false
    var focused = false
    var mono = false
    var height: CGFloat = 28
    var size: CGFloat = 13

    var body: some View {
        HStack(spacing: 1) {
            Text(text)
                .font(.system(size: size, design: mono ? .monospaced : .default))
                .foregroundStyle(placeholder ? Palette.tertiary : Palette.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
            if focused && !placeholder { Rectangle().fill(Palette.foreground).frame(width: 1.5, height: size + 3) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: height, alignment: height > 32 ? .top : .center)
        .padding(.top, height > 32 ? 6 : 0)
        .background(Color.black.opacity(0.22), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.foreground.opacity(0.12), lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.accent.opacity(focused ? 0.7 : 0), lineWidth: 3).padding(-3))
    }
}

struct PopUp: View {
    let title: String
    var note: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 13)).foregroundStyle(Palette.foreground)
            if let note { Text(note).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.tertiary).lineLimit(1).truncationMode(.middle) }
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(Palette.foreground.opacity(0.1), in: .capsule)
    }
}

struct Button2: View {
    let title: String
    var primary = false
    var destructive = false

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: primary ? .medium : .regular))
            .foregroundStyle(destructive ? Palette.red : Palette.foreground)
            .padding(.horizontal, 16)
            .frame(height: 28)
            .background(primary ? Palette.accent : Palette.foreground.opacity(0.1), in: .capsule)
    }
}

struct Check: View {
    let on: Bool
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4)
                .fill(on ? Palette.accent : Palette.foreground.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.foreground.opacity(on ? 0 : 0.2), lineWidth: 1))
                .overlay(Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white).opacity(on ? 1 : 0))
                .frame(width: 16, height: 16)
            Text(label).font(.system(size: 13)).foregroundStyle(Palette.foreground)
        }
    }
}

struct Key: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.secondary)
                .padding(.horizontal, 4)
                .frame(minWidth: 20, minHeight: 20)
                .background(Palette.foreground.opacity(0.1), in: .rect(cornerRadius: 4))
            Text(label).font(.system(size: 11)).foregroundStyle(Palette.secondary)
        }
    }
}

struct GlassPanel<Content: View>: View {
    var radius: CGFloat = 20
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(Color(hex: 0x30343C).opacity(0.97), in: .rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 28, y: 14)
    }
}

struct Arrow: Shape {
    enum Edge { case up, left }
    let edge: Edge

    func path(in rect: CGRect) -> Path {
        Path { path in
            if edge == .up {
                path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            } else {
                path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            }
            path.closeSubpath()
        }
    }
}

// MARK: Panel frame on the sheet

struct Panel<Content: View>: View {
    let code: String
    let title: String
    let caption: String
    var width: CGFloat = 400
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(code)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.black, in: .rect(cornerRadius: 4))
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.black)
            }
            content
            Text(caption)
                .font(.system(size: 12))
                .foregroundStyle(.black.opacity(0.75))
                .frame(width: width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: width, alignment: .leading)
    }
}

struct Notes: View {
    let title: String
    let lines: [String]
    var recommendation: String?
    var width: CGFloat = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.black)
            ForEach(lines, id: \.self) {
                Text($0).font(.system(size: 13)).foregroundStyle(.black).frame(width: width, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            if let recommendation {
                Text(recommendation).font(.system(size: 13, weight: .semibold)).foregroundStyle(.black).frame(width: width, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 36)
    }
}

struct SheetTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(.black)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.black.opacity(0.6))
        }
    }
}

// MARK: Sample sidebars

struct ProjectSidebar: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(name: "acme-hub", count: 36)
            Row(title: "Registry filters endpoint search design", time: "24m", pr: (1384, Palette.green), branch: "feat/registry-filters", loaded: true, selected: true)
            Row(title: "Pricelist agent for issue 1369", time: "3h", branch: "main", status: .needsYou, loaded: true)
            Row(title: "Acme-hub PR 1380 review", time: "1h", pr: (1380, Palette.magenta), branch: "main", elsewhere: true)
            Header(name: "berth", count: 12)
            Row(title: "Custom sidebar groups design", time: "now", branch: "main", status: .working, loaded: true)
            Row(title: "Archive sessions from the sidebar", time: "2h", branch: "feat/archive")
            Header(name: "tine", count: 41)
            Row(title: "Spec loader crash on empty JSON", time: "1d")
        }
    }
}

struct RepositorySidebar: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(name: "acme-hub", count: 44)
            Row(title: "Registry filters endpoint search design", time: "24m", project: "acme-hub-filters", branch: "feat/registry-filters", loaded: true, selected: true)
            Row(title: "Pricelist agent for issue 1369", time: "3h", project: "acme-hub-1369", branch: "issue-1369", status: .needsYou, loaded: true)
            Row(title: "Acme-hub PR 1380 review", time: "1h", project: "acme-hub", pr: (1380, Palette.magenta), branch: "main", elsewhere: true)
            Header(name: "berth", count: 12)
            Row(title: "Custom sidebar groups design", time: "now", branch: "main", status: .working, loaded: true)
            Row(title: "Archive sessions from the sidebar", time: "2h", branch: "feat/archive")
            Header(name: "tine", count: 41)
            Row(title: "Spec loader crash on empty JSON", time: "1d")
        }
    }
}

struct RecentSidebar: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(name: "Today", count: 7, plus: false)
            Row(title: "Custom sidebar groups design", time: "now", project: "berth", branch: "main", status: .working, loaded: true)
            Row(title: "Registry filters endpoint search design", time: "24m", project: "acme-hub", pr: (1384, Palette.green), loaded: true, selected: true)
            Row(title: "Pricelist agent for issue 1369", time: "3h", project: "acme-hub", branch: "main", status: .needsYou, loaded: true)
            Header(name: "Yesterday", count: 4, plus: false)
            Row(title: "Spec loader crash on empty JSON", time: "1d", project: "tine")
            Row(title: "Rinse ControlWidget extension", time: "1d", project: "rinse", branch: "widget")
            Header(name: "This Week", count: 9, collapsed: true, plus: false)
            Header(name: "Older", count: 41, collapsed: true, plus: false)
        }
    }
}

struct CustomSidebar: View {
    var plusOnAcme = false
    var customCollapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if customCollapsed {
                Header(name: "Acme", count: 47, collapsed: true)
                Header(name: "Mac apps", count: 63, collapsed: true)
            } else {
                custom
            }
            GroupDivider()
            Header(name: "crew", count: 9)
            Row(title: "Hermes bots multiplatform SwiftUI app", time: "2d", branch: "main")
            if customCollapsed {
                Row(title: "Chief-of-staff terminal hardening", time: "4d", branch: "harden/terminal")
                Header(name: "rinse", count: 24)
                Row(title: "Rinse ControlWidget extension", time: "1d", branch: "widget")
            }
        }
    }

    @ViewBuilder private var custom: some View {
            Header(name: "Acme", count: 47, plusActive: plusOnAcme)
            Row(title: "Registry filters endpoint search design", time: "24m", project: "acme-hub", pr: (1384, Palette.green), loaded: true, selected: !plusOnAcme)
            Row(title: "Pricelist agent for issue 1369", time: "3h", project: "acme-hub", branch: "main", status: .needsYou, loaded: true)
            Row(title: "CDK synth on Apple container", time: "5h", project: "acme-infra", branch: "infra/container")
            Header(name: "Mac apps", count: 63)
            Row(title: "Custom sidebar groups design", time: "now", project: "berth", branch: "main", status: .working, loaded: true)
            Row(title: "Rinse ControlWidget extension", time: "1d", project: "rinse", branch: "widget")
    }
}

struct LineDemoSidebar: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(name: "Acme", count: 47)
            Row(title: "Registry filters endpoint search design", time: "24m", project: "acme-hub", pr: (1384, Palette.green), branch: "feat/registry-filters", loaded: true, selected: true)
            Row(title: "CDK synth on Apple container", time: "5h", project: "acme-infra", branch: "infra/apple-container-cdk-synth", status: .needsYou, loaded: true)
            Row(title: "Acme-hub PR 1380 review", time: "1h", project: "acme-hub", pr: (1380, Palette.magenta), branch: "main", elsewhere: true)
            Header(name: "Mac apps", count: 63)
            Row(title: "Custom sidebar groups design", time: "now", project: "berth", branch: "main", status: .working, loaded: true)
            Row(title: "Spec loader crash on empty JSON", time: "1d", project: "tine", pr: (88, Palette.green), branch: "fix/empty-json-spec")
            Row(title: "Menu bar text instead of icon", time: "2w", project: "tinecast")
            GroupDivider()
            Header(name: "crew", count: 9)
            Row(title: "Hermes bots multiplatform SwiftUI app", time: "2d", pr: (41, Palette.green), branch: "feat/macos-target")
        }
    }
}

// MARK: Sheet 7, grouping modes

let projectGroupMenu: [MI] = [
    .header("Group By"),
    MI(title: "Project", check: true, key: "⌃⌘1"),
    MI(title: "Repository", key: "⌃⌘2"),
    MI(title: "Recent", key: "⌃⌘3"),
    .divider,
    MI(title: "Show Custom Groups", check: true),
    MI(title: "New Group…"),
    MI(title: "Edit Groups…"),
]

struct Sheet7: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 48) {
            SheetTitle(title: "Berth · Grouping modes", subtitle: "Sheet 7. Custom groups always sit on top; the mode picks how everything else is grouped. Pick one switcher (G1–G3) and see the modes in G4–G6.")
            HStack(alignment: .top, spacing: 48) {
                Panel(code: "G1", title: "Pull-down in the sidebar toolbar", caption: "A glass toolbar item reads the current mode as text (\"Project ⌄\"). Its menu holds the modes with ⌃⌘1–3 plus the group actions, so all grouping lives in one place.") {
                    Window(toolbar: { GroupByButton(mode: "Project") }, side: { ProjectSidebar() })
                        .overlay(alignment: .topLeading) { Menu(items: projectGroupMenu, width: 220).offset(x: 172, y: 48) }
                }
                Panel(code: "G2", title: "View ▸ Group By in the menu bar", caption: "Nothing new in the window: the standard View menu gets a Group By submenu with the same ⌃⌘1–3 shortcuts. Most native, least discoverable.", width: 600) {
                    MenuBarPanel()
                }
                Panel(code: "G3", title: "Segmented control above the list", caption: "Always-visible three-way glass segment. One click to switch and the mode is never in doubt, but it costs 40 pt of sidebar height forever.") {
                    Window(side: {
                        VStack(alignment: .leading, spacing: 0) {
                            Segmented(options: ["Project", "Repository", "Recent"], selected: 0).padding(.horizontal, 16).padding(.bottom, 4)
                            ProjectSidebar()
                        }
                    })
                }
            }
            HStack(alignment: .top, spacing: 48) {
                Panel(code: "G4", title: "Repository mode", caption: "Groups by git root, so worktrees (acme-hub-filters, acme-hub-1369) merge into acme-hub. The detail line names the worktree folder when it differs from the repo.") {
                    Window(toolbar: { GroupByButton(mode: "Repository") }, side: { RepositorySidebar() })
                }
                Panel(code: "G5", title: "Recent mode", caption: "Today / Yesterday / This Week / Older. Headers have no + (no single folder); the project name moves into the detail line. Older buckets start collapsed.") {
                    Window(toolbar: { GroupByButton(mode: "Recent") }, side: { RecentSidebar() })
                }
                Panel(code: "G6", title: "Project mode with custom groups", caption: "Default. Custom groups (Acme, Mac apps) pinned on top, a hairline, then automatic project groups for everything they don't claim. Rows in multi-project groups show the project name.") {
                    Window(toolbar: { GroupByButton(mode: "Project") }, side: { CustomSidebar() })
                }
            }
            HStack(alignment: .top, spacing: 48) {
                Panel(code: "L1", title: "Line 2: project · branch", caption: "In mixed groups (custom, Recent, Repository worktrees) line 2 starts with the project name, dim, then a faint dot, then PR tag and branch. The project name never truncates; the branch truncates in the middle. crew (automatic) keeps today's line.") {
                    Window(toolbar: { GroupByButton(mode: "Project") }, side: { LineDemoSidebar() })
                }
                Panel(code: "L2", title: "Line 2: project, then PR tag", caption: "Same rows, no separator: project name then the PR tag; the branch is dropped when a PR exists (the PR implies it) and shown otherwise. Shorter lines, less truncation, but the branch disappears on PR rows.") {
                    Window(toolbar: { GroupByButton(mode: "Project") }, side: { LineDemoSidebar() })
                        .environment(\.lineStyle, .prFirst)
                }
                Notes(title: "Where line 2 changes", lines: [
                    "Automatic Project groups: unchanged (PR tag, branch, or –). The header already names the project.",
                    "Custom groups and Recent: project name first, always, even on rows with no branch (\"tinecast\" alone replaces the dash).",
                    "Repository mode: the worktree folder name takes the project's place, only when it differs from the repo name.",
                ], recommendation: "Recommendation: L1. The dot reads as a separator between two dim, similar-looking texts, and the branch stays visible on PR rows.")
            }
        }
        .padding(48)
        .background(.white)
    }
}

struct Segmented: View {
    let options: [String]
    let selected: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                Text(options[index])
                    .font(.system(size: 12, weight: index == selected ? .semibold : .regular))
                    .foregroundStyle(index == selected ? Palette.foreground : Palette.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .background(Palette.foreground.opacity(index == selected ? 0.14 : 0), in: .capsule)
            }
        }
        .padding(2)
        .background(Palette.foreground.opacity(0.06), in: .capsule)
        .overlay(Capsule().strokeBorder(Palette.foreground.opacity(0.1), lineWidth: 1))
    }
}

struct MenuBarPanel: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Window(width: 600, height: 560, side: { ProjectSidebar() })
                .padding(.top, 36)
            HStack(spacing: 20) {
                Image(systemName: "apple.logo").font(.system(size: 14))
                Text("Berth").fontWeight(.bold)
                Text("File")
                Text("Edit")
                Text("View").padding(.horizontal, 8).padding(.vertical, 2).background(Palette.foreground.opacity(0.16), in: .capsule).padding(.horizontal, -8)
                Text("Window")
                Text("Help")
                Spacer()
            }
            .font(.system(size: 13))
            .foregroundStyle(Palette.foreground)
            .padding(.horizontal, 16)
            .frame(width: 600, height: 28)
            .background(Color(hex: 0x1E2127), in: .rect(cornerRadius: 8))
            Menu(items: [
                MI(title: "Show Sidebar", key: "⌃⌘S"),
                MI(title: "Show Terminal Panel", key: "⌘J"),
                .divider,
                MI(title: "Group By", sub: true, open: true),
                MI(title: "Expand All Groups", key: "⌥⌘→"),
                MI(title: "Collapse All Groups", key: "⌥⌘←"),
                .divider,
                MI(title: "Enter Full Screen", key: "fn F"),
            ], width: 232)
            .offset(x: 152, y: 32)
            Menu(items: [
                MI(title: "Project", check: true, key: "⌃⌘1"),
                MI(title: "Repository", key: "⌃⌘2"),
                MI(title: "Recent", key: "⌃⌘3"),
                .divider,
                MI(title: "Show Custom Groups", check: true),
            ], width: 200)
            .offset(x: 380, y: 98)
        }
        .frame(width: 600, height: 596, alignment: .topLeading)
    }
}

// MARK: Sheet 8, custom groups

struct GroupSheet: View {
    var body: some View {
        GlassPanel(radius: 24) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Edit Group").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.foreground)
                HStack(spacing: 12) {
                    Text("Name").font(.system(size: 13)).foregroundStyle(Palette.secondary).frame(width: 56, alignment: .trailing)
                    Field(text: "Acme", focused: true)
                }
                HStack(alignment: .top, spacing: 12) {
                    Text("Folders").font(.system(size: 13)).foregroundStyle(Palette.secondary).frame(width: 56, alignment: .trailing).padding(.top, 8)
                    VStack(alignment: .leading, spacing: 0) {
                        FolderRule(path: "~/Repos/Work", subfolders: true, matches: 44, selected: true)
                        Rectangle().fill(Palette.foreground.opacity(0.08)).frame(height: 1)
                        FolderRule(path: "~/Repos/Gustaf/crew", subfolders: false, matches: 3)
                        Rectangle().fill(Palette.foreground.opacity(0.08)).frame(height: 1)
                        HStack(spacing: 0) {
                            Image(systemName: "plus").frame(width: 28, height: 24)
                            Rectangle().fill(Palette.foreground.opacity(0.12)).frame(width: 1, height: 16)
                            Image(systemName: "minus").frame(width: 28, height: 24)
                            Spacer()
                            Text("Drop folders here").font(.system(size: 11)).foregroundStyle(Palette.tertiary).padding(.trailing, 12)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                        .padding(.horizontal, 4)
                        .frame(height: 32)
                    }
                    .background(Color.black.opacity(0.22), in: .rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.foreground.opacity(0.12), lineWidth: 1))
                }
                HStack(alignment: .top, spacing: 12) {
                    Text("Matches").font(.system(size: 13)).foregroundStyle(Palette.secondary).frame(width: 56, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("47 sessions in 4 projects").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.foreground)
                        HStack(spacing: 8) {
                            Chip(name: "acme-hub", count: 36)
                            Chip(name: "acme-infra", count: 6)
                            Chip(name: "acme-cms", count: 2)
                            Chip(name: "crew", count: 3)
                        }
                    }
                }
                HStack(spacing: 8) {
                    Button2(title: "Delete Group…", destructive: true)
                    Spacer()
                    Button2(title: "Cancel")
                    Button2(title: "Save", primary: true)
                }
                .padding(.top, 4)
            }
            .padding(24)
            .frame(width: 520)
        }
    }
}

struct FolderRule: View {
    let path: String
    let subfolders: Bool
    let matches: Int
    var selected = false

    var body: some View {
        HStack(spacing: 12) {
            Text(path).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.foreground).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text("\(matches)").font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.tertiary)
            Check(on: subfolders, label: "Subfolders")
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Palette.foreground.opacity(selected ? 0.08 : 0))
    }
}

struct Chip: View {
    let name: String
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Text(name).foregroundStyle(Palette.foreground.opacity(0.85))
            Text("\(count)").monospacedDigit().foregroundStyle(Palette.tertiary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Palette.foreground.opacity(0.08), in: .capsule)
    }
}

struct GroupPopover: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            GlassPanel(radius: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Field(text: "Mac apps", focused: true)
                    VStack(alignment: .leading, spacing: 4) {
                        Token(path: "~/Repos/Gustaf/berth")
                        Token(path: "~/Repos/Gustaf/tine")
                        Token(path: "~/Repos/tinecli", note: "+ subfolders")
                        Token(path: "~/Repos/Gustaf/rinse")
                        Token(path: "~/Repos/Gustaf/spaces")
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        Text("Add Folder…")
                        Spacer()
                        Text("63 sessions").foregroundStyle(Palette.secondary)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.foreground)
                    .frame(height: 24)
                }
                .padding(16)
                .frame(width: 300)
            }
            Arrow(edge: .left).fill(Color(hex: 0x30343C)).frame(width: 10, height: 20).offset(x: -9, y: 16)
        }
    }
}

struct Token: View {
    let path: String
    var note: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(path).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.foreground).lineLimit(1).truncationMode(.middle)
            if let note { Text(note).font(.system(size: 11)).foregroundStyle(Palette.tertiary) }
            Spacer(minLength: 4)
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.tertiary)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Palette.foreground.opacity(0.06), in: .rect(cornerRadius: 6))
    }
}

struct SettingsWindow: View {
    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Lights().padding(.leading, 20).padding(.top, 20)
                VStack(spacing: 8) {
                    Text("Groups").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.foreground)
                    HStack(spacing: 4) {
                        SettingsTab(symbol: "gearshape", title: "General")
                        SettingsTab(symbol: "paintpalette", title: "Appearance")
                        SettingsTab(symbol: "rectangle.stack", title: "Groups", selected: true)
                        SettingsTab(symbol: "info.circle", title: "About")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
            }
            .frame(height: 96)
            VStack(alignment: .leading, spacing: 20) {
                FormSection(title: "Custom groups") {
                    SettingsGroupRow(name: "Acme", summary: "~/Repos/Work + subfolders, ~/Repos/Gustaf/crew", count: 47, expanded: true)
                    VStack(alignment: .leading, spacing: 0) {
                        FolderRule(path: "~/Repos/Work", subfolders: true, matches: 44)
                        FolderRule(path: "~/Repos/Gustaf/crew", subfolders: false, matches: 3)
                        HStack(spacing: 16) {
                            Text("Add Folder…").foregroundStyle(Palette.foreground)
                            Text("Remove").foregroundStyle(Palette.secondary)
                            Spacer()
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                    }
                    .padding(.leading, 28)
                    FormDivider()
                    SettingsGroupRow(name: "Mac apps", summary: "berth, tine, tinecast, rinse, spaces", count: 63)
                    FormDivider()
                    HStack {
                        Text("Add Group…").font(.system(size: 13)).foregroundStyle(Palette.foreground)
                        Spacer()
                        Text("Drag to reorder").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                }
                FormSection(title: "Everything else") {
                    HStack {
                        Text("Group by").font(.system(size: 13)).foregroundStyle(Palette.foreground)
                        Spacer()
                        PopUp(title: "Project").frame(width: 140)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    FormDivider()
                    HStack {
                        Text("Sessions in two groups").font(.system(size: 13)).foregroundStyle(Palette.foreground)
                        Spacer()
                        Text("First match wins").font(.system(size: 13)).foregroundStyle(Palette.secondary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                }
            }
            .padding(.horizontal, 24)
            Spacer(minLength: 0)
        }
        .frame(width: 600, height: 540)
        .background(Palette.background)
        .clipShape(.rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.hairline, lineWidth: 1))
    }
}

struct SettingsTab: View {
    let symbol: String
    let title: String
    var selected = false

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 18)).frame(height: 24)
            Text(title).font(.system(size: 11))
        }
        .foregroundStyle(selected ? Palette.foreground : Palette.secondary)
        .frame(width: 80, height: 48)
        .background(Palette.foreground.opacity(selected ? 0.1 : 0), in: .rect(cornerRadius: 8))
    }
}

struct FormSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.secondary).padding(.leading, 12)
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.vertical, 4)
                .background(Palette.foreground.opacity(0.05), in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.foreground.opacity(0.08), lineWidth: 1))
        }
    }
}

struct FormDivider: View {
    var body: some View { Rectangle().fill(Palette.foreground.opacity(0.08)).frame(height: 1).padding(.horizontal, 12) }
}

struct SettingsGroupRow: View {
    let name: String
    let summary: String
    let count: Int
    var expanded = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundStyle(Palette.tertiary).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.foreground)
                Text(summary).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Text("\(count) sessions").font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.tertiary)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
    }
}

struct Sheet8: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 48) {
            SheetTitle(title: "Berth · Custom groups", subtitle: "Sheet 8. A group is a name plus folder rules (a folder, optionally with subfolders). Matching sessions go there; the rest fall back to the automatic groups below. First matching group wins.")
            HStack(alignment: .top, spacing: 48) {
                Panel(code: "C1", title: "Custom group header menu", caption: "Right-click a custom header. New Session lists the group's folders (same as its +), then edit, rename in place, reorder, delete. Deleting never touches transcripts.") {
                    Window(toolbar: { GroupByButton(mode: "Project") }, side: { CustomSidebar() })
                        .overlay(alignment: .topLeading) {
                            Menu(items: [
                                MI(title: "New Session in", sub: true),
                                .divider,
                                MI(title: "Edit Group…"),
                                MI(title: "Rename"),
                                MI(title: "Move Up"),
                                MI(title: "Move Down"),
                                .divider,
                                MI(title: "Delete Group…", destructive: true),
                            ], width: 200)
                            .offset(x: 80, y: 96)
                        }
                }
                Panel(code: "C2", title: "Project header: Add to Group ▸", caption: "Right-click an automatic project header. Add to Group adds that project's folder as a rule to an existing group, or starts a new group prefilled with it.") {
                    Window(toolbar: { GroupByButton(mode: "Project") }, side: { CustomSidebar(customCollapsed: true) })
                        .overlay(alignment: .topLeading) {
                            ZStack(alignment: .topLeading) {
                                Menu(items: [
                                    MI(title: "New Session"),
                                    .divider,
                                    MI(title: "Add to Group", sub: true, open: true),
                                    MI(title: "Copy Path"),
                                    MI(title: "Reveal in Finder"),
                                    .divider,
                                    MI(title: "Collapse"),
                                ], width: 160)
                                Menu(items: [
                                    MI(title: "Acme"),
                                    MI(title: "Mac apps"),
                                    .divider,
                                    MI(title: "New Group from crew…"),
                                ], width: 204)
                                .offset(x: 156, y: 36)
                            }
                            .offset(x: 28, y: 200)
                        }
                }
                Panel(code: "C3", title: "Edit sheet with live match count", caption: "Edit Group… / New Group… open a sheet: name, folder list (+/−, drag folders in), a Subfolders toggle and match count per rule, and a live preview of which projects land in the group before you save.", width: 600) {
                    Window(width: 600, height: 600, side: { CustomSidebar() })
                        .overlay { Color.black.opacity(0.25).clipShape(.rect(cornerRadius: 16)) }
                        .overlay(alignment: .top) { GroupSheet().scaleEffect(0.96).padding(.top, 64) }
                }
            }
            HStack(alignment: .top, spacing: 48) {
                Panel(code: "C4", title: "Inline popover from the header", caption: "Lighter alternative to C3: Edit Group… opens a popover beside the header. Name, folder tokens (× to remove, \"+ subfolders\" when recursive), Add Folder…, live count. Changes apply as you type.", width: 640) {
                    Window(width: 640, side: { CustomSidebar() })
                        .overlay(alignment: .topLeading) { GroupPopover().offset(x: 288, y: 254) }
                }
                Panel(code: "C5", title: "Settings ▸ Groups tab", caption: "All groups in one place, next to General / Appearance / About. Rows expand to their folder rules, drag to reorder (order = priority), plus the fallback grouping for everything else.", width: 600) {
                    SettingsWindow()
                }
            }
        }
        .padding(48)
        .background(.white)
    }
}

// MARK: Sheet 9, new session

struct Launcher: View {
    var body: some View {
        GlassPanel(radius: 20) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.secondary)
                    HStack(spacing: 1) {
                        Text("~/Repos/Gustaf/ti").font(.system(size: 17)).foregroundStyle(Palette.foreground)
                        Rectangle().fill(Palette.foreground).frame(width: 1.5, height: 20)
                    }
                    Spacer()
                    Key(key: "⌘O", label: "Browse…")
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                Rectangle().fill(Palette.foreground.opacity(0.08)).frame(height: 1)
                VStack(spacing: 0) {
                    Match(head: "ti", tail: "ne", path: "~/Repos/Gustaf/tine", meta: "41 sessions · 1d", selected: true)
                    Match(head: "ti", tail: "necast", path: "~/Repos/Gustaf/tinecast", meta: "18 sessions · 3d")
                    Match(head: "ti", tail: "netype", path: "~/Repos/Gustaf/tinetype", meta: "7 sessions · 1w")
                    Match(head: "ti", tail: "dy", path: "~/Repos/Gustaf/tidy", meta: "5 sessions · 2w")
                }
                .padding(8)
                Rectangle().fill(Palette.foreground.opacity(0.08)).frame(height: 1)
                HStack(spacing: 12) {
                    Text("❯").font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.secondary)
                    Text("First prompt (optional)").font(.system(size: 13)).foregroundStyle(Palette.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
                Rectangle().fill(Palette.foreground.opacity(0.08)).frame(height: 1)
                HStack(spacing: 16) {
                    Key(key: "↩", label: "Start in tine")
                    Key(key: "⇥", label: "Prompt")
                    Key(key: "↑↓", label: "Folder")
                    Spacer()
                    Key(key: "esc", label: "Cancel")
                }
                .padding(.horizontal, 16)
                .frame(height: 40)
            }
            .frame(width: 520)
        }
    }
}

struct Match: View {
    let head: String
    let tail: String
    let path: String
    let meta: String
    var selected = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    Text(head).fontWeight(.bold).foregroundStyle(Palette.foreground)
                    Text(tail).foregroundStyle(Palette.foreground.opacity(0.85))
                }
                .font(.system(size: 13))
                Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.tertiary)
            }
            Spacer()
            Text(meta).font(.system(size: 11)).foregroundStyle(Palette.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Palette.foreground.opacity(selected ? 0.1 : 0), in: .rect(cornerRadius: 10))
    }
}

struct NewSessionPopover: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            GlassPanel(radius: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("New Session").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.foreground)
                    PopUp(title: "rinse", note: "~/Repos/Gustaf/rinse")
                    Field(text: "What should Claude do? (optional)", placeholder: true, focused: true, height: 72)
                    HStack(spacing: 8) {
                        Button2(title: "Browse…")
                        Spacer()
                        Button2(title: "Start", primary: true)
                    }
                }
                .padding(16)
                .frame(width: 320)
            }
            Arrow(edge: .up).fill(Color(hex: 0x30343C)).frame(width: 20, height: 10).offset(x: 16, y: -9)
        }
    }
}

struct InlineNewSidebar: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("New session in").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.secondary)
                Field(text: "~/Repos/Work/pl", focused: true, mono: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
            ProjectSidebar().opacity(0.4)
        }
    }
}

struct SinglePathSidebar: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(name: "acme-hub", count: 36)
            Row(title: "Registry filters endpoint search design", time: "24m", pr: (1384, Palette.green), branch: "feat/registry-filters", loaded: true)
            Row(title: "Pricelist agent for issue 1369", time: "3h", branch: "main", status: .needsYou, loaded: true)
            Header(name: "rinse", count: 24, plusActive: true)
            Row(title: "New session", time: "now", branch: "main", loaded: true, selected: true)
            Row(title: "Rinse ControlWidget extension", time: "1d", branch: "widget")
            Row(title: "App Group signing from .env", time: "3d", pr: (12, Palette.magenta), branch: "signing")
            Header(name: "tine", count: 41)
            Row(title: "Spec loader crash on empty JSON", time: "1d")
        }
    }
}

struct Sheet9: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 48) {
            SheetTitle(title: "Berth · New session, folder first", subtitle: "Sheet 9. Folder suggestions come from every cwd in history (most recent first) plus Browse…. Choosing a folder you've never used just starts claude there.")
            HStack(alignment: .top, spacing: 48) {
                Panel(code: "N1", title: "⌘N launcher over the terminal", caption: "Spotlight-style glass panel centred over the terminal. Type to fuzzy-match known folders (name, then path), ↩ starts claude there, ⇥ jumps to an optional first prompt that is sent once claude is ready. A typed path that exists works too; ⌘O opens the folder picker.", width: 1000) {
                    Window(width: 1000, height: 600, terminal: Terminal(title: "Custom sidebar groups design", path: "~/Repos/Gustaf/berth", lines: [("✻ Thinking…", Palette.secondary)]), toolbar: { ComposeButton() }, side: { ProjectSidebar().opacity(0.6) })
                        .overlay { Color.black.opacity(0.2).clipShape(.rect(cornerRadius: 16)) }
                        .overlay(alignment: .topLeading) { Launcher().offset(x: 390, y: 96) }
                }
                Panel(code: "N2", title: "Popover from the compose button", caption: "The sidebar toolbar gets a compose button (also ⌘N). Its popover: folder pop-up (recent folders, Other…), optional prompt, Start. Mouse-friendly, but slower to type into than N1.", width: 640) {
                    Window(width: 640, height: 600, toolbar: { ComposeButton(active: true) }, side: { ProjectSidebar() })
                        .overlay(alignment: .topLeading) { NewSessionPopover().offset(x: 256, y: 52) }
                }
            }
            HStack(alignment: .top, spacing: 48) {
                Panel(code: "N3", title: "Inline row at the top of the sidebar", caption: "⌘N inserts an editable folder field above the groups; completions drop down as a menu, ↩ starts and the field turns into the new row. Stays in the sidebar, no prompt field.") {
                    Window(side: { InlineNewSidebar() })
                        .overlay(alignment: .topLeading) {
                            Menu(items: [
                                MI(title: "acme-hub", key: "36"),
                                MI(title: "acme-infra", key: "6"),
                                MI(title: "acme-cms", key: "2"),
                                .divider,
                                MI(title: "Browse…", key: "⌘O"),
                            ], width: 268)
                            .offset(x: 16, y: 120)
                        }
                }
                Panel(code: "N4", title: "+ on a single-folder group", caption: "Project groups (and custom groups with one folder, no subfolders) start a session instantly: the new row appears on top of the group, selected, time \"now\" in green, title \"New session\" until the first prompt names it.") {
                    Window(toolbar: { ComposeButton() }, terminal: Terminal(title: "New session", path: "~/Repos/Gustaf/rinse", lines: [("╭ Claude Code", Palette.dim), ("│ cwd: ~/Repos/Gustaf/rinse", Palette.secondary), ("❯ ", Palette.foreground)]), side: { SinglePathSidebar() })
                }
                Panel(code: "N5", title: "+ on a multi-folder group", caption: "When a group spans folders, + opens a small menu: known projects under its rules (most recent first), then Other Folder… scoped to the rule's root. Same menu as C1's New Session in ▸.") {
                    Window(toolbar: { GroupByButton(mode: "Project") }, side: { CustomSidebar(plusOnAcme: true) })
                        .overlay(alignment: .topLeading) {
                            Menu(items: [
                                .header("Start in"),
                                MI(title: "acme-hub", key: "24m"),
                                MI(title: "acme-infra", key: "5h"),
                                MI(title: "acme-cms", key: "2w"),
                                MI(title: "crew", key: "2d"),
                                .divider,
                                MI(title: "Other Folder in Work…"),
                            ], width: 248)
                            .offset(x: 52, y: 92)
                        }
                }
            }
        }
        .padding(48)
        .background(.white)
    }
}

extension Window {
    init(width: CGFloat = 400, height: CGFloat = 600, @ViewBuilder toolbar: () -> Toolbar, terminal: Terminal, @ViewBuilder side: () -> Side) {
        self.init(width: width, height: height, terminal: terminal, toolbar: toolbar, side: side)
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
    write(Sheet7(), to: "\(directory)/sheet-7.png")
    write(Sheet8(), to: "\(directory)/sheet-8.png")
    write(Sheet9(), to: "\(directory)/sheet-9.png")
}
