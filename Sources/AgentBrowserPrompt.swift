import BerthCore
import SwiftUI

struct AgentBrowserPrompt: View {
    let access: BrowserAccess

    var body: some View {
        if let request = access.requests.first {
            AgentBrowserApproval(request: request) { access.resolve(request, with: $0) }
                .background(.background, in: .rect(cornerRadius: CardBorder.radius))
                .overlay { CardBorder() }
                .shadow(radius: 12, y: 4)
        }
    }
}

struct AgentBrowserApproval: View {
    let request: BrowserAccess.Request
    let decide: (BrowserAccess.Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Allow Browser Access?")
                    .font(.headline)
                Text("This agent wants to open and control pages in Berth’s browser.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            sessionCard
            Text("Berth asks once for each session.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Deny", role: .cancel) { decide(.denied) }
                Button("Allow for This Session") { decide(.allowed) }
            }
            .controlSize(.large)
        }
        .padding(20)
        .frame(width: 400)
    }

    private var sessionCard: some View {
        let isWorktree = request.session.map { $0.cwd != $0.checkout } ?? false
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.quaternary, in: .rect(cornerRadius: 7))
                .accessibilityLabel(request.session?.agent.harness.name ?? "Agent")
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: request.title)
                    .font(.headline)
                    .lineLimit(2)
                RepoAndBranch(checkout: request.session?.checkout ?? request.folder, branch: request.session?.branch)
                if isWorktree {
                    Label("Worktree \(URL(filePath: request.folder).lastPathComponent)", systemImage: "square.stack.3d.up")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let url = request.url {
                    Label(url, systemImage: "globe")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.quinary, in: .rect(cornerRadius: 10))
    }
}
