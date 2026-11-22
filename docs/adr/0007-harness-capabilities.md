# 0007 One Harness descriptor per agent, with a capability set

## Context

Codex support (#229) added `SessionSummary.agent` and checks like `agent == .codex` in launch, idle unload, locking, the Conversation gate, the row glyph and the remote list. Each new agent would repeat those edits across views.

## Decision

`Harness` (BerthCore) is one value per agent: identity (`name`, `glyph`), `isOptIn`, `liveSource`, the launch command per `LaunchStart`, an optional `claim` for agents whose session id is only known after the tab runs, an optional transcript adapter into the shared turn model, and a `Capability` set (needsYou, approvals, modelEffortMenu, contextSize, pullRequestLinks, backgroundTasks, idleUnload, worktrees, remote, conversation). `Agent.harness` finds it; the UI calls `supports(_:)` and never compares agents. Claude has every capability, Codex none. `Store.openSession(_ agent:)` is the one launch path.

`contextSize` means the transcript-usage context and the model catalog window (Claude); Codex rows still show the context their rollout reports.

## Rejected alternatives

- A protocol with one class per agent: nothing owns state, so a struct of values and closures is enough.
- Moving session discovery behind the descriptor: `TranscriptIndex` and `CodexIndex` stay typed in `Store` (search, Review and the remote read Claude's index directly) until a third agent needs it.
- Keeping `Agent` checks where they are few: the point is that a new harness touches no views.
