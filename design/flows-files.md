# Files mode

The Files mode of the right side (ADR 0010). It needs Review enabled, because the pane is Review's editor.

- Sidebar: `FilesPanel` lists the session's worktree root lazily. `FilesModel` (one per Claude tab, `Store.filesModels`) lists a folder only when it is expanded, hides `.git`, and hides ignored entries unless the eye toggle is on (`ReviewGit.ignored`, one `git check-ignore --stdin` per folder). Status letters come from `ReviewModel.changes.uncommitted`, folders with changes get a dot.
- Filter: a substring match over `ReviewGit.files` (tracked and untracked, never ignored), shown as a flat list with each file's folder.
- Keyboard: up and down move the cursor (a file opens as you pass it), right and left expand and collapse, Return opens a file and focuses the editor or toggles a folder. Quick Look, New File and New Folder are not built.
- Context menu: Reveal in Finder, Open in Default App, Copy Path, Copy Relative Path.
- Pane: `ReviewDiffColumn(isFiles: true)` shows the Review model's selected plain working-tree document (`compare: nil`) without the tab strip, under Review's path bar. Edits, disk-change handling and the Markdown toggle are Review's. Images use `FilesImageView`.
- Selected file and expanded folders live in memory per session tab and survive mode switches. A file opened from Files goes through `Store.openFile`, which keeps the Files mode (any other `ReviewModel.open` switches back to Changes).
- Watching: `FileWatcher` on the root re-lists the expanded folders, ignoring events inside `.git`. Review's own watcher refreshes statuses and the open file.
- Shortcut: ⇧⌘E, because ⇧⌘F is Search Sessions.
