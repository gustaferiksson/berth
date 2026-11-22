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

## Implementation notes

Moved from CLAUDE.md.

### Terminals and tabs

Terminals (`design/flows-terminals.md`): plain shells and Claude tabs share `Store.tabs` (kind `shell` / `claude`) and `selectedTabID`. Shells sit in a "Terminals" group at the very top (id `terminals`, hidden when empty, + is New Terminal, row menu Close Terminal); Claude tabs sit in their session's group (row menu Unload Session). `recentTabIDs` is the selection history, pushed only by `activate` and `openClaude`; closing the selected tab falls back to its first entry. ⌘J (View ▸ Switch Terminal / Claude, toolbar button) activates the most recent tab of the other kind, else the last one of that kind; from a Claude tab with no terminal it opens one, from a terminal with no Claude tab it does nothing.

⌘T (File menu, the group's +) opens a terminal in `Store.currentCwd`: the selected tab's folder (a terminal's OSC 7 directory, `TerminalViewState .workingDirectory`, else the folder it opened in; a Claude tab's session folder), else home. libghostty injects its zsh integration via `ZDOTDIR` for plain shells (verified). Terminal rows show Ghostty's title and working dots while a command runs (the integration's OSC 2), else the folder's name; line 2 is the folder. Relaunch reopens terminals in their last folder and Claude tabs (skipping locked sessions and a missing resume folder) and reselects the saved `isSelected` tab.

Claude tabs run `claude … || exec /bin/zsh -il`: a clean exit closes the tab, a failure leaves a shell with the error. That exec'd shell gets no integration (the `-c` shell already restored `ZDOTDIR`), so a dead claude tab is detected as "not live and open over 10 s"; clicking its row closes it and resumes.

### Shortcuts and the key monitor

Every `AppAction` shortcut (`AppAction.routedPastTerminal`: ⌘K ⌘N ⇧⌘F ⌘T ⌘J ⌥⌘K ⌃⌘1–3 ⇧⌘S ⌘S ⌘, ⌃- ⌃⇧-; ⌘S only while Review's Save is available; Go Back ⌃- and Go Forward ⌃⇧- (View menu, not the palette, like the caret actions) only while `Store.isReviewTextFocused` and the selected tab has somewhere to go, so otherwise ⌃- reaches the terminal (readline undo); the monitor matches a shortcut's key against `charactersIgnoringModifiers` lowercased or `characters(byApplyingModifiers: [])` (⇧- arrives as `_` in the first, arrows only match the first); Settings opens via `Store.isSettingsRequested` → ContentView's `openSettings`), ⇧⌘[ ⇧⌘] ⌃⇥ ⌃⇧⇥ and ⌘1–⌘9 go through a local key monitor in `AppDelegate` (only for windows whose identifier starts with `main`; it also stamps `Store.lastKeyInput`), because a focused Ghostty surface can claim key equivalents before the menu sees them.

The generated Ghostty config unbinds Ghostty's defaults for app and tab shortcuts (⌘, ⇧⌘, ⌘N ⌘T ⌘K ⌘Q ⇧⌘F ⇧⌘W ⌥⌘W ⌘↩, ⌘1–⌘9, ⇧⌘[ ⇧⌘], ⌃⇥ ⌃⇧⇥). Tab cycling and ⌘1–⌘9 run over `Store.sidebarOrderedTabs`: terminals, pinned, then each group's tabs. Ghostty's ⌘K clear screen is Edit ▸ Clear Terminal (⌥⌘K, also in the palette), which runs the `clear_screen` binding action on `Store.focusedTerminal`. Copy, paste, font size and ⌘W stay with Ghostty, except that while Review's panel is shown the key monitor takes ⌘W (see design/review-implementation.md).

Edit ▸ Find… (⌘F, `AppAction.findInTerminal`, Ghostty's `super+f` unbound) sends `start_search`; `TerminalFindBar` (top-right glass capsule) is driven by `Store.terminalSearch`, fed by `extension TerminalViewState: @retroactive TerminalSurfaceSearchDelegate` through `Store.shared` (the package's state never conformed, so counts went nowhere). Typing sends `search:<needle>`, ↩/⇧↩ and ⌘G/⇧⌘G navigate, Esc sends `end_search`; switching tabs and Harbor end it. ⌘F in a `ReviewTextView` opens its own find bar instead (the key monitor checks it first).

### Session host (see docs/adr/0006)

Session host (opt-in, Settings > General `keepsSessionsRunning`, off by default; #224): new tabs then run `berth-host new <hosts dir> <tab id> '<command>'` in the surface, which only holds a client. `berth-host` (target in `Packages/BerthCore/Sources/berth-host`, logic in BerthCore `SessionHost*`, embedded in `Contents/MacOS`) is one detached host per tab (double fork + `setsid`, owned by launchd) running `/bin/sh -c <command>` on a `forkpty` pty behind `~/Library/Application Support/<bundle id>/hosts/<first 12 hex of tab id>.sock` (0600, dir 0700; `sun_path` holds 104 bytes, a too-long path falls back to a plain tab).

One client at a time (a new attach sends `replaced`), a 256 KB scrollback ring replayed on attach (earlier terminal modes are not restored; a winsize jiggle redraws TUIs), the exit status sent last (the client exits with it). Frames are `type u8, length u32, payload` (`HostFrame`); probe answers pids without attaching. Quit and updates leave hosts running (`Store.isTerminating` keeps client exits from hanging up); `Store.close` and idle unload send `hangUp`. `SavedTab.id` is the host key and `restoreOpenTabs` reattaches tabs whose host answers a probe before the locked, orphan and stale checks.

`Tab.isHosted` tabs don't count in `busySessionCount` or `Store.isIdle`. Orphaned hosts (no saved tab) aren't cleaned up.

### Idle unload

Idle unload (`IdleTabs.unloadable`, `Store.unloadIdleTabs`, in the 5 min poll): closes Claude tabs whose live session is `idle` with no `attachID` and untouched for longer than Settings > General `unloadIdleSessionsAfter` (Never, 1 h, 4 h default, 1 day). Touched is the latest of open time, last deselection, `lastActivity` and `statusUpdatedAt`. Spared: the selected tab, pinned sessions, the most recent Claude tab in `recentTabIDs` (⌘J's target), working, waiting, attached and dead ones. The row stays and resumes on click.

Relaunch restore skips Claude tabs whose `lastActivity` is already past the threshold (not the selected or a pinned one; an idle orphan is still ended), restored tabs have no open-time clock, and a status written within 30 s of the live file's `startedAt` (a resume) doesn't count as a change.

### File drops

File drops: AppKit picks a drag destination by registered types and ignores opacity, so `VisibleDropTerminalView` (the surfaces' platform view) unregisters its drag types while hidden; otherwise a hidden tab stacked above took the drop.

### Surfaces stay mounted (see docs/adr/0002)

Keep every tab's `TerminalSurfaceView` mounted (opacity 0 + `isSurfaceVisible = false`); removing the view tears down the shell.
