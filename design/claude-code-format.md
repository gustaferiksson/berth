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

Claude Code 2.1.330 and later can keep watching a PR after `/ship` commits, pushes, opens it and runs `/code-review`. `/steward [number|URL]` starts at the watch. Claude checks for failing checks, conflicts and comments for up to seven days. `/tasks` shows its scheduled `/steward --tend …` task. `/ship stop`, `/steward stop`, Esc and Ctrl+C can stop it. Merge, close, checkout change, session exit, `/clear` and `/resume` also end it.

The watch records are undocumented. Berth infers a start from a human user record with exact `<command-name>/ship</command-name>` or `/steward` and optional `<command-args>`. It also recognises a successful CronCreate or Monitor launch with an exact `/steward --tend` command prefix, including REPL tool results carrying that command. Scheduled ticks alone don't extend the watch. For a command-started watch, the seven days start at the command timestamp. A positive number or a github.com pull request URL supplies the PR. Berth otherwise uses the linked PR, when available. Steward's schedule stays out of the background task lists.

Berth infers stops from local command records, tagged stop output, interruption records, session end or resume records, relocation and changes in recorded worktree or branch metadata. It also consumes successful task stops or cron deletions, terminal task notifications and task notices that say the watched PR number merged or closed. The existing GitHub lookup can clear the indicator when it knows the PR has merged or closed. A regular compact boundary preserves the watch. Only evidence from the current live process counts when its start time is known. If Claude emits none of these records for an event such as Esc while idle, the transcript may leave the inferred state visible until another end signal arrives. The parser shapes are assumptions covered by invented fixtures.

`TranscriptActivity` prefilters raw bytes before decoding watch records. The Store reads live Claude transcripts off the main thread, keeps an in-memory offset per transcript and scans appended bytes on change. This is separate from the head and tail reads for session summaries.

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
