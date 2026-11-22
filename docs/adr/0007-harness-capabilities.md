# 0007 One Harness descriptor per agent, with a capability set

## Context

Codex support (#229) added `SessionSummary.agent` and checks like `agent == .codex` in launch, idle unload, locking, the Conversation gate, the row glyph and the remote list. Each new agent would repeat those edits across views.

## Decision

`Harness` (BerthCore) is one value per agent: identity (`name`, `glyph`), `isOptIn`, `liveSource`, the launch command per `LaunchStart`, an optional `claim` for agents whose session id is only known after the tab runs, a live-status reader (`readLive`, returning the shared `LiveSession` records, with `liveSource` saying whether they come from processes outside Berth or from the tab itself), an optional transcript adapter into the shared turn model, and a `Capability` set (needsYou, approvals, modelEffortMenu, contextSize, pullRequestLinks, backgroundTasks, idleUnload, worktrees, remote, conversation). `Agent.harness` finds it; the UI calls `supports(_:)` and never compares agents. Claude has every capability. Codex has conversation, contextSize and pullRequestLinks. `Store.openSession(_ agent:)` is the one launch path.

`contextSize` means transcript usage context. The model catalog resolves a window and name only when the transcript lacks a window; summaries carrying a rollout window are excluded from the missing-model lookup and keep that window.

## Rejected alternatives

- A protocol with one class per agent: nothing owns state, so a struct of values and closures is enough.
- Moving session discovery behind the descriptor: `TranscriptIndex` and `CodexIndex` stay typed in `Store` (search, Review and the remote read Claude's index directly) with `Store.sessionIndex(for:)` exhaustively selecting their shared `SessionIndex` protocol (`root`, `url(ofSession:)`) for conversation readers.
- Keeping `Agent` checks where they are few: the point is that a new harness touches no views.

## Adding a harness

A new agent is one descriptor plus its adapters, all in BerthCore, each returning the shared model (`SessionSummary`, `RemoteEntry` with the neutral tool names Bash, Edit, Write, WebSearch and TodoWrite, `LiveSession`). Views, Remote and the Conversation never see the agent's own record types. Files touched, using Codex as the example:

- `Agent.swift`: the new case.
- `Harness.swift`: the descriptor (identity, capabilities, `liveSource`, `readLive`, `isStatusTitle`, `command`, `claim`, `readTranscript`), its entry in `Harness.all` and in `Agent.harness`.
- `CodexLaunch.swift`: the launch line and, when the session id is only known after the tab runs, the claim.
- `CodexRollout.swift`: `SessionIndex` and the reader that turns the agent's files into `SessionSummary`.
- `CodexTranscript.swift`: `readTranscript`, the records into `RemoteEntry` and whether a turn is open.
- `CodexLive.swift`: `readLive`, status as `LiveSession` records.
- `Store.swift`: `sessionIndex(for:)` and `agentDirectory(for:)`, plus the typed index, its scan and watcher (the rejected alternative below), and a Settings toggle when the agent is opt-in.
- `Packages/BerthCore/Tests`: fixtures with invented records for each adapter.

A capability goes in the descriptor only when an adapter backs it.

