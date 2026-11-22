# Codex

Moved from CLAUDE.md. The abstraction that would remove the per-agent branches is issue #234 (Harness).

Codex (Settings > General `codexEnabled`, off by default): BerthCore `CodexRollout` + `CodexIndex` read `$CODEX_HOME/sessions/**/rollout-*.jsonl` and `session_index.jsonl` into `SessionSummary` with `agent: .codex` (interactive rollouts only: `thread_source` user, originator not `codex_exec` or `Claude Code`; title is the newest index name, else the first `user_message`; context is the last `last_token_usage.input_tokens` over `model_context_window`, unknown after `compacted`). `CodexLaunch` runs `codex resume "$BERTH_SESSION_ID"`; ⌥⇧↩ in ⌘N starts `codex` and the tab claims the first new rollout by cwd and start time.

Codex tabs have no live file (never locked, unloaded, needs-you or Conversation) and are excluded from the remote; stored pins, flags, archive, seen and snoozes keep Codex ids (`codexSessionIDs`) while the toggle is off. `-codexEnabled YES` lists rollouts from `CFFIXED_USER_HOME/.codex`; `-snapshotLauncherKeys` knows `alt-shift-enter`.
