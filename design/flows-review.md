# Review mode: flows

Opt-in mode to review an agent's branch without leaving Berth, and to send line comments
back into the same Claude session. Strictly native (SwiftUI and TextKit, no web view).
This is the slim first version; the rest is listed under Later.

## Model

- Opt-in: Settings > General toggle, off by default (`@AppStorage` `reviewEnabled`). Off
  means nothing exists: no menu item, palette action, toolbar control or shortcut, and
  every `ReviewModel` is dropped.
- Review is a mode of the selected Claude session that replaces the terminal area, like
  Harbor. It is not a tab kind, so `Store.tabs` and `openTabs` persistence are untouched.
  The sessions sidebar stays.
- One compare: the merge-base of the base and HEAD to the working tree (committed,
  uncommitted and untracked), `ReviewGit.snapshot(in:)`.
- Base, first hit wins: `branch.<b>.gh-merge-base` (the key `gh` writes), `@{upstream}`
  when it names a different branch, then `origin/HEAD`, `origin/main`, `origin/master`,
  `main`, `master`; remote refs preferred. No base: HEAD, so only uncommitted work shows.
- A background `git fetch` of the base branch runs at most every 15 s per repository.
  A failure falls back to local refs and shows a warning icon in the header.
- State lives in a `ReviewModel` per session (`Store.reviewModels`, created on entering
  Review): snapshot, selected file, loaded contents, unsaved drafts and comments, so they
  survive leaving Review. Closing the session's tab drops it. While any model has unsaved
  drafts, `Store.isIdle` is false (no update restart).

## Layout

- Toolbar: a Review Changes toggle button (`plus.forwardslash.minus`, pressed while
  reviewing), only while the feature is on and a Claude session is selected.
- File column, 260 pt: a flat `List` of changed files (status letter A/M/D/R in the theme's
  working, needs-you, closed and branch colours, file name, dimmed parent folder, +/-
  counts), the session's comments below it with a delete button each, and Send N Comments.
- Header above the diff: branch → base, the file path, a fetch warning when the fetch
  failed, Refresh.
- Diff: `ReviewDiffPane` gets the file's `ReviewContents`, a draft binding and `onComment`.
  Base on the left (read only), working tree on the right (editable unless deleted), in the
  Ghostty font (`font-family`, `font-size`, else monospaced 12) and theme colours. Filler rows
  keep unchanged lines side by side, changed lines are tinted full width (closed red left,
  working green right) with changed words tinted stronger, and tree-sitter syntax colours.
  Scrolling either side scrolls the other. Added and deleted files show the missing side as
  filler; a binary or too large side is a `ContentUnavailableView`.
- Each side has a line number gutter. Clicking or dragging across numbers opens a popover to
  write a comment (↩ or Comment adds it). Right side numbers are used; unchanged lines on the
  left map to their right side numbers; changed lines on the left keep the base's numbers and
  the snippet's lines are prefixed with `-`.
- Edits on the right become the file's draft; 300 ms after the last edit the diff and
  highlighting are recomputed off the main thread. Save (⌘S) appears in the header while
  there is a draft. Undo is per file view.
- Loading, no changes and errors (not a git repository, git failures) are
  `ContentUnavailableView`s; the last two offer Refresh.

## Keys

| Key | From | Result |
|---|---|---|
| ⇧⌘R, View ▸ Review Changes, palette, toolbar toggle | a Claude tab | Toggles Review for the selected session |
| ⌘W | Review | Leaves Review |
| ⌘S, Save in the header | Review, the file has a draft | Saves it through `ReviewGit.save` |
| ⌘F | the diff | The focused side's find bar |
| Send N Comments | the file column | See Comments |

⌘J keeps its meaning (Switch Terminal / Claude). Selecting any tab or session leaves
Review, as with Harbor.

## Comments

- Added through the diff pane's `onComment` and listed in the file column.
- Send N Comments pastes `ReviewComment.prompt` (one block per comment: path, line range,
  the snippet, the comment) into the session's claude prompt without submitting it, then
  returns to the terminal. Sent comments are cleared. If Claude isn't running in the tab,
  nothing is pasted and the comments are kept.

## Trust boundary

Saves go through `ReviewGit.save`: the path is resolved and must stay inside the
repository root (no `..`, `.git` or symlink escapes), or the write is refused. A save is
also refused when the file on disk changed since it was loaded.

## Later

Inline comment display in the diff; uncommitted and PR compares; a folder tree and whole-project files; go to definition;
per-prompt snapshots; posting comments to GitHub.
