import GhosttyTerminal
import SwiftUI

enum PanelPosition: String {
    case bottom
    case right
}

struct TerminalPanel: View {
    let available: CGSize
    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme
    @AppStorage("terminalPanelHeight") private var height = 240.0
    @State private var dragStart: Double?

    var body: some View {
        let isShown = store.isPanelOpen && !store.shells.isEmpty
        let upperBound = max(120, available.height * 0.7)
        let size = min(max(height, 120), upperBound)
        VStack(spacing: 0) {
            Hairline(axis: .horizontal)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .contentShape(.rect)
                .pointerStyle(.rowResize)
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { drag in
                            let start = dragStart ?? size
                            dragStart = start
                            height = min(max(start - drag.translation.height, 120), upperBound)
                        }
                        .onEnded { _ in dragStart = nil }
                )
            PanelBody(isShown: isShown)
        }
        .frame(height: isShown ? size : 0)
        .clipped()
        .opacity(isShown ? 1 : 0)
        .allowsHitTesting(isShown)
    }
}

struct PanelBody: View {
    let isShown: Bool
    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(store.shells) { shell in
                    ShellTab(shell: shell, terminal: shell.terminal, isSelected: shell.id == store.selectedShellID) {
                        store.selectedShellID = shell.id
                    } close: {
                        store.close(shell.id)
                    }
                }
                Button("New Terminal", systemImage: "plus") { store.openShell(cwd: store.currentCwd) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondary)
                    .frame(width: 24, height: 24)
                    .help("New terminal (⌘T)")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
            ZStack {
                ForEach(store.shells) { shell in
                    let isVisible = isShown && shell.id == store.selectedShellID
                    TerminalSurfaceView(context: shell.terminal)
                        .opacity(isVisible ? 1 : 0)
                        .allowsHitTesting(isVisible)
                        .onChange(of: isVisible, initial: true) { shell.terminal.isSurfaceVisible = isVisible }
                }
            }
        }
        .onChange(of: store.selectedShellID) { _, id in
            store.shells.first { $0.id == id }?.terminal.requestFocus()
        }
    }
}

private struct ShellTab: View {
    let shell: Tab
    @ObservedObject var terminal: TerminalViewState
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isHovering = false
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        let title = shell.title(terminalTitle: terminal.title, sessionTitle: nil)
        HStack(spacing: 4) {
            Image(systemName: "apple.terminal").imageScale(.small)
            Text(title).lineLimit(1)
            if title != Tab.shellName {
                WorkingDots(label: "Running")
            }
            Button("Close Terminal", systemImage: "xmark", action: close)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .bold))
                .opacity(isHovering ? 1 : 0)
                .help("Close terminal")
        }
        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
        .foregroundStyle(isSelected ? theme.foreground : theme.secondary)
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(theme.foreground.opacity(isSelected ? 0.1 : isHovering ? 0.05 : 0), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .help((shell.cwd as NSString).abbreviatingWithTildeInPath)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
    }
}
