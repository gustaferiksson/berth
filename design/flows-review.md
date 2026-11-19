# Review mode: flows

Opt-in mode to review an agent's branch without leaving Berth, and to send line comments
back into the same Claude session. Strictly native (SwiftUI and TextKit, no web view).
This is the slim first version; the rest is listed under Later.

## Model

- Opt-in: Settings > General toggle, off by default (`@AppStorage` `reviewEnabled`). Off
  means nothing exists: no menu item, palette action, toolbar control or shortcut, and
  every `ReviewModel` is dropped.
- Review is a panel at the window edge the sessions sidebar doesn't use, plus a diff column
  beside the terminal on the panel's side (`design/review-panel.md`, layer 1). Panel
  visibility is window state (`Store.showsReviewPanel`, persisted behind `persistsTabs`), not a
  mode: selecting another tab or session keeps it and the panel follows the selected Claude
  tab; a terminal tab shows "Select a Claude Session". Harbor hides the panel and the diff. It
  is not a tab kind, so `Store.tabs` and `openTabs` persistence are untouched, and the
  terminal surfaces are never re-hosted (`-snapshotReviewSurfaces` proves it).
- Two compares, both from `ReviewGit.changes(in:)`: Uncommitted (HEAD to the working tree,
  untracked files included) and Committed (the merge base of the base and HEAD to HEAD). On
  the default branch, or with no base, there is no Committed compare. A path can be in both.
  Plus the repository's files (`ReviewGit.files(in:)`, `git ls-files --cached --others
  --exclude-standard`), each openable as a plain file.
- Configured base, first hit wins: `branch.<b>.gh-merge-base` (the key `gh` writes), then
  `@{upstream}` when it names a different branch; remote refs preferred. Default branch, first hit
  wins: `origin/HEAD`, `origin/main`, `origin/master`, `main`, `master`. Without a configured base
  it is the default branch; the current branch is the default branch when it is the configured base.
- Base candidates (`ReviewChanges.bases`, for stacked branches): local and `origin/` branches between
  the merge base with the default branch and HEAD (`git for-each-ref --merged=HEAD --contains=<merge
  base>`), without the current branch, its `origin/` twin and refs at HEAD or at the merge base; a
  local branch at the same commit as its `origin/` twin shows once, as the remote. Each carries its
  distance (`rev-list --count <ref>..HEAD`), nearest first, and the default branch always comes last.
- Base, first hit wins (`ReviewChanges.baseReason`): the user's pick (`reviewBaseBranches`, per
  repository root and branch), the PR's base branch (`baseRefName`, as `origin/<name>` else `<name>`),
  the configured base when it isn't the default branch, each only while it shares history with HEAD,
  then the nearest candidate, then the default branch. A pick that no longer resolves is removed.
  Everything below that says base uses this one: the Committed compare, ahead and behind, the
  commits, the branch total and Create Pull Request.
- A background `git fetch` of the configured base and the default branch runs at most every 15 s per
  repository; a picked, PR or nearest base is compared as it is locally.
  A failure falls back to local refs and shows a warning icon in the header.
- State lives in a `ReviewModel` per session (`Store.reviewModels`, created when the panel
  shows the session): changes, branch status, file tree, open tabs, loaded contents, unsaved
  drafts and comments, so
  they survive switching sessions and hiding the panel. Closing the session's tab drops it. While any model has unsaved
  drafts, `Store.isIdle` is false (no update restart).

## Layout

- Toolbar: a Show / Hide Changes button, `sidebar.left` next to the traffic lights when the
  panel is on the left, `sidebar.right` at the trailing end when it is on the right.
- Panel, 272 pt ideal (220–440), on the Ghostty theme like the sessions sidebar: the header,
  the card, one list of collapsible sections (the sessions sidebar's headers and disclosure),
  the session's comments below it with a delete button each, and Send N Comments. Collapsed
  sections persist in `@AppStorage` `collapsedReviewSections` (comma-separated ids
  `uncommitted`, `committed`, `files`; default `files`).
- Uncommitted and Committed (count, summed +/-) sections, each only when it
  has files. Rows: status letter A/M/D/R in the theme's working, needs-you, closed and branch
  colours, file name, +/- counts. Each row opens its own compare. Nothing changed: "No
  uncommitted changes on <branch>" on the default branch or without a base, else "No changes,
  <branch> matches <base>".
- Files: the repository as an outline (`ReviewFileTree`, folders first), changed files in their
  status colour (Uncommitted first). A file row opens its Uncommitted compare when it has one,
  else the plain file. Folders only expand. The list highlights the current tab's row: its
  compare's row, or the Files row for a plain file.
- Hovering a file row (any section) shows an Open File button (`doc`) before the counts; it opens
  the working-tree file as the plain file, through the same `ReviewModel.open`. Deleted files
  have none.
- Refreshing: the panel reloads its lists on its own when the repository changes on disk. While
  the panel shows a model (not while hidden or under Harbor; showing it again reloads), one
  FSEvents watcher in `Store` covers the repository root and the common git dir (`git rev-parse
  --git-dir --git-common-dir`). Inside the git dirs only the own git dir's `HEAD` and `index`,
  `packed-refs` and `refs/` (not `.lock`) count, so other worktrees' entries don't; in the working
  tree, paths under directories git reports as ignored (`ls-files --others --ignored --directory`,
  re-read before each reload, so a new `.build` costs one reload) don't. Review's own saves
  reload too, which updates the counts. The reload runs 500 ms after the last event and goes
  through `Store.refreshReview`, like Refresh: a transcript scan, `prepareReviewModel` (so a moved
  session is followed at once), then the shown model's `load()`. Loads are serialized, and
  requests made while one runs share one follow-up load. A reload keeps the current tab's
  contents until the new ones arrive and reloads them from disk (a draft still wins over the
  file), and other tabs reload when selected. A failed reload keeps the last lists and shows a
  warning by Refresh.
- Following the session: the model is per session and folder. When the session's folder
  changes (a scan after `/cd`, or Claude entering a worktree), the next `prepareReviewModel`
  replaces the model, which stops its language servers and drops its tabs and editors. While it
  has unsaved drafts or comments it stays, with "This session moved to <folder>. Save or undo
  your edits and send or delete your comments to follow it." under the header, and swaps once
  both are gone; the notice clears if the session moves back.
- Panel header: branch → base ("<branch>, uncommitted only" on the default branch or without a
  base), a fetch warning when the fetch failed, Refresh. "→ base" is a pull-down menu (Compare
  against…) listing the candidates as "<ref> · N commits", the PR's base marked "PR base" and the
  current one checked; picking one stores it and reloads. Below it the PR or branch card
  (`design/review-panel.md`), from `ReviewGit.changes(in:)` and `branchStatus(of:)`, loaded with
  the lists; if the status fails there is no card. Which card, first match wins:
  - On the default branch, or with no base: "Uncommitted changes on <branch>" ("No uncommitted
    changes on <branch>" with a clean tree), its upstream
    state ("N not pushed", "N behind <upstream>", "Up to date with <upstream>" or "No
    upstream") and its last two commits.
  - With a PR (the sidebar's data, `Store.pullRequest(in:branch:)`): a state pill (Open, Draft,
    Merged, Closed in the sidebar tag's colours), `#number`, Open on GitHub, the title (two
    lines), then the branch total (below), the checks summary ("Checks passed", "N failed" or
    "N running", counts in the tooltip) and "N open" unresolved review threads. Checks and threads are one `gh api graphql`
    call (`PullRequestDetail`) for this PR only, off the main thread, when the panel shows the
    session, when the PR first appears and on Refresh; kept per PR number, so a failed call
    keeps the last result. Without `gh` only the total is left on the line.
  - Otherwise: a "No pull request" pill (only once the sidebar's lookup answered no PR; without
    `gh` or a GitHub remote there is no pill), "N commits ahead of <base>" ("No commits yet" at
    0), ↑ahead ↓behind the base, the branch total, the upstream state ("Not pushed, no
    upstream" without one), and the branch's commits, at most 5 then "N more": short SHA, subject, age, and a dot,
    filled when pushed to the upstream, hollow in the needs-you colour when not. With the pill and
    at least 1 commit ahead, a Create Pull Request… button ends the card (see Create Pull Request).
  - The branch total (`ReviewChanges.total`) is `+N −M` of the working tree against the merge
    base (what the PR would hold with everything committed), untracked files included and binary
    files as 0, so a committed line reverted in the working tree counts nowhere, unlike the sum of
    both sections. None on the default branch or without a base.
- Diff column (`ReviewDiffColumn`, an `NSSplitViewController` item next to the terminal): open
  whenever the panel shows, collapsed only while the panel is hidden or Harbor is shown, so the
  terminal's width doesn't change as files open and close. With no tab (or a terminal tab
  selected) it shows "No File Open" in secondary text under an empty tab strip row, like Xcode's
  "No Editor"; nothing opens by itself. It opens 760 pt wide (also on the first layout), less to
  leave the terminal 360, never under 440, and window or panel resizes keep both within those
  minimums where they fit (`TerminalSplitController.fitDiff`, after layout: constraint minimums
  the window can't fit crash AppKit). When the split settles under 801 pt with the panel shown
  (300 ms after its last width change, so launch's transient widths don't count), the session
  sidebar collapses, and hiding the panel brings it back unless the user toggled it meanwhile
  (`ContentView.sidebarYieldsToDiff`, an overlay on the stored visibility, so nothing persisted
  changes).
- While the panel shows, the terminal pane has a 32 pt header row (the selected tab's title) as
  tall as the diff's tab strip, so the hairline under both crosses the diff | terminal divider,
  as in Xcode's split editor. The divider starts under the toolbar; a full-height one cut
  through the window title.
- Tabs (`ReviewModel.tabs`, VS Code preview semantics): one tab strip row with back and forward,
  the scrolling tabs (file name, a diff or file icon, ×), then the layout toggle and Save (icon,
  while the current document's path has a draft); the diff starts under it. Tabs whose file names
  collide show their shortest distinguishing parent folders dimmed after the name; the tooltip is
  the repo-relative path, plus (Committed) or (Uncommitted) for a compare. A tab's context menu
  has Copy Path, Copy Relative Path, Reveal in Files (selects it, expands Files and its parent
  folders and scrolls to the row), Close and Close Others. A click on a row (or a ⌘-clicked definition) opens a preview tab,
  title in italics: at most one exists, and the next open replaces its document in place,
  dropping its forward history, so back and forward walk that tab's history. A document already
  open in a tab selects that tab. Double-clicking the row or the tab, or editing the file, keeps
  it (regular title); opening from a kept tab then starts a new preview tab after it. Closing a
  tab selects its neighbour and, when it was the current tab, focuses the neighbour's right side;
  closing the last leaves "No File Open" and focuses the terminal. Refresh keeps each history
  entry still listed in its compare, turns one that isn't into the plain file while the file
  exists, else drops it; a tab whose current entry is dropped closes.
- A document is a path and a compare (`ReviewDocument`, `nil` for the plain file). Uncommitted
  compares and plain files are the working tree: they share the path's editor
  (`ReviewModel.editors`), undo history, draft and diagnostics, sync to the language servers,
  and a save or a load updates every loaded one of that path. A Committed compare is read only
  (HEAD on the right) with its own text view, no draft and no language server. A plain file is
  a single editable pane (identical sides shown unified); edits show against the file on disk
  until saved.
- Diff: `ReviewDiffPane` gets the file's `ReviewContents`, a draft binding and `onComment`.
  Base on the left (read only), working tree on the right (editable unless deleted), in the
  Review style (Settings > Appearance > Review: colour scheme, One Dark by default, or Match
  Terminal; font family and size, default the terminal's; line height, default 1.3). The diff
  column uses the style's background and light or dark appearance; changes apply live. Filler rows
  keep unchanged lines side by side, changed lines are tinted full width (the style's removed tint left,
  added tint right) with changed words tinted stronger, and tree-sitter syntax colours.
  Scrolling either side (text, gutter, minimap or ruler) scrolls both, for added and deleted
  files too. Added and deleted files show the missing side as filler; a binary or too large
  side is a `ContentUnavailableView`.
- Layout: `@AppStorage` `reviewDiffLayout` is `auto` (default), `sideBySide` or `inline`. A
  toggle at the tab strip's trailing edge (`rectangle.split.2x1` "Show Side by Side"
  while unified, `rectangle` "Show Inline" while side by side, hidden for a plain file and for an
  added or deleted file, which are always unified) sets an
  explicit value; View ▸ Show Side by Side / Show Inline and the palette run the same
  (`AppAction.showSideBySide` / `.showInline`, only while the panel shows a compare with both sides). Nothing in
  the UI sets `auto` back. In `auto`, below 760 pt of diff column width the diff is unified,
  switching live on divider moves and window resizes (the top visible line stays put). Unified:
  only the right side shows, and each hunk's
  removed lines sit above its added lines in rows of their own, drawn from the base with its
  syntax colours, the removed tint and changed words, and numbered with the base's numbers in
  the removed colour. They are not part of the editable text, so they can't be selected, edited
  or found with ⌘F; editing, undo, save and the language servers see exactly the file. Minimap
  and ruler follow the unified rows.
- Right of the right side: a VS Code style minimap (80 pt, Settings > Appearance > Review
  toggle `reviewShowsMinimap`, default on): blocks per non-blank run in syntax colours, full-width
  green bands for added lines and red for removed rows from the aligned left side, the
  viewport as a translucent rectangle; click or drag scrolls. Then a 10 pt overview ruler,
  always shown: red (left lane) and green (right lane) marks by aligned row, a faint viewport
  band, click or drag to jump.
- Each side has a line number gutter. Clicking or dragging across numbers highlights those
  lines (number and text) and opens an inline comment box below the last one, spanning the
  text width, with the same space reserved on the other side so lines stay aligned: header
  "Line 33" / "Lines 31–33", a borderless field in the editor font ("Leave a comment",
  focused at once), Cancel and Add Comment (default, enabled with text). ↩ adds, ⇧↩ inserts
  a newline, Esc cancels. One box at a time; a new selection replaces it. Right side numbers
  are used and unchanged lines on the left map to their right side numbers (the box opens on
  the right); changed lines on the left keep the base's numbers, the box opens on the left and
  the snippet's lines are prefixed with `-`. In the unified diff, a selection that starts on a
  removed line takes the base's lines like a selection on the left (unchanged lines included);
  any other selection takes the file's lines. Every box and card opens in the one side, below
  its last line's row.
- Added comments stay in the diff as compact cards (line label, text, pencil and × on hover) on their
  side, below their last line; switching between side by side and unified moves them, and an
  open box, with the rows. Deleting a card or the comment in the panel removes both.
- The pencil or a double-click on a card swaps it for the comment box in its place, prefilled
  with the text, caret at the end, with Save instead of Add Comment. ↩ saves (same id, lines,
  side, compare and order), Esc or ↩ with the text cleared restores the card unchanged (×
  deletes). It is the one box: a new selection or another edit replaces it. Double-clicking a
  comment in the panel opens its document and starts the same edit.
- Edits on the right become the file's draft; 300 ms after the last edit the diff and
  highlighting are recomputed off the main thread. Save (⌘S) appears in the tab strip while
  there is a draft. Each file keeps its own undo history while Review's model lives (switching
  files and Refresh keep it); reloading a file whose text changed on disk clears it.
- Loading, no changes and errors (not a git repository, git failures) are
  `ContentUnavailableView`s in the panel; the last two offer Refresh.

## Keys

| Key | From | Result |
|---|---|---|
| ⇧⌘R, View ▸ Show / Hide Changes, palette, toolbar button | anywhere | Shows or hides the panel (showing leaves Harbor) |
| ⌘W, a tab's × | a tab is open, focus outside a terminal | Closes the current tab; closing the last leaves "No File Open" and focuses the terminal |
| View ▸ Show Side by Side / Show Inline, palette, the tab strip toggle | a compare of a file that is neither added nor deleted is shown | Sets `reviewDiffLayout` |
| ⌘S, Save in the tab strip | Review, the file has a draft | Saves it through `ReviewGit.save` |
| ⌘F | the diff | The focused side's find bar |
| ⌘-click | an identifier on the right side, language servers on | Goes to its definition |
| Send N Comments | the panel | See Comments |
| Create Pull Request… | the branch card | See Create Pull Request |

⌘J keeps its meaning (Switch Terminal / Claude).

## Comments

- Added inline in the diff (see Layout), listed in the panel and shown as cards in the
  diff; both views read `ReviewModel.comments`. A comment keeps its document's compare
  (`ReviewComment.compare`) and shows only in that document's tab.
- A Committed comment's lines are HEAD's, which the working tree may have moved, so its block
  says so: `path:lines (as committed)`.
- Send N Comments pastes `ReviewComment.prompt` (one block per comment: path, line range,
  the snippet, the comment) into the session's claude prompt without submitting it, then
  focuses the terminal (the panel stays). Sent comments are cleared. If Claude isn't running in the tab,
  nothing is pasted and the comments are kept.

## Create Pull Request

- The button does nothing outward itself: like Send, it pastes a prompt ("Push this branch and
  open a pull request for it with gh.", or "… against <base> with gh (--base <base>)." when the base
  isn't the default branch, without `origin/`) into the session's claude prompt without submitting it and
  focuses the terminal, so the user reads it and presses Return. Claude's own instructions decide
  the PR's wording. It is disabled, with a tooltip saying so, while Claude isn't running in the tab.
- The new PR shows up through the sidebar's lookup (app activation or the 5 min poll, at most once a
  minute), or at once on the panel's Refresh, which looks up the panel's branch in its repository
  (`Store.fetchPullRequests`, unthrottled) whenever the card knows its PR state.

## Language servers

- Opt-in: Settings > General "Enable language servers", shown while Review is on, off by
  default (`languageServersEnabled`). Language servers and the build scripts they run execute the
  repository's code. Off means no server process ever starts, and turning it off stops them.
- Servers are entries in Settings > General > Language Servers (`languageServers`, a JSON string in
  UserDefaults, never read from a repository): name, command, arguments, languages (file extensions
  or language ids), root markers, optional settings (a JSON object answering the server's
  `workspace/configuration` requests by section and sent once as `didChangeConfiguration`), and
  whether the server gives diagnostics only or also definition and hover. Add, Edit… (a sheet; Remove for added entries, Restore Default for built-ins) and an
  enable switch per row. SourceKit-LSP (root marker `Package.swift`), rust-analyzer and
  typescript-language-server are built-in entries the user can edit or turn off; stored entries
  override them by id (`LanguageServerEntry.configured`).
- A command resolves from the server root's `node_modules/.bin`, then PATH, then known install
  folders; a script with a node shebang runs through a resolved `node`, since an app opened from
  Finder has no node on its PATH.
- One server per entry and root, owned by the session's `ReviewModel`: started when a file it
  serves is shown, stopped when the model is dropped or the entry changes. The root is the nearest
  folder above the file, up to the repository root, holding one of the entry's root markers; with
  markers and none found, no server starts; without markers, the repository root.
- Only the right side (working tree) talks to the server: its text is opened when shown and sent
  again 300 ms after the last edit, with the diff recompute. The left side is another revision.
- A server that advertises `diagnosticProvider` (ESLint's) is also asked with
  `textDocument/diagnostic` after each open and change. ESLint's server
  (`vscode-eslint-language-server --stdio` from vscode-langservers-extracted) needs settings, at
  least `{"validate": "on", "nodePath": null, "experimental": {}, "problems": {},
  "rulesCustomizations": []}`; without them it lints nothing.
- Diagnostics from every server serving a file are merged, each labelled by its `source` (else
  the entry's name). A squiggle under the range (errors in the closed colour, warnings in the needs-you
  colour, others dimmed) and a dot in the right gutter; hovering either shows the message and
  source as a tooltip. Diagnostics for other files are kept and show when that file opens.
- Hover: resting the pointer on an identifier for 500 ms shows the server's hover in a small card
  below it (code fences monospaced, the rest plain); moving off it, scrolling, typing or clicking
  dismisses it.
- ⌘-click: while ⌘ is held the identifier under the pointer gets a link underline and the
  pointing hand. A click goes to the definition: in the same file it scrolls there (both sides
  follow) and selects it; another file opens in the preview tab, its Uncommitted compare when it
  has one, else the plain file, then scrolls and selects once loaded;
  outside the repository (SDK headers) nothing happens.
- Definition and hover ask the file's servers that do more than diagnostics, in entry order, and
  take the first answer.
- A content-modified error or an empty answer just after start is retried once after 500 ms. A
  crashed server never takes Review down; the next file shown starts it again.

## Trust boundary

Saves go through `ReviewGit.save`: the path is resolved and must stay inside the
repository root (no `..`, `.git` or symlink escapes), or the write is refused. A save is
also refused when the file on disk changed since it was loaded.

## Later

A PR compare; per-prompt snapshots; posting comments to GitHub.
