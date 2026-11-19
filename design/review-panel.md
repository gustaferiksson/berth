# Review panel: design

Review moves from a mode that replaces the terminal area to a panel at a window edge plus a
diff pane beside the terminal, so the terminal stays visible. Agreed through a configurator
mock (final code `diff=split tb=panel pr=card side=left parts=tabs pin=dbl scope=groups
nopr=commits`). `flows-review.md` describes what has landed; each layer below updates it.

## Layout

- The window becomes: review panel | diff pane | terminal area | session sidebar (mirrored
  when the session sidebar is on the left). The panel takes the window edge the session
  sidebar doesn't use: the left edge when the sidebar is on the right (`sidebarPosition =
  right`), the right edge when it is on the left. The diff pane sits next to the panel.
- The panel is about 272 pt wide, resizable, and holds, top to bottom: the PR or branch card,
  a header line (branch → base, Refresh), one list with collapsible Uncommitted, Committed and
  Files sections. The session's comments and Send N Comments stay at the bottom of the panel.
- The diff pane sits between the panel and the terminal in a native split. The split always
  exists and the diff pane is open whenever the panel is (collapsed only with the panel hidden
  or Harbor shown), so the terminal keeps its width as files open and close; with no tab it
  shows "No File Open". A tab's `TerminalSurfaceView` must never be removed or re-parented, or
  its shell dies. Minimum widths keep the terminal usable (360 pt) and the diff readable (440 pt).
- When the panel shows, or the window narrows while it shows, and the window can't fit panel,
  diff, terminal and session sidebar at those minimums, the session sidebar collapses (its
  native column visibility or inspector presentation). It comes back when the panel hides,
  unless the user showed or hid it by hand meanwhile; a sidebar the user reopens stays open.
- Like Xcode's split editor, the diff | terminal divider starts under the toolbar, and while the
  panel shows the terminal gets a header row (the tab's title) as tall as the diff's tab strip,
  so one hairline crosses the divider. A full-height divider was tried and rejected: it cut
  through the window title at 1200 and 1600 pt.
- The diff is side by side when its pane is at least 760 pt wide, unified below that, unless a
  side by side / inline toggle in the tab strip picked one (`reviewDiffLayout`).

## Toolbar, menu, keys

- The Review toggle becomes a panel toggle: `sidebar.left` (or `sidebar.right` when the panel
  is on the right) in the toolbar zone next to the panel's edge, help "Show Changes" / "Hide
  Changes". The blue pressed fill goes away.
- View ▸ Show Changes / Hide Changes (title flips), ⇧⌘R and the palette run the same
  `AppAction`. Still only while `reviewEnabled` is on.
- Panel visibility is window state (`@AppStorage`), not a mode: selecting another tab or
  session no longer leaves it; the panel follows the selected Claude session. For a terminal
  tab it shows a `ContentUnavailableView` ("Select a Claude session"). Harbor hides both the
  panel and the diff pane while shown.
- ⌘W with the diff pane focused closes its current tab; closing the last tab leaves "No
  File Open" in the pane. ⌘S, ⌘F as today.

## Changes sections

- Two sections: Uncommitted (HEAD → working tree, including untracked) and Committed (merge
  base → HEAD, with the commit count in the header). A file can appear in both; each row
  opens its own compare. Only compares whose right side is the working tree are editable.
- On the default branch, or with no base, there is no Committed section.
- Rows keep today's look: status letter, name, dimmed folder, +/- counts, 24 pt rows. Hovering a
  row shows an Open File button that opens the working-tree file as a plain file.

## Files section

- A folder tree of the repository from git (`git ls-files --cached --others
  --exclude-standard`), so `.gitignore` is respected. Changed files carry their status colour.
- An unchanged file opens as a single editable pane (no diff), the same `ReviewTextView`.

## Diff tabs

- The diff pane has a tab strip. Clicking a row (or a ⌘-clicked definition) opens a preview
  tab, title in italics, which the next open replaces in place; back and forward arrows walk
  that tab's history. Double-clicking a row or the tab, or editing the file, keeps it (regular
  title). Opening from a kept tab opens a new preview tab.

## PR and branch card

- With a PR: state pill, `#number`, title, checks summary (passed, failed, running) and the
  open review thread count; Open on GitHub. Checks and threads are fetched for the panel's
  branch only, when the panel shows it and on Refresh, never in the sidebar's per-repo batch.
- Without a PR: "No pull request", "N commits ahead of <base>", ↑ahead ↓behind, push state
  ("N not pushed", or "Not pushed, no upstream"), the branch's commits (hollow dot when
  unpushed), and Create Pull Request… (pastes a prompt into the session's tab, see
  `design/flows-review.md`).
- On the default branch: "Uncommitted changes on <branch>", whether it is up to date with
  its upstream, its last two commits, no button.

## Layers (one PR each, in order)

1. Shell: panel at the edge, diff pane in the split, toolbar toggle and View menu, reusing
   today's file list and two-sided diff. Prove terminals survive toggling.
2. Unified diff for narrow panes.
3. Changes sections, Files tab, preview and kept diff tabs.
4. PR and branch cards (data comes from a BerthCore layer that can land first).
5. LSP: ⌘-click definition, hover, diagnostics (client in BerthCore lands first).
6. Create Pull Request….
