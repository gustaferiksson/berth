# Launcher, palette, pull requests and issues

Moved from CLAUDE.md. See also design/flows-groups.md (Launcher section).

## New Session (⌘N)

⌘N (File ▸ New Session…) opens the launcher (`Launcher`, a glass overlay on the terminal area): known session folders, the current folder first, fuzzy matched, plus a typed existing path. `submit` reads `highlighted` at submit time (an `onSubmit` closure once started a stale row). `Store.openClaude` passes the session id (or attach job id) to `claude --session-id|--resume|attach "$BERTH_SESSION_ID"` through the `BERTH_SESSION_ID` env var (`envVars` on the surface), never interpolated, and shows "Folder Not Found" instead of launching in a missing folder.

Settings > General > Agents picks the agent ⌘N starts (`newSessionAgent`, `Store.defaultAgent`, Claude unless chosen otherwise). With both agents enabled the primary action names the default and ⌥⇧↩ starts the other (`Store.otherAgent`), also available in Actions.

With Settings > General `startsInWorktree` on, a new session (launcher, group +, drop, remote) in a folder inside a git repo starts as `claude --session-id "$BERTH_SESSION_ID" -w` (`ClaudeLaunch.Start.newInWorktree`; Claude names the worktree and branch). ⌥↩ starts in the main checkout. Actions offers the opposite checkout of the stored preference where available. The launcher's promoted folder is the selected tab's checkout.

## Open Pull Request

`.pullRequests` (File ▸ Open Pull Request…, the palette, ⇥ or a leading `#` in ⌘N, the toolbar capsule) lists open PRs where my review is requested, mine and assigned to me (`PullRequestInbox`: one `gh api graphql` call with three aliased `search`es of at most 50, deduplicated in that order), sectioned Review Requested, Mine, Assigned; with an empty query, Mine and Assigned PRs not updated in 30 days hide behind a count. Fetched off main at launch, on activation, in the 5 min poll and when the scope opens, at most once a minute, keeping old results on failure, never in snapshot mode.

A PR's sessions are those whose `pr-link`s name it or whose branch lookup gives it (`Store.sessions(for:)`). ↩ resumes the most recent through `Store.activate(.session)`, else opens the PR in a worktree on its head branch: `Store.openPullRequest` finds the repo's checkout (the origin cache inverted; origins resolve for every session root). With `wt` installed (`PullRequestStatus.worktrunk`), `wt -C <repo> switch pr:N --no-cd -y --format json` creates or reuses the worktree so the user's worktrunk hooks run (3 min timeout, path read from the JSON, `PATH` gains Homebrew so wt finds `gh`); its failure shows in the alert with no git fallback. Without `wt`, Berth reads the head with `gh pr view` and `PullRequestCheckout.prepare` fetches `origin pull/N/head` and adds `<repo>.worktrees/<branch>` (worktrunk's template, `/` and `\\` become `-`). A branch already checked out in a worktree is reused and fast-forwarded (`merge --ff-only`, failures ignored); a path held by another branch (`a/b` vs `a-b`) is an error. A fork PR keeps the head branch name, or `<owner>/<branch>` when a local branch of that name exists outside its own worktree. Same-repo branches track `origin/<branch>`. Nothing is reset, forced or deleted. Claude then starts in that folder as a plain new session (no `-w`), and once live and not waiting, at least 5 s after the tab opened (the Conversation composer's gate), Ctrl+U clears typed-ahead input and 'Summarize PR #N (url).' is pasted without Return. Work is serialised, a banner shows progress, and failures show a 'Couldn’t Open Pull Request' alert. Snapshot and probe runs skip git and gh. No checkout shows 'No local checkout of owner/name' with Open on GitHub. ⌥↩ opens the PR.

The toolbar's 'N to review' capsule (hidden at 0) opens the scope filtered to Review Requested (`Store.launcherRole`).

## Issues

Tab cycles through Folders, Pull Requests and Issues. Issues lists open issues assigned to, authored by or mentioning you, in that priority for deduplication. The inbox uses one GitHub CLI request and counts unique open PRs from up to 50 linked timeline events per issue. Refreshing follows the PR inbox schedule and retains the last successful results. Search includes issues older than 30 days, which are hidden until you type.

Return or a click looks up an issue's current linked PRs and opens them. With zero open linked PRs, Berth starts a Claude worktree session from the local checkout and pastes `Work on issue #N (url).` without Return. A missing checkout shows Open on GitHub. Option-Return opens the issue on GitHub.

### Open from Issue

Paste a GitHub issue URL or type `owner/repo#N` in Pull Requests or Issues to see the issue’s open linked PRs across repositories, including drafts. Return opens every available PR and selects the first. Click a row to open just that PR. Both actions switch to or resume an existing session when available, or open the PR in its own worktree from a known local checkout (as above, one at a time).

Lookup errors appear in the issue panel. The launcher stays open when a PR is unavailable or fails to open so its status remains visible. Checkout failures appear in the alert.

## Local checkout discovery

PR and issue sessions prefer checkouts known from session folders. Berth also scans one level of each known repo's parent folder for sibling checkouts with a `.git` directory and a matching GitHub origin. It scans off the main thread, caches results by parent, and refreshes when the known repo folders change or on the five-minute poll. Berth skips worktree pointers and never clones a repo.

## Launcher modes

The New Session scopes and Show in Review show the selection and its primary action in the bottom bar. ⌘K opens Actions for the selection, with ↑↓ and ↩. Escape closes Actions, backs out of an issue drill-down, clears the query, then closes the launcher. See [Launcher.swift](../Sources/Launcher.swift) and [BerthApp.swift](../Sources/BerthApp.swift).

The launcher has modes (`LauncherMode`, `Store.launcherMode`, nil = closed): `.newSession` (⌘N) and `.search` (⇧⌘F, File ▸ Search Sessions…) share the glass panel, query field, highlighted row, ↑↓ and footer hints. `Store.launcherQuery` seeds the field when a mode opens. Closing focuses the selected tab's surface, unless Harbor is shown. Search shows one row per matching session (title, project · age, up to 2 snippets with the matched words bold in the foreground colour), newest first, at most 50, active and archived; ↩ runs `Store.activate(.session)` (the sidebar click path, locks respected).

## Command palette

⌘K (View ▸ Command Palette…) opens [CommandPaletteView](../Sources/CommandPaletteView.swift). It lists available actions, grouped by the context captured before the query field receives focus and by General when the query is empty. [AppAction](../Sources/AppAction.swift) defines the commands and their context relevance. [CommandPalette.rank](../Packages/BerthCore/Sources/BerthCore/CommandPalette.swift) fuzzy-ranks a typed query and puts context actions first on ties.

Unavailable ones are hidden (Clear Terminal without a terminal, Mark Current Session as Done without a listed selected session, the current Group By). Collapse/Expand All Groups writes `collapsedGroups` (skipped when `persistsTabs` is off, so not visible in snapshots).

The Project scope shows a column chip row under the scope tabs (All, then each Status in board order with its item count). Click a chip to select it, or press ⌃⇥ to cycle forward and ⌃⇧⇥ to cycle backward, wrapping between All and the last column. The app key monitor handles them (`ProjectsModel.stepColumn`, since AppKit takes ⌃⇥ before the query field sees it), and plain Tab still switches scopes. Option+digit shortcuts interfere with typing on non-US layouts, and ⌘1–9 switch tabs. The choice is kept per selected-project set in `ProjectsModel.launcherColumn` for the session and falls back to All when the column has no matching items.
