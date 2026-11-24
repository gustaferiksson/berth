# 0010 The diff column is a pane host, and owned terminals float over it

## Context

Review's diff column only ever showed Changes (#407). Browser, Files, Terminal, Background tasks and Side chat panes are planned for the same column, each replacing it whole, chosen from a + menu and remembered per session. The Terminal pane (#410) shows a session's owned shells (`Tab.parentTabID`, the ones `berth open-terminal` opens), which until now were shown in the terminal area like any tab.

Two constraints decide where those shells live. A `TerminalSurfaceView` can never move between hosting trees: libghostty-spm builds a new platform view, surface and shell in `makeNSView` and frees them when that view dies (0002). And Review's column is an `NSSplitViewItem` that is collapsed whenever it isn't shown (Review is off by default), and a collapsed item's view leaves the window, so a surface mounted inside it gets no size and never starts its shell. An agent's `berth open-terminal --background -- npm run dev` would then wait forever.

## Decision

`TerminalSplit`'s second item hosts `PaneHost`: `ReviewDiffColumn` unchanged for Changes, and the Terminal pane's strip (one tab per owned shell, New Terminal, the + menu) over an empty card. The pane is per Claude tab in memory (`Store.sessionPanes`, absent means Changes). The column shows when Review's panel shows or the session's pane is Terminal, so the Terminal pane works with Review off. The + menu lists only built panes (Changes only with Review on); unbuilt ones are hidden, not disabled.

Every owned shell's surface is mounted once in `PaneTerminals`, an overlay on the whole split that is always in the window and sized. `TerminalSplitController` reports the column's frame after layout and resize, and the overlay places the shown surface below the strip in that frame; hidden ones keep opacity 0 and `isSurfaceVisible = false` (0002), with the whole split's size while the column is collapsed. `TerminalArea` mounts only Claude tabs and unowned shells. Restore passes the parent when it opens or reattaches an owned shell, so no surface changes trees.

`selectedTabID` may still name an owned shell (find, clear, cycling, the CLI). `Store.mainTabID` (the selected tab, or its parent) picks what the terminal area shows and `Store.sessionTab` the session that Review, conversation and the pane follow. A surface that gains focus becomes the selected tab, so the sidebar highlight follows clicks between the Claude surface and a pane terminal.

## Rejected alternatives

- Mounting owned surfaces inside the column: they never start while it is collapsed, which is most of the time with Review off.
- Re-parenting a cached platform view (`makePlatformView` returning a kept view) between the terminal area and the column: SwiftUI's make and dismantle order across two hosting views is unspecified, and a dismantle removing the view from its new superview kills the shell.
- Showing owned shells in both places: a surface can live in only one tree.
- Never collapsing the column, only moving its divider to the edge: every `fitDiff`, cramped-sidebar and below-mode path assumes `isCollapsed`, and the divider stays draggable.
