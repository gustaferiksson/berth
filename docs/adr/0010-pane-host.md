# 0010 The diff column is a pane host, and owned terminals float over it

## Context

Review's diff column only ever showed Changes (#407). Files, Browser and Terminal are planned for the same place, and the user picked the layout in a mock: the right side is one unit with modes, and a mode switches both the trailing sidebar and the column. The Terminal pane (#410) shows a session's owned shells (`Tab.parentTabID`, the ones `berth open-terminal` opens), which until now were shown in the terminal area like any tab.

Two constraints decide where those shells live. A `TerminalSurfaceView` can never move between hosting trees: libghostty-spm builds a new platform view, surface and shell in `makeNSView` and frees them when that view dies (0002). And Review's column is an `NSSplitViewItem` that is collapsed whenever it isn't shown (Review is off by default), and a collapsed item's view leaves the window, so a surface mounted inside it gets no size and never starts its shell. An agent's `berth open-terminal --background -- npm run dev` would then wait forever.

## Decision

Layout, as picked:

- The mode switcher is a segmented icon control in the window toolbar where the Review toggle sat. `ModeSwitcher` uses `NSSegmentedControl` so it can detect a click on the selected segment and hide the pane. The modes are Changes, Files, Browser and Terminal. With Review off, the switcher offers Browser and Terminal.
- The mode's sidebar stays trailing (with `sidebarPosition` right it takes the leading column, as Review did). Changes uses today's Review list; Terminal lists the session's owned terminals (`TerminalList`, + for New Terminal, × and Close Terminal per row).
- Changes keeps Review's slim path bar. Terminal shows the current terminal's folder and title in `TerminalPathBar`.
- Files shows the full folder tree in the sidebar and the file in the pane (design/flows-files.md).
- Browser puts a Safari 26-style Liquid Glass row above the opaque web card. Pinned tabs use individual circles, and session tabs share a capsule beside the address capsule. Below 640 pt, the header prioritizes session tabs and moves the navigation and share controls into Tab Overview. Browser hides the mode sidebar, leaving the pane as the whole unit. [0011 Browser tabs](0011-browser-tabs.md)

`TerminalSplit`'s pane item hosts `PaneHost`. Changes and Files use `ReviewDiffColumn`, Browser uses `BrowserPane`, and Terminal shows its path bar over the card that the shell surface covers. `Store.sessionPanes` holds the mode per Claude tab in memory and defaults to Changes. `Store.shownPane` controls whether the pane is visible. Browser and Terminal work with Review off.

Every owned shell's surface is mounted once in `PaneTerminals`, an overlay on the whole split that is always in the window and sized. `TerminalSplitController` reports the column's frame after layout and resize, and the overlay places the shown surface below the path bar in that frame; hidden ones keep opacity 0 and `isSurfaceVisible = false` (0002), with the whole split's size while the column is collapsed. `TerminalArea` mounts only Claude tabs and unowned shells. Restore passes the parent when it opens or reattaches an owned shell, so no surface changes trees.

`selectedTabID` may still name an owned shell (find, clear, cycling, the CLI). `Store.mainTabID` (the selected tab, or its parent) picks what the terminal area shows and `Store.sessionTab` the session that Review, conversation and the pane follow. A surface that gains focus becomes the selected tab, so the sidebar highlight follows clicks between the Claude surface and a pane terminal.

## Rejected alternatives

- Mounting owned surfaces inside the column: they never start while it is collapsed, which is most of the time with Review off.
- Re-parenting a cached platform view (`makePlatformView` returning a kept view) between the terminal area and the column: SwiftUI's make and dismantle order across two hosting views is unspecified, and a dismantle removing the view from its new superview kills the shell.
- Showing owned shells in both places: a surface can live in only one tree.
- A + menu inside the column kept the Review list fixed across modes. The window toolbar switcher lets each mode show the sidebar it needs and lets Browser use that width for the page.
- The user tried vertical browser tabs in the mode sidebar. The list rarely exceeds a handful of tabs, and dedicating a whole sidebar column to it reduces the web view’s width.
- Never collapsing the column, only moving its divider to the edge: every `fitDiff`, cramped-sidebar and below-mode path assumes `isCollapsed`, and the divider stays draggable.
