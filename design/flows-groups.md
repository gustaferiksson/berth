# Grouping, custom groups and new sessions: flows

Approved: sheets 7 (G1, G2, G4, G5, G6, L1), 8 (C1, C2, C3) and 9 (N1, N4, N5).

## Model

- A custom group is a name plus folder rules (`path`, `includeSubfolders`). Groups are
  ordered; order is priority. A session goes to the first custom group whose rule matches
  its folder (the resolved session folder, so `/cd` moves it), otherwise to the mode's
  automatic group.
- Sidebar order: each custom group (shown even when empty) keeps a slot, its index among
  all groups, clamped to the end when there are fewer groups; the mode's groups fill the
  other slots by recency, then Archived. A group saved without a slot sits right after
  the custom group before it, so new groups land under the last one.
- Modes: Project (one group per folder), Repository (one group per git root; worktrees
  and subfolders merge into it), Recent (Today, Yesterday, This Week, Older).
- Line 2 shows the project name first whenever the row's folder differs from its group's
  folder: always in custom groups and Recent, in Repository only for worktrees and
  subfolders, never in Project groups.
- Custom groups, mode and Show Custom Groups persist in UserDefaults; snapshots never
  write them.

## Entry points

| Entry point | Pointer | Keyboard | Result |
|---|---|---|---|
| Switch mode | View ▸ Group By, palette | ⌃⌘1 / ⌃⌘2 / ⌃⌘3, View ▸ Group By | Regroups at once; collapse state per group id |
| Show Custom Groups | View ▸ Group By | none | Off: custom groups hidden, their sessions fall back to the mode |
| New Group… | File menu, palette, C2 ▸ Add to Group ▸ New Group from X… | menu bar | C3 sheet (empty, or prefilled with X's folder) |
| Edit Group… | Custom header context menu | none | C3 sheet for that group |
| Rename | Custom header context menu | ↩ commits, esc cancels | Inline field in the header |
| Move to a position | Drag a custom header onto another header (drops above it) or below the last group | none | Stores every custom group's slot; priority follows the new order |
| Move Up / Move Down | Custom header context menu (hidden at the ends of the sidebar) | none | Moves one position among all groups, same as a drag |
| Delete Group… | Custom header menu, C3 sheet | confirmation default is Cancel | Group removed; its sessions fall back to the mode; transcripts untouched |
| Add to Group ▸ | Project or repository header context menu | none | Adds that folder as a rule (no subfolders) |
| Copy Path, Reveal in Finder | Project or repository header context menu | none | Pasteboard, Finder |
| + on a header | Project, repository, single non-recursive custom group | none | Starts claude in that folder |
| + on a multi-folder custom group | Menu "Start in": known folders under its rules (recent first), Other Folder in X… | none | Starts claude there, or folder picker rooted at X |
| New Session in ▸ | Custom header context menu | none | Same items as the multi-folder + |
| New Session… | File menu | ⌘N | N1 launcher over the terminal area |
| Launcher | Click a row | type to filter, ↑↓ move, ↩ start, ⌘O Browse…, esc close | Starts claude in the folder |

## Launcher (N1)

- Empty query: the current folder (focused shell's or selected session's) first, then
  every known session folder, most recent first, with session count and age.
- Typing: fuzzy match on name, then path. A query that is an existing directory path
  (`/…` or `~/…`) is offered first even if no session ever ran there.
- Folders that no longer exist are left out. Clicking outside or esc closes and returns
  focus to the terminal.
- The prompt never touches a shell string: it reaches `claude` through an environment
  variable after `--`.

## Edge states

- No sessions and no groups: the existing "No Claude Sessions" placeholder; ⌘N still works.
- Custom group matching nothing: header with 0 and no rows; its + offers Other Folder in X….
- Custom group with no rules: cannot be saved (Save disabled).
- Folder deleted: its sessions still list; starting or resuming there shows a "Folder Not
  Found" alert instead of launching claude in the wrong place; launcher and Start in
  menus omit it.
- Session matching two custom groups: the higher group wins; the sheet preview counts
  only sessions this group would actually get.
- Archived sessions: archived first, so no custom group or mode shows them; Archived stays
  at the bottom in every mode.
- Recent: buckets without sessions are hidden; headers have no +; Older starts collapsed.
- Not a git repo (Repository mode): the folder is its own root.
- Without `gh`: PR tags show uncoloured, as before.
