# Review mode: flows

Opt-in mode to review an agent's branch without leaving Berth, and to send line comments
back into the same Claude session. Strictly native (SwiftUI and TextKit, no web view).
## Model

- Opt-in: Settings > General toggle, off by default (`@AppStorage` `reviewEnabled`). Off
  means nothing exists: no menu item, palette action, toolbar control or shortcut, and
  every `ReviewModel` is dropped.
- Review is a panel at the window edge the sessions sidebar doesn't use, plus a diff column
  beside the terminal on the panel's side (`design/review-panel.md`, layer 1). Panel
  visibility is window state (`Store.showsReviewPanel`, persisted behind `persistsTabs`), not a
  mode: selecting another tab or session keeps it and the panel follows the selected Claude
  tab; an unowned terminal tab shows "Select a Claude Session" and an owned one shows its session. Harbor hides the panel and the diff. It
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
  distance (`rev-list --count <ref>..HEAD`), `origin/` refs first, then local branches, each nearest first, and the default branch always comes last.
- Base, first hit wins (`ReviewChanges.baseReason`): the user's pick (`reviewBaseBranches`, per
  repository root and branch), the PR's base branch (`baseRefName`, as `origin/<name>` else `<name>`),
  the configured base when it isn't the default branch, each only while it shares history with HEAD,
  then the first candidate (the nearest `origin/` one, a local branch only when there is none), then the default branch. A pick that no longer resolves is removed.
  Everything below that says base uses this one: the Committed compare, ahead and behind, the
  commits, the branch total and Create Pull Request.
- A background `git fetch` of the configured base (the default branch without one) runs at most
  every 15 s per repository; other bases are compared as they are locally.
  A failure falls back to local refs and shows a warning icon in the header.
- State lives in a `ReviewModel` per session (`Store.reviewModels`, created when the panel
  shows the session): changes, branch status, file tree, open tabs, loaded contents, unsaved
  drafts and comments, so
  they survive switching sessions and hiding the panel. Closing the session's tab drops it. While any model has unsaved
  drafts, `Store.isIdle` is false (no update restart).

## Layout

- The toolbar’s `plus.forwardslash.minus` icon toggles Review when enabled.
- The panel header holds the branch, base menu, warnings, tree toggle and Refresh. In a
  non-stacked session, the list starts with the linked issue, the branch PR or its empty state,
  Stack when present, then Session pull requests. Review Threads, Uncommitted, Committed,
  Commits, Files and Edited by Session follow. Counts show on collapsed sections. The comments
  bar sits below the list. Stacked sessions keep their per-repository cards.
- Uncommitted and Committed appear when they have files. Rows show a coloured status letter,
  a monospaced file name and nonzero line counts at the right edge. Click to open the compare.
  ⌘-click or use the hover Open File button to open the working-tree file. Deleted files only
  open the compare.
- Edited by Session (collapse id `sessionFiles`, count, follows the Changes tree
  or flat toggle, home-relative paths with `~`): the files the session wrote through Edit, Write,
  MultiEdit or NotebookEdit (`TranscriptEdits.existingFiles`, from the local transcript only,
  Claude sessions only, subagent lines skipped) that exist and that no loaded Uncommitted or
  Committed list shows (own repository and every edited or task repository, by resolved absolute
  path). It covers non-git folders, git-ignored files and files in repositories with nothing
  to diff. A file that no longer exists is dropped, not dimmed: it can't be opened. In a session
  whose folder isn't a git repository the panel shows this section instead of "No Git
  Repository". It is hidden while a task's single repository tab is picked. The transcript scan
  is incremental (`Store.refreshEditedRepositories` keeps the byte offset per session and parses
  only lines that mention a tool use of those tools), so `Store.editedFiles` follows every
  transcript change. A row opens the file read-only as plain content through the same
  `ReviewModel.open` and diff pane, in a per-session `ReviewModel` (`ReviewModel()`,
  `isSessionFiles`, key `Store.sessionFilesRoot`) whose paths are absolute minus the leading
  slash. There is no diff against HEAD: an unlisted file in a repository has none by
  construction (ignored, or equal to HEAD or the base). No comments or edits there; Remote is
  unchanged.
- Files shows the repository tree with folders first. A row opens its Uncommitted compare when
  available, otherwise the plain file. Reveal in Files expands the section and parent folders
  and scrolls to the row. When expanded, Files follows the working path.
- Commits shows the branch’s commits and a History disclosure for the graph. On the default
  branch, the graph appears directly. Select a commit to show its changed files and preview the
  first diff. Load More fetches older commits. See `Sources/ReviewGraphView.swift`.
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
- The header's base menu lists candidates as "<ref> · N commits", marks the PR base and
  checks the current selection. Picking a base saves it and reloads the list.
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
- A commit document is a path and a commit SHA. It shows a read-only diff against the first
  parent, with the short SHA in the tab and path bar. Commit diffs stay open through refresh and
  have no language-server features or inline comments.
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
| View ▸ Show Claude Below Diff / Show Claude Beside Diff, palette | the panel shows | Sets `reviewTerminalBelow`: the split goes vertical, diff on top, terminal below, no strip above the terminal; 160 pt minimum each; the diff starts at 60% (`reviewTerminalBelowRatio`, written while dragging the divider) |
| ⌘S, Save in the tab strip | Review, the file has a draft | Saves it through `ReviewGit.save` |
| ⌘F | the diff | The focused side's find bar |
| ⌘-click | an identifier on the right side, language servers on | Goes to its definition |
| Send N Comments | the panel | See Comments |
| Create Pull Request… | the branch summary menu | See Create Pull Request |

The diff column is a pane host (docs/adr/0010): Changes is its default pane, and the + at the
trailing end of the tab strip lists the built panes (Changes ⇧⌘D, Terminal ⌘J; Browser, Files,
Side chat and Background tasks stay hidden until built). The pane is remembered per session in
memory. ⇧⌘D (View ▸ Show Changes Pane, palette) and ⇧⌘R's Show Changes switch the session back
to Changes and show the panel; ⌘J toggles the Terminal pane (design/flows-terminals.md).

The Review panel stays tied to Changes and is unchanged while the Terminal pane shows: it keeps
listing the session's changes, and opening a file from it (or `berth show-pr`, a notification)
switches the pane to Changes. Hide Changes with the Terminal pane showing hides only the panel.

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

## Pull request review threads

- Review Threads groups the pull request's threads by file and puts unresolved threads first
  within each group. The PR card's count opens and scrolls to the section. Picking a row opens
  the file and scrolls to its review line when available. Outdated threads open the file.
- Threads with a line also appear below that line in the diff. Original-side threads follow
  the removal rows, and resolved threads start collapsed. Reply opens an inline draft.
  Choosing Send Reply adds it to the user's pending GitHub review. Failures keep the draft.
- Add to Pull Request Review is available from a local line comment's context menu or its row
  in the comment list when a PR is loaded. Berth clears the local comment after GitHub accepts
  it. The user submits the pending review on GitHub.
- Send to Claude pastes the thread into the current session's prompt for the user to read and
  submit, using the same flow as Send N Comments.

## Pull requests and issues

- The issue card shows the first issue the branch PR closes, or the session's task issue.
  It shows state, repository and title. The cached GitHub preview adds the assignee and labels.
  Click to open the issue. The context menu also offers Copy Link.
- The branch PR card shows its state, number, repository, title and head → base. The footer
  shows check counts, review decision and unresolved threads. Click the thread count to expand
  and scroll to Review Threads. Issue and PR cards show project status when available.
- With no PR, a short summary shows commits ahead of the comparison base and push status.
  The branch menu offers **Create Pull Request…** and **Add Existing Pull Request…**. The
  default branch shows a one-line uncommitted and upstream summary.
- Stack shows the open or draft parent PR above this branch, with open or draft children below.
  Stack and session PR rows show a combined check and review indicator and the comment count.
  Session PR chevrons expand the changed files. Click a file to see its read-only diff or
  ⌘-click to open the file.
- Click a PR card or row to open a read-only PR #N diff tab. It starts at the first changed
  file. Use the path bar to switch files. The menu also offers Show Diff in Review,
  Show Details, Open on GitHub, Steward with Claude for open or draft PRs,
  Move To Status for editable project items, and Copy Link.
- Show Details opens a PR #N details tab with the linked issue, selectable Markdown description,
  reviewers, latest comments and named checks. It uses the same preview, keep, history and close
  controls as a diff tab. Opening the same details again focuses its existing tab.

## Create Pull Request

- Create Pull Request… pastes a prompt into the Claude session and focuses the terminal.
  It includes the comparison base when it differs from the default branch. Press Return
  to submit it. The menu item requires a live Claude session.
- Berth picks up the new PR on its next branch lookup or when the panel is refreshed.

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

A PR compare and per-prompt snapshots.
