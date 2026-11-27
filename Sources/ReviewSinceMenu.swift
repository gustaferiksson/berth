import BerthCore
import SwiftUI

struct ReviewSinceMenu: View {
    let model: ReviewModel
    let changes: ReviewChanges
    @State private var recent: [ReviewCommit] = []
    @State private var asksRef = false
    @State private var ref = ""

    var body: some View {
        HStack(spacing: 3) {
            Menu {
                ForEach(recent, id: \.sha) { commit in
                    Button("\(commit.sha) \(commit.subject)") { Task { await model.setSince(commit.sha) } }
                }
                Divider()
                Button("Compare with…") {
                    ref = ""
                    asksRef = true
                }
            } label: {
                HStack(spacing: 3) {
                    if let since = changes.since {
                        Text("since \(since.shortSHA)")
                    } else {
                        Image(systemName: "clock.arrow.circlepath")
                            .accessibilityLabel("Compare since")
                    }
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("Show only what changed since a commit")
            if changes.since != nil {
                Button("Clear Since", systemImage: "xmark.circle.fill") { Task { await model.setSince(nil) } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .help("Compare against the base again")
            }
        }
        .task(id: changes.head) { recent = await (try? ReviewGit.recentCommits(of: changes)) ?? [] }
        .alert("Compare With", isPresented: $asksRef) {
            TextField("Commit, tag or branch", text: $ref)
            Button("Compare") {
                let typed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { if await !model.setSince(typed) { model.notice = "Couldn’t find “\(typed)” in this repository" } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Show only what changed since this commit, tag or branch.")
        }
    }
}

extension ReviewModel {
    @discardableResult
    func setSince(_ ref: String?) async -> Bool {
        since = ref
        await load()
        return ref == nil || since != nil
    }
}
