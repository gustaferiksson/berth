# Launcher, palette and pull requests: implementation notes

Moved from CLAUDE.md. See also design/flows-groups.md (Launcher section).

## New Session (⌘N)

⌘N (File ▸ New Session…) opens the launcher (`Launcher`, a glass overlay on the terminal area): known session folders, the current folder first, fuzzy matched, plus a typed existing path. `submit` reads `highlighted` at submit time (an `onSubmit` closure once started a stale row). `Store.openClaude` passes the session id (or attach job id) to `claude --session-id|--resume|attach "$BERTH_SESSION_ID"` through the `BERTH_SESSION_ID` env var (`envVars` on the surface), never interpolated, and shows "Folder Not Found" instead of launching in a missing folder.

With Settings > General `startsInWorktree` on, a new session (launcher, group +, drop, remote) in a folder inside a git repo starts as `claude --session-id "$BERTH_SESSION_ID" -w` (`ClaudeLaunch.Start.newInWorktree`; Claude names the worktree and branch); ⌥↩ in the launcher (`NewSessionCheckout.main`, footer hint only while the setting is on) starts in the main checkout. The launcher's promoted current folder is the selected tab's checkout, so worktree paths never appear there.

## Open Pull Request

`.pullRequests` (File ▸ Open Pull Request…, the palette, ⇥ or a leading `#` in ⌘N, the toolbar capsule) lists open PRs where my review is requested, mine and assigned to me (`PullRequestInbox`: one `gh api graphql` call with three aliased `search`es of at most 50, deduplicated in that order), sectioned Review Requested, Mine, Assigned; with an empty query, Mine and Assigned PRs not updated in 30 days hide behind a count. Fetched off main at launch, on activation, in the 5 min poll and when the scope opens, at most once a minute, keeping old results on failure, never in snapshot mode.

A PR's sessions are those whose `pr-link`s name it or whose branch lookup gives it (`Store.sessions(for:)`). ↩ resumes the most recent through `Store.activate(.session)`, else starts a `-w` session (`NewSessionCheckout.worktree`) in the repo's checkout (the origin cache inverted; origins resolve for every session root) and, once live and not waiting plus 2 s, pastes 'Check out PR #N (url) with gh pr checkout N in this worktree, then summarize it.' without Return; no checkout shows 'No local checkout of owner/name' with Open on GitHub. ⌥↩ opens the PR.

The toolbar's 'N to review' capsule (hidden at 0) opens the scope filtered to Review Requested (`Store.launcherRole`).

## Launcher modes

The launcher has modes (`LauncherMode`, `Store.launcherMode`, nil = closed): `.newSession` (⌘N), `.search` (⇧⌘F, File ▸ Search Sessions…) and `.palette` (⌘K, View ▸ Command Palette…) share the glass panel, query field, highlighted row, ↑↓ and footer hints. `Store.launcherQuery` seeds the field when a mode opens (the palette's Search Sessions… carries its typed text). Closing focuses the selected tab's surface, unless Harbor is shown. Search shows one row per matching session (title, project · age, up to 2 snippets with the matched words bold in the foreground colour), newest first, at most 50, active and archived; ↩ runs `Store.activate(.session)` (the sidebar click path, locks respected).

## Command palette

Palette (`CommandPalette.rank`, FuzzyMatch on title then keywords/folder): empty query shows open tabs in sidebar order, terminals included ("Sessions"), then actions ("Actions"); typing mixes open tabs, actions and unopened active sessions by score (ties: tabs, actions, sessions, then recency), at most 12 (the empty query is uncapped), plus a "Search Sessions for “…”" row. Actions are `AppAction`, the one source of titles, shortcuts and behaviour for the menus, the Group By picker, the palette's shortcut column and the key monitor.

Unavailable ones are hidden (Clear Terminal without a terminal, Mark Current Session as Done without a listed selected session, the current Group By). Collapse/Expand All Groups writes `collapsedGroups` (skipped when `persistsTabs` is off, so not visible in snapshots).
