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
  hookBased}`) is written at start and re-appended with metadata during the turn (4 times
  in the 332 KB `wt-plugin-test` transcript, the last 7 KB from the end), so the tail has it. After the worktree is gone and the session resumes, it becomes
  `worktreeSession: null` and later records carry the main checkout's `cwd` and branch.
- `claude --resume <id>` from the main checkout re-enters the worktree while it exists.
  After `wt remove`, it continues in the main checkout on `main`. `--resume <id> -w <name>`
  from the main checkout re-enters the worktree, or recreates it when it is gone (reusing
  a surviving branch per the plugin README, not run).
- `-w` with no name works through the hook: Claude picks a name (`clever-hatching-russell`)
  used for both folder and branch.
- No trust prompt in a worktree of a trusted repo, even though `~/.claude.json` has no
  entry for the worktree path (`-snapshotClaude` on `plug-hub.worktrees/one-agent`).
- A subagent with `isolation: worktree` goes through `wt`: `<repo>.worktrees/agent-<id>`,
  branch `agent-<id>`. It stays behind once it commits; Claude fires no `WorktreeRemove`
  for subagents.
- The hook bases new branches on the default branch; `worktree.baseRef` has no effect
  (plugin README). So a subagent worktree never contains the parent's unmerged commits.
- `wt remove <branch> -y` without `-f`/`-D` refuses a dirty worktree and keeps an unmerged
  branch (`wt remove --help`, not run). A clean worktree with no commits counts as
  integrated: `wt remove wtx` removed worktree and branch ("same commit as main"). `wt list --format json` gives per worktree: path, branch, `main`, `changes`,
  upstream ahead/behind.

## Claude Code setup

`~/.claude/settings.json`:

- Keep `enabledPlugins."worktrunk@worktrunk": true`.
- Keep `worktree.bgIsolation: "none"` until tested: a hook-made worktree starts from the
  default branch, so a session backgrounded from its own worktree could continue without
  its commits. Switch to `"worktree"` only if that test shows it keeps them.
- Keep `cleanupPeriodDays: 1095`: it also deletes transcripts. Worktrees are removed by hand
  (`wt remove`).
- Leave `worktree.baseRef` and `worktree.symlinkDirectories` unset: the hook ignores the
  first, and the reflink copy beats symlinked `node_modules` (no shared mutable state).

`~/.claude.json`: nothing. Trust resolves through the repo; per-project MCP entries only
exist for `/Users/gustaf`.

Global `~/.claude/CLAUDE.md`, replacing "Worktrees are fine for the main session and
subagents; remove one once its branch is pushed.":

> Sessions start in their own worktree (Berth launches them with `-w`); never `cd` to the
> main checkout to edit. Subagents that edit code in parallel get `isolation: worktree`
> only for work that starts from the default branch (their worktree never has this
> branch's commits); otherwise they edit in this worktree, one at a time. Once the task is
> clear, rename a generated branch to a descriptive one (`git branch -m`). Never run
> `git worktree add` or `wt remove` yourself.

## Launch (⌘N)

- Settings > General "Start new sessions in a worktree" (`startsInWorktree`, off by
  default). On, picking a folder inside a git repo starts `claude --session-id
  "$BERTH_SESSION_ID" -w`; Claude names the worktree and branch itself, as with `claude -w`
  in a terminal. Off, or outside a git repo, today's plain launch.
- With the setting on, ⌥↩ in the launcher starts in the main checkout instead (footer hint
  shown only then). Every other new-session entry (group +, New Session menus, drop,
  remote) follows the setting.
- Berth creates worktrees itself only to open a pull request (design/flows-launcher.md, Open Pull Request); every other one goes through Claude and the `wt` hook. A plain `git worktree add` does not run worktrunk's `post-start` `copy-ignored` step.
- ⌘T from a worktree session opens a terminal in the worktree (today's `currentCwd`).

## Folder, grouping, launcher list

- Session folder: `relocatedCwd`, else the tail's last `worktree-state` (non-null:
  `worktreePath`; null: the first `cwd` after it, where the resume landed, else the last
  non-null state's `originalCwd`, since Claude writes the null state before any record),
  else today's rule. Fixes ⌘T, Review and Folder Not Found for resumed and `EnterWorktree`
  sessions. A `worktree-state` older than the tail window falls back to today's rule.
  `SessionSummary.originalCwd` comes from the tail's last non-null `worktree-state`.
- `SessionSummary.checkout` (set in `Store.refresh`'s scan, cached per existing folder):
  while the folder exists, `RepositoryRoot.checkout(folder)` (a linked worktree maps to the
  main checkout plus the folder's path below the worktree root, anything else to itself);
  once it is gone, `originalCwd`, else the folder. Repository roots (PRs, Repository mode)
  resolve from the checkout, so a removed worktree still finds its repo.
- Custom group rules and Project mode match the checkout, not the worktree (a rule for
  `…/plug-hub` never matches `plug-hub.worktrees/x`). Project mode groups by checkout, so a repo is one group however many
  sessions it runs. Repository mode is unchanged (it already merges worktrees). Line 2
  shows the branch from the transcript's `gitBranch`, so a renamed branch shows its new
  name; the folder keeps Claude's generated name.
- ⌘N's known folders are checkouts, and the promoted current folder is mapped through
  `RepositoryRoot.checkout`; worktree paths never appear there. The remote's folders and
  project names (line 2, palette, search, notifications, Stats) use the checkout too.

## Resume

- One rule for every session (row click, notification, relaunch restore): plain
  `--resume <id>` launched from `originalCwd`, else the folder if it exists, else the
  checkout. Claude re-enters the worktree while it
  exists and continues in the checkout once it was removed (both verified), so a removed
  worktree never shows Folder Not Found and relaunch restore doesn't skip it. No `-w` on
  resume: after a branch rename, `-w <generated name>` would ask `wt` for a branch that no
  longer exists while the folder still does.
- Berth never removes worktrees.

## Unverified

- `EnterWorktree` and `ExitWorktree` writing `worktree-state` like `-w` does.
- Background sessions (`bgIsolation: "worktree"`) through `wt`, and `claude attach` to them.
- What tab close, idle unload and quit (SIGHUP/SIGTERM) do to a worktree (Claude's
  remove-on-exit; `/exit` prompts for named ones).
