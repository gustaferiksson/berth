# Competitor flows

Researched 2026-11-20 from docs, READMEs and secondary write-ups. Source tags: (P) primary docs or README, (S) secondary blog, aggregator or forum. Claims without a primary source are marked. Review UI details for Xcode, Nova and Tower are thinner than the rest.

Status checks done today: Conductor's acquisition and cloud shutdown, Superset's rename and the Codex merge were each single-source in the first pass and were re-checked against several news sources (see their sections).

## T3 Code (Ping Labs, MIT)

Flows
- Layout: sidebar of projects (local repos), a list of threads per project, a chat, plan and tool-call pane, composer with model, reasoning level, chat or plan mode and a full-access or supervised toggle (S).
- Parallel work: "New worktree" at thread start, one thread per worktree.
- Diff review: per-turn diff, unified or split (S).
- PR: Commit, or "Commit, Push & Create PR" with a pre-filled message; the thread icon shows the PR's state (S).
- Terminal: integrated terminal; project quick actions (for example `npm run dev`) that can run when a worktree is created (S).
- Remote: one server shared by desktop, web and phone, reached over Tailscale or a hosted connection (P).

Unique: agent-agnostic control plane (Claude Code, Codex, Cursor, OpenCode, any ACP agent) and a stated performance value, "dropped frames are bugs" (P).

Why it is good: one thread model, one click from change to PR, per-turn diffs answer "what did this prompt change".

Falls short: early alpha reviews report broken tilde paths, missing file diff views, an unsecured web server mode and full access by default (S). It is a chat client first, not a terminal session manager.

Sources: [README](https://github.com/pingdotgg/t3code), [Better Stack guide](https://betterstack.com/community/guides/ai/t3-code/), [daily.dev review](https://daily.dev/posts/t3-code-another-agentic-gui-that-is-good-but-not-usable--jorrdkvkz)

## Conductor (Melty Labs)

Flows
- Model is repo, then workspace (worktree, branch, terminal, diff and review in one).
- Add workspace, run setup script, auto-name branch, review the diff, open PR, merge, archive. A dashboard shows agent status and pending reviews (P).
- Linear and GitHub issues can be injected as context (S).
- Reference pages exist for the diff viewer, checks, agent modes and an API (P).

Unique: the workspace as a full lifecycle object, from setup script to archive. Native Mac, uses the existing Claude or Codex login.

Why it is good: the whole loop for one task sits in one place, so parallel tasks do not mix.

Falls short (HN threads via search summary, S): it clones the repo instead of adopting an existing checkout (dependencies reinstall), weak multi-repo, broad GitHub OAuth scopes, closed source, agents run with full user permissions.

Status: Meta acquired Conductor and announced it on 2026-11-04. Sign-ups stopped then, the cloud went read-only 2026-11-13 and cloud shutdown and data deletion start 2026-11-20. The Mac app keeps running into early 2027 (multiple news sources agree on the dates; the early 2027 detail is from one source). Crystal (deprecated for Nimbalyst, Feb 2026) and Vibe Kanban (sunsetting) show the same pattern: wrapper apps that own the state churn quickly.

Sources: [docs](https://www.conductor.build/docs/), [rywalker](https://rywalker.com/research/conductor), [TechRepublic](https://www.techrepublic.com/article/news-meta-conductor-cloud-shutdown-export-projects/), [Winbuzzer](https://winbuzzer.com/2026/11/06/meta-buys-coding-startup-conductor-and-winds-down-its-service-xcxwbn/)

## Claude Code desktop

Flows
- Sessions: a sidebar of sessions run in parallel, grouped and sorted from a hover icon on the heading, archive, auto-archive after the PR merges or closes, an OS notification when a session finishes while you are elsewhere. Option-click opens a split view, Cmd-click a separate window. It lists only sessions the app itself runs, 20 by default (P).
- Worktrees: a toggle before the first prompt, `.worktreeinclude` copies gitignored files such as `.env`, location and branch prefix are configurable. Archiving deletes the worktree after a warning (P). Disk usage complaints led to a Storage panel (S).
- Diff review: Cmd+Shift+D opens the diff pane. Hover a line, click +, write a comment, submit all with Cmd+Enter. Claude applies them and shows a new diff. `/code-review` produces a findings card with "Walk through in Changes", "Fix this one", "Apply fixes" (P).
- PR: a PR card in Changes with CI status. The overflow menu has Auto-fix (Claude fixes failing checks and addresses review comments from owners and members) and Merge when ready (GitHub auto-merge, squash) (P).
- Browser: Cmd+Shift+B opens a pane with a dev-server menu driven by `.claude/launch.json`, auto-verify with screenshots and DOM reads, per-site allow prompts and a clean profile (P).
- Terminal: Ctrl+` opens tabs in the session's cwd. Cmd+/ shows a shortcut sheet; there is no real command palette (P).

Unique: the most complete loop (comment, apply, re-diff, auto-fix CI, auto-merge) in one first-party app.

Why it is good: after a PR exists, the user never leaves the app to get it green and merged.

Falls short (GitHub issues, S): the sidebar hides or floats below roughly 700 px width, an empty sidebar on macOS in one report, intermittent breakage. The disk cost of silently deleted-on-archive worktrees.

Sources: [docs](https://code.claude.com/docs/en/desktop), [worktree disk tip](https://wmedia.es/en/tips/claude-code-worktrees-desktop-disk)

## OpenAI Codex app

Flows
- Layout: inbox, automations pane, worktree selector (S).
- Automation: a schedule plus a skill. At the trigger it creates a disposable worktree, runs, drops the result into the inbox with a desktop notification, and the user applies or reverts (S).
- Review: diffs in the thread with comments; an explicit Apply or Revert checkpoint (the "panic button"); three permission modes, where read-only makes unattended runs trustworthy (S).

Unique: unattended scheduled runs that land as reviewable results, not as live sessions.

Why it is good: recurring chores (triage, dependency bumps) cost no attention until there is something to decide.

Falls short: no editor loop, so small fixes mean jumping to VS Code; worktrees merged by hand; single vendor (S).

Status: the standalone app was merged into the ChatGPT desktop app on 2026-07-09 (OpenAI announcement and release notes, plus several secondary sources). It keeps a Codex view and gained inline Markdown and code editing, GitHub PR review in the sidebar and multi-repo projects. The flows above describe the standalone app.

Sources: [Lavaee](https://alexlavaee.me/blog/codex-macos-orchestration-desktop/), [Verdent](https://www.verdent.ai/guides/codex-app-first-impressions-2026), [OpenAI announcement](https://openai.com/index/chatgpt-for-your-most-ambitious-work/), [release notes](https://learn.chatgpt.com/docs/whats-new)

## Cursor 3 Agents Window (GA 2026-04-02)

Flows
- A full-screen agent workspace. The sidebar lists every agent, whether local, cloud, SSH or started from phone, web, Slack, GitHub or Linear, with pinning. Agents open as tabs side by side or in a grid (P).
- A diffs view reviews, commits and manages PRs.
- Slash commands: `/worktree`, `/best-of-n` (same task across models, outputs compared side by side), `/in-cloud`, `/autopilot` for a PR, `/multitask` (P).
- Browser: Design Mode in the integrated browser. Shift-drag selects an element, Cmd+L adds it to chat (P).

Unique: best-of-n comparison and element picking that feeds the prompt.

Why it is good: one list shows agents from every origin, and the browser closes the "make this button look different" loop without describing it in words.

Falls short (forum summary, S): missing classic editor features (extensions, language server), reopens on launch against the setting, intrusive promotion, a learning curve of days.

Sources: [docs](https://cursor.com/docs/agent/agents-window), [agentpatterns](https://www.agentpatterns.ai/tools/cursor/agents-window/), [digitalapplied](https://www.digitalapplied.com/blog/cursor-3-agents-window-complete-guide)

## Zed agent panel

Flows
- Threads sidebar (Cmd+Alt+J) grouped by project, with archive and history. Ctrl+Tab cycles recent threads. A worktree picker sits in the title bar (P).
- Review Changes opens a multibuffer with per-hunk accept or reject; an inline single-file review is optional.
- Follow mode: the editor jumps to each file the agent touches.
- Notifications and a sound when the agent is waiting or done; an option prevents idle sleep (P).

Unique: Follow mode, and review in the same multibuffer you edit in.

Why it is good: you watch the agent's work as it happens without opening a diff, and per-hunk accept is the smallest review unit.

Falls short: checkpoints were removed in 1.27 because snapshotting before each message hung on big repos (S). The lesson is not to snapshot the working tree per turn.

Source: [agent panel docs](https://zed.dev/docs/ai/agent-panel)

## Warp

Flows
- Vertical tabs carry per-tab metadata (git branch, worktree, PR).
- Notifications when an agent needs approval, plan review, or has finished.
- Interactive code review: comments go back to the agent in one click. An agent management panel lists runs (P).

Unique: the terminal itself is the agent surface, with blocks grouping command output.

Why it is good: tab metadata answers "which tab is which branch and PR" without opening anything.

Falls short: code indexing sends embeddings to servers, login and subscription are required, and it keeps drifting from "being a terminal" (S).

Sources: [warp.dev](https://www.warp.dev/agents), [XDA](https://www.xda-developers.com/warp-isnt-terminal-tried-new-agentic-coding-mode/)

## Superset (renamed Paradev)

Flows
- Each task is a worktree, branch and terminals. A Changes pane reviews, commits and pushes. A PR pane shows checks, review threads and merge. Selected PR diff lines can be sent to the agent (P).
- In-app browser with per-workspace port detection and a Design mode.
- Status working, done or waiting, with chimes and Dock badges. Terminal tabs, splits, presets and persistent sessions. Setup and teardown scripts in a config file. A CLI, SDK, MCP server and an iPhone app (P).

Unique: the PR pane brings review threads into the app and lets you forward diff lines from them.

Why it is good: the reviewer's side of the PR (threads, checks) is handled in the same place as the author's.

Falls short (HN, S): login required, bundled agent copies, about 2 GB of Electron, terminal freezes (xterm.js), and the review bottleneck ("five agents make five branches faster than you can review").

Status: renamed Paradev on 2026-10-26 with an $11.5M seed. superset.sh redirects to paradev.com, the repo moved to ParadevAI/Paradev, and the `superset` CLI still works (re-checked: paradev.com blog, YC page and several secondary sources).

Sources: [README](https://github.com/superset-sh/superset), [rename post](https://paradev.com/blog/superset-is-now-paradev)

## Crystal and Nimbalyst

Flows
- Crystal was deprecated in Feb 2026 in favour of Nimbalyst (P).
- Nimbalyst: a visual workspace (Markdown, CSV, mockups, Excalidraw, Mermaid, browser preview), parallel Claude Code and Codex sessions, optional worktrees, a files-edited sidebar per session, a kanban session board (backlog, planning, implementing, complete), an iOS app, and every AI edit shown as an approvable diff (P).

Unique: non-code artifacts (diagrams, mockups) are first-class next to sessions.

Why it is good: the files-edited list per session answers "what did this session touch" at a glance.

Sources: [Crystal README](https://github.com/stravu/crystal), [nimbalyst.com](https://nimbalyst.com)

## Sculptor (Imbue)

Flows
- Each agent runs in its own container, not a worktree, so there is no dependency reinstall and execution is isolated.
- Pairing Mode: one click syncs the agent's work into your local repo, in both directions, so you test in your own dev environment.
- Merge: choose what to keep; conflicts are flagged and handed back to the agent. Suggestions (beta) critique before merge (P).

Unique: Pairing Mode.

Why it is good: it removes the "my environment is not the agent's environment" gap.

Source: [imbue.com/sculptor](https://imbue.com/sculptor/)

## Vibe Kanban (sunsetting)

Flows
- Issues on a board, each becoming a workspace (branch, terminal, dev server). Review the diff with inline comments to the agent, open a PR with an AI description, then review and merge on GitHub.
- Built-in browser with devtools, inspect mode and device emulation (P).

Unique: the browser with devtools.

Why it is good: the diff and browser review loop was the value. Kanban was the headline and the project is winding down anyway.

Source: [README](https://github.com/BloopAI/vibe-kanban)

## GitHub Copilot coding agent and Agents panel

Flows
- Agents panel on github.com (Aug 2025) and an Agents tab per repo list delegated tasks with session logs showing tools used.
- You can steer a run mid-flight (each message costs a premium request). The PR opens as a draft, and Actions do not run until you approve in the merge box (S).

Unique: the approval gate on CI for agent-authored PRs.

Why it is good: logs show what the agent did, and the draft plus CI gate keep unreviewed code from running anything.

Falls short: no clear UI signal about what triggers Copilot, and PR comments may or may not start a new session (community thread, S).

Source: [GitHub docs](https://docs.github.com/en/copilot/concepts/agents/coding-agent) (reached through search only)

## Linear and agents

Flows
- Delegate an issue to Linear's own cloud coding agent (Claude Code or Codex underneath) or an installed agent (Cursor, Codex, Copilot, Devin). A coding session is tied to the issue and teammates can follow and steer.
- The PR lands in a Reviews tab with the diff and verification artifacts (screenshots, recordings). Loops can auto-start on Triage (P).

Unique: the issue is the unit; the PR comes back attached to it with proof of verification.

Why it is good: whoever filed the issue can see progress and the result without opening a terminal.

Falls short: reported reliability problems delegating to Codex Cloud (S). Claude Code has no confirmed native Linear delegation (anthropics/claude-code#12925, S).

Source: [Linear docs](https://linear.app/docs/linear-cloud-coding-agent)

## Xcode 26.3 coding assistant

Flows
- The agent (Claude Agent, Codex) works through MCP tools Xcode exposes (build, previews, project settings). A milestone is created at each agent change so you can revert. External agents get fine-grained permissions (S).

Unique: milestones per change, inside a native IDE.

Falls short: the undo button may not appear when auto-apply is off (use history or git), and the agent does not inherit shell env such as `.zshrc` (S). Review UI details are unverified; Apple's UI docs were not readable.

Sources: [fatbobman](https://fatbobman.com/en/posts/xcode-263-claude/)

## Nova (Panic)

Flows
- No built-in agent. The third-party Claude Code Bridge extension exposes about 12 editor tools to the CLI and launches `claude` in a real terminal; Nova's terminal is an ordinary pane (P).

Unique and why it is good: a native editor integrates agents by being driven, not by growing a chat UI.

Source: [extension](https://extensions.panic.com/extensions/ca.okapi/ca.okapi.claudecode-nova/)

## Tower

Flows
- Tower 18 (Oct 2026): a `gittower` launcher opens views (History, Blame, Working Copy, Branches Review, Pull Requests) from the terminal. Stacked-branch parent metadata lives in git config. An Agent Skill (SKILL.md) lets Claude or Codex offer "open the Working Copy so you can review" (P).

Unique: the terminal-to-GUI hand-off plus a skill that teaches the agent to use it.

Falls short: reviews say PR review inside Tower is limited (S, conflicting).

Source: [Tower 18 post](https://www.git-tower.com/blog/tower-mac-18)

## Cross-app patterns worth stealing for Berth

Berth already has, so not gaps: per-line review comments batched and sent to the session (ReviewComment, Send N Comments); a branch and PR card with CI checks, review threads and Create Pull Request; a Pull Requests inbox; status glyphs for working, needs you, unread and flagged, Dock badge and needs-you notifications; phone control (Berth Remote); worktree start (`startsInWorktree`, `-w`); archive and pins; a status filter and sidebar filter; a ⌘K palette; tasks grouping sessions by issue and PR; Review's Files and Comments tabs; native glass and a Ghostty terminal; hover cards on session rows. Berth reads the user's own transcripts, so it owns no state and requires no account.

Ordered by value over cost.

1. Review-finish loop (Claude desktop, Vibe Kanban, Warp). After Send, when the session goes busy then idle, Review marks hunks changed since the send and resolves cards whose lines changed. Berth has Send; it does not close the loop. Uses the file watcher and `ReviewModel.comments`.
2. PR card Auto-fix and Merge when ready (Claude desktop, Superset). On a failing check, a button pastes "Fix the failing checks" into the session; Merge when ready runs `gh pr merge --auto --squash` after a confirm. Berth has the card and checks but no actions on them. Uses only `gh`. Per the anti-patterns below, show what will fire and keep it off by default.
3. Needs-attention inbox (Codex inbox, Warp, Superset). One sidebar section or popover for sessions waiting, finished unseen, failed checks and review requested, each with one primary action. Berth has every signal separately (needs you, unread, the toolbar's "N to review" capsule); this unifies them.
4. Per-turn diffs (T3, Xcode milestones, Zed). A turn picker in Review: All changes, Since last prompt, Turn N. Derive it from transcript tool-use records (BerthCore's `TranscriptEdits`) and file state, never from git snapshots (Zed removed checkpoints after hangs). Not in Berth today.
5. Context verbs in ⌘K (Cursor, Zed, Xcode Open Quickly). Open PR, Copy branch, Reveal worktree, Send "continue", Compare with main, ranked by the selected session. Berth has ⌘K (`CommandPalette`, `AppAction`) but its actions are global.
6. Local preview pane with element picker (Claude desktop, Cursor Design Mode, Superset, Vibe Kanban). A WKWebView tab in the Review panel (Changes, Files, Comments, Preview). Detect ports from the session's descendant processes (`ProcessAncestry` exists). A picked element goes out as a Review comment with selector, HTML snippet and screenshot. Berth has none of this. Native WKWebView avoids the Electron cost.
7. Review a PR in a worktree (Cursor autopilot, Conductor). Berth has the PR inbox and a `-w` start that pastes a checkout prompt; the open piece is posting the comments back to GitHub as a pending review through `gh api`.
8. Terminal-side CLI plus SKILL.md (Tower's `gittower`, Superset CLI and MCP, Nova bridge). `berth open-review`, `berth show-pr`, `berth notify`, and a skill that tells Claude to offer "open the diff" at the end of a task. Berth has no CLI.
9. Archive on PR merge with a worktree guard (Claude desktop). A setting that archives when the PR merges or closes, skipped when the worktree is dirty, with the worktree's disk size in the row menu. Berth's archive never deletes worktrees; keep it that way.
10. Follow mode (Zed). A Review toggle that jumps the diff column to each file Claude edits, debounced and off while the user is typing in the diff. Berth's Review already follows FSEvents.
11. Issue-first start (Linear, Conductor, Vibe Kanban). A GitHub or Linear issue URL in ⌘N starts a session with the issue body as the first prompt. Berth's Tasks already link sessions to issues; this is the start side. No kanban: the sidebar groups already serve as the board.
12. Split or window per session (Claude desktop Option-click and Cmd-click, Cursor grid). Option-click a row to open it beside the current one. Berth shows one terminal at a time.
13. Compare two sessions' branches (Cursor best-of-n, Sculptor). Select two sessions on one task and open a diff between their branches. Cheap with git.
14. Scheduled runs into the inbox (Codex automations, Linear Loops, Superset). A saved prompt run by `claude -p` in a disposable worktree, landing as an unread session. Depends on pattern 3 and is the largest piece; the CLI already has routines.
15. Worktree-aware start strip (Claude desktop, Zed picker, T3). In ⌘N: folder, worktree toggle, base branch, a `.worktreeinclude` hint when `.env` is missing. Berth has `startsInWorktree` as a global setting only.

### Anti-patterns the research supports

- Kanban as the main surface (Vibe Kanban sunset; Nimbalyst keeps it optional).
- Owning the agent or requiring sign-in (Superset login and bundled agents, Warp account).
- Silent destructive cleanup (Claude desktop archive deleting worktrees).
- Per-turn filesystem checkpoints (Zed).
- Full access by default (T3, Conductor); show the permission mode, do not set it.
- Electron weight and web terminals (Superset about 2 GB, xterm.js freezes).
- A second editor competing with the user's IDE; offer Open in Editor instead.
- A sidebar that hides or empties on its own (Claude desktop issues).
- Promotion or a forced window mode (Cursor).
- More parallel agents with no triage (HN review bottleneck); triage means pattern 3 and 4 above.
- Opaque automatic triggers (Copilot); auto-fix, auto-archive and auto-merge must show what will fire.
- Sending code off-machine for convenience (Warp indexing).
- Running repo-supplied code silently (setup scripts, language servers). Berth already gates language servers; the same rule would cover worktree setup scripts.
