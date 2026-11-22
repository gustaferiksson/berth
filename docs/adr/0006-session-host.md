# 0006 A detached host per tab keeps sessions running when Berth quits

## Context

Berth hung up every descendant on quit and resumed Claude sessions on relaunch (#224). That loses running shells, background tasks and in-flight turns, and blocks updates while anything works. Rex's server, which owns its PTYs so clients reattach later, was the model.

## Decision

Opt-in (`keepsSessionsRunning`): a new tab runs `berth-host new <hosts dir> <tab id> '<command>'`, a thin client. `berth-host` is one detached host per tab (double fork and `setsid`, owned by launchd) running the command on a `forkpty` pty behind a 0600 unix socket under `~/Library/Application Support/<bundle id>/hosts/`. One client at a time, a 256 KB scrollback ring replayed on attach, the exit status sent last. Quit and updates leave hosts running; `Store.close` and idle unload hang them up. `SavedTab.id` is the host key, so relaunch reattaches.

Details: design/flows-terminals.md (Session host).

## Rejected alternatives

- Status quo (hang up on quit, resume on relaunch): kept as the default because the host is opt-in.
- One server owning every pty (Rex's design): the issue's inspiration; the reason for a host per tab instead is not recorded.
- Cleaning orphaned hosts (no saved tab): not done yet.
