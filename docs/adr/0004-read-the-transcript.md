# 0004 Read the transcript instead of driving a headless session

## Context

The Conversation view shows a session as a conversation, and Berth Remote shows it on a phone. Both need the transcript, status and the ability to send prompts and answer prompts, while the user's real `claude` keeps working with resume, live status and idle unload.

## Decision

The claude TUI keeps running in the hidden, still-mounted pty. The view reads the transcript (`TranscriptTail`, `TranscriptActivity`, shared with the remote) and sends prompts and keys through the same guarded paste and press paths (`Store.submit`, `press`, `interrupt`). Text appears per content block, not per token, which was accepted. `ConversationFallback` switches a tab to the terminal for states the view cannot show (unknown `waitingFor`, multi-question prompts, a dead tab). Views depend only on neutral entry and turn types so another agent can plug in later (issue #234).

Details: design/conversation.md, design/remote.md.

## Rejected alternatives

- Headless `stream-json` (a separate `claude` process fed over stdin): it would not be the user's terminal session, so resume, live session status and idle unload would not apply to it. Streaming per token was the one thing it would have bought.
