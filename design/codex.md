# Codex

Codex is the `Harness.codex` descriptor in BerthCore `Harness.swift` (docs/adr/0007): capabilities `.conversation`, `.contextSize`, `.pullRequestLinks`, `.needsYou`, `.approvals`, `.backgroundTasks`, `.idleUnload`, `.worktrees` and `.remote`, `liveSource` `.tabSignals` with `CodexLive.sessions` as `readLive`, `isOptIn` (listed only while enabled, named in the row's VoiceOver value and the hover card, with no logo on rows), a `claim` that adopts a new tab's rollout and `CodexTranscript.read` as its transcript adapter. The UI asks `agent.harness.supports(_:)`, `liveSource` or `isOptIn`, never `agent == .codex`; a third agent is a new descriptor.

Codex (Settings > General `codexEnabled`, off by default): BerthCore `CodexRollout` + `CodexIndex` read `$CODEX_HOME/sessions/**/rollout-*.jsonl` and `session_index.jsonl` into `SessionSummary` with `agent: .codex` (interactive rollouts only: `thread_source` user, originator not `codex_exec` or `Claude Code`; title is the newest index name, else the first `user_message`; context is the last `last_token_usage.input_tokens` over `model_context_window`, unknown after `compacted`). `CodexLaunch` runs `codex resume "$BERTH_SESSION_ID"`; ⌥⇧↩ in ⌘N starts `codex` through `Store.openSession(.codex, …)` and the tab claims the first new rollout by cwd and start time (`Harness.claim`, applied by `Store.claimNewSessions`). A tab in a new worktree has a different cwd than its rollout, so the claim falls back to the earliest rollout in a linked worktree of the tab's repository when no cwd matches exactly.

Model and effort: `CodexModels` reads `models_cache.json` in the Codex directory (visibility `list`, by priority) for display names and supported efforts. Settings > General > Agents stores the choice under `launchModel.codex` and `launchEffort.codex`; `Store.openSession` passes it as `LaunchOptions` and `CodexLaunch` adds `-m` and `-c model_reasoning_effort=` (values validated, never written to `config.toml`). It applies to every start and resume Berth makes. The read-only chip takes the model and effort from the latest `thread_settings_applied` or `turn_context` record in rollout order. `thread_settings_applied` is written on each `/model` change and at each turn start. `.modelEffortMenu` stays off and also gates attachments. Changing effort for the current session needs arrow navigation followed by `s` at the effort step. Enter or a digit there saves a global default. The picker order depends on `models_cache.json`, the effort list can contain a More reasoning row, and Plan mode adds a dialog. Reliable picker automation remains unverified offline.

Worktrees: `.worktrees` makes `Store.openSession` choose `.newInWorktree`; Codex has no session id flag, so `CodexLaunch` runs `wt switch --create codex-<time> --no-cd -x codex -- …`, the same Worktrunk layout (`<repo>.worktrees/<branch>`) Claude's hook produces. Needs `wt` on the login shell's PATH; otherwise the tab falls back to a shell. Codex's own `--worktree` is not used (it lays worktrees out elsewhere).

Codex tabs have no live file (never locked); Codex sessions appear in the remote (design/remote.md); stored pins, flags, archive, seen and snoozes keep Codex ids (`codexSessionIDs`) while the toggle is off. `-codexEnabled YES` lists rollouts from `CFFIXED_USER_HOME/.codex`; `-snapshotLauncherKeys` knows `alt-shift-enter`.

## Conversation view

The Conversation view reads the rollout through `Harness.readTranscript` and resolves its URL and watch root through `Store.sessionIndex(for:)`. `TranscriptIndex` and `CodexIndex` implement `SessionIndex` (`root`, `url(ofSession:)`). The session summary supplies the model, effort and context usage.

`CodexTranscript` reads prompts and replies from `event_msg` user_message and agent_message records, including commentary and final replies. It also reads item_completed UserMessage and AgentMessage records. If the head contains item_completed, command execution and file changes use completed items; otherwise commands use response_item function calls and outputs, with patch_apply_end for changes. This era rule prevents duplicate tools. Adjacent duplicate prompts and repeated replies within a prompt are deduplicated. Web searches use web_search_end, and update_plan becomes a plan tool row. Polling and agent bookkeeping calls are omitted. Pull request tags come from standalone GitHub pull URL lines in gh command output.

`task_started` opens a turn; `task_complete` and `turn_aborted` close it. An incremental chunk's nil `isTurnOpen` leaves the previous state intact. A full read reporting an open turn whose newest entry predates the tab is treated as a dead turn. Open turns show Working. After 20 seconds without new entries or a turn-state change, a quiet hint offers Show Terminal. Codex does not use the missing-live-session terminal fallback.

Sending is refused while waiting, or during an open turn when the title supplies no usable status. The tab must already be open and at least five seconds old. Bracketed paste followed by Enter after 300 ms submits a prompt, and during a running turn it steers that turn. Stop sends Escape.

Attachments are off for Codex. Its context chip is read-only and opens the shared usage popover. The composer uses the harness name and keeps drops as a no-op when attachments are unavailable.

## Live status

`Harness.readLive` returns `LiveSession` records, so the sidebar dots, Needs Attention, notifications, Dock badge, Triage and idle unload read Codex exactly like Claude. `CodexLive` derives one record per open Codex tab with a session id (pid 0, kind `tab`; `Store.liveBySession` merges every enabled harness and skips pid 0 for orphan, lock and claim logic). `Store` polls every 2 seconds while such a tab is open, because a title change touches no file.

Signals, in order. The TUI terminal title: `CodexLaunch` passes `-c 'tui.terminal_title=["spinner","run-state"]'` per launch. `CodexRunState` maps titles ending in Action Required to waiting, including the alternating `[ . ]` and `[ ! ]` frames. The spinner item is required for approval and question titles. Working and Thinking map to busy, Ready to idle, and the existing Needs input and Blocked labels also map to waiting. Without a signal the rollout tail decides: busy when the newest turn is open (`task_started` without `task_complete` or `turn_aborted`, or no turn event in the 256 KiB window) and the file changed in the last 300 seconds, else idle. `statusUpdatedAt` is the rollout's modification time, stable while nothing is written. `LiveSession.observesWaiting` is true only when the title signal was seen. A fresh Codex tab hides the status title (`Harness.isStatusTitle`) and shows New Codex Session until its rollout is claimed.

## Approvals

The waiting status carries `action required`. Berth reads the rollout tail independently of the conversation transcript and uses the latest tool call without a matching output in the current turn. Command and patch calls supply the command or patch and any justification. A single `request_user_input` question with one to nine options supplies the option labels and descriptions. Unrepresentable requests or missing details after the grace period open the terminal.

Codex CLI 0.171 uses digit 1 for Allow, 2 for Always Allow, and 3 for Deny. The second option applies a prefix rule to commands or a file rule to patches. Digit 3 aborts the turn. A digit submits a single-question answer immediately. Question dismissal uses the terminal because digit 3 can choose a question answer. Escape as a literal deny key remains unverified and the TUI keymap is configurable.

## Background tasks

An `item_completed` event containing a started `SubAgentActivity` links the `spawn_agent` call to the child thread UUID. Berth locates the child rollout under `sessions` and verifies the parent thread ID in its first `session_meta` line. A later metadata line can be inherited from the parent. The child appears in running tasks while its newest turn is open. The spawn card and running-task row open the child conversation through the Codex transcript reader.

With the terminal title Ready, the macOS app lists direct children of the Codex process as background terminals. It matches the process by the open rollout and tab process ancestry and excludes the subagent code-mode host.

`notify` only reports turn completion. The `thread-id` title item, permission hooks, and additional approval kinds such as network approvals remain unverified.
