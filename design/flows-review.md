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
- One compare: the merge-base of the base and HEAD to the working tree (committed,
  uncommitted and untracked), `ReviewGit.snapshot(in:)`.
- Base, first hit wins: `branch.<b>.gh-merge-base` (the key `gh` writes), `@{upstream}`
  when it names a different branch, then `origin/HEAD`, `origin/main`, `origin/master`,
  `main`, `master`; remote refs preferred. No base: HEAD, so only uncommitted work shows.
- A background `git fetch` of the base branch runs at most every 15 s per repository.
  A failure falls back to local refs and shows a warning icon in the header.
- State lives in a `ReviewModel` per session (`Store.reviewModels`, created when the panel
  shows the session): snapshot, open file, loaded contents, unsaved drafts and comments, so
  they survive switching sessions and hiding the panel. Closing the session's tab drops it. While any model has unsaved
  drafts, `Store.isIdle` is false (no update restart).

## Layout

- Toolbar: a Show / Hide Changes button, `sidebar.left` next to the traffic lights when the
  panel is on the left, `sidebar.right` at the trailing end when it is on the right.
- Panel, 272 pt ideal (220–440), on the Ghostty theme like the sessions sidebar: the header,
  then a flat `List` of changed files (status letter A/M/D/R in the theme's
  working, needs-you, closed and branch colours, file name, dimmed parent folder, +/-
  counts), the session's comments below it with a delete button each, and Send N Comments.
- Panel header: branch → base, a fetch warning when the fetch failed, Refresh. When the
  reviewed branch has a PR (the sidebar's data, `Store.pullRequest(in:branch:)`), it becomes
  three lines: a state pill (Open, Draft, Merged, Closed in the sidebar tag's colours) and
  `#number`, the PR title, then `base ← head` with the head in the branch colour (base is
  still the guessed one). Open on GitHub sits before Refresh. No CI checks.
- Diff column (`ReviewDiffColumn`, an `NSSplitViewController` item next to the terminal):
  collapsed until a file row is clicked; nothing opens by itself. It opens 760 pt wide, less
  to leave the terminal 360, never under 440, and window or panel resizes keep both within
  those minimums where they fit (`TerminalSplitController.fitDiff`, after layout: constraint
  minimums the window can't fit crash AppKit). When the split can't hold 801 pt, opening a diff
  (or narrowing the window with one open) collapses the session sidebar, and closing the diff
  brings it back unless the user toggled it meanwhile (`ContentView.sidebarYieldsToDiff`, an
  overlay on the stored visibility, so nothing persisted changes). Its header is the file path, Save while there is a draft, and Close Diff (×).
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
  the snippet's lines are prefixed with `-`.
- Added comments stay in the diff as compact cards (line label, text, × on hover) on their
  side, below their last line. Deleting a card or the comment in the panel removes both.
- Edits on the right become the file's draft; 300 ms after the last edit the diff and
  highlighting are recomputed off the main thread. Save (⌘S) appears in the header while
  there is a draft. Each file keeps its own undo history while Review's model lives (switching
  files and Refresh keep it); reloading a file whose text changed on disk clears it.
- Loading, no changes and errors (not a git repository, git failures) are
  `ContentUnavailableView`s in the panel; the last two offer Refresh.

## Keys

| Key | From | Result |
|---|---|---|
| ⇧⌘R, View ▸ Show / Hide Changes, palette, toolbar button | anywhere | Shows or hides the panel (showing leaves Harbor) |
| ⌘W, Close Diff | a diff is open, focus outside a terminal | Closes the diff (collapses its column) and focuses the terminal |
| ⌘S, Save in the header | Review, the file has a draft | Saves it through `ReviewGit.save` |
| ⌘F | the diff | The focused side's find bar |
| ⌘-click | an identifier on the right side, language servers on | Goes to its definition |
| Send N Comments | the panel | See Comments |

⌘J keeps its meaning (Switch Terminal / Claude).

## Comments

- Added inline in the diff (see Layout), listed in the panel and shown as cards in the
  diff; both views read `ReviewModel.comments`.
- Send N Comments pastes `ReviewComment.prompt` (one block per comment: path, line range,
  the snippet, the comment) into the session's claude prompt without submitting it, then
  focuses the terminal (the panel stays). Sent comments are cleared. If Claude isn't running in the tab,
  nothing is pasted and the comments are kept.

## Language servers

- Opt-in: Settings > General "Enable language servers", shown while Review is on, off by
  default (`languageServersEnabled`). Language servers and the build scripts they run execute the
  repository's code. Off means no server process ever starts, and turning it off stops them.
- Servers are entries in Settings > General > Language Servers (`languageServers`, a JSON string in
  UserDefaults, never read from a repository): name, command, arguments, languages (file extensions
  or language ids), root markers, and whether the server gives diagnostics only or also definition
  and hover. Add, Edit… (a sheet; Remove for added entries, Restore Default for built-ins) and an
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
- Diagnostics from every server serving a file are merged, each labelled by its `source` (else
  the entry's name). A squiggle under the range (errors in the closed colour, warnings in the needs-you
  colour, others dimmed) and a dot in the right gutter; hovering either shows the message and
  source as a tooltip. Diagnostics for other files are kept and show when that file opens.
- Hover: resting the pointer on an identifier for 500 ms shows the server's hover in a small card
  below it (code fences monospaced, the rest plain); moving off it, scrolling, typing or clicking
  dismisses it.
- ⌘-click: while ⌘ is held the identifier under the pointer gets a link underline and the
  pointing hand. A click goes to the definition: in the same file it scrolls there (both sides
  follow) and selects it; a changed file is selected in the panel, then scrolled and selected once
  loaded; any other file in the repository opens as an unchanged file (identical sides, editable,
  kept open by Refresh);
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

Uncommitted and PR compares; a folder tree and whole-project files; preview tabs for
definitions (#71); per-prompt snapshots; posting comments to GitHub.
