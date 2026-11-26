#if DEBUG
import AppKit
import BerthCore
import Foundation
import SwiftUI

extension ItemPreview {
    static let fixtureRoundingPullRequest: Self = {
        let updated = Date.now.addingTimeInterval(-3600)
        let checks = ["Build", "Lint", "Unit tests", "API tests", "Ledger fixtures", "Type check", "Migration check", "Package smoke test"]
            .map { ItemChecks.Check(name: $0, outcome: .passed) }
            + [.init(name: "Settlement replay", outcome: .failed), .init(name: "Integration tests", outcome: .failed), .init(name: "Coverage", outcome: .running)]
        return Self(
            kind: .pullRequest, repository: "alder-labs/ledger", number: 4837, url: URL(string: "https://github.com/alder-labs/ledger/pull/4837")!,
            title: "Round half up in the ledger reconciliation", state: .open,
            body: """
            <!-- Internal pull request template -->
            ### Settlement rounding

            - Round half-cents up before comparing settlement totals.
            - Cover positive and negative adjustments in the replay fixtures.

            ```swift
            let total = amount.rounded(.halfUp, scale: 2)
            ```

            | Input | Before | After |
            | --- | --- | --- |
            | 10.005 | 10.00 | 10.01 |
            | −10.005 | −10.00 | −10.01 |
            """,
            author: .init(login: "marin-cole", avatarURL: URL(string: "https://example.invalid/marin.png")),
            createdAt: .now.addingTimeInterval(-3 * 86_400), updatedAt: updated,
            labels: [.init(name: "billing", color: "b60205"), .init(name: "bug", color: "d73a4a"), .init(name: "needs review", color: "fbca04")],
            assignees: ["marin-cole", "ren-owens"],
            reviewers: [
                .init(login: "ren-owens", state: .approved),
                .init(login: "ines-nash", state: .changesRequested),
                .init(login: "ledger-platform", state: .requested),
            ],
            reviewDecision: .changesRequested, checks: .init(items: checks),
            additions: 214, deletions: 37, changedFiles: 9, baseRefName: "main", headRefName: "fix/settlement-rounding",
            related: [.init(repository: "alder-labs/ledger", number: 4821, title: "Ledger and settlement export disagree by a cent", isPullRequest: false, state: "OPEN")],
            comments: [
                .init(author: "ren-owens", body: "The two examples now match the reconciliation report.", createdAt: updated.addingTimeInterval(-14_400)),
                .init(author: "ines-nash", body: "Please add a replay test for a negative adjustment at the half-cent boundary.", createdAt: updated.addingTimeInterval(-7200)),
                .init(author: "marin-cole", body: "Added the negative case to `ledger-fixtures`. The replay is running again.", createdAt: updated),
            ], commentCount: 7
        )
    }()

    static var fixtureReviewIssue: Self {
        let issue = Snapshot.reviewIssueFixture
        return Self(
            kind: .issue, repository: issue.ref.repository, number: issue.ref.number, url: issue.ref.url!,
            title: issue.title, state: .open, body: "The CSV export omits the currency for EUR invoices.",
            author: .init(login: "mara"), createdAt: .now - 86_400, updatedAt: .now - 3600,
            labels: [.init(name: "bug", color: "d73a4a"), .init(name: "export", color: "0366d6")], assignees: ["mara"]
        )
    }

    static var fixtureReviewPullRequest: Self? {
        guard let pullRequest = Snapshot.reviewPullRequestFixture, let reference = ItemReference(url: pullRequest.url) else { return nil }

        let state: State = switch pullRequest.state {
        case .open: .open
        case .draft: .draft
        case .merged: .merged
        case .closed: .closed
        }
        return Self(
            kind: .pullRequest, repository: reference.repository, number: pullRequest.number, url: pullRequest.url,
            title: pullRequest.title, state: state,
            body: """
            Add currency to the ledger export and cover reconciliation in the fixtures.

            - Include `invoice.currency` on each row.
            - Check that EUR settlements round to the correct minor unit.
            """,
            author: .init(login: "mara"), createdAt: .now - 86_400, updatedAt: .now - 1800,
            reviewers: [
                .init(login: "lee", state: .approved),
                .init(login: "kim", state: .changesRequested),
                .init(login: "sam", state: .requested),
            ],
            reviewDecision: .changesRequested,
            checks: .init(items: [.init(name: "Build", outcome: .passed), .init(name: "Settlement replay", outcome: .failed), .init(name: "Unit tests", outcome: .running)]),
            baseRefName: pullRequest.baseRefName, headRefName: pullRequest.headRefName,
            related: pullRequest.closingIssues.map { .init(repository: $0.ref.repository, number: $0.ref.number, title: $0.title, isPullRequest: false, state: "OPEN") },
            comments: [
                .init(author: "kim", body: "Please cover totals less than one euro in the replay fixture.", createdAt: .now - 10_800),
                .init(author: "mara", body: "Added a case for `0.01 EUR` and restarted the replay.", createdAt: .now - 1800),
            ], commentCount: 2
        )
    }

    static let fixtureStartupIssue: Self = {
        let updated = Date.now.addingTimeInterval(-2 * 3600)
        return Self(
            kind: .issue, repository: "alder-labs/ledger", number: 4902, url: URL(string: "https://github.com/alder-labs/ledger/issues/4902")!,
            title: "Export fails for ledgers with more than 10,000 rows", state: .open,
            body: """
            ### Reproduce the export failure

            1. Import a ledger with more than 10,000 entries.
            2. Choose **Export CSV** from the ledger.
            3. Check the export log after the progress bar disappears.

            ```text
            Export stopped after 10,000 rows
            ```

            The CSV should include the full ledger.
            """,
            author: .init(login: "inez-park"), createdAt: .now.addingTimeInterval(-5 * 86_400), updatedAt: updated,
            labels: [.init(name: "bug", color: "d73a4a"), .init(name: "good first issue", color: "7057ff"), .init(name: "p1", color: "fc8a15")],
            assignees: ["nico-chen"],
            related: [
                .init(repository: "alder-labs/ledger", number: 4911, title: "Stream rows when exporting a large ledger", isPullRequest: true, state: "OPEN"),
                .init(repository: "alder-labs/ledger", number: 4908, title: "Log the row count when a CSV export stops", isPullRequest: true, state: "MERGED"),
            ],
            comments: [
                .init(author: "nico-chen", body: "Reproduced on a new ledger with 10,001 rows.", createdAt: updated.addingTimeInterval(-10_800)),
                .init(author: "inez-park", body: "Confirmed that exports with exactly **10,000** rows still work.", createdAt: updated),
            ], commentCount: 2
        )
    }()
}

extension Snapshot {
    static func captureItemPreview(to output: URL, theme: GhosttyTheme) {
        guard let variant = UserDefaults.standard.string(forKey: "snapshotItemPreview") else { return }

        let preview: ItemPreview
        let actions: ItemPreviewActions
        switch variant {
        case "pr", "pr-checks":
            preview = .fixtureRoundingPullRequest
            actions = ItemPreviewActions(openInBerth: {}, openInBerthTitle: "Resume Session", copyLink: {}, openOnGitHub: {})

        case "issue":
            preview = .fixtureStartupIssue
            actions = ItemPreviewActions(openInBerthDisabledReason: "This repository has no local checkout.", copyLink: {}, openOnGitHub: {})

        default:
            fail("snapshotItemPreview requires pr, issue or pr-checks")
        }

        let card = ItemPreviewView(
            preview: preview, actions: actions, checksExpanded: variant == "pr-checks",
            initialNodes: ItemPreviewView.markdownNodes(in: preview.body)
        )
        .environment(\.ghosttyTheme, theme)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .background(theme.background ?? .white, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.foreground.opacity(0.15)))
        .padding(8)

        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        let destination = URL(fileURLWithPath: "\(output.path).preview-\(variant).png")
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              (try? png.write(to: destination)) != nil
        else { fail("could not write \(destination.path)") }
    }
}
#endif
