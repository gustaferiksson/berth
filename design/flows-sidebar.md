# Sidebar: implementation notes

Moved from CLAUDE.md. Grouping and ordering are in design/flows-groups.md, terminals in design/flows-terminals.md.

## The sidebar List (see docs/adr/0001)

The sidebar is a `List` (`.sidebar` style); every section (Terminals, Pinned, groups, Done) is a `Section(isExpanded:)` fed by `collapsedGroups` / `archivedExpanded`, so collapsing is the system disclosure (chevron on header hover, no custom animation). A ScrollView + LazyVStack attempt (#35) made expand/collapse worse on screen; offscreen snapshot timings don't reflect on-screen feel. Rows draw their own selection and hover fills (`RowChrome`). Review's file rows share that fill (`RowFill`): a `listRowBackground` over `List(selection:)` still drew the system highlight, so Review draws the fill from the current tab and handles ↑/↓/Return itself (`ReviewFileList.list`, `ReviewRowChrome`).

An expanded task has no container: its members indent 16 pt (`SessionItem.taskIndent`) and so does their selection fill, and a 1 pt guide line (foreground at 12%, drawn by `RowFill` for any indented row) hangs them off the task on the chevron's centre axis. Review cards and rows share the sidebar's 8 pt edges, `.caption` secondary lines and 10 pt semibold chevrons. Sidebar density (Settings > Appearance, `SidebarDensity`) is the `sidebarDensity` environment value set on the session sidebar list only (Review's `GroupHeader`s stay comfortable): a row's PR tag and time sit 6 pt from the fill's right and bottom edges (`CardRow` trailing padding −10, tag 16 pt tall); compact drops line 2 and moves the row's `detail` (PR tag, suggestion glyph, task issue chip and count, terminal folder if it fits) onto the title line (title at `layoutPriority(1)`) and sets `sidebarRowSize` to `.small`, since the Medium sidebar size gives rows a ~32.5 pt minimum `defaultMinListRowHeight` can't lower.

Don't `cmp` snapshots that use `-snapshotFakeStatus`: `WorkingDots` start at random offsets. Arrow keys are handled with `onKeyPress`: ↑/↓ switch straight to open tabs (terminals included, without touching selection history or leaving the sidebar) but only move a cursor onto history sessions (so scanning doesn't resume them), Return opens, ←/→ collapse and expand. A click runs `Store.activate`, which focuses the tab's surface. Clicking a branch copies it; the PR tag is right-aligned and opens the PR.

## Multi-selection

Multi-selection (`Store.multiSelection`, in memory, ordered): ⌘-click toggles a row (the first one seeds it with the current row), ⇧-click and ⇧↑/⇧↓ select the range from the anchor over the sidebar's visible items (modifiers read from `NSEvent.modifierFlags` in the row's tap). Its rows get the selected fill instead of the current row. `activate`, plain ↑/↓ and Esc clear it; `archive`, `close` and the scan prune it. A row in it gets `MultiSelectionMenu` (counted titles, items that apply to none hidden), and the palette's Archive / Flag / Unflag Current Session act on it.

Batches loop over the single-row actions: Pin in sidebar order, the rest with the selected row last, so `close` falls back once.

## Glass (see docs/adr/0005)

The session sidebar column and the Review panel show untinted system glass in both positions. `glassSidebarTint` in `ContentView` hides the list background. The window behind it uses `GhosttyTheme.chrome`, the theme background mixed toward black (40% dark, 5% light), then 3% toward white. `ScrollPocketSeparatorRemover` clears the separator and preserves the edge effect. The detail column draws glass only when Window Background is set to Glass. That layer extends under the toolbar and scales past the window edges to clip the rim offscreen. `GlassCapsule` (`ReviewView.swift`) is the one 24 pt glass capsule (the tab pill's height, 22 pt buttons) for grouped icon buttons (the diff strip's back/forward, change arrows, layout/Save, the Changes tab's tree/Refresh).

The sidebar's footer is a bottom inset: `UsageBar` above the filter field (Settings > Sidebar `showsSessionUsageDivisions` divides the 5-hour bar into hours and `showsWeeklyUsageDivisions` divides a window of two days or more into days, both off by default), both glass in one `GlassEffectContainer` with 10 pt padding on every side; the field is 28 pt (NSSearchField's large size) with a magnifying glass. Reminders-style smart tiles (Needs You, Working, Unread, Flagged: tinted symbol circle and count, a 2x2 grid) top the sidebar and set the status filter; a second click clears it. The status filter (`Store.sidebarStatus`: All, Working, Needs You, Unread, Flagged, Background Shell, one entry per status dot; in memory, All at launch) counts non-archived sessions, keeps a task's matching members, shows terminals only under All, combines with the text filter in `Store.sidebarLayout` and is cleared with it by Esc (`-snapshotSidebarStatus <status>`).

Hovering a session row for 600 ms (at once while a card is already showing, which then follows the pointer from row to row and hides 250 ms after it leaves the rows) shows `HoverCardPanel` (`SessionHoverCard.swift`), a read-only, non-activating child `NSPanel` that ignores mouse events (the pointer never enters it) with glass in the theme's appearance, 8 pt outside the sidebar column's edge and aligned to the row (`HoverCardPanel.frame`), hidden on scroll, click or key: title, project · branch, every PR (state dot, `#n State`, checks; numbers through `Text(verbatim:)`), folder, last prompt and reply read from the tail before showing, and context; `-snapshotHover` also writes `<out>.hover-<sessionId>.png` through `ImageRenderer`, since the panel can't be captured offscreen.

The sidebar filter (`Store.sidebarFilter`, in memory, ⌥⌘F via `AppAction.filterSidebar`) is applied in `Store.sidebarLayout` (`SidebarFilter.swift`): every word must match a title, project, branch, `#PR` or `#issue` of a session, task or terminal (`localizedStandardContains`); empty groups hide, Show More and collapsed sections are ignored while set, Esc clears it then refocuses the terminal. Previous/Next Change (⌃⌥↑/⌃⌥↓ while a diff text view has focus, and the strip's chevrons) set `ReviewModel.changeStep`; `ReviewTextView.goToChange(by:)` steps through runs of changed or filler rows and wraps with a beep, compare documents only.

Real glass never renders offscreen.

## Sidebar position

Sidebar position (Settings > General, `sidebarPosition`): left is the `NavigationSplitView` sidebar; right is a SwiftUI `.inspector` with its own toolbar toggle (`showsTrailingSidebar`) and width (`trailingSidebarWidth`). `ScrollPocketSeparatorRemover` clears the separator AppKit draws on the inspector's scroll pocket. The `NavigationSplitView` sidebar column's toggle is the system's (trailing edge of the column, after the traffic lights when hidden), removed only when Review is off with `sidebarPosition` right, since that column then has nothing to show; the inspector's toggles are `.primaryAction` items; the PR capsule and ⌘J are separate glass capsules split by a fixed `ToolbarSpacer`.

For a selected Claude tab a session cluster follows (`SessionToolbar.swift`, in the detail column's toolbar with `.automatic` placement; only the panel toggle is `.primaryAction`): a terminal/conversation segmented control (with `conversationEnabled`), the session's PR tag (click opens), a Changes toggle showing `+N −N` (review totals, else `ReviewGit.changes` off main at most every 60 s) that replaces the panel button for Claude tabs, and an always-shown context button (ring and percent, popover with model and tokens); snapshot hooks `-snapshotReviewContext <tokens>`, `-snapshotReviewHidePanel YES`, `-snapshotReviewConversation YES`.

Snapshots can't show the system toggle's placement.

## Scrollers

Scrollers are overlay app-wide: `BerthApp.init` puts `AppleShowScrollBars = WhenScrolling` in the argument domain (volatile, nothing written), so scroll views are created overlay. Never restyle a SwiftUI List's scroll view afterwards: SwiftUI's `AppKitScrollView` observes the change and re-tiles inside its next update, and with Review's Files outline (then an `OutlineGroup`) expanded that re-entered a row's hosting view and aborted (AttributeGraph precondition in `value_set` from `ViewGraph.beginNextUpdate`) under the user's `Always` scrollers.

Review snapshot runs should pass `-languageServersEnabled NO` unless testing servers, or each waits 120 s for diagnostics.

## Working indicators

Working indicators are three dots (`WorkingDots`), each a `TimelineView` stepping every 0.4 s from a random per-view offset so rows don't pulse in sync; they always animate. Green (palette 2) for `busy`. `shell` means idle with a background Bash task running (CLI 2.1.317: `idle && tasks.some(local_bash running)`; `!` commands never produce it), so a turn reports `busy` over it. `Store.backgroundShellIDs` keeps the session marked through busy and waiting until it reports plain idle or ends; the mark is a static 6pt dot in the row's leading status slot in `GhosttyTheme.shellAttached`, no working dots.

`shell` counts as idle for Harbor (not for update-when-idle), idle unload still spares it, and it never alerts. Otherwise, in the leading status slot (priority needs you, working, background shell, unread, then open), an open session shows a hollow 6 pt secondary-colour ring, so open, unread (bold title, blue dot) and unloaded (nothing) differ; every dot has a tooltip. A locked row (live elsewhere, no tab) gets a lock glyph before the time and is dimmed only while idle: needs-you and working rows stay at full opacity.

Compacting isn't shown: the session file stays `busy`, and libghostty-spm's viewport text read is public only on `InMemoryTerminalSession`. Per-row repeating symbol effects cost ~13% CPU (Debug). A native-tabs experiment lives on branch `native-tabs`.

A live, idle PR watch shows an eye and **Watching #N** (or **Watching PR** while the number is unknown) in the session row and hover card. The row shows Claude’s usual working or needs-input state during a turn or approval. **Stop Watching** in the session menu submits `/ship stop` in its running Berth tab with the regular prompt safety checks. Active watches are kept loaded by the idle-unload timer.

## Harbor

Harbor (View ▸ Harbor, palette; `Store.isHarborShown`) replaces the terminal area: one pier per group with live or open sessions (Pinned first, at most 6 piers; per pier at most what fits before the open water, then "+N"), one side-view boat per session; working boats bob with a wake in the working colour, needs-you boats bob more under a flag in the needs-you colour, idle ones sit still, live sessions locked elsewhere are dimmed, and sessions finished in the last hour (not live, no tab) lie at anchor, faded, in the open water.

A click runs `Store.activate(.session)` (locks respected); hover shows a glass card with title and status. Esc (the focused Harbor view's `onExitCommand`, so keys never reach the hidden terminal) leaves it, as does selecting any tab or session. Everything static is one Canvas; each moving boat is a small `NSHostingView` whose layer carries repeating Core Animation translations, re-added only when a boat's motion changes. A `TimelineView` redrawing a Canvas cost ~13% CPU (Debug) at both 10 and 15 fps: each tick re-ran AppKit constraint and layout passes over the whole window.

The render-server animations measured 0.4% (Debug, over 10 s), against 0.4% for the terminal view.

## One seamless background

`WindowChrome` (an `NSViewRepresentable`) makes the title bar transparent and sets the window background to `GhosttyTheme.chrome` at zero transparency. SwiftUI's toolbar background modifiers alone left the title bar a shade off (#28282a vs #282c34).

Window Background in Settings > Terminal sets the fill behind the cards. Theme (default) uses the chrome colour at zero transparency and reveals the window backdrop when transparency is raised. Glass opts into the oversized system glass layer described above. Darker uses the cards' theme background colour at full opacity and fades to `1 - windowTransparency` when transparency is raised. Window Transparency continues to affect the backdrop behind the sidebars in every mode. The terminal, conversation and diff cards stay opaque.
