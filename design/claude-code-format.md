# Claude Code on-disk format and CLI behaviour

External facts the code cannot show, verified on CLI 2.1.312 unless a section says otherwise. Moved from CLAUDE.md. The remote's activity scanning (task launches and ends, context) is in design/remote.md.

## Transcripts

Transcripts: `~/.claude/projects/<slug>/<sessionId>.jsonl`. Only the first 32 KB and last 64 KB are read; the tail doubles (8 MB cap) until it holds a title and a conversational record, since single lines reach 3 MB (pasted images, api-request-blob), and api-request, tool_result and attachment lines are skipped on raw bytes before decoding. If a re-read yields no summary, `TranscriptIndex` keeps the previous one. Title priority: last `custom-title`, `ai-title`, `summary`, `agent-name`, then the first real user prompt.

Title records are re-appended often, so the tail always has them. Records' `cwd` follows Bash-tool `cd`s, so a session's folder (`cwd`: tab cwd, new-terminal dir, Review) is: the last `relocatedCwd` in the tail, else the tail's last `worktree-state` (`worktreeSession.worktreePath`, or when `worktreeSession` is null, the worktree was removed and the session resumed, the first `cwd` after it, where the resume landed, else the last non-null state's `originalCwd`, since Claude writes the null state before any record), else the latest `cwd` whose slug equals the project folder the file lives in, else the first `cwd`.

`originalCwd` comes from that last non-null `worktree-state` (`design/flows-worktrees.md`). A session's checkout (`SessionSummary .checkout`, set by `Store.refresh`'s scan, cached per existing folder) is where its project is meant: `RepositoryRoot.checkout(cwd)` (a linked worktree maps to the main checkout plus the folder's path below the worktree root) while the folder exists, else `originalCwd`, else `cwd`. Grouping, custom group rules, ⌘N's folders, the remote's folders, project names (line 2, palette, search, notifications, Stats) and repository roots (PRs) use the checkout.

Resume (row click, notification, relaunch) launches `--resume` from `originalCwd`, else `cwd` if it exists, else the checkout: Claude re-enters a worktree that still exists and continues in the checkout once it is gone. Slug: every UTF-16 unit outside `[A-Za-z0-9]` becomes `-` (over 200 chars Claude truncates and appends a hash; those fall back to the first cwd). Transcripts with no title and no prompt (claude started, never used) are hidden.

## /cd

`/cd <path>` (from the binary; `-p` rejects it, so not observed on disk) renames `<old slug>/<id>.jsonl` and the `<id>/` dir into `<new slug>/` (copy + delete across volumes; an existing target is set aside as `.superseded-<ts>`), then appends `{"type":"relocated","sessionId","relocatedCwd"}`; later records carry the new cwd. Open claude tabs take the session's folder as their `cwd` on each scan.

## Branches and pull requests

Transcripts also carry `gitBranch` on most records. `SessionSummary.branches` is the session's own branch history, newest first: tail, then branches remembered from earlier scans (`TranscriptIndex`, in memory), then head. A session's PR is the first of those branches with a PR in the GitHub repo of its repository root's `origin` (https or ssh remote, `git remote get-url origin`, resolved once per root after the scan and cached), headed in that same repo (not a fork), open or draft first, else the latest updated; the repo's default branch never counts.

`pr-link` records (`prRepository`, `prNumber`, `prUrl`) are Claude Code's current PR for a session: the CLI writes one when the session creates, pushes to, checks out, merges, comments on, reviews or edits a PR and re-appends it on every metadata flush, so the tail always holds the current one. They feed `SessionSummary.pullRequests`, newest first (tail, then links remembered from earlier scans, then head); a link that left the tail is missed after a relaunch. The sidebar's PR tag, hover card and Review chips use `Store.pullRequests(of:)`: the session's pr-link PRs (fetched by number in the same per-repo batch into `Store.linkedPullRequests`, only while uncached or open/draft) plus every recorded branch's lookup hit, ordered by BerthCore's `PullRequestSelection.order` (open/draft, merged, closed; then the session's current repo; then a head matching a recorded branch; then the newest link); the tag shows the first plus `+N`, and `Store.pullRequests(inRoot:of:branch:)` unions the session's linked PRs in that repo.

PRs come from one `gh api graphql` call per repo (branches and linked numbers passed as variables), keyed by repo and branch with "no PR" remembered, merged so a failed call keeps old results, off the main thread, in memory only, at most once a minute (scan when an unknown branch appears, app activation, 5 min poll). Misses: after a relaunch, a branch seen only mid-transcript of a long session. Without `gh`, no tag. The same batch asks each PR's `statusCheckRollup { state }` (`PullRequest.checks`, mapped by `PullRequestChecks.State`); open and draft tags show it after a separator.

## Pull request watches

Claude Code 2.1.330 and later can keep watching a PR after `/ship` commits, pushes, opens it and runs `/code-review`. Claude checks for failing checks, conflicts and comments for up to seven days. `/ship stop`, Esc and Ctrl+C can stop the watch. Merge, close, checkout change, session exit, `/clear`, `/resume` and `/cd` also end it.

The watch records are undocumented. Berth infers a start from a human user record with `<command-name>/ship</command-name>` and optional `<command-args>`. The seven-day window starts at the command timestamp. Berth uses a positive PR number or a `github.com` pull request URL from the command arguments when present and otherwise uses the linked PR when available.

Berth infers stops from local command records, tagged stop output, interruption records, session end or resume records, relocation and changes in recorded worktree or branch metadata. Task notices that say the watched PR number merged or closed also end the watch. The existing GitHub lookup can clear the indicator when it knows the PR has merged or closed. A regular compact boundary preserves the watch. Only evidence from the current live process counts when its start time is known. If Claude emits none of these records for an event such as Esc while idle, the transcript may leave the inferred state visible until another end signal arrives. The parser shapes are assumptions covered by invented fixtures.

`TranscriptActivity` prefilters raw bytes before decoding watch records. The Store reads live Claude transcripts off the main thread, keeps an in-memory offset per transcript and scans appended bytes on change. This is separate from the head and tail reads for session summaries.

## Background tasks

`TranscriptActivity` pairs Bash, Agent and Task calls with their tool results. Bash results carry `backgroundTaskId` and can name an absolute `<id>.output` file in the result text. Async agent results carry `agentId` and `isAsync` or `status: async_launched`. Virtual Code Mode results can provide launch details without a separate tool-use record. Synchronous agents stay in the history and use their tool-use ID to locate subagent metadata when the result omits the agent ID.

Completion can arrive in a `<task-notification>` on an enqueue operation, a queued-command attachment, or a user record with task-notification origin. The envelope pairs `<task-id>` with `<status>` and may carry `<output-file>`, `<result>` or `<summary>`. The parser also accepts a numeric `<exit-code>` or an exit code in the summary. A fast task can emit its completion before its virtual launch result. `TaskStop` tool results record a successful stop. Berth reads these records and the named output files. The repository documents no callable CLI interface for stopping an individual task by ID from Berth.

An agent transcript lives at `<sessionId>/subagents/agent-<agentId>.jsonl`. Its sibling `.meta.json` can identify the launch via `toolUseId` or record completion via `finished` and `stoppedByUser`. Log writes more than five seconds after completion metadata suggest the agent resumed. The Tasks pane uses the current live process start time to mark unfinished history from an earlier process as Finished.


### Stopping a background subagent

Subagents run inside the claude process, so Berth can't signal them; it drives Claude Code's own `/tasks` dialog through the session's pty (`Store.stopSubagentThroughTasksDialog`, key plan in `SubagentStop`). Read from the 2.1.332 bundle (strings of `~/.local/share/claude/versions/2.1.332`); `SubagentStop.verifiedVersion` records it and `isSupported` gates on the 2.1 series, read from `version` in `~/.claude/sessions/<pid>.json`.

- `/tasks` (alias `/bashes`) is an `immediate` local-jsx command titled "Background" (dialog id `background-tasks-dialog`). Section order: Shells, Monitors, MCP tasks, Cloud agents, Background agents, Completed, Dynamic workflows, Scheduled, Goal, Forks. Within a section running rows come first, newest first (`startTime` descending). Rows are labelled with the task description, which for an agent is the Agent call's `description`.
- Only tasks with `isBackgrounded !== false` are listed, so an Agent call running in the foreground of the turn never appears. Berth marks those `SessionBackgroundTask.runsInForeground` (a pending Agent call without `run_in_background`) and offers Stop Turn (Esc) instead.
- When exactly one task is listed (running or lingering, and the user not viewing an agent) the dialog opens straight in that task's detail view. Otherwise it opens the list, focused on the first row. The first row and the detail view both take `x`, so the plan is the same.
- Keys: Down moves the focus, `x` stops the focused row (list) or the open agent (detail) with no confirmation, Esc closes. Detail view: left goes back, Enter, Space and Esc close. A stopped agent can stay listed for a grace period, so Berth always ends with Esc. `Ctrl+X Ctrl+K` (`chat:killAgents`) stops all background agents; Berth doesn't use it.
- The plan is `/tasks`, Enter, Down for each row ahead of the target (running shells, then monitors, then agents, each newest first), `x`, Esc. It is only driven while the session is idle, so the closing Esc can't interrupt a turn; Berth skips that Esc if the session turned busy meanwhile.
- Berth can't read the dialog, so it re-checks that the session isn't `waiting` before every key, never types while it is, and counts success only when the transcript shows the task no longer running. Tasks Berth can't see (MCP tasks, cloud agents) ahead of the target would shift the row; the confirmation then fails or another row stops.
- Fallback when the version is unknown, the task runs in the foreground or the plan can't be built: Stop Turn behind a confirmation, only while the session is busy (a busy session with a verified version and a background target offers nothing). It sends Esc, which interrupts the whole turn.

Docs: code.claude.com/docs/en/sub-agents ("/tasks and clearing rows", `x` stops the selected subagent) and interactive-mode (`Ctrl+X Ctrl+K`).

## Typed prompts

Typed prompt: `origin` absent or `kind: human`; `task-notification` origins, `isCompactSummary` and `<bash-stdout>` records are not prompts; sidechains are skipped. A prompt sent mid-turn is not a user record but an `attachment` of type `queued_command` (`commandMode: prompt`, human origin or `humanTurn`); it counts for `lastPrompt` and `lastActivity` (other attachment lines are still skipped on raw bytes). Search and Stats don't read them yet; the remote tail does.

## Live sessions

Live: `~/.claude/sessions/<pid>.json`, `status` is `busy`, `idle`, `waiting` (with `waitingFor`, this is "needs you") or `shell`. Liveness is `kill(pid, 0)`; the newest file per session id wins. `kind: "bg"` with a `jobId` is a background session (`LiveSession.attachID`): clicking it opens a tab running `claude attach <jobId>`. A live session without `attachID` and without a Berth tab is locked (dimmed row, notice on click; the notice hides the hover card until the pointer leaves the row), unless it is orphaned (`OrphanedSessions`: `kind: "interactive"`, ppid 1, no controlling tty, `e_tdev == NODEV`; `Store.isLockedElsewhere`): a click, notification or relaunch ends it (SIGHUP, SIGTERM, SIGKILL, 100 ms polls) and resumes it in a tab, asking first when it isn't idle.

## Ordering and the row time

Ordering and the row time come from `lastPrompt`, the last typed prompt's `timestamp` (tail, else scanned backwards from the tail in 64 KB chunks, floored at the size known from the previous scan, else head; a 1 MB cap once dated a session by its first prompt after a relaunch), so replies of working sessions don't reorder rows. `lastActivity` is the last conversational record (a typed prompt or a non-sidechain assistant message) and drives archive, idle unload, Harbor's anchored boats and the palette and search ages.

Neither uses the file mtime: `claude --resume` appends only `system`, `bridge-session`, `cost-state`, `last-prompt` and title records, so resuming doesn't bump a session. Group order is fixed at launch (new projects go on top); within a group, reorders wait until the pointer leaves the sidebar.

## Context fill (#51)

Context fill (#51): `Transcript.summary` takes the tail's last non-sidechain, non-`<synthetic>` assistant `usage` and `message.model` (`SessionContext`, the same rule as `TranscriptActivity`), unknown when a `compact_boundary` follows it. With neither in the tail it keeps the previous scan's value only while the tail covers every byte since that scan (a boundary sits 0.3 to 6 MB before the next reply). `Store.refresh` adds the window and model name from the model catalog (`TranscriptActivity.catalogModel`, cached per model until relaunch).

Open or live rows from 80% show `ContextRing` (13 pt, square ends so 94% doesn't read as full) left of the status dot, reserving the dot's slot like the flag. Compaction counts reach only the remote (`TranscriptActivity.context`), not the Mac UI (the sidebar's context footer was removed).

## Other processes' environment

Other processes' environment is unreadable on this macOS (`KERN_PROCARGS2`, `ps -E`), so tabs are matched to live sessions by session id (`--session-id` / `--resume`), and a live session descended from Berth with an unknown id, whose process started after the tab opened, is re-attached to the claude tab in the same cwd. Closing a tab also hangs up its live claude when it descends from Berth (a closed surface once leaked, leaving it running).

## Environment inherited from Claude Code

Launched from inside Claude Code, Berth inherits `CLAUDECODE`/`CLAUDE_CODE_*`, which turns transcript saving off in child sessions; they are unset at launch.

## Errors, retries and failure notices

Searched 8.8 GB of real transcripts on CLI 2.1.322 and later. No `system` record has subtype `api_error`; the system subtypes present are `stop_hook_summary`, `turn_duration`, `away_summary`, `informational`, `compact_boundary`, `local_command`, `scheduled_task_fire`, `agents_killed` and `bridge_status`. Nothing records `retryInMs`, `retryAttempt`, `maxRetries` or an auto-update failure.

- An API error is an assistant record with `message.model` `<synthetic>`, one text block starting `API Error: `, and top-level `isApiErrorMessage: true`, `apiErrorStatus` (a number, for example 403), `error` (`server_error`, `authentication_failed`, `timeout`) and `failedResponseHadNoToolCall`. The TUI shows it as a yellow warning with a filled dot, and Berth does the same.
- The retry line ("Can't reach the API server… · retrying in 34s · attempt 7/10") and the auto-update failure notice live only in the TUI. Berth skips them.
- `system` records with subtype `informational` carry `content` and `level` (`notice` or `warning`, never `error`), for example a Remote Control disconnect. Berth does not show them.
