// Run: swift design/mockups-5.swift   (writes design/sheet-5.png)
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

enum Concept { case drawer, tabs, split }

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
            Row(title: "Registry filters endpoint search design", time: "24m", detail: "⑂ feat/registry-filters", detailColor: Palette.cyan, selected: true, shellBadge: concept == .drawer)
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

struct Detail: View {
    let concept: Concept

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Registry filters endpoint search design").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.foreground)
                    Text("~/Repos/Work/acme-hub").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
                Spacer()
                Text(shortcut).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Palette.foreground.opacity(0.08), in: .capsule)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            if concept == .tabs {
                HStack(spacing: 4) {
                    tab("Claude", symbol: "sparkle", selected: false)
                    tab("zsh", symbol: "apple.terminal", selected: false)
                    tab("npm run dev", symbol: "apple.terminal", selected: true)
                    Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(Palette.secondary).frame(width: 24, height: 24)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                Pane(lines: shellLines)
            } else if concept == .drawer {
                Pane(lines: claudeLines)
                drawerHeader
                Pane(lines: shellLines).frame(height: 200)
            } else {
                HStack(spacing: 0) {
                    Pane(lines: claudeLines)
                    Rectangle().fill(Palette.foreground.opacity(0.1)).frame(width: 1)
                    VStack(spacing: 0) {
                        Pane(lines: shellLines)
                        Rectangle().fill(Palette.foreground.opacity(0.1)).frame(height: 1)
                        Pane(lines: [("➜ acme-hub git:(feat/registry-filters) git status", Palette.cyan), ("nothing to commit, working tree clean", Palette.dim)])
                    }
                    .frame(width: 300)
                }
            }
        }
    }

    private var shortcut: String {
        switch concept {
        case .drawer: "⌘J  Shell drawer"
        case .tabs: "⌘T  New shell tab"
        case .split: "⌘D  Split shell"
        }
    }

    private var drawerHeader: some View {
        HStack(spacing: 8) {
            Capsule().fill(Palette.foreground.opacity(0.25)).frame(width: 32, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 12)
        .overlay(alignment: .top) { Rectangle().fill(Palette.foreground.opacity(0.1)).frame(height: 1) }
    }

    private func tab(_ title: String, symbol: String, selected: Bool) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 11, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Palette.foreground : Palette.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(selected ? Palette.foreground.opacity(0.1) : .clear, in: .rect(cornerRadius: 8))
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
                Window(concept: .drawer, title: "A  Shell drawer per session (⌘J)", pro: "Claude stays full width; the shell is one keystroke away and lives with its session (green glyph on the row while it runs).", con: "Only one visible shell per session; long-running output is cramped in a drawer.")
                Window(concept: .tabs, title: "B  Tabs inside the session (⌘T)", pro: "Any number of shells, familiar tab model, the sidebar stays sessions only.", con: "Claude and the shell are never visible at the same time.")
            }
            HStack(alignment: .top, spacing: 32) {
                Window(concept: .split, title: "C  Side split (⌘D, up to 2 stacked)", pro: "Claude and a dev server visible side by side, good on wide screens.", con: "Squeezes Claude's column; awkward on a laptop.")
                VStack(alignment: .leading, spacing: 12) {
                    Text("Header terminal button, no session selected").font(.system(size: 15, weight: .semibold)).foregroundStyle(.black)
                    Text("Suggestion: drop the terminal button from project headers (the headers above show only +). A shell always belongs to a session: ⌘J / ⌘T / ⌘D act on the selected session, and with nothing selected they start a new Claude session in that project first. One less button per header and no orphan terminal rows.")
                        .font(.system(size: 13)).foregroundStyle(.black).frame(width: 600, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    Text("Recommendation: A, with B's tab strip appearing inside the drawer only once a second shell is opened.")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.black).frame(width: 600, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 40)
            }
        }
        .padding(32)
        .background(.white),
        to: "\(directory)/sheet-5.png"
    )
}
