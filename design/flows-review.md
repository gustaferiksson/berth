# Review mode: flows

Opt-in mode to review an agent's branch, local changes or a PR without leaving Berth,
and to send line comments back into the same Claude session. Going to a definition or its
references happens in the review through a peek; bigger edits stay in the user's editor.

Decided through the clickable mock (`pl=tab sb=keep fl=tree fw=col src=seg cq=panel
nav=peek`, side-by-side diff, editable right side).

## Model

- Opt-in: Settings > General toggle, off by default (`@AppStorage` `reviewEnabled`). Off
  means nothing exists: no menu item, palette action, toolbar control, shortcut or web view.
- Review is a mode of the selected Claude session that replaces the terminal area, like
  Harbor. It is not a tab kind, so `Store.tabs` and `openTabs` persistence are untouched.
  The sessions sidebar stays.
- Compare tabs, per session:
  - All changes: merge-base of the base and HEAD to the working tree (committed,
    uncommitted and untracked).
  - Uncommitted: HEAD to the working tree.
  - PR #N, when the session has a PR: fetched as `pull/N/head` into
    `refs/berth/review/pr-N`, read only.
  - By prompt: per-prompt diffs from hidden snapshot refs. Later; shown disabled.
- Base, first hit wins: `branch.<b>.gh-merge-base` (the key `gh` writes), `@{upstream}`
  when it names a different branch, then `origin/HEAD`, `origin/main`, `origin/master`,
  `main`, `master`; remote refs preferred.
- A background `git fetch` of the base branch runs at most every 15 s per repository.
  A failure falls back to local refs and shows a note. (Base chain, fetch throttle and
  hidden checkpoint refs follow T3 Code's source.)
- Comments live in memory per session until sent.

## Layout

- Toolbar: an Agent | Review segmented control, only while the feature is on and a Claude
  session is selected.
- File column, 260 pt, with a toggle at the top:
  - Flat: changed files in one list.
  - Folders: tree of changed files, single-child folders compressed.
  - Whole project: VS Code style tree. Changed files coloured, folders containing changes
    marked, unchanged files openable read only.
- Comments panel at the bottom of the file column.
- Diff: Monaco's diff editor in a `WKWebView` (monaco-editor 0.52.2, fetched by
  `scripts/fetch-monaco.sh` into `Resources/Review/vs`, not tracked), side by side. The
  modified side is editable for All changes and Uncommitted; PR and unchanged files are
  read only.

## Keys

| Key | From | Result |
|---|---|---|
| ⇧⌘R, View ▸ Review Changes, palette | a Claude tab | Toggles Review for the selected session |
| Agent | Review segment | Back to the terminal, focused |
| ⌘S | the editable side | Saves the file into the worktree |
| + in the glyph margin, ⇧⌘M on a selection | the diff | Opens the inline composer |
| ⌘-click | a symbol | Monaco's peek: definition and references, click-through inside the peek |
| Send N to Claude | Comments panel | See Comments |

⌘J keeps its meaning (Switch Terminal / Claude). Selecting any tab or session leaves
Review, as with Harbor.

## Comments

- A comment shows as an inline thread in the diff and as a row in the Comments panel.
- Send N to Claude pastes one block per comment (path, line range, the comment, the code
  snippet) into that session's claude prompt without submitting it, then selects the
  session's tab. Sent comments are cleared.

## Navigation

- First version: the peek answers from a declaration search over the loaded files.
- Later: a language server per worktree (sourcekit-lsp, typescript-language-server, Biome)
  bridged through the web view.

## Trust boundary

The web view is untrusted input. A save path from it is resolved and must stay inside the
repository root, or the write is refused.

## Edge cases

- Session folder is not a git repo: Review shows a notice instead of a diff.
- No PR on the session: no PR tab.
- Fetch fails or the base cannot be resolved: local refs, with a note.
- Turning the setting off while in Review returns to the terminal and removes the
  controls.

## Not in the spike

By prompt snapshots, posting comments to GitHub, a language server, opening in an
external editor.

## Open questions

- Keep Monaco, or move to a native diff later?
- Language server lifecycle and memory per worktree.
- Behaviour for sessions without a git repo beyond the notice.
- The snapshot waits for the base fetch (up to 20 s offline) instead of showing local refs first.
- Monaco ships in the bundle (~13 MB) even when the setting is off.
