# Grouping, custom groups and new sessions: flows

Approved: sheets 7 (G1, G2, G4, G5, G6, L1), 8 (C1, C2, C3) and 9 (N1, N4, N5).

## Model

- A custom group is a name plus folder rules (`path`, `includeSubfolders`). Groups are
  ordered; order is priority. A session goes to the first custom group whose rule matches
  its folder (the resolved session folder, so `/cd` moves it), otherwise to the mode's
  automatic group.
- Sidebar order: each custom group (shown even when empty) keeps a slot, its index among
  all groups, clamped to the end when there are fewer groups; the mode's groups fill the
  other slots by recency, then Done. A group saved without a slot sits right after
  the custom group before it, so new groups land under the last one.
- Modes: Project (one group per folder), Repository (one group per git root; worktrees
  and subfolders merge into it), Recent (Today, Yesterday, This Week, Older), Recent (One List) (one newest-first group, 15 rows before Show More).
- Both Recent modes also have an Active section (id `recent:active`) between Terminals and Pinned, as in Berth Remote:
  every session with a live status (waiting, busy, shell, then idle, newest activity first) plus open Claude tabs
  without a transcript. They leave Pinned, custom groups and the date buckets; no Show More. A task keeps only
  its not-live members, so live sessions sit flat in Active. Reorders wait for the pointer to leave the sidebar.
- Line 2 shows the project name first whenever the row's folder differs from its group's
  folder: always in custom groups and both Recent modes, in Repository only for worktrees and
  subfolders, never in Project groups.
- Custom groups, mode and Show Custom Groups persist in UserDefaults; snapshots never
  write them.

## Entry points

| Entry point | Pointer | Keyboard | Result |
|---|---|---|---|
| Switch mode | View ▸ Group By, palette | ⌃⌘1 to ⌃⌘4, View ▸ Group By | Regroups at once; collapse state per group id |
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
- Done sessions (archived internally): archived first, so no custom group or mode shows them; Done stays
  at the bottom in every mode.
- Recent: buckets without sessions are hidden; headers have no +; Older starts collapsed. Recent (One List) has the single group `flat`, titled Recent, also without +.
- Not a git repo (Repository mode): the folder is its own root.
- Without `gh`: no PR tags.

## Implementation notes

Moved from CLAUDE.md.

### Archive (shown as Done)

A session stays archived while its last conversational record is no newer than its archive time; newer activity unarchives it, and ids without a listed transcript are pruned (`SessionArchive.split`, applied after the first scan). Marking an open session as done closes its tab and unpins it; the Done section (bottom, collapsed by default, `archivedExpanded`) resumes and unarchives on click.

### Pins

Pins: `pinnedSessions` (ordered ids) feeds a Pinned section (id `pinned`) above the groups; `SessionPins.split` takes pinned active sessions out of grouping and prunes unknown ids after the first scan. Pin / Unpin in the row menu; drag reorders (`PinDrag`, UTType `dev.gustaf.berth.pin`, `SessionPins.moving`).

### Grouping

Grouping (`design/flows-groups.md`): sidebar order is Needs Attention, Terminals, Active (Recent modes only), Pinned, the groups, Done. Custom groups (name + folder rules, path and subfolders; first match wins) sit among the mode's groups (Project by checkout, Repository by git root, Recent by calendar day: Today, Yesterday, This Week, Older; Recent (One List), `GroupingMode.flat`, is one newest-first group `flat`) at `CustomGroup.slot` (`SessionGrouping.place`, top when unset); dragging a header (UTType `dev.gustaf.berth.group`) or Move Up/Down writes every custom group's slot (`SessionGrouping.moving`).

Archive and pins run before grouping. Triage (`showsTriage`, off by default; Group By menu toggle, View ▸ Show Triage, palette; `Store.triageSections`, `SessionTriage.sections`) lifts Working (busy) and Unread (`hasUnseenActivity`, a selected row stays until deselected) above the groups in every mode, titles Needs Attention as Needs You, and replaces Active. Mark as Done is `Store.archive` (row menu, E in the sidebar list, multi-selection, palette). Snooze (`Store.snooze`, `SessionSnooze`, `snoozedSessions` behind `persistsTabs`, pruned after the first scan) hides a session into a collapsed Snoozed section above Archived, keeps its tab, unpins it, and wakes it as unread when its time passes or it enters waiting.

A group shows 5 sessions (15 for the flat group), then "Show N More" / "Show Less" (in-memory). Repository roots: walk up to `.git`; a `.git` file's `gitdir:` → `commondir` → its parent, resolved once per folder in the scan task and cached. Group ids: the folder path for Project and Repository (so collapse state is shared), `custom:<uuid>`, `recent:<bucket>`, `flat`, `recent:active`; `recent:older` is collapsed by default (`collapsedGroups` lists it when expanded). Open tabs without a transcript yet are placed with the same folder-to-group function (Recent by the tab's open time).

Line 2 starts with the project name whenever the row's folder isn't its group's folder. Both Recent modes (`GroupingMode.hasActive`) put an Active section (`SessionGrouping.active`, `Store.sidebarActive`) between Terminals and Pinned: every session with a live status, ordered waiting, busy, shell, idle, then newest `lastActivity`, plus open Claude tabs without a transcript. They leave Pinned, custom groups and the date buckets; no Show More; a task keeps only its non-live members. It counts in Collapse/Expand All and in the ⌘1–9 / ⌃⇥ order.

### Needs Attention

Needs Attention (`SidebarLayout.attentionIDs`, id `Sidebar.attentionID`, `Store.attentionSessions`) leads the sidebar: sessions in no task whose live status is waiting, or whose open or draft PR has failing checks, newest first, waiting before failing. Pinned (not live) sessions qualify too and leave Pinned; sessions leave Active and the groups, so a row never appears twice. Unread never qualifies, so selecting a row never moves it. Its rows use the user's density like every other section and the header is tinted `theme.needsYou`.

It counts in Collapse/Expand All and leads `Store.sidebarOrderedTabs` (⌘1-9, ⌃⇥). Active shows at least 5 sessions and every one up to the last that isn't idle or is the selected session (`SidebarLayout.Group.visibleLimit`), the rest behind Show N More; a group left empty by Needs Attention is dropped. Terminal rows use the compact density and show their folder as a tooltip. A passed checks mark is hidden on the row's PR tag (failed and running stay; the hover card and Review show all). Line 2 of a row shows the project (when it has a name), the branch and the PR chip together; when space is short the branch truncates first (middle, down to 48 pt), then the project, never the chip; the chip is always on line 2 except in the compact density, where it moves to line 1 for every row.

### Unread and flags

Unread and flags (`Store.isUnread`, row menu, Flag / Unflag Current Session in the palette): a session is unread while `lastActivity` is newer than its `seenAt`, shown as a blue (palette 4) dot in the status slot, never while working or needs-you, nor for the selected tab while Berth is active. Deselecting a tab or Berth resigning active stamps it seen; ids first seen by a scan are seeded as seen now, so launch marks nothing unread. Flags are a set of ids (red palette 1 `flag.fill` left of the row time), kept through archive, pruned when the transcript is gone.
