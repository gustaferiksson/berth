# Worktree-first sessions: flows

Every Claude session that edits code runs in its own git worktree, created through
Worktrunk (`wt`, user config `~/.config/worktrunk/config.toml`: worktrees at
`<repo>.worktrees/<branch>`, gitignored files reflinked from the main checkout). Claude
Code reaches `wt` through the `worktrunk@worktrunk` plugin's `WorktreeCreate` and
`WorktreeRemove` hooks. Berth adapts to that layout; the layout never bends to Berth.

## Facts (verified on CLI 2.1.326, wt 0.82.0, 2026-11-17)

- `claude --session-id <id> -w <name>` honours both: the transcript is `<id>.jsonl`, the
  session runs in `<repo>.worktrees/<name>` on branch `<name>`, `node_modules` copied.
- The transcript lives under the worktree's slug (`…-plug-hub-worktrees-<name>`), and
  records carry `cwd` = the worktree path.
- A `worktree-state` record (`worktreeSession: {originalCwd, worktreePath, worktreeName,
  hookBased}`) is written at start and again with each turn's metadata, so the tail has
  it. After the worktree is gone and the session resumes, it becomes
  `worktreeSession: null` and later records carry the main checkout's `cwd` and branch.
- `claude --resume <id>` from the main checkout re-enters the worktree while it exists.
  After `wt remove`, it continues in the main checkout on `main`. `--resume <id> -w <name>`
  recreates the worktree (`wt switch` reuses the branch if it still exists).
- No trust prompt in a worktree of a trusted repo, even though `~/.claude.json` has no
  entry for the worktree path (`-snapshotClaude` on `plug-hub.worktrees/one-agent`).
- A subagent with `isolation: worktree` goes through `wt`: `<repo>.worktrees/agent-<id>`,
  branch `agent-<id>`. It stays behind once it commits; Claude fires no `WorktreeRemove`
  for subagents.
- The hook bases new branches on the default branch; `worktree.baseRef` has no effect
  (plugin README). So a subagent worktree never contains the parent's unmerged commits.
- `wt remove <branch> -y` without `-f`/`-D` refuses a dirty worktree and keeps an unmerged
  branch. `wt list --format json` gives per worktree: path, branch, `main`, `changes`,
  upstream ahead/behind.

## Claude Code setup

`~/.claude/settings.json`:

- Keep `enabledPlugins."worktrunk@worktrunk": true`.
- Drop `worktree.bgIsolation: "none"` (default `"worktree"`), so background sessions stop
  sharing the main checkout.
- Keep `cleanupPeriodDays: 1095`: it also deletes transcripts. Berth owns worktree cleanup.
- Leave `worktree.baseRef` and `worktree.symlinkDirectories` unset: the hook ignores the
  first, and the reflink copy beats symlinked `node_modules` (no shared mutable state).

`~/.claude.json`: nothing. Trust resolves through the repo; per-project MCP entries only
exist for `/Users/gustaf`.

Global `~/.claude/CLAUDE.md`, replacing "Worktrees are fine for the main session and
subagents; remove one once its branch is pushed.":

> Sessions start in their own worktree (Berth launches them with `-w`); never `cd` to the
> main checkout to edit. Subagents that edit code in parallel get `isolation: worktree`
> only for work that starts from the default branch (their worktree never has this
> branch's commits); otherwise they edit in this worktree, one at a time. Never run
> `git worktree add` or `wt remove` yourself; Berth cleans up.

## Launch (⌘N)

- Picking a folder inside a git repo starts `claude --session-id "$BERTH_SESSION_ID" -w
  "$BERTH_WORKTREE"` in the main checkout, the name passed through the env like the
  session id. Outside a git repo, today's plain launch.
- ⌥↩ in the launcher starts in the main checkout instead (reviewing, quick questions).
- Berth never creates worktrees itself; every one goes through Claude and the `wt` hook.
- ⌘T from a worktree session opens a terminal in the worktree (today's `currentCwd`).

## Folder, grouping, launcher list

- Session folder: `relocatedCwd`, else the last `worktree-state` (non-null:
  `worktreePath`; null: the newest `cwd` after it), else today's rule. Fixes ⌘T, Review and
  Folder Not Found for resumed and `EnterWorktree` sessions.
- `SessionSummary.checkout`: the main checkout, from `originalCwd`, else
  `RepositoryRoot` of the folder (plus the folder's path below the worktree root). Known
  even after the worktree is gone.
- Project mode groups by checkout, not worktree, so a repo is one group however many
  sessions it runs. Repository mode is unchanged (it already merges worktrees). Line 2
  always shows the branch, which names the worktree.
- ⌘N's known folders are checkouts; worktree paths never appear there.

## Resume

- A session whose worktree still exists resumes there, as today.
- A session whose worktree is gone resumes from its checkout with
  `--resume <id> -w <worktreeName>`, recreating the worktree (on its branch if `wt remove`
  kept it unmerged) instead of continuing on `main` or showing Folder Not Found.

## Cleanup (Berth's job; Claude's own never fires)

- Archiving a worktree session runs `wt remove <branch> -y` in the background, once no
  unarchived session, open tab or live session uses that worktree. No force flags: `wt`
  keeps dirty worktrees and unmerged branches, and the refusal shows as a one-line notice.
- Palette action "Clean Up Worktrees": per known checkout, `wt list --format json`, then
  `wt remove` for every clean worktree whose branch has no unarchived session and is
  integrated into the default branch or has a merged PR (Berth's PR cache). Covers
  leftover `agent-*` subagent worktrees. Lists what it kept and why.
- The 106 existing worktrees: one manual `wt step prune --dry-run` per repo first.

## Unverified

- `claude -w` with no name through the hook, and what name it picks.
- `EnterWorktree` and `ExitWorktree` writing `worktree-state` like `-w` does.
- Background sessions (`bgIsolation: "worktree"`) through `wt`, and `claude attach` to them.
- `wt` treating a squash-merged branch as integrated (its docs say it does).
