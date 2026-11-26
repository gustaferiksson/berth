# Snapshots

Offscreen snapshot and verification flags for Debug builds (`Sources/Snapshot.swift` and its siblings). Moved from CLAUDE.md. Never drive real windows, mouse or focus; these hooks exist so nothing has to.

## Basics, shell and Claude tabs

Use `-snapshotGhosttyTheme "Atom One Light"` for light snapshots because the app derives its colours from the Ghostty theme.

Snapshot without touching the screen (Debug build only): `.build/Build/Products/Debug/Berth.app/Contents/MacOS/Berth -snapshot /abs/out.png` plus `-AppleInterfaceStyle Dark`, `-snapshotShell YES` (two terminals in the Terminals group, the second showing a fake `npm run dev` title and working dots; add `-snapshotShellCd "<args>"` to type `cd <args>` into the first one), `-snapshotClaudeTab YES` (a shell-backed claude tab with no transcript yet), or `-snapshotClaude /abs/dir` (launches real `claude` without `-w` whatever the setting, shows its trust prompt), or `-snapshotResume <sessionId>` (the sidebar click path, `claude --resume`).

Use `-windowBackground theme|glass|darker` to select the detail background through the argument domain. For example, pass `-windowBackground darker` to show the cards' theme background colour in the gaps. System glass requires an on-screen window to render.

## Sidebar fixtures

`-snapshotBusySidebar YES` seeds 28 sessions in eight projects and two terminals. It includes all pull request and check states, live activity, unread and flagged sessions, pins, two tasks with members, Snoozed and Done. Use `-sidebarTwoLineRows YES` to show the repository and branch under session titles. The fixture shows triage and expands Snoozed and Done by default. Use `-snapshotSidebarWidth <pt>` to change the leading sidebar’s ideal width from 300 pt.


`-snapshotPaneTerminal YES` (with `-snapshotSessionTerminals YES -snapshotSelectNestedTerminal YES -reviewEnabled NO`) types `stty size` into the pane terminal at window widths 1500, 1000 and 1400 and prints the surface size and focus per width, saving `<out>.pane-<width>.png`. It then selects the session tab, leaves focus in the pane terminal, opens find, types a needle and saves `<out>.pane-find.png`.

`-snapshotSessionTerminals YES` opens a shell-backed Claude tab for a fixture session, two terminals indented under it, and one plain terminal in the Terminals group. `-snapshotSelectNestedTerminal YES` selects the first nested one (Terminal mode: both nested terminals in the trailing list, the mode switcher in the toolbar), `-snapshotCloseNested YES` calls `Store.close` on it and prints the tab counts. `-snapshotClickAt "x,y;x,y"` (any run, points from the window's top-left) sends each synthetic click through `window.sendEvent` before the capture and prints the tabs before and after (Buttons land, plain row taps do not).

`-snapshotBrowser YES` (`SnapshotBrowser.swift`) writes six local fixture pages with data-URL favicons and opens a Claude tab with two pinned and four session browser tabs. The header above the web card selects Invoices. Add `-snapshotHover "Export API"` to show an inactive tab’s hover fill and leading close button. Add `-snapshotBrowserNewTab YES` to keep one pinned tab, select it, run New Browser Tab and call the key-view search on the focused address field under a 1 s watchdog (prints `probe PASS` or `FAIL`). Add `-snapshotBrowserPin single|pinOnly|pinnedActive|pinnedSelected` for one unpinned session tab, the same tab pinned, or a pinned and selected Berth Docs beside one session tab; pinnedSelected selects the first of two pinned tabs beside two session tabs. Add `-snapshotBrowserPin grid` with `-snapshotBrowserPinned N`, `-snapshotBrowserSessions N` and `-snapshotBrowserSelect pinned|session` for an exact tab mix. Add `-snapshotBrowserAgent YES` to select a long local URL tab marked as agent-driven, showing the Agent badge beside the truncated address. Add `-snapshotBrowserAgentInactive YES` to leave that tab unselected. Add `-snapshotBrowserExtraTabs 12` for extra tabs before Invoices and vary `-snapshotWindowWidth` to check compression and horizontal overflow. `-snapshotBrowserFocusAddress YES` makes the offscreen window key and runs ⌘L to edit the full URL. With `-snapshotClickAt "x,y;x,y"`, the browser fixture also logs the address field editor’s frame and selection after each click. The summary prints the window width, tab counts and titles, loaded favicon count, forced hover titles, selected page, loading state, first responder and the fixture page’s `navigator.userAgent`. The summary also prints the scrollbar probe with the measured width and height, our system style and AppKit style value; `-snapshotScrollBars Always|Automatic|WhenScrolling` overrides the global setting we read.

Add `-snapshotBrowserLocked YES` for two pinned tabs and one selected session tab, with a lock marker on the collapsed Berth Docs tab.

The fixture loads via `file:` and embeds its favicons as `data:` URLs. The content rule list permits only `file:`, `data:` and `about:` resources. Other navigations print `snapshot browser blocked <url>`. The store runs in memory. Web views turn off WebKit's window occlusion check so the offscreen window can paint the page.

Add `-snapshotIncomingURL <url>` (with or without `-snapshotBrowser YES`) to feed a URL to `Store.openIncomingURL` and print the session, browser tab counts, pane, launcher and pending URL.

Add `-snapshotBrowserApproval YES` to raise the Allow Browser Access sheet for a long-titled worktree session with a requested URL and save only the sheet to the output path (use `-snapshotGhosttyTheme "Atom One Light"` for light).

Add `-snapshotBrowserHistory back|forward|both` to navigate the selected tab through the local pages and capture the requested history controls. The summary prints whether Back and Forward are available. Use `-snapshotWindowWidth 1600 -reviewTerminalBelow YES` to give the browser enough width to show the controls in the header.

`-snapshotBrowserInspector YES` opens the browser fixture and prints `isInspectable`, `developerExtras` and `showPath` for the selected tab without opening Web Inspector. Repeat with `-browserDeveloperTools NO` to check the configuration with developer tools off.

Add `-snapshotPaneWidths YES -reviewEnabled YES -languageServersEnabled NO` to the browser fixture to exercise every directed switch between Changes, Files, Browser and Terminal. The probe briefly resizes the offscreen window by 1 pt to settle the split, then moves the session/pane divider by 100 pt in Browser before switching modes. It checks that the divider stays at the new position after the drag settles and that each switch keeps the resulting session width in the side-by-side layout or divider height with `-reviewTerminalBelow YES`. Each line logs the session width, divider position in window coordinates, pane width and split width before and after the drag or switch. After the switches it resizes the window across eight widths from 900 to 1600 pt and drags the divider to 10%, 90% and 50% in every mode, printing a `stress PASS` line if no layout exception is thrown. Repeat with `-sidebarPosition right` or `-reviewTerminalBelow YES` to cover the other layouts.

Add `-snapshotRememberedSizes YES -snapshotBrowser YES -reviewEnabled YES -languageServersEnabled NO -snapshotWindowWidth 1800` (plus `-sidebarPosition right` or `-reviewTerminalBelow YES`) and a temp `CFFIXED_USER_HOME` to drag the session/pane divider, hide and show the pane in every mode, switch to a second session in another mode, restore both sidebars and shrink the window, printing `PASS` or `FAIL` for each size.

Add `-snapshotModeSwitch YES -snapshotBrowser YES -reviewEnabled YES -languageServersEnabled NO` to run `Store.selectPane` (the toolbar's call) from Browser after opening, navigating, pinning and selecting tabs, then between every pair of Changes, Files, Browser and Terminal, printing `PASS` or `FAIL` for the mode and the visible column. It can't cover the toolbar itself, which the snapshot window doesn't have.

For PR pill layout, `-snapshotLongNames YES -snapshotLinkedPullRequests YES -snapshotChecks "running|passed|passed|passed" -snapshotFakeStatus YES` gives a top-level row with a "+3" pill and the open, merged, draft and closed variants.

Add `-snapshotFakeStatus YES` to fake the top project's first three sessions as "needs you", "working" and "shell", `-snapshotSelectRow <n>` to select the top project's nth session, `-snapshotHover "<header or row title or branch>|..."` to force hover states, `-snapshotExpandedGroups "<group id>|..."` to open their Show More, `-snapshotPinned YES` to pin the first session of the last two groups, `-snapshotFlagged YES` to flag the top project's 1st and 3rd sessions, `-snapshotUnread YES` to mark its 2nd and 4th unread, `-snapshotMultiSelect "2|shift4|5|term1"` (opens shell-backed claude tabs for the named top-project rows, clicks the first, ⌘-clicks `<n>` and `term<n>`, ⇧-clicks `shift<n>`, saves `<out>.selected.png`, then runs the menu's Unload and Pin and the palette's Flag, printing selection, tabs, flags, menu and palette titles each step), `-snapshotLongNames YES` (fixture sessions with long project, branch and title names and every PR state), `-snapshotChecks "<state>|…"` (passed, failed, running or empty for each `-snapshotLongNames` fixture session in order, as its PR's check rollup), `-snapshotPlanUsage YES` (fake 42% Session and 81% Week plan usage, `-snapshotPlanUsageAhead YES` for 55% and 66% ahead of pace; pass `-showsPlanUsage YES` too, since the fetch never runs in snapshot mode), `-snapshotCodexUsage YES` (fake Codex 18% Session and 47% Week beside it; needs `-codexEnabled YES`, `-snapshotCodexUsageStale YES` records it 3 hours ago, which dims it), `-snapshotFakeContext YES` (the top group's first four sessions at 34%, 63%, 81% and 94% of a 200k window; claude tabs open for the 81% and 94% ones, the 94% one selected; add `-snapshotFakeStatus YES` so the 63% one is live without a tab), `-snapshotSidebarWidth <pt>` (default 300), and `-snapshotGhosttyTheme "<name>"` to replace the Ghostty config with just that theme, `-groupingMode project|repository|recent`, `-showsCustomGroups NO`, `-sidebarPosition right`, `-snapshotCustomGroups /abs/groups.json` (JSON `[CustomGroup]`; a JSON string can't be passed as an argument, NSArgumentDomain drops it).

Add `-snapshotItemPreview "pr|issue|pr-checks"` with one of the three values to render a standalone fixture card at 2×. The `pr-checks` variant expands the checks disclosure. With `-snapshot /abs/out.png`, the card is written to `/abs/out.png.preview-<value>.png`.

`-snapshotBackgroundTasks YES -AppleInterfaceStyle Dark` opens Tasks mode with invented transcript, subagent and output files in a temporary directory. Use an empty `CFFIXED_USER_HOME` to isolate the sessions sidebar. The default capture selects the running shell and appends one line after the pane opens. Use `-snapshotBackgroundTask agent|finished|terminal` to select the corresponding row. The terminal variant checks surface identity and session width across mode switches. Pass `-snapshotWindowWidth 1500` for room for both sidebars.

## Launcher, palette, search, stats and dialogs

`-snapshotLauncher "<query>"` (opens the ⌘N launcher with that query), `-snapshotPalette "<query>"` (opens the ⌘K palette with that query; add `-snapshotClaude /abs/dir` for an open tab in its Sessions section), `-snapshotSearch "<query>"` (opens search mode with that query and prints index build time, text size, memory footprint and the hits once the whole index, subagents included, is built: add `-snapshotHold 6` or it exits first), `-snapshotStats YES` (captures the Stats view in its own 960×800 window after the index is built and prints build time, footprint, the 30-day token totals and the tile values), `-snapshotEditGroup "<name>"` (captures the group editor for that group, or a new one for an unknown name, in its own window: a real `.sheet` moved the offscreen window onto the screen), `-snapshotRestartBanner "<version>"` (the update restart banner, 18 s deadline), and `-snapshotHold <s>` to keep the window up longer (for CPU checks).

## Review: open, panel and review card

`-snapshotReview /abs/repo` opens a shell-backed claude tab (session `snapshot-review`) in that folder in a 1600×900 window (`-snapshotReviewWidth <pt>` changes the width), registers `reviewEnabled` in memory (`-reviewEnabled NO` tests the gate), shows Changes, opens the first Uncommitted file (else the first Committed one) in a preview tab, waits for its contents and prints, per side, whether the text view is still TextKit 2, its height, reserved comment space and inline views, whether the first unchanged line after each hunk and every unchanged pair sit at the same y on both sides, and whether each line sits at `top(ofRow:)`, and per side how many line views (`_NSTextViewportElementView`) are on screen and how many sit off their layout fragment's rendering frame (0 when lines are where the layout says).

It also prints the mode: side by side, or unified with the right side's width and `minimumWidth`, whether its text equals the file (or the draft), and its height against `top(ofRow: rowCount)` (2 pt short in both modes, the last row's bottom padding; a row more for a file deleted without a trailing newline, whose absent side's one empty line is an added row nothing draws). `-snapshotReviewFile <path>` opens that path instead, Files-tab style (its Uncommitted compare when listed, else the plain file; `committed:<path>` opens its Committed compare), `-snapshotReviewHoverRow <path>` (Debug) forces the Open File overlay on that Changes row as if hovered, `-snapshotReviewChangedFiles "/abs/a,/abs/b"` opens no default file and instead runs the Conversation card's Review Changes action with those edited paths (the first one listed in Changes opens in the diff column; pair with `-snapshotReviewHidePanel YES` for the hidden panel start), `-snapshotReviewNoFile YES` opens no file, so the diff column shows No File Open.

`-snapshotFiles YES` (with `-snapshotReview /abs/repo -snapshotReviewNoFile YES`) switches to Files mode and prints the shown pane, tree rows, filter matches and selection. `-snapshotFilesExpand "a;a/b"` expands those folders, `-snapshotFilesOpen <path>` selects and opens that file (add `-rendersMarkdown YES` for the rendered Markdown), `-snapshotFilesFilter <text>` fills the filter field.

Review pull request fixtures use these flags.

- `-snapshotReviewPullRequest "<branch>"` adds fixture PR #4821 for the named branch.
- `-snapshotReviewPullRequestState open|draft|merged|closed|none` sets its state. Use `none` for the empty branch summary.
- `-snapshotReviewChecks "<passed>:<failed>:<running>:<open threads>"` supplies hero check counts and review threads.
- `-snapshotReviewIssue YES` links the open issue `acme/billing#377`, assigned to mara with the bug and export labels. Use `-projectsEnabled YES` for its In progress status.
- `-snapshotReviewStack YES` adds parent PR #412 with passing checks and approval, and draft child PR #421 with a failing check.
- `-snapshotReviewPullRequestDetails YES` opens PR #4821 details with a Markdown description, reviewers, comments and named checks.
- `-snapshotReviewPullRequestFile <path>` (with `-snapshotReviewPullRequest "<branch>"`) opens that file as Open File on the fixture PR's row would, with `-snapshotReviewPullRequestHead <sha>` as the PR head (default fake) and `-snapshotReviewPullRequestDefinition <line>:<col>` asking the language server there (with `-languageServersEnabled YES`). It prints the root and path the file opened from, the drift note and the definition's target. A branch checked out in another worktree opens from that worktree; otherwise the GitHub copy shows with the checkout hint.
- `-snapshotReviewSelectPullRequest <number>` opens the specified fixture's read-only diff as a card or row click would. Use #4821 for the hero, #412 or #421 with the stack fixture, or #1445 with the session PR fixture. The diff uses fixture file contents.

Review snapshots use fixtures for GitHub data.

`-snapshotReview /abs/repo -snapshotReviewThreads YES` uses the current branch for the fake PR, opens `README.md` and expands Review Threads. Use a repo with at least six lines in `README.md` to see the open thread at line 3 and the resolved thread at line 6. The panel also shows an outdated thread and an original-side thread on `docs/usage.md`. The `review threads` line prints total and resolved counts by file. Checks default to four passed, zero failed, and one running. With `-snapshotReviewChecks`, its counts override the defaults and its open threads are added to the four fixture threads.

`-snapshotReviewCreatePullRequest YES` fakes a live, idle Claude session and invokes the empty summary's Create Pull Request… action. With `-snapshotRemoteLog /abs/file` the terminal runs `tee -a` into that file. The hook clears focus, runs the action, logs the focus, notice and terminal output, saves `<out>.pr.png`, then presses Enter and reads the log again. The pasted prompt reaches the log after Enter.

`-snapshotReviewRepository <owner/name>` replaces the fixture PRs' repository (default `acme/billing`); `-snapshotReviewRefresh "<x>,<y>"` clicks that point (401,55 is Refresh at the default width), prints the panel branch's lookup before and 8 s after, and saves `<out>.refreshed.png`. Every Review run also prints `review card` (base, default branch, ahead, behind, upstream, each commit pushed or not, the branch total, `base <ref> (<reason>)`, `bases [<ref> <distance>, …]`, PR details; `-snapshotReviewBase <ref>` puts a pick into the argument domain after the first load and reloads, `-snapshotReviewPullRequestBase <branch>` sets the fixture PR's `baseRefName`).

It also prints each changed file per section, the file tree's top level and its expanded folders, with `-reviewChangesAsTree YES` each changed section as its compacted tree, and the open tabs (path, compare or `file`, preview or kept, history position; the selected tab in brackets), which `diff` in every state line repeats.

`-snapshotReviewPanelTab graph` expands Commits and History. On the default branch, the graph appears directly in Commits. The graph initially shows 10 rows on the default branch and through the merge base on feature branches, with 10 rows as the fallback. `-snapshotReviewGraphCommit <n>` reveals and selects the zero-based commit in graph order, loading more pages as needed, and opens its first changed file as a preview. This flag also expands Commits and History. The `review selected` line reports the loaded graph count, selected commit SHA and tabs. Historical tabs appear as `commit <sha7>:<path>`.

`-snapshotReviewSessionPullRequests YES` links open PR #1445 “Let Margo switch between approved reviewers” to the fixture session and opens the Session pull requests section. Add `-snapshotReviewExpandPullRequest 1445` to expand that row and open its first changed file. For the expanded snapshot, use a checkout whose GitHub `origin` matches `acme/billing` (or the value of `-snapshotReviewRepository`) and serves `refs/pull/1445/head`. The local URL rewrite in the fixture recipe below lets Git fetch from a local repo. The PR uses `-snapshotReviewPullRequestBase <branch>` when supplied, or the repository’s default base. The `review selected` output reports the file count and shows the selected tab as `PR #1445:<path>`. Add `-snapshotReviewCommandClick YES` to open that file the way ⌘-click does: the working-tree file when the session folder holds it, otherwise the PR head version read-only (delete the file in the clone to see this).

`-snapshotHoverPullRequestRows YES` draws every pull request row in the Session pull requests section as hovered, so its ... menu shows in place of the status dot.

The billing clone recipe gives PR #1445 a compacted `review/permissions` folder with a nested `rules` folder. With the PR expanded, use `-reviewChangesAsTree YES` to start in tree mode, or `-reviewChangesAsTree NO -snapshotKeys "shot:list toggle-tree shot:tree toggle-tree"` to capture both layouts and return to list mode in one run.

Use `-snapshotReview /abs/api -snapshotReviewShowPullRequest /abs/billing -languageServersEnabled NO` to show fixture PR `acme/billing#1445` in the API session and open its first changed file. Add `-snapshotReviewShowPullRequestLauncher YES` for the launcher in Show in Review mode over that diff. Use the clone fixture recipe in the Agent control section.

## Review: edit, scroll, minimap, gutter and comments

`-snapshotMarkdownRendered YES` shows a `.md` file open in Review (pair with `-snapshotReviewFile <path>`, a committed unmodified file, so it opens as a file and not a diff) as rendered Markdown; images load from paths inside the review folder. `-reviewWrapsLines YES` (argument domain, no snapshot flag) turns on line wrapping in any Review run; pair it with `-snapshotReviewWidth` and `-reviewDiffLayout inline|sideBySide`. `-snapshotReviewBlameLine <line>` places the caret on a one-based line in the working-tree editor, scrolls it into view and saves `<out>.blame.png`. Pair it with `-snapshotReviewFile <path>` to choose the file. Use a tracked file with a short line so the annotation fits in the editor.

`-snapshotReviewEdit "<text>"` inserts text at the top of the right side (the draft and recompute path), `-snapshotReviewScroll <y>` scrolls the right side (the left follows), `-snapshotReviewWheel "<target>:<dy>"` sends a pixel scroll-wheel event to the view hit-tested at the centre of `left`, `right`, `gutter-left`, `minimap` or `ruler`, `-snapshotReviewMinimap "<y1>-<y2>"` drags the minimap and `-snapshotReviewRuler <y>` clicks the overview ruler (each prints both clip ys; the minimap also its render count).

`-snapshotReviewGutter "left|right:<a>-<b>"` drags across those gutter lines (rows from `top(ofRow:)`; unified, `left` drags the right gutter at those base lines' rows), prints the draft box and focus, saves `<out>.draft.png`, sends Esc, reopens, types `fix` ⇧↩ `it` ↩, prints the comments and saves `<out>.card.png`; `-snapshotReviewRestyle "<scheme>:<line height>"` then writes those two settings (restored afterwards), reports and saves `<out>.restyled.png`; `-snapshotReviewCommitsExpanded YES` expands Commits; `-snapshotReviewDelete YES` then deletes the card with its × and appends and removes a comment through the model (the file column's path).

`-snapshotReviewEditComment YES` clicks the first card, types, Escs, clicks it again, edits and saves, saves an emptied edit, drags the gutter over an open edit, expands the panel's comment list, double-clicks its comment row at 100,90 (bottom-left origin) and deletes the edited comment, printing comments, box, cards, `reserved` and the alignment report each step (`<out>.editing.png`, `.edited.png`, `.card-hover.png`, `.panel-edit.png`). `-snapshotReviewPanelTab changes|files|graph|comments|preview` keeps the default view, expands Files, expands Commits and History, shows the comment list, or opens the diff column’s Preview.

`-snapshotReviewResize <pt>` then sets the window width, reports and saves `<out>.resized.png` (crossing 760 pt of diff column switches the mode). `-snapshotReviewSplit <ratio>` scrolls the right side to x 40, drags the divider between the sides to that ratio with real mouse events (queued drag and up, then the down), prints both sides' widths, the stored `reviewSplitRatio` and both clip xs and reports, saves `<out>.split.png`, closes and reopens the diff, switches to unified (`<out>.split-unified.png`) and back through the argument domain, double-clicks the divider (`<out>.split-reset.png`) and restores the stored ratio.

## Review: surfaces across tabs, Harbor and sidebar

`-snapshotReviewSurfaces YES` (with `-snapshotShell YES`) then closes and reopens the diff, hides and shows Changes, selects a terminal and the claude tab, enters and leaves Harbor and flips `sidebarPosition` twice (argument domain only), scrolls the right side to x 40 and ends a live resize, then narrows the window to 1200 pt, closes, reopens and closes the diff, printing per step both sides' clip x, the split's frame and panes and whether every tab keeps the same surface view and superview, Berth's descendant pids, ptys and shell starts, and saving `<out>.<step>.png`.

`-snapshotKeys` reaches the focused text view (typing, ⌘Z) and ⌘S (the key monitor runs `AppAction.save`), but not SwiftUI button shortcuts: `NSApp.sendEvent` skips the fake key window's key-equivalent pass (menu items still fire).

## Review: language servers, hover, definitions and references

`-snapshotLanguageServers /abs/servers.json` puts a JSON `[LanguageServerEntry]` into the argument domain (entries with a default's id override it); `-snapshotEditServer "<id>"` captures the server editor for that entry, or a new one for an unknown id, in its own window. The diagnostics print waits until the shown diagnostics are unchanged for 3 s, so every server's are in. With `-languageServersEnabled YES` the Review run waits (up to 120 s, skipped on a Committed compare) for the right side's first diagnostics, prints them with their tags and the gutter's tooltip string and saves `<out>.diagnostic.png`; `-snapshotReviewToggleServers YES` then turns the setting off (argument domain), prints the servers and diagnostics left, turns it on and prints them once diagnostics are back; `-snapshotReviewCrash YES` then SIGKILLs the server, prints that Review still shows the file, opens another Uncommitted file and the first again (through the preview tab) and prints the restarted server's pid; `-snapshotReviewHover "[left:]<line>:<col>"` (1-based; `left:` is the left side's text, sent to the right view at that row when unified, found through `unifiedOriginal`) moves the pointer there until a card shows (60 s), prints each section's text (`———` for the separator) and the layoutManager count, saves `<out>.hover.png` and moves away; `-snapshotReviewDefinition "[left:]<line>:<col>|…"` ⌘-moves (saves `<out>.link-<l>-<c>.png`) and ⌘-clicks each position in the starting file and prints the tabs it landed in (the preview tab's document: the Uncommitted compare or the plain file), the position and selected text, both clip ys and first responder, saving `<out>.definition-<l>-<c>.png`, then runs Refresh and prints whether that document is still shown, or prints that the position is its own definition.

`-snapshotReviewReferences "[left:]<line>:<col>|…"` prints the context menu and Writing Tools state, ⌘-clicks and prints the peek (title, groups, preview selection, owner, reserved) with the alignment report and `<out>.references-<pos>.png`, then, with `-snapshotReviewReferencesResize <pt>`, sets the window width (height 900), prints whether it is the same peek, its orientation, both pane frames, the list column, the peek and the alignment report, and saves `<out>.references-<pos>-resized.png` (later steps run at that width), then, with `-snapshotReviewReferencesSplit <list share>`, fakes the window as key (swizzled `keyWindow` / `isKeyWindow` plus `window.becomeKey()`: rows never emphasize offscreen without it), drags the peek's divider to that share along its axis with queued mouse events, prints side by side or stacked, the panes' sizes along the axis, the preview's clip x, whether a point 2 pt past the divider hits the split, the stored ratio and the row's emphasis, saves `<out>.references-<pos>-split.png`, double-clicks the divider and restores `reviewReferencesSplitRatio`, then ↓ (`-down.png`), a click on the last row (scrolled into view first), Esc in the preview, ⇧F12 (the context menu's Find References on a unified removed row), ×, ↓ ↩ (`-opened.png`) and the list's double-click action, printing where each landed.

The hooks' ⌘-click queues a mouse-up, so a miss no longer hangs in NSTextView's tracking loop.

## Review: language server fixtures

Fixture: `Packages/BerthCore` with a scratch type error, or a copy of the package committed in its own repo under the worktree's `.build/`; a package under `/private/tmp` makes sourcekitd fail ("semantic editor is disabled"). A worktree whose `Packages/BerthCore/.build/index-build` was copied from the main checkout makes sourcekit-lsp answer "Loading the standard library failed" (its module cache records the other path); move it aside.

## Terminals, Harbor, archive, unload, drops and performance

`-snapshotTerminalSearch "<needle>"` (with `-snapshotShell YES`) prints lines into the first terminal, opens Find, types the needle, steps ↩ ↩ ⇧↩, clears and Escs, printing total, selected and first responder; saves `<out>.find.png` and `<out>.cleared.png`. `-snapshotHarbor YES` shows Harbor; with `-snapshotFakeStatus YES` the faked sessions get shell-backed claude tabs so they moor undimmed (`-snapshotHover "<title>"` shows a boat's card). `-snapshotArchiveRow <n>` archives the top project's nth session in memory and scrolls to the Archived section (add `-archivedExpanded YES`; pick a session that isn't live, or new activity unarchives it at once).

`-snapshotCloseTabs YES` closes every tab after the wait and prints which of Berth's child processes are still alive 3 s later. `-snapshotArchiveTab YES` opens two shell surfaces as claude tabs, archives the background then the selected one through `Store.archive` and prints whether each `TerminalView` was freed and Berth's `/dev/ptmx` count. `-snapshotUnloadIdle YES` (with `-unloadIdleSessionsAfter 2`) opens fake idle, touched, selected, pinned, busy, waiting, attach and dead claude tabs plus a terminal, runs `Store.unloadIdleTabs` at once and after 3 s and prints what was unloaded and kept.

`-snapshotDrop YES` opens two claude tabs and two shells running `cat`, drops two files and a group drag on three of them in turn and prints the drop destination and what each received. `-snapshotOrphan <pid>` (with a `CFFIXED_USER_HOME` holding a session file for that pid and its transcript) prints orphaned and locked, clicks the top session and prints whether the pid died, the notice and the probed `openClaude` calls. `-snapshotActivateFocus YES` prints the first responder before and after `Store.activate` for an already open and a new tab.

`-snapshotPerf YES` (`SnapshotPerf.swift`) times, as main-thread ms and process CPU, window resizes (a sweep down to 900 pt and back, and across the 801 pt sidebar yield), the session sidebar toggle and the Review panel toggle; `-snapshotPerfRounds <n>` (toggle pairs, default 1), `-snapshotPerfSteps resize,sidebar,panel` (default all) and `-snapshotPerfSetup closeDiff,hidePanel,hideSessions` (run first). Release timing needs `SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG`.

`-snapshotPerfSteps resize,scroll` adds an opt-in scroll step that times 40 steps from bottom to top and 40 back in the window’s tallest scroll document. The Conversation snapshot also accepts `-snapshotPerfSteps scroll`.

## Fixture homes, URLs and window state

To test folder following against real transcript records, point a fixture home at `CFFIXED_USER_HOME=/abs/home` (Store reads `~/.claude` through it) holding `projects/<slug>/snapshot-review.jsonl`, and don't pass `-snapshotReviewPullRequest` (fixture sessions replace the scan). With a scratch repo nested in the checkout, export `GIT_CEILING_DIRECTORIES` so a broken scratch repo doesn't resolve to the parent. Snapshot modes swallow `openURL` (PR and issue chips, cards, `Link`s) and print `snapshot openURL <url>`, so nothing reaches the browser.

Snapshot modes ignore saved window state (`ApplePersistenceIgnoreState`); before that, state restoration showed the real `main` window on screen during every snapshot.

## Keys

`-snapshotKeys "cmd+, cmd+shift+f ctrl+tab …"` (with `-snapshotShell YES`) fakes the snapshot window as key, sends each chord through `NSApp.sendEvent` (CGEvent-backed: `NSEvent.keyEvent`'s events never match ⇧⌘Z) with the selected tab's surface focused, types a plain key (`a`, `s`, `1`, …) into the focused view, and prints menu actions fired plus launcher, tabs, selected, focused, terminals, grouping and open windows, and with a `ReviewTextView` focused its text and whether it can undo and redo (⌥⌘W, ⌘Q and ⌘W with Review's panel hidden end the run; with the panel shown ⌘W only closes the diff tab).

`-snapshotKeysGap <ms>` (default 400, plus 100) shortens the wait between keys (50 types and undoes inside Review's 300 ms re-render). Pseudo-keys: `browse<n>` selects the nth sidebar-ordered tab like ↑/↓ (no selection history), `exit` types `exit` into the selected terminal, `terminal` focuses the selected tab's terminal (ctrl chords sent by the harness never reach zsh, so only Review's side of a terminal-focused ⌃- can be shown), and in Review: `file<n>` clicks the nth Changes row (Uncommitted, then Committed), `open:<u|c|f>:<path>` clicks that path's Uncommitted row, Committed row or Files row, `dbl:<u|c|f>:<path>` double-clicks it (open and keep), `keep` double-clicks the current tab, `back`, `forward`, `reveal` (sets `ReviewModel.filesReveal` to the current path, like the tab menu's Reveal in Files), `save` (saves the draft directly; `cmd+s` works too), `refresh` runs `Store.refreshReview` like Refresh.

`layout:<auto|sideBySide|inline>` writes `reviewDiffLayout` (the run restores its starting value, also after a tab strip toggle click (836,68 with Save showing, else 861,68, at the default width)), `width:<pt>` sets the window width, `git:<a>,<b>,…` runs git with those arguments in the review model's folder, `relocate:</abs/dir>` sets the selected tab's folder like a scan after `/cd`, `uncomment` deletes the review model's comments (every Review snapshot starts with a fixture comment, so a move only shows `movedFolder` until it runs); each waits, then prints.

`toggle-tree` flips `reviewChangesAsTree` in the argument domain, waits for the Changes panel to update, and prints the new mode. It works while a Session pull request is expanded.

The state line also prints the terminal split's pane widths, the diff layout (stored, shown, which of Show Side by Side / Show Inline is offered), the review model's folder, branch, Uncommitted and Committed paths and `movedFolder`, each Uncommitted path's +/- counts, the model's `loads` count and its `error`, the Files list's expanded folders, the changed trees' collapsed folders (`collapsed change folders`), and the focused text view's character count. A `click:` on a row's Open File button lands, unlike a plain row click.

Each then focuses the diff's right side and prints whether it is editable, unified, the path's shared editor and wired to a language server. `click:<x>,<y>` and `dblclick:<x>,<y>` send real mouse events at a window point (top-left origin; the mouse-up is queued before the mouse-down because a control's tracking loop waits for it): a row or tab double-click lands, and so does a click anywhere on a Files folder row (its label is a `Button`; an `onTapGesture` there never fired from this click); a single file row click or a segmented-control click changes nothing.

`shot:<name>` saves `<out>.<name>.png`. `altclick:<line>:<col>` (1-based, right side) and `altclick:row<n>` (a row from `top(ofRow:)`, for removed or filler rows) send ⌥ mouse down/up straight to the right text view's `mouseDown`/`mouseUp` (posted to the window they never reach it); `altdrag:<l>:<c>-<l>:<c>` sends ⇧⌥ down, drag, up. Extra key names: `d l u i up down left right delete f2`; plain or ⇧/⌥ arrows go to the window as NSEvents (CGEvent chords without ⌘ never move the selection). The state line also prints `review text focused`, and with a `ReviewTextView` focused its `carets` (line:col+length), primary, layoutManager requests and TextKit 2.

The run restores the pasteboard's string afterwards. Consecutive edits in one run merge into one undo step (native typing too), so the harness can't show undo separation. `select:<text>` selects that text's first match on the right side (`\n` and `\s` stand for a newline and a space), waits until its occurrences change (2 s at most) and prints how long that took. The state line also prints each side's `occurrences N on M rows`, and `find field "<text>"` while a find field has focus.

## Launcher keys, waiting and menus

`-snapshotLauncherKeys "hub down enter …"` opens the ⌘N launcher over two fixture folders (`x-hub-ui`, a git repo, then `x-hub`, not one), types each token (letters h u b x i -, `down`, `up`, `enter`, `alt-enter`) and prints the launcher mode and the `openClaude` calls it would make with their start kind (nothing launches); add `-startsInWorktree YES` for the worktree launch. `-snapshotFakeWaiting YES` steps the top project's first session through busy, waiting, waiting, busy, waiting (in a Berth tab from the third step) and prints the Dock badge and each notification it would post (snapshot mode never posts or requests notification authorization).

It prints the window title, toolbar items, the File and View menus (Group By with ⌃⌘ shortcuts and checkmarks) and open tabs (with OSC 7 pwd and title), and hangs up its child processes on exit. -

## Settings snapshot

Settings snapshot (rinse's pattern): `Berth -settingsSnapshot /abs/out.png -settingsTab general|sidebar|terminal|conversation|review|github|browser|remote|about`, a stored `appearance` opens Sidebar (plus `-AppleInterfaceStyle Dark`). It opens Settings through the app menu's ⌘, item with window ordering swizzled so the window never touches a display and its saved frame isn't overwritten. `-settingsScroll <y>` scrolls the form to y before capture (420 shows General's Language Servers section with Review and language servers on).

`-snapshotProjects YES` enables GitHub Projects and installs two fixture boards without calling `gh` (`-snapshotProjectsLauncher YES` opens the launcher's Project scope, `-snapshotHover` shows the status on a fixture PR's hover card with `-snapshotLongNames YES`), and `-snapshotProjectsState needsScope|noCLI|failed` shows a notice in `-settingsTab github`.

## Snapshot window and activation policy

The snapshot window is a hand-built NSHostingController window: no glass sidebar, and it bridges the toolbar and subtitle but not `navigationTitle`, so `Snapshot` sets `window.title` itself ("Untitled" there was never an app bug). Capturing the real scene window off-screen doesn't work: the glass sidebar's contents come out blurred, and the saved `NSWindow Frame main` puts it on screen anyway. Never set `window.toolbar` there. Snapshot mode must use activation policy `.accessory`; `.prohibited` hides the window and `CGWindowListCreateImage` returns nil.

## Flags documented with their feature

Moved out of the feature notes they came from.

### Remote

Phone: `-snapshotRunning YES` / `-snapshotContext YES` open the sheets.

Snapshot hook: `-snapshotRemote YES -remoteEnabled YES -remoteToken <t>`, plus `-snapshotRemotePort <p>` (Debug only) so it doesn't collide with a running Berth on 7878; `-snapshotFakeStatus YES -snapshotHarbor YES` gives the faked sessions tabs, so they aren't read-only; with `-snapshotRemote` it also fakes an idle session in a tab and one locked elsewhere, and `-snapshotRemoteLog /abs/file` makes those tabs `tee -a` into that file instead of running zsh, so sent prompts can be asserted.

Berth Remote's DEBUG `-snapshotExpanded YES` and `-snapshotExpandedCalls YES` open its tool groups and tool calls, `-snapshotAttachments "/abs/a.jpg|/abs/b.txt"` uploads those files into the composer, `-snapshotDraft "<text>"` and `-snapshotSend YES` send them, `-snapshotSettings YES` opens Settings, `-snapshotUpdateAvailable <version>` fakes an available update (the install row atop the session list and on the connect screen), and `-snapshotFocusAndExpand YES` focuses the composer at 4 s and toggles every finished turn's Worked for four times from 6 s (the freeze repro: `axe swipe` the transcript up about 450 pt first).

More DEBUG flags: `-snapshotPullRequest YES`, `-snapshotChanges YES` (open those sheets), `-snapshotQuery "<text>"` (list search), `-snapshotTray YES` (quick reply tray), `-snapshotIntent "<spec>"` with `-snapshotIntentConnect "<url>|<token>"` (runs an intent against a Mac and prints the result).

`-snapshotDemo YES` opens a sample session without a Mac server. Add `-snapshotDemoImageOnly YES` to end the session with an image-only prompt. Add `-snapshotDemoList YES` to stay on the session list with Needs You, Working and Unread triage sections, PR tags with running, passed and failed checks, long branches, and Claude and Codex usage rows with stale Codex data. Add `-snapshotDemoFocus YES` to focus the composer after 1.5 seconds.

Add `-snapshotDemoCode YES` to append a fenced code block with one long line and two multi-command shell rows with stdout and empty stderr. The longer output starts collapsed. Combine it with `-snapshotDemoImageOnly YES` to end the same transcript with the image-only prompt.

On the Mac, run Berth with `-snapshotRemoteSections /abs/out.json -snapshotBusySidebar YES` to write the seeded sidebar sections as wire-format JSON and exit. In the iOS simulator, launch Berth Remote with `-snapshotDemoSectionsFile /abs/in.json` pointing to the exported file to open it in the demo session list.

Add `-snapshotDemoSlashCommands YES` to seed `/co` and sample project and user commands. Capture each appearance with `xcrun simctl io booted screenshot /abs/out.png` after setting it with `xcrun simctl ui booted appearance light|dark`.

### Glass (see docs/adr/0005)

`-snapshotSidebarFilter "<q>|…"` prints the visible rows per query; `-snapshotKeys` ⌃⌥+arrow chords take the CGEvent path and its state line prints `right top line`.

### Pull Requests and Issues

`-snapshotPullRequests "<query>"` uses fixture sessions and a fixture inbox (no `gh`) and prints each PR's section, checks, decision, sessions and what ↩ does; `-snapshotLauncherKeys` also knows `tab`, `#`.

`-snapshotIssues "<query>"` opens Issues with fixture rows across several repos, including 0, 1 and 3 linked PRs, one long title and one older issue. Use an empty query for the full recent list. Add `-snapshotLauncherKeys "enter"` to probe opening the three linked PRs, or use the query `"rounding"` with Enter to probe a new Claude worktree session and its unsent prompt. Use `"bucket"` to see the missing checkout notice, or `"alt-enter"` as a key to probe opening the issue URL.

Add `-snapshotLauncherLoading YES` to `-snapshotIssues ""` or `-snapshotPullRequests ""` to show the loading state for that scope.

`-snapshotIssue "owner/repo#1"` opens Pull Requests with one fixture linked PR. `-snapshotIssue "acme/api#10"` shows four PRs across repositories, with three known checkouts and an unavailable row for `acme/infra`. The snapshot prints each row's status. Add `-snapshotLauncherKeys "enter"` to print the recorded `openClaude` calls and whether the launcher stays open. The issue lookup uses fixtures and session opens are recorded as probes.

`-snapshotWatching YES` adds a **Watching #N** row to the sidebar fixtures and works with `-snapshotFakeStatus YES`. With `-snapshotConversation YES` and the empty fixture home used by Conversation snapshots, it writes an invented `/steward` record, defaults Claude to idle, and exercises transcript detection in the footer.

### Conversation view

`-snapshotConversation YES` (needs an empty `CFFIXED_USER_HOME`; pass `-reviewEnabled NO`, `-conversationEnabled YES`; `-snapshotConversationStatus busy|waiting|idle`, `-snapshotConversationMode auto|plan|acceptEdits|default` (the permission mode the status bar shows; for the branch counts make `/private/tmp/berth-conversation-fixture` a git repo with an upstream), `-snapshotConversationExpanded YES`, `-snapshotConversationHeight <pt>`) seeds an invented transcript, saves `<out>.conversation.png` and `<out>.terminal.png` and prints the surface identity across toggles.

Add `-snapshotConversationEmpty YES` to open a session with zero turns, and use `-snapshotConversationWidth <pt>` to set the capture width (1100 pt by default).

Add `-snapshotConversationSlashCommands YES` to capture the Claude composer with `/co` and the picker open. The flag seeds a command in the fixture home. `-snapshotConversationSlashText "<text>"` sets the draft (`|` marks the caret, for a slash typed mid-text), and `-snapshotConversationSlashAccept YES` accepts the first match and saves `<out>.slash-accepted.png` (the open picker is `<out>.slash-open.png`).

Add `-snapshotConversationShellCompletions YES` to capture shell mode with `!git ch` and the tine completion popover open. A fake tine socket in a temp path answers with invented items, so the real tine is never contacted. Add `-snapshotTineReal YES` to query the installed tine instead.

The Claude fixture includes shell-mode stdout and stderr, and `-snapshotConversationExpanded YES` expands the shell output.

`-snapshotConversationLongCode YES` replaces the default Claude transcript with a prompt containing a 60-line shell block and a reply containing a 40-line Swift block. Both blocks start collapsed. Add `-snapshotConversationExpanded YES -snapshotConversationHeight 2400` to capture both expanded blocks in the same image. Run `-snapshotConversationSelect YES` separately against the default or heavy fixture.

`-snapshotConversationAgent codex` with `-codexEnabled YES` seeds an invented Codex rollout and opens a Codex conversation tab without fake live status. `-snapshotConversationStatus busy` leaves its final turn open; other statuses close it with task_complete. `-snapshotTerminalTitle "<text>"` sets the tab terminal's OSC title, so `[ ! ] Action Required`, `Thinking` or `Ready` drives the Codex live status. The fixture includes command output, updated and added files, a web search, a plan, a final reply, context usage and a pull request URL.

With `-snapshotConversation YES -codexEnabled YES`, `-snapshotConversationCodexApproval YES` sets the Action Required title and shows an invented command, its justification, and the Allow, Always Allow, and Deny buttons. `-snapshotConversationCodexTasks YES` sets the Ready title and shows an invented running subagent and background terminal in the tasks pill. Use an empty `CFFIXED_USER_HOME` and leave `CODEX_HOME` unset or point it at that fixture home’s `.codex` directory.

`-snapshotConversationRepeat <n>` repeats the fixture transcript with unique record, message and tool IDs and monotonic timestamps for longer conversation performance runs (try `16`, about 500 entries; the image is kept in the first repetition only, since the reader takes the last 256 KB).

`-snapshotConversationHeavy <turns>` replaces the Claude fixture with an invented JSONL transcript. Try `440` for long Markdown replies with three fenced code blocks each, 5–15 tool calls and results per turn, and three image prompts near the end. The performance log prints the on-disk size and the model’s loaded turns, entries and images after `TranscriptTail` applies its normal byte window.

With the heavy fixture, `-snapshotPerf YES` defaults to `-snapshotPerfSteps switch,stream,scroll`. The first switch is timed from Show Conversation to loaded turns and an offscreen display flush at the bottom. `switch` adds `-snapshotPerfRounds <n>` terminal-to-conversation reopens (default one). `stream` appends a prompt, three successively longer assistant blocks, a tool call and its result to the fixture JSONL. It times each write through file watching, model update and display flush. Wall times include the 5 ms polling interval and the display run-loop turn. Main-thread CPU times include work on that thread throughout each interval. `scroll` also reports the sweep’s wall time and main-thread CPU. The profile signpost category is `Conversation Performance`.

If FSEvents cannot start, the DEBUG harness logs `explicit refresh (FSEvents unavailable)` and refreshes the model after each append. Those stream timings exclude file event delivery.

```sh
CONFIGURATION=Debug ./build.sh
app="$PWD/.build/Build/Products/Debug/Berth.app/Contents/MacOS/Berth"
out=$(mktemp -d /tmp/berth-conversation-perf.XXXXXX)
for run in 1 2 3; do
  fixture_home=$(mktemp -d "$out/home.XXXXXX")
  env -i PATH=/usr/bin:/bin CFFIXED_USER_HOME="$fixture_home" "$app" \
    -snapshot "$out/run-$run.png" -snapshotConversation YES \
    -conversationEnabled YES -reviewEnabled NO -languageServersEnabled NO \
    -snapshotConversationHeavy 440 -snapshotPerf YES \
    -snapshotPerfSteps switch,stream,scroll -snapshotPerfRounds 3 > "$out/run-$run.log" 2>&1
done

fixture_home=$(mktemp -d "$out/home.XXXXXX")
trace_home=$(mktemp -d "$out/trace-home.XXXXXX")
CFFIXED_USER_HOME="$trace_home" xcrun xctrace record --template 'Time Profiler' \
  --instrument os_signpost --time-limit 30s --output "$out/conversation.trace" --target-stdout "$out/profile.log" \
  --launch -- /usr/bin/env -i PATH=/usr/bin:/bin CFFIXED_USER_HOME="$fixture_home" "$app" \
  -snapshot "$out/profile.png" -snapshotConversation YES -conversationEnabled YES \
  -reviewEnabled NO -languageServersEnabled NO -snapshotConversationHeavy 440 \
  -snapshotPerf YES -snapshotPerfSteps switch,stream -snapshotPerfRounds 3
CFFIXED_USER_HOME="$trace_home" xcrun xctrace export --input "$out/conversation.trace" \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
  --output "$out/time-profile.xml"
```

`-snapshotConversationSelect YES` (with `-snapshotConversationHeight 1500`) tests transcript selection with synthesized mouse events sent to the window: a drag from the first reply across tool rows and a reply into the code block and table of the third, a drag across the next turn's shell prompts and image prompt, a click then Shift-click (again after Show Terminal and Show Conversation), Select All and a link click, each copy going through the responder chain to a private pasteboard (docs/adr/0009). It saves `<out>.selection.png`, prints `select: <case> PASS` or `FAIL` and exits non-zero on a failure. With `-snapshotConversationHeavy 440` (and the fixture home's `.claude`) it instead runs Select All from the last reply and checks the copy holds the first and last loaded turns, which `LazyVStack` has not all mounted, then drags from the last reply to above the transcript, holds for autoscroll and checks the copy spans the previous turn.

`-snapshotConversationMentions <dir>` appends a prompt that @-mentions `Screen Recording demo.mov`, `diagram.png` and `notes.txt` in that folder (create them first) and a missing `gone.pdf`, so the thumbnail cards, file chip and missing chip show. `-snapshotConversationImageOnly YES` appends a prompt that is only an image, so no text bubble shows. `-snapshotConversationQueued "<text>"` adds a queued prompt to the fixture (use with `-snapshotConversationStatus busy`; the fixture already runs a background shell and agent, so the agents pill shows), and `-snapshotConversationSubagent YES` opens the invented docs agent conversation directly, including its prompt, tool call and reply. Use with `-snapshotConversation YES`.

`-snapshotConversationDrive "<step>|…"` (type:, attach:, remove:, send:, enqueue:<text>, dequeue:<text> (a queue-operation record, plus the user prompt for dequeue) and reply:<text> (appended to the fixture transcript), probe:<label>[:<text>] (prints the status row's top and the top of the bubble holding that text, in window points), reviewComments:<a;b> (sends those review comments through Review's Send path), decline:, stop, show, allow, deny, choose:<n>, status:<s>[/<waitingFor>], restamp, drop, wait:<ms>, snap:<name>, keys:<lines>:<name> (types lines one keystroke at a time into the real composer, saves a frame per line and prints the scroll origin at every change), burst:<count>:<interval ms>:<name> (saves `<out>.<name>-<n>.png` frames right after the previous type or send step, to catch an animation), log), `-snapshotConversationWaitingFor`, `-snapshotConversationPending bash|edit|question|plan` and `-snapshotConversationRawLog /abs/file` (raw-mode pty logger, so Esc and digits reach the file) prove what reaches the pty.

### Session host (see docs/adr/0006)

Snapshot mode never uses the session host (no hosted launch, reattach or hang-up, whatever `keepsSessionsRunning` says), so a snapshot can't spawn or touch the real hosts in Application Support; only `-snapshotHost` enables it, and that already requires a temp `CFFIXED_USER_HOME`.

`-snapshotHost new|reattach|close -snapshotHostID <uuid> -keepsSessionsRunning YES` (short `CFFIXED_USER_HOME`; end with `close`). Add `-snapshotHostNested YES` to open or reattach the hosted shell under a Claude tab; it then selects it and prints whether it is in the window, its frame and whether the Terminal pane shows it.

### Agent control

`-snapshotControl YES -controlEnabled YES -keepsSessionsRunning YES` (short `CFFIXED_USER_HOME`) runs the embedded `berth-cli` against the live control socket from a fake caller tab and prints `ls`, `open-terminal`, `wait` (exit status), `send`, `capture`, a refused send and close on the caller, a close, a wrong token and a missing environment. It first plants a stale skill and hook in the temp home and prints whether launch refreshed them, and it runs `open` on a folder, a file, a missing path and no path.

`-snapshotControlBrowser YES -controlEnabled YES` runs the embedded CLI from a shell parented to a fixture Claude session. It verifies session-only tab listing and denies pinned, foreign and unknown tab ids and a shell without a Claude parent. It checks that an unloaded background tab paints a PNG, that the full-page capture reaches the bottom, and that console messages, an uncaught exception, an unhandled promise rejection, `--since`, text, URL and reload work. It checks snapshot roles, names, values, states and stable refs on a form, and verifies HTML output and selector errors.

The CLI drives two local fixture pages to check filling by ref, React-style controlled input tracking, typing, keyboard focus and submission, selection, clicks, hover, scrolling, wait conditions, navigation and async eval results. It verifies that hidden and disabled elements, stale refs and click, fill and eval on tabs outside the caller’s session are refused. It also checks foreground and background blank-tab opens. The probe uses local files and exercises HTTP navigation policy with a blocked HTTPS URL. It also checks the agent approval gate: a first command from an unapproved session waits and runs after a simulated Allow, a denied session gets the denial error until re-allowed, an unanswered prompt times out, Always allow skips the prompt and Off refuses. It writes the alert to `<snapshot>-prompt.png` and the window, with the Agent badge, to the path passed to `-snapshot`, and exits nonzero on failure.

```sh
fixture_home=$(mktemp -d /tmp/bcb.XXXXXX)
env -i PATH=/usr/bin:/bin HOME="$HOME" CFFIXED_USER_HOME="$fixture_home" \
  .build/Build/Products/Debug/Berth.app/Contents/MacOS/Berth \
  -snapshot "$fixture_home/browser.png" -snapshotControlBrowser YES -controlEnabled YES
```

Add `-snapshotControlSessionClone "$fixture/api" -snapshotControlPullRequestClone "$fixture/billing" -reviewEnabled YES` to exercise `show-pr` via the embedded CLI. The probe sends a number from an owned terminal, opens a URL from another clone using `--repo`, checks the no-clone error, and repeats the URL with different capitalization. It verifies that the session tab stays the target, that each repository’s PR #1445 appears once and is expanded, and that the selected read-only diff comes from the billing clone.

Create both fixture clones in the caller shell, before launching the snapshot with `env -i PATH=/usr/bin:/bin`. The URL rewrite keeps the fixture fetches local while the configured origins exercise GitHub repository matching.

```sh
fixture=$(mktemp -d /tmp/berth-pr.XXXXXX)
for name in api billing; do
  producer="$fixture/$name-origin"; clone="$fixture/$name"; github="https://github.com/acme/$name.git"
  git init -q -b main "$producer"
  printf 'Current behavior in %s\n' "$name" > "$producer/$name.txt"
  git -C "$producer" add "$name.txt"
  git -C "$producer" commit -q -m Base
  git -C "$producer" switch -q -c proposal
  printf 'Proposed behavior in %s\n' "$name" >> "$producer/$name.txt"
  if [ "$name" = billing ]; then
    mkdir -p "$producer/review/permissions/rules"
    printf 'Approved reviewers\n' > "$producer/review/permissions/reviewers.txt"
    printf 'Allow reviewer switches\n' > "$producer/review/permissions/rules/switching.txt"
  fi
  git -C "$producer" add -A
  git -C "$producer" commit -q -m "Proposed change"
  git -C "$producer" update-ref refs/pull/1445/head proposal
  git -C "$producer" switch -q main
  git -C "$producer" branch -q -D proposal
  git clone -q "$producer" "$clone"
  git -C "$clone" config remote.origin.url "$github"
  git -C "$clone" config "url.$producer.insteadOf" "$github"
done
```

It also runs `open-session --cwd <dir> --background -- "hello"` with the system temporary directory and a missing folder inside it. Expect exit 0 with an 8 hex tab id for the existing folder, exit 1 with `No folder` for the missing folder, and one `probeOpened` call for a new Claude session in the temporary directory. The DEBUG probe returns before launching Claude.

### Grouping

`-snapshotTriage YES` (with `-showsTriage YES`, `-snapshotAllDone YES`, `-snoozedExpanded YES`).

### Needs Attention

`-snapshotChecks "passed|passed||failed"` fails the draft #12 fixture session's checks (marked as your own PR) so it enters Needs Attention; `-snapshotSidebarStatus` sets the status filter and `-snapshotSidebarFilter` also prints `attention`.

### Session files

`-snapshotSessionFiles "/abs/a:/abs/b"` (with `-snapshotReview /abs/folder`) sets the claude tab's edited files as if the transcript had listed them (nothing is filtered for existence), so Review shows Edited by Session; `-snapshotSessionFileOpen /abs/file` opens one in the diff column and prints its state. A non-git folder shows the section instead of No Git Repository. Run with `CFFIXED_USER_HOME=/abs/home` for `~` paths and `-reviewChangesAsTree YES|NO` for the two layouts.

### Tasks

`-snapshotTasksReview YES` builds scratch repos under `.build/tasks-review` (`-snapshotTasksReviewSession`, default `task-usage-api`, the only one that forms the task card; `-snapshotReviewRepoTab <repo name|all>`, `-snapshotTasksReviewDefaults "key=value|…"` flips argument-domain keys mid-run and saves a shot per step, `-snapshotTasksReviewCollapse "billing|web|infra"` collapses those repo sections, `-snapshotTasksReviewTransition YES` drops a repo while its tab is selected, `-snapshotLinkedPullRequests YES` gives fixture sessions linked PRs in two repos).

`-snapshotTasks YES` seeds eight fixture sessions across acme/billing, acme/web and acme/infra and prints the formed tasks, stored state, suggestions and entries; `-snapshotSoleTask YES` marks one member of the second task as done so it shows as a single session row.

## Flags described in feature docs

- `-snapshotReviewContext`: design/flows-sidebar.md
- `-snapshotReviewHidePanel`: design/flows-sidebar.md
- `-snapshotReviewConversation`: design/flows-sidebar.md
- `-snapshotPreview`: design/review-implementation.md
