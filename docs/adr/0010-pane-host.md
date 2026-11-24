# 0010 The diff column is a pane host, and owned terminals float over it

## Context

Review's diff column only ever showed Changes (#407). Files, Browser and Terminal are planned for the same place, and the user picked the layout in a mock: the right side is one unit with modes, and a mode switches both the trailing sidebar and the column. The Terminal pane (#410) shows a session's owned shells (`Tab.parentTabID`, the ones `berth open-terminal` opens), which until now were shown in the terminal area like any tab.

Two constraints decide where those shells live. A `TerminalSurfaceView` can never move between hosting trees: libghostty-spm builds a new platform view, surface and shell in `makeNSView` and frees them when that view dies (0002). And Review's column is an `NSSplitViewItem` that is collapsed whenever it isn't shown (Review is off by default), and a collapsed item's view leaves the window, so a surface mounted inside it gets no size and never starts its shell. An agent's `berth open-terminal --background -- npm run dev` would then wait forever.

## Decision

Layout, as picked:

- Mode switcher: a segmented icon control in the window toolbar where the Review toggle sat (`ModeSwitcher`, one `NSSegmentedControl` capsule, since a SwiftUI segmented `Picker` can't report a click on the selected segment). Modes are Changes, Files, Browser and Terminal; only Changes and Terminal are built, the rest are hidden. Clicking the active mode hides the sidebar and the column.
- The mode's sidebar stays trailing (with `sidebarPosition` right it takes the leading column, as Review did). Changes uses today's Review list; Terminal lists the session's owned terminals (`TerminalList`, + for New Terminal, × and Close Terminal per row).
- Pane header: a slim path bar. Changes keeps Review's; Terminal shows the shown terminal's folder and title (`TerminalPathBar`).
- Later modes, for their follow-up issues: Files shows a full folder tree in the sidebar and the file in the pane. Browser shows vertical tabs in the sidebar, grouped into "Pinned" and "This session" `SidebarSection` accordions, with a URL bar in the pane (built, tab ownership in 0011).

`TerminalSplit`'s second item hosts `PaneHost`: `ReviewDiffColumn` unchanged for Changes, or the Terminal path bar over an empty card. The mode is per Claude tab in memory (`Store.sessionPanes`, absent means Changes; `Store.shownPane` is what shows). The sidebar and column show when Review's panel shows or the session's mode is Terminal, so Terminal works with Review off (the switcher then offers only Terminal).

Every owned shell's surface is mounted once in `PaneTerminals`, an overlay on the whole split that is always in the window and sized. `TerminalSplitController` reports the column's frame after layout and resize, and the overlay places the shown surface below the path bar in that frame; hidden ones keep opacity 0 and `isSurfaceVisible = false` (0002), with the whole split's size while the column is collapsed. `TerminalArea` mounts only Claude tabs and unowned shells. Restore passes the parent when it opens or reattaches an owned shell, so no surface changes trees.

`selectedTabID` may still name an owned shell (find, clear, cycling, the CLI). `Store.mainTabID` (the selected tab, or its parent) picks what the terminal area shows and `Store.sessionTab` the session that Review, conversation and the pane follow. A surface that gains focus becomes the selected tab, so the sidebar highlight follows clicks between the Claude surface and a pane terminal.

## Rejected alternatives

- Mounting owned surfaces inside the column: they never start while it is collapsed, which is most of the time with Review off.
- Re-parenting a cached platform view (`makePlatformView` returning a kept view) between the terminal area and the column: SwiftUI's make and dismantle order across two hosting views is unspecified, and a dismantle removing the view from its new superview kills the shell.
- Showing owned shells in both places: a surface can live in only one tree.
- A + menu inside the column choosing its pane, with the Review list fixed: built first, replaced by the mode switcher after the mock, because a mode needs its own sidebar (terminal list, file tree, browser tabs).
- Never collapsing the column, only moving its divider to the edge: every `fitDiff`, cramped-sidebar and below-mode path assumes `isCollapsed`, and the divider stays draggable.
