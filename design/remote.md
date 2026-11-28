# Remote

Moved from CLAUDE.md. Snapshot flags for the phone app are in docs/SNAPSHOTS.md.

## Server and protocol

Remote (Settings > General `remoteEnabled`, off by default): `RemoteServer` listens on 127.0.0.1:7878 only (phones reach it through `tailscale serve --bg 7878`). The token never travels: each connection gets a 32-byte nonce and must answer with HMAC-SHA256(token, nonce) in a frame of at most 256 bytes, else it is closed with code 1008 (the phone's cue to stop reconnecting); at most 4 unauthenticated connections, upgrades with an `Origin` header are rejected, and a changed token (Regenerate Token) drops every client.

A listener failure shows in Settings. Prompts are `paste` then `sendKey(.enter)`, which submits in hidden tabs, refused while the session is `waiting` so text never lands in a dialog; keys are pressed only while the session is still `waiting` with the `waitingFor` and `statusUpdatedAt` the phone showed (a tool dialog's `waitingFor` is always "permission prompt"). The pending `tool_use` reaches the transcript up to ~1 s after the session file says `waiting`. Sessions locked in another terminal are read-only.

Transcript tails are read off the main thread, one read per client at a time. Berth Remote keeps the token in the Keychain, accepts only `wss://` (plus `ws://127.0.0.1` in Debug), drops the socket in the background and reconnects on activation and after drops (1, 2, 5, 10 s).

The sessions message carries the Mac sidebar’s sections in order (attention, active, working, unread, pinned, groups, snoozed, done) with optional `isCollapsed`, `visibleCount` and per-session `isPinned`. Older phones ignore these fields. Newer phones connected to older Macs infer pin state from the pinned group.

## Codex sessions

`RemoteSession` carries an optional agent descriptor with the harness name, symbol, and per-session settings and attachment flags. The phone assumes Claude when an older Mac omits the descriptor. Codex transcripts come from the rollout index and the read-only context chip uses the session summary.

Prompt submission shares the Mac’s `Store.submit` gate. What the phone offers per session follows the descriptor built by `RemoteAgent(harness:)` from `Harness` (`canChangeSettings`, `canAttach`, `canRunBash`, `approvalKeys`) and the capabilities on `Harness.codex`, which include approvals and background tasks. Codex approval keys, running tasks and their limits are in design/codex.md.

## Attachments

Attachments (advertised as the `upload` feature): the phone JPEG-compresses photos and sends each file in 512 KB chunks with offsets (so the 1 MB frame cap stays), at most 20 MB, into `~/Library/Caches/<bundle id>/RemoteUploads/<uuid>/<sanitized name>`. A prompt names upload ids only; Berth pastes each image path as its own paste with 0.5 s between (Claude turns a lone pasted image path into `[Image #n]`; inside other text it stays a path), then `@<path>` for other files with the text (a mention needs whitespace before it), re-checking `waiting` before every paste and Enter.

Verified on CLI 2.1.325 in manual permission mode, also while a turn runs.

## Activity

Activity (`TranscriptActivity`, sent as `activity` on `transcript`): each client scans the whole transcript once (raw-byte prefilter, 0.35 s Release on a 92 MB file), then only appended bytes. Launches are keyed on `toolUseResult`, never on `run_in_background` (shells get backgrounded without it): Bash `backgroundTaskId`, Agent `isAsync` + `agentId`, Monitor `taskId` (`timeoutMs` unless `persistent`), SendMessage `resumedAgentId` (runs again). A pending Agent `tool_use` is a foreground agent while the session is `busy` or `waiting`.

Ends: a `<task-notification>` with any `<status>` (completed, failed, killed, stopped; one can list several `<task-id>`s) in a queue-operation enqueue, a user record with origin `task-notification` or a `queued_command` attachment; a `<event>[Monitor expired` or `[Monitor timed out` event; a non-error TaskStop result (`toolUseResult.task_id`; stopping a shell writes no notification); `subagents/agent-<id>.meta.json` `finished` or `stoppedByUser` (a user stop writes nothing to the main transcript; older agents have neither key). The flags stay in the meta file when an agent is resumed from its transcript view, so they are ignored once the agent's `.jsonl` was written more than 5 s after the meta file.

Sessions in REPL mode launch through a virtual user record (`isVirtual`, tool_result id `repl_…`, no matching `tool_use`) whose `toolUseResult` has `agentId` + `isAsync`, `backgroundTaskId` or `taskId`, counted like the direct tools (title from its `description`); a REPL-launched shell leaves no launch record, only its end notification. Tasks die with the process and resumed files carry old launches, so only launches after the live file's `startedAt` count, none without a live file, and no shells while it says `idle`.

Nested subagents' tasks are not counted. Context is the last non-sidechain, non-`<synthetic>` assistant `usage` (input + cache read + cache write) and `message.model`; after a `compact_boundary` the size is unknown until the next reply (`postTokens` omits the system prompt and tools). The window is that model's `runtime.max_input_tokens` in the newest `~/.claude/cache/model-catalog/*.json` (`message.model` never carries `[1m]`, only Agent `resolvedModel` does, and requests send no 1M beta), dropped when the size exceeds it.

Agent and background-shell calls render as cards (`TaskCards.swift`, matched to running `RemoteTask`s by tool use id, else start time and title) that stay outside the folded turn; the header capsule holds Changes and Pull Request; elapsed times use `ElapsedText` ("5m 8s", never a `.timer` colon); typing while a session waits sends Esc, then the draft once it leaves waiting. The transcript is a plain `VStack`: a `LazyVStack` re-placed its items forever (main thread at 100%) when the keyboard came up or a turn expanded while scrolled up.

Sessions can also carry an optional `pullRequestWatch` with the PR number and repository when known and the date watching began. The phone shows an eye on idle session rows and the number and expiry in the row's context menu. Older session payloads decode without the field.

## Queued prompts

Prompts queued mid-turn come from `queue-operation` records (enqueue, dequeue, remove by content, popAll; `<`-tagged ones are notifications), folded per client across reads and sent as the transcript message's optional `queued`.

## Feature-gated requests

Feature-gated requests: `sessions` carries `features` (the list is built in `RemoteServer.sessionsMessage`, each name is a static on its feature type in `RemoteProtocol.swift`); the phone sends a request only when its feature is advertised and the Mac replies only to the requester (an old peer drops the connection on a message it can't decode). `pullRequest` fills the PR sheet (`PullRequestSheet`), `search` is transcript search in the session list (3+ characters, results and indexing state), `changes` and `changeDiff` are the changes viewer (`ChangesSheet`: Uncommitted and Committed files, then one file's diff; at most 200 files and 300 KB a diff). `triage` gates the session actions `flag`, `unflag`, `unarchive`, `snoozeOneHour`, `snoozeTomorrow`, `snoozeUntilNeedsYou` and `unsnooze` (the Mac applies the same Store calls as the sidebar menu) and the per-session `isFlagged`; the phone infers done and snoozed from the `archived` and `snoozed` groups. `codexUsage` (advertised with `usage` when Codex is on) is Codex's plan usage beside Claude's in the usage meter: the phone asks once after connecting, the Mac replies and then pushes to askers whenever it changes, and the phone dims it once `recordedAt` is over an hour old.

The composer has quick replies and slash commands (`QuickReplyTray`, `quickReplies` in `@AppStorage`) and per-session drafts (`drafts` in UserDefaults, put back when a notice follows a send within 5 s). App Intents (`Intents.swift`): Open Session, Send Prompt to Session, Sessions That Need Me and New Session, as App Shortcuts.
