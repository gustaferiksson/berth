# CLAUDE.md changes for sidebar-rethink

Apply to the Berth CLAUDE.md (a symlink outside the repo).

- Grouping: sidebar order is now Needs Attention, Terminals, Active (Recent modes only), Pinned, the groups, Archived. Needs Attention (`SidebarLayout.attentionIDs`, id `attention`, `Store.attentionRank`) holds sessions in no task and not pinned whose live status is waiting (rank 0), whose open or draft PR has failing checks (1) or that are unread (2), newest first within a rank. They leave Active and the groups, so a row never appears twice. It counts in Collapse/Expand All and the ⌘1-9 / ⌃⇥ order.
- Active shows at least 5 sessions and every one up to the last that has a tab or isn't idle (`SidebarLayout.Group.visibleLimit`), the rest behind Show N More (`expandedGroups`, id `recent:active`). A group left empty by Needs Attention is dropped.
- The status icon row (`IconTabBar` in the sidebar) is gone. The filter field sits at the top in the 32 pt strip (hairline below, level with the terminal and diff strips); its leading menu picks the status filter (All, Working, Needs You, Unread, Flagged, with counts) and shows it as a token. `IconTabBar` stays for Review's panel tabs. `-snapshotSidebarStatus` still sets the status; `-snapshotSidebarFilter` also prints `attention`.
- Terminal rows use the compact density (one line, folder only if it fits).
- Rows: the context ring shows from 80% (was 60%) and a passed checks mark is hidden on the row's PR tag (failed and running stay; the hover card and Review show all).
- Snapshot fixture for 20+ idle live sessions: a `CFFIXED_USER_HOME` with 28 invented transcripts and `sessions/<n>.json` files (pid 1; one busy, one waiting, one shell, the rest idle), run with `-groupingMode recent -sidebarPosition left -showsReviewPanel NO -languageServersEnabled NO` and `-snapshotGhosttyTheme "Atom One Dark"`.
