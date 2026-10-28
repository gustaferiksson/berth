// Run: swift design/mockups-6.swift   (writes design/sheet-6.png)
import AppKit
import SwiftUI

enum Palette {
    static let background = Color(hex: 0x282C34)
    static let foreground = Color(hex: 0xFFFFFF)
    static let secondary = Color(hex: 0xFFFFFF).opacity(0.6)
    static let green = Color(hex: 0x98C379)
    static let yellow = Color(hex: 0xE5C07B)
    static let magenta = Color(hex: 0xC678DD)
    static let cyan = Color(hex: 0x56B6C2)
    static let dim = Color(hex: 0xABB2BF)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

enum Concept { case strip, panel, toolbar }

struct Row: View {
    let title: String
    let time: String
    var detail = "–"
    var detailColor = Palette.secondary
    var status: Color?
    var selected = false
    var shellBadge = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title).font(.system(size: 13)).foregroundStyle(Palette.foreground).lineLimit(1)
                if shellBadge {
                    Image(systemName: "apple.terminal.fill").font(.system(size: 10)).foregroundStyle(Palette.green)
                }
                Spacer(minLength: 8)
                Text(time).font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }
            Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(detailColor).lineLimit(1).frame(height: 16)
        }
        .padding(.leading, 24)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .topLeading) {
            if let status { Circle().fill(status).frame(width: 8, height: 8).padding(.leading, 8).padding(.top, 13) }
        }
        .background(selected ? Palette.foreground.opacity(0.1) : .clear, in: .rect(cornerRadius: 8))
        .padding(.horizontal, 8)
    }
}

struct Header: View {
    let name: String
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).frame(width: 12)
            Text(name).fontWeight(.semibold)
            Text("\(count)").opacity(0.6)
            Spacer()
            Image(systemName: "plus").frame(width: 24, height: 24)
        }
        .font(.system(size: 11))
        .foregroundStyle(Palette.secondary.opacity(0.8))
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

struct Sidebar: View {
    let concept: Concept

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color(hex: 0xFF5F57), Color(hex: 0xFEBC2E), Color(hex: 0x28C840)], id: \.self) { Circle().fill($0).frame(width: 12, height: 12) }
            }
            .padding(.horizontal, 20)
            .frame(height: 44)
            Header(name: "acme-hub", count: 36)
            Row(title: "Registry filters endpoint search design", time: "24m", detail: "⑂ feat/registry-filters", detailColor: Palette.cyan, selected: true)
            Row(title: "Acme-hub PR 1380", time: "1h", detail: "⑂ main", detailColor: Palette.cyan)
            Row(title: "Acme-hub issue 1369 pricelist agent", time: "3h", detail: "⑂ main", detailColor: Palette.cyan, status: Palette.yellow)
            Header(name: "Gustaf", count: 36)
            Row(title: "Hermes bots multiplatform SwiftUI app", time: "now")
            Row(title: "Accessible SharePoint sites endpoint", time: "2h")
            Spacer()
        }
        .frame(width: 320)
    }
}

struct Pane: View {
    let lines: [(String, Color)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(lines.indices, id: \.self) { Text(lines[$0].0).foregroundStyle(lines[$0].1) }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

let claudeLines: [(String, Color)] = [
    ("● Added the filter endpoint and its tests.", Palette.foreground),
    ("✻ Worked for 2m 10s", Palette.secondary),
    ("❯ run the dev server and check /registry", Palette.dim),
    ("● Starting it in your shell…", Palette.yellow),
]
let shellLines: [(String, Color)] = [
    ("➜ acme-hub git:(feat/registry-filters) npm run dev", Palette.cyan),
    ("  VITE v6.0.3  ready in 412 ms", Palette.green),
    ("  ➜  Local:   http://localhost:5173/", Palette.dim),
]

struct ShellTab: View {
    let title: String
    let symbol: String
    var selected = false
    var running = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).imageScale(.small)
            Text(title).lineLimit(1)
            if running {
                HStack(spacing: 1) { ForEach(0..<3) { Circle().fill(Palette.green.opacity($0 == 2 ? 1 : 0.4)).frame(width: 2.5, height: 2.5) } }
            }
        }
        .font(.system(size: 11, weight: selected ? .semibold : .regular))
        .foregroundStyle(selected ? Palette.foreground : Palette.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(selected ? Palette.foreground.opacity(0.1) : .clear, in: .rect(cornerRadius: 8))
    }
}

struct Tabs: View {
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            ShellTab(title: compact ? "Claude" : "Registry filters endpoint…", symbol: "sparkle", selected: true)
            ShellTab(title: "zsh", symbol: "apple.terminal")
            ShellTab(title: "npm run dev", symbol: "apple.terminal", running: true)
            Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(Palette.secondary).frame(width: 24, height: 24)
        }
    }
}

struct Detail: View {
    let concept: Concept

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if concept == .toolbar {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Registry filters endpoint search design").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.foreground).lineLimit(1)
                        Text("~/Repos/Work/acme-hub").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    }
                    .frame(width: 220, alignment: .leading)
                    Tabs(compact: true)
                        .padding(4)
                        .background(Palette.foreground.opacity(0.05), in: .capsule)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                Pane(lines: claudeLines)
            } else {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Registry filters endpoint search design").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.foreground)
                        Text("~/Repos/Work/acme-hub").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    }
                    Spacer()
                    Text(concept == .strip ? "⌘T  New shell tab" : "⌘J  Terminal panel").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Palette.foreground.opacity(0.08), in: .capsule)
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
                if concept == .strip {
                    Tabs().padding(.horizontal, 12).padding(.bottom, 4)
                    Pane(lines: claudeLines)
                } else {
                    Pane(lines: claudeLines)
                    VStack(alignment: .leading, spacing: 0) {
                        Capsule().fill(Palette.foreground.opacity(0.25)).frame(width: 32, height: 4).frame(maxWidth: .infinity).frame(height: 12)
                        HStack(spacing: 4) {
                            ShellTab(title: "zsh", symbol: "apple.terminal")
                            ShellTab(title: "npm run dev", symbol: "apple.terminal", selected: true, running: true)
                            Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(Palette.secondary).frame(width: 24, height: 24)
                            Spacer()
                            Image(systemName: "chevron.down").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                        }
                        .padding(.horizontal, 12)
                        Pane(lines: shellLines)
                    }
                    .frame(height: 230)
                    .overlay(alignment: .top) { Rectangle().fill(Palette.foreground.opacity(0.1)).frame(height: 1) }
                }
            }
        }
    }
}

struct Window: View {
    let concept: Concept
    let title: String
    let pro: String
    let con: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.black)
            HStack(spacing: 0) {
                Sidebar(concept: concept)
                Rectangle().fill(Color.black.opacity(0.25)).frame(width: 1)
                Detail(concept: concept)
            }
            .frame(width: 1000, height: 620, alignment: .top)
            .background(Palette.background)
            .clipShape(.rect(cornerRadius: 16))
            Text("+ " + pro).font(.system(size: 12)).foregroundStyle(.black)
            Text("− " + con).font(.system(size: 12)).foregroundStyle(.black)
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
            HStack(alignment: .top, spacing: 32) {
                Window(concept: .strip, title: "A  Global tab strip above the terminal (⌘T)", pro: "One familiar strip; shells stay put across sessions and the Claude tab follows the sidebar.", con: "The first tab changes meaning as you switch sessions, which can surprise.")
                Window(concept: .panel, title: "B  Global bottom panel with tabs (⌘J)", pro: "Claude and a dev server visible together; the panel is independent of sessions, like VS Code.", con: "Takes vertical space from Claude whenever it's open.")
            }
            HStack(alignment: .top, spacing: 32) {
                Window(concept: .toolbar, title: "C  Tabs in the toolbar (Safari-style compact)", pro: "No extra chrome row; the most native macOS 26 look.", con: "Toolbar space is tight next to a long session title; tabs truncate quickly.")
                VStack(alignment: .leading, spacing: 12) {
                    Text("Running process signal").font(.system(size: 15, weight: .semibold)).foregroundStyle(.black)
                    Text("A shell tab running a command shows the same small green ellipsis as a working Claude session, right of its title (\"npm run dev ···\"). Idle shells show nothing.")
                        .font(.system(size: 13)).foregroundStyle(.black).frame(width: 600, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    Text("Recommendation: B. It keeps Claude and a running shell visible at once, which A and C can't.")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.black).frame(width: 600, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 40)
            }
        }
        .padding(32)
        .background(.white),
        to: "\(directory)/sheet-6.png"
    )
}
