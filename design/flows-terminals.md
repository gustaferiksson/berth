# Terminals in the sidebar: flows

Plain shells leave the bottom/right panel and become sidebar rows, selected and shown in
the terminal area exactly like Claude tabs.

## Model

- One list of open tabs (`Store.tabs`), kind `claude` or `shell`, one `selectedTabID`.
  Every surface stays mounted; only the shown ones are visible (opacity 0 and
  `isSurfaceVisible = false` for the rest): the terminal area's tab and, with the Terminal
  pane, one owned terminal of its session.
- Selection history: every change of `selectedTabID` moves that id to the front of a
  most-recently-selected list. Closing a tab removes it from the list.
- A shell tab's optional `parentTabID` links it to a Claude tab. Owned terminals open
  in the session's folder. `SavedTab.parentID` persists that link only behind `persistsTabs`.
- Owned terminals show in their session's Terminal mode (docs/adr/0010): the trailing sidebar
  lists them (title, folder, ×; + is New Terminal) and the column beside the terminal area shows
  the selected one under a slim path bar (folder and title), never the terminal area. Selecting
  one (row click, ↑/↓, ⌘1 to ⌘9, ⌃⇥, the Terminal list, CLI `open-terminal` without `--background`) keeps the session's
  Claude tab in the terminal area, switches the session's pane to Terminal and shows that
  shell there. `Store.mainTabID` is the tab the terminal area shows (the selected tab, or its
  parent) and `Store.sessionTab` the session Review, the conversation view and the pane follow.
- Clicking into a visible surface selects its tab (`SelectsOnFocus`), so the sidebar
  highlight, ⌘F and Clear Terminal follow focus between the Claude surface and a pane terminal.
- A terminal's folder is its OSC 7 directory, else the folder it was opened in.
- Terminals are restored on relaunch like the panel shells were (same `openTabs` entry,
  opened in the folder they started in).

## Sidebar

- A "Terminals" group sits at the very top, above Pinned, hidden when there are no
  terminals. Same header as other groups: chevron, title, count, + (New Terminal).
  Collapse state is shared with the other groups (`collapsedGroups`, id `terminals`).
- Rows in opening order. Line 1: Ghostty's title while a command runs, else the folder
  name. Line 2: the folder, abbreviated with `~`. Working dots while a command runs, else a terminal symbol in the same leading slot as session status dots, so titles align with session titles; the close button sits at the same trailing inset as a session's age.
  Same selection and hover chrome as session rows. Context menu: Close Terminal.
- Only unowned terminals appear in Terminals. Owned terminals use compact rows indented
  one level under their owner wherever its session or tab row appears, including tasks.
  They show whenever the owner row shows, following its filtering and collapse state.
- Sidebar order for ↑/↓, ⌘1 to ⌘9 and ⌃⇥ / ⇧⌘] puts owned terminals immediately
  after their owner, in opening order.

## Keys

| Key | From | Result |
|---|---|---|
| ⌘T, + on the header | anywhere | New terminal in the current folder, added to Terminals, selected and focused |
| New Terminal for Session, session row New Terminal | an open Claude tab | New owned terminal in the session folder, selected and focused; no shortcut |
| ⌘J | a Claude tab or one of its owned terminals | Toggles the session's Terminal pane. On: the most recently selected owned terminal is selected and focused; none open: a new one in the session folder. Off: the pane goes back to Changes (the column hides unless Review's panel shows) and the Claude tab is selected and focused |
| ⌘J | Harbor or nothing selected | Most recently selected terminal, selected and focused; none open: a new one in the current folder |
| ⌘J | an unowned terminal | Most recently selected Claude tab, selected and focused; none open: nothing happens |
| + in the Terminal list | Terminal mode | New owned terminal in the session folder, shown and focused |
| Terminal in the toolbar's mode switcher | a session | Terminal mode on, as ⌘J; clicking it again hides the sidebar and column |
| ⌘W | a terminal | Ghostty closes the surface; the row goes away |

Current folder: the selected terminal's folder, else the selected Claude tab's session
folder, else home.

## Focus

- Selecting a terminal (click, ⌘J, ⌘T, ⌘1 to ⌘9, ⌃⇥) focuses its surface through
  `requestFocus`, the path a sidebar click uses. ↑/↓ select without leaving the sidebar.
- Closing the launcher focuses the selected tab, whatever it is.

## Edge cases

- Closing a session tab closes all its owned terminals through `Store.close`, including
  hosted terminals. Relaunch and host reattachment re-link saved ownership; a terminal
  whose parent was not restored becomes plain.
- CLI `open-terminal` belongs to the caller's Claude tab, or an owned caller's parent.
  Other callers create plain terminals; an explicit `--cwd` still sets the folder.
- Closing the selected terminal selects the most recently selected remaining tab
  (terminal or Claude) and focuses it. An owned one selects the session's most recently
  selected remaining owned terminal, else the session. Closing a session's last owned
  terminal returns its pane to Changes. Closing a background terminal changes nothing.
- Review off: Terminal mode still shows its list and column, and the mode switcher offers only Terminal.
- `--background` owned terminals start at once although their pane is hidden: owned surfaces
  float over the split with its size while the column is collapsed (docs/adr/0010).
- Relaunch opens or reattaches an owned terminal with its parent already set, so its surface
  never moves between the terminal area and the pane.
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

Terminals (`design/flows-terminals.md`): plain shells and Claude tabs share `Store.tabs` (kind `shell` / `claude`) and `selectedTabID`. Unowned shells sit in a "Terminals" group at the very top (id `terminals`, hidden when empty, + is New Terminal, row menu Close Terminal); Claude tabs sit in their session's group (row menu New Terminal and Unload Session). Owned shells carry `Tab.parentTabID`, render compact and indented after their owner, show in the owner's Terminal pane (`PaneHost`, `PaneTerminals`; docs/adr/0010) and close with it. `SavedTab.parentID` restores the link across resumed or reattached tabs, falling back to plain when the parent is absent. `recentTabIDs` is the selection history, pushed only by `activate` and `openClaude`; closing the selected tab falls back to its first entry. ⌘J (View ▸ Toggle Terminal) toggles the session's Terminal pane from a Claude tab or its owned terminal; from an unowned terminal, Harbor or nothing it activates the most recent tab of the other kind, else the last one of that kind, and from a terminal with no Claude tab it does nothing.

⌘T (File menu, the group's +) opens a terminal in `Store.currentCwd`: the selected tab's folder (a terminal's OSC 7 directory, `TerminalViewState .workingDirectory`, else the folder it opened in; a Claude tab's session folder), else home. libghostty injects its zsh integration via `ZDOTDIR` for plain shells (verified). Terminal rows show Ghostty's title and working dots while a command runs (the integration's OSC 2), else the folder's name; line 2 is the folder. Relaunch reopens terminals in their last folder and Claude tabs (skipping locked sessions and a missing resume folder) and reselects the saved `isSelected` tab.

Claude tabs run `claude … || exec /bin/zsh -il`: a clean exit closes the tab, a failure leaves a shell with the error. That exec'd shell gets no integration (the `-c` shell already restored `ZDOTDIR`), so a dead claude tab is detected as "not live and open over 10 s"; clicking its row closes it and resumes.

### Shortcuts and the key monitor

Every `AppAction` shortcut (`AppAction.routedPastTerminal`: ⌘K ⌘N ⇧⌘F ⌘T ⌘J ⇧⌘D (Show Changes Pane, only while available) ⌥⌘K ⌃⌘1–3 ⇧⌘S ⌘S ⌘, ⌃- ⌃⇧-; ⌘S only while Review's Save is available; Go Back ⌃- and Go Forward ⌃⇧- (View menu and palette) only while `Store.isReviewTextFocused` and the selected tab has somewhere to go, so otherwise ⌃- reaches the terminal (readline undo); the monitor matches a shortcut's key against `charactersIgnoringModifiers` lowercased or `characters(byApplyingModifiers: [])` (⇧- arrives as `_` in the first, arrows only match the first); Settings opens via `Store.isSettingsRequested` → ContentView's `openSettings`), ⇧⌘[ ⇧⌘] ⌃⇥ ⌃⇧⇥ and ⌘1–⌘9 go through a local key monitor in `AppDelegate` (only for windows whose identifier starts with `main`; it also stamps `Store.lastKeyInput`), because a focused Ghostty surface can claim key equivalents before the menu sees them.

The generated Ghostty config unbinds Ghostty's defaults for app and tab shortcuts (⌘, ⇧⌘, ⌘N ⌘T ⌘K ⌘Q ⇧⌘F ⇧⌘D ⇧⌘W ⌥⌘W ⌘↩, ⌘1–⌘9, ⇧⌘[ ⇧⌘], ⌃⇥ ⌃⇧⇥). Tab cycling and ⌘1–⌘9 run over `Store.sidebarOrderedTabs`: terminals, pinned, then each group's tabs. Ghostty's ⌘K clear screen is Edit ▸ Clear Terminal (⌥⌘K, also in the palette), which runs the `clear_screen` binding action on `Store.focusedTerminal`. Copy, paste, font size and ⌘W shortcuts stay with Ghostty, except that while Review's panel is shown the key monitor takes ⌘W (see design/review-implementation.md); in a pane terminal ⌘W always reaches Ghostty and closes that shell. See [AppAction](../Sources/AppAction.swift) for terminal commands in the palette.

Edit ▸ Find… (⌘F, `AppAction.findInTerminal`, Ghostty's `super+f` unbound) sends `start_search`; `TerminalFindBar` (top-right glass capsule) is driven by `Store.terminalSearch`, fed by `extension TerminalViewState: @retroactive TerminalSurfaceSearchDelegate` through `Store.shared` (the package's state never conformed, so counts went nowhere). Typing sends `search:<needle>`, ↩/⇧↩ and ⌘G/⇧⌘G navigate, Esc sends `end_search`; switching tabs and Harbor end it. ⌘F in a `ReviewTextView` opens its own find bar instead (the key monitor checks it first).

### Session host (see docs/adr/0006)

Session host (opt-in, Settings > General `keepsSessionsRunning`, off by default; #224): new tabs then run `berth-host new <hosts dir> <tab id> '<command>'` in the surface, which only holds a client. `berth-host` (target in `Packages/BerthCore/Sources/berth-host`, logic in BerthCore `SessionHost*`, embedded in `Contents/MacOS`) is one detached host per tab (double fork + `setsid`, owned by launchd) running `/bin/sh -c <command>` on a `forkpty` pty behind `~/Library/Application Support/<bundle id>/hosts/<first 12 hex of tab id>.sock` (0600, dir 0700; `sun_path` holds 104 bytes, a too-long path falls back to a plain tab).

One client at a time (a new attach sends `replaced`), a 256 KB scrollback ring replayed on attach (earlier terminal modes are not restored; a winsize jiggle redraws TUIs; `ReplayQueries` strips DSR, DA, XTWINOPS report, DECRQM, OSC colour and clipboard and DCS queries first, because the terminal would answer them into a shell that never asked), the exit status sent last (the client exits with it). Frames are `type u8, length u32, payload` (`HostFrame`); probe answers pids without attaching. Quit and updates leave hosts running (`Store.isTerminating` keeps client exits from hanging up); `Store.close` and idle unload send `hangUp`. `SavedTab.id` is the host key and `restoreOpenTabs` reattaches tabs whose host answers a probe before the locked, orphan and stale checks.

`Tab.isHosted` tabs don't count in `busySessionCount` or `Store.isIdle`. Orphaned hosts (no saved tab) aren't cleaned up.

### Agent control

Agent control (opt-in, Settings > General `controlEnabled`, off by default; #223): `ControlService` (owned by `Store`, started before tabs restore) runs a `ControlServer` on `~/Library/Application Support/<bundle id>/control/control.sock` (socket 0600, folder 0700, peer uid must equal ours, a path over 104 bytes is refused and shown in `failure`). The token is made once and saved in `control/token` (0600, `ControlEnvironment.persistentToken`), so it survives relaunches; switching control off deletes it. Tabs get `BERTH_SOCKET`, `BERTH_TAB_ID` (the full tab uuid) and `BERTH_TOKEN` through `Store.terminal(id:…)`, and hosted tabs reattached after a relaunch keep working. Only tabs that started before control was last switched off, or before the token was saved, are refused (the error says to open a new tab).

One JSON request line in, one response line out per connection (`ControlRequest`, `ControlResponse` in BerthCore; the server checks the token before the handler sees anything). The CLI is `berth-cli` (target `Packages/BerthCore/Sources/berth-cli`, embedded in `Contents/MacOS` like `berth-host`; the name avoids `Berth` on a case-insensitive volume) and Settings links `~/.local/bin/berth` to it. Parsing and output are `ControlCommand`.

- `ls [--json]`: every tab with an 8 hex id (any unique prefix resolves), kind, title, folder, session id, live status; `*` marks tabs the caller opened.
- `open-terminal [--cwd] [--background] [-- cmd…]`: `Store.openShell` in the caller's folder; `--background` restores the previous selection. The command runs as `ControlExitStatus.wrapping`, which writes its status to `control/exits/<tab uuid>` before the tab ends.
- `open-session [--cwd <dir>] [--background] [--json] [-- <prompt words>]` opens a Claude tab through `Store.openSession` with checkout `.main` and returns its 8 hex id. The caller's folder is the default and the folder must exist. Berth uses the existing checkout, pastes any prompt as raw text, and keeps the current tab selected with `--background`.
- `open <path> [--background] [--json]` shows a folder to the user: it selects the Claude tab already in that folder (compared by `Tab.folder`), or opens one through `Store.openSession` with checkout `.main`, and returns the 8 hex id. Only a tab it opened is marked as the caller's. The path is made absolute by the CLI, must exist and be a folder; a file is refused. Opening a single file in Review's viewer is not offered: Review models exist only for the selected Claude tab with the panel shown, their documents are repo-relative and need `changes` loaded, so a file in a non-git folder has no viewer.
- `show-pr <number|url> [--repo <path>] [--json]` expands a GitHub pull request under Session pull requests and opens its first changed file in the caller’s Review panel. An owned terminal targets its parent session. A number uses the caller’s GitHub origin, falling back to the session’s origin. A URL such as `https://github.com/acme/api/pull/42` selects a clone by its GitHub origin. Use `--repo` to specify a clone. Review must be enabled in Settings. The files open as a read-only diff against the PR’s merge base and the checkout stays on its current branch.
- `review mark <path>:<start>[-<end>] [--note <text>] ... [--json]` and `review marks clear` point at code in the caller session’s Review diff. `ControlReviewMarks.validate` runs in `ControlService.handle` before the app sees a request: up to 50 marks, relative paths without `..`, lines 1 to 1000000 on the new side, notes trimmed, stripped of control characters and capped at 500 characters. `Store.updateReviewMarks` (session must be the shown one, Review enabled) checks each path is a file inside the repo, appends the marks to `Store.reviewMarks` (in memory per session, replacing a mark with the same range), opens each file as a kept Review tab, then reveals the first mark without focusing anything. `ReviewTextView.marks` draws a very faint accent tint over the range and a `text.bubble` glyph in the gutter at its first line; hovering or clicking the glyph shows the note in the hover card. Marks survive tab switches and go on `marks clear`. `--base <ref>` (validated by `ControlReviewMarks.validate`, once, mark only) first calls `ReviewModel.setSince`, so the marks land on the diff since that ref; an unknown ref fails the call before any mark is placed (design/flows-review.md, Since).
- `send <tab> <text> [--no-enter]` and `close <tab>`: only tabs the caller opened (`openedBy`, in memory), so a session can't type into or close the user's terminals or other sessions.
- `wait <tab> [--timeout]`: until the exit file exists or the tab is gone; the CLI exits with that status.
- `capture <tab>`: any tab. libghostty-spm exposes no screen read on a live surface, so it reads the session host's scrollback ring through `HostFrame.dump` (a request that doesn't attach, so the tab's client isn't replaced) and strips escapes with `TerminalText.plain`; tabs not behind a host report capture as unsupported.

- `open-url <url> [--background] [--json]` opens an http or https page as a new tab in the caller's session browser (the Claude tab, or the parent of a terminal it opened) and switches that session to Browser mode unless `--background`.
- `berth browser tabs [--json]` lists the session browser tabs with 8 hex ids, titles, URLs and loading states. A leading `*` marks the active session tab.
- `berth browser screenshot [--tab <id>] [--out <path>] [--full-page] [--json]` writes a PNG via WebKit and prints the path. The CLI resolves relative paths against its working directory and uses a fresh temporary filename by default. Full-page captures are capped at 10000 points in height.
- `berth browser console [--tab <id>] [--since <n>] [--follow] [--json]` reads the tab’s last 500 console messages, uncaught errors, unhandled promise rejections and network failures. Sequence numbers are per tab and survive eviction. `--since` returns sequences greater than `n`, and `--follow` polls every 500 ms and prints one JSON object per line with `--json`.
- `berth browser url [--tab <id>] [--json]` prints the current URL.
- `berth browser reload [--tab <id>] [--json]` reloads the page.
- `berth browser navigate <url> [--tab <id>] [--json]` navigates to an http or https URL.
- `berth browser text [--tab <id>] [--json]` returns `document.body.innerText` with a truncation note at the 100000-character limit.
- `berth browser html [--tab <id>] [--selector <css>] [--json]` returns the formatted DOM for the document or the first matching element, with a truncation note at the 100000-character limit.
- `berth browser snapshot [--tab <id>] [--json]` returns an accessibility-style outline with roles, names, values, states and refs that stay stable for the life of the page, with a truncation note at the 100000-character limit.

- Browser approval (`BrowserAccess`, owned by `BrowserModel`, setting `agentBrowserControl`): before any `berth browser` or `open-url` command from a session, `ControlService.handle` calls `BrowserAccess.authorize` with the browser key (`BrowserModel.key(of:)`). `off` fails at once. A session denied this run fails with "Browser access was denied for this session". `allow` passes. `ask` queues one `AgentBrowserPrompt` alert per session as a nonmodal glass card centred over the window with a faint dim, whether or not the Browser pane is open, taking no focus and no Return or Esc shortcut (Allow for This Session or Deny), posts a notification when the app is inactive, and holds every command from that session until answered, failing after 2 minutes with a retry message and no decision. Decisions live in memory only, so they reset on relaunch. A tab an agent used shows an Agent badge; its menu, the tab context menu and the tab overview menu stop or restore access through `BrowserModel.setAgentAccess`.
- `berth browser open [<url>] [--background] [--json]` shares the `open-url` path and can open a blank tab when the URL is omitted.
- Berth declares `http` and `https` (`CFBundleURLTypes`) and HTML documents (Viewer, rank Alternate) in `project.yml`, so it is listed under System Settings > Desktop & Dock > Default web browser and in Open With. `AppDelegate.application(_:open:)` calls `Store.openIncomingURL`: a new tab in the selected session's Browser pane (the last Claude tab when a shell is selected), or the New Session launcher with the URL held in `pendingIncomingURL` until `openSession` selects a session. Other schemes are ignored. Berth never sets itself as the default.
- `berth browser click <target>`, `fill <target> <text>`, `type <text>`, `press <key>`, `select <target> <value>` and `hover <target>` send DOM events. Fill replaces the current value, type enters text at the caret, and select looks up an option by value and then by label.
- `berth browser scroll (<target> | --to top|bottom | --by <px>)` scrolls an element into view or scrolls the page.
- `berth browser wait (<selector> | --text <text> | --url <substring> | --load | --ms <n>) [--timeout <seconds>]` polls about every 100 ms across navigations. The default timeout is 10 seconds. The timeout error names the condition.
- `berth browser back` and `berth browser forward` use the current tab’s history.
- `berth browser eval <js>` runs an async function body in the page world and prints the JSON serialization of its return value. It returns `null` for `undefined` and errors when serialization fails or the result exceeds 100000 characters.

Browser commands resolve the current Claude session the same way as `open-url` and only see tabs owned by that session. Pinned tabs and tabs owned by other sessions are excluded. `--tab <id>` accepts a unique id prefix within that session. By default commands use the selected session browser tab or fall back to the last session browser tab. The new commands accept `--json` and, except for `open`, `--tab <id>`. ControlService rechecks session ownership after asynchronous interaction steps.

Use **Lock to Page** in a pinned browser tab’s context menu to keep it on its current page. While the tab is on that page, links and typed addresses to other pages open in a new selected session tab, and Back or Forward can only visit variants of the locked page. The scheme, host, port and path must match. Scheme and host are case-insensitive, and query strings, fragments and a trailing slash are ignored. Initial loads and authentication redirects can continue in the pinned tab while it is away from the locked page. **Unlock** or unpinning clears the lock.

Targets are a snapshot ref such as `e12`, `text=<visible text>` (exact then partial, favoring interactive elements), or a CSS selector. Multiple matches use the first in document order and include a note. The interaction script shares the isolated `berth` WebKit world with snapshot refs and uses its native value setter for controlled inputs. Screenshots, text, HTML and snapshots wait up to 15 seconds for navigation to finish. Actions observe navigation for 300 ms, then wait up to 15 seconds for it to finish. The outcome includes the action, target, URL, title and whether the tab navigated.

Agents use `review mark` when the user asks where something changed. Agents use `show-pr` when the user asks to review or check out a PR in Berth. Use `open-session` for a separate working session when the user asks for one.

In the PR launcher, Option-Return and the Show in Review row menu apply to the selected session tab when Review is enabled. File ▸ Show Pull Request in Review… (⌥⌘R) and the plus button beside Session pull requests open a launcher where Return shows the highlighted PR. A pasted GitHub PR URL also works in that mode.

On launch, and when Agent control is switched on, `ControlInstall.refreshInstalled` rewrites a skill and SessionStart hook that Berth installed earlier when they differ from the bundled ones (atomic write, a backup of `settings.json` first). It writes nothing that is absent, and only a skill file named `berth` and a hook command starting with `ControlInstall.hookSignature`.

Settings > General installs on a click only: the symlink, `~/.claude/skills/berth/SKILL.md` (`ControlInstall.skill`) and a SessionStart hook (`ControlInstall.hookCommand`, prints one line when `BERTH_TAB_ID` is set) merged into `~/.claude/settings.json` by `ControlInstall.settings(adding:)`: other keys kept, idempotent, unreadable or oddly shaped files refused, the old file copied to `settings.json.berth-backup`, and the sheet shows the added JSON first. `-snapshotControl` exercises it end to end.

### Idle unload

Idle unload (`IdleTabs.unloadable`, `Store.unloadIdleTabs`, in the 5 min poll): closes Claude tabs whose live session is `idle` with no `attachID` and untouched for longer than Settings > General `unloadIdleSessionsAfter` (Never, 1 h, 4 h default, 1 day). Touched is the latest of open time, last deselection, `lastActivity` and `statusUpdatedAt`. Spared: the selected tab, pinned sessions, the most recent Claude tab in `recentTabIDs` (⌘J's target), working, waiting, attached and dead ones. The row stays and resumes on click.

Relaunch restore skips Claude tabs whose `lastActivity` is already past the threshold (not the selected or a pinned one; an idle orphan is still ended), restored tabs have no open-time clock, and a status written within 30 s of the live file's `startedAt` (a resume) doesn't count as a change.

### File drops

File drops: AppKit picks a drag destination by registered types and ignores opacity, so `VisibleDropTerminalView` (the surfaces' platform view) unregisters its drag types while hidden; otherwise a hidden tab stacked above took the drop.

### Surfaces stay mounted (see docs/adr/0002)

Keep every tab's `TerminalSurfaceView` mounted (opacity 0 + `isSurfaceVisible = false`); removing the view tears down the shell.
