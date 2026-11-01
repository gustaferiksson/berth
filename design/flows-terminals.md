# Terminals in the sidebar: flows

Plain shells leave the bottom/right panel and become sidebar rows, selected and shown in
the terminal area exactly like Claude tabs.

## Model

- One list of open tabs (`Store.tabs`), kind `claude` or `shell`, one `selectedTabID`.
  Every surface stays mounted; only the selected one is visible (opacity 0 and
  `isSurfaceVisible = false` for the rest).
- Selection history: every change of `selectedTabID` moves that id to the front of a
  most-recently-selected list. Closing a tab removes it from the list.
- A terminal's folder is its OSC 7 directory, else the folder it was opened in.
- Terminals are restored on relaunch like the panel shells were (same `openTabs` entry,
  opened in the folder they started in).

## Sidebar

- A "Terminals" group sits at the very top, above Pinned, hidden when there are no
  terminals. Same header as other groups: chevron, title, count, + (New Terminal).
  Collapse state is shared with the other groups (`collapsedGroups`, id `terminals`).
- Rows in opening order. Line 1: Ghostty's title while a command runs, else the folder
  name. Line 2: the folder, abbreviated with `~`. Working dots while a command runs.
  Same selection and hover chrome as session rows. Context menu: Close Terminal.
- Sidebar order for ↑/↓, ⌘1 to ⌘9 and ⌃⇥ / ⇧⌘]: terminals, then Pinned, then groups.

## Keys

| Key | From | Result |
|---|---|---|
| ⌘T, + on the header | anywhere | New terminal in the current folder, added to Terminals, selected and focused |
| ⌘J | a Claude tab, Harbor or nothing selected | Most recently selected terminal, selected and focused; none open: a new one in the current folder |
| ⌘J | a terminal | Most recently selected Claude tab, selected and focused; none open: nothing happens |
| ⌘W | a terminal | Ghostty closes the surface; the row goes away |

Current folder: the selected terminal's folder, else the selected Claude tab's session
folder, else home.

## Focus

- Selecting a terminal (click, ⌘J, ⌘T, ⌘1 to ⌘9, ⌃⇥) focuses its surface through
  `requestFocus`, the path a sidebar click uses. ↑/↓ select without leaving the sidebar.
- Closing the launcher focuses the selected tab, whatever it is.

## Edge cases

- Closing the selected terminal selects the most recently selected remaining tab
  (terminal or Claude) and focuses it. Closing a background terminal changes nothing.
- Closing the last terminal: the Terminals group disappears and selection falls back as
  above; with no tabs left the terminal area shows "No Open Session".
- ⌘J with no Claude tab while on a terminal: no-op, focus stays.
- ⌘J or ⌘T while the launcher is open: the launcher closes, then the switch happens.
- ⌘J with the Terminals group collapsed: the terminal is selected and shown; the group
  stays collapsed (its count still shows), the same as a Claude tab in a collapsed group.
- Update when idle treats any terminal running a command as busy.
