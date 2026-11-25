# Background Tasks pane

Tasks is a session pane mode alongside Changes, Files, Browser and Terminal. It appears when the session has background work and stays visible while selected. The toolbar segment, View menu and ⇧⌘A open it. The Conversation task capsule selects its first active task. Each session tab remembers its selected task in memory.

The trailing sidebar groups Claude background shells, subagents and owned terminals opened by `berth open-terminal` into Running and Finished accordions. Rows show the description, kind and elapsed time or completion status. The selected task’s card uses the terminal theme. It follows new output while scrolled to the bottom.

- Shells show up to 64 KiB and 500 lines of the recorded output. Copy Output copies the displayed tail.
- Subagents show the prompt and live replies. Open Transcript uses the same turn renderer as the Conversation subagent overlay when the transcript is available.
- Owned terminals show an Open Terminal action that selects the existing surface in Terminal mode. Copy Output uses Ghostty’s clipboard actions on that surface. Stop Terminal closes the owned tab through the normal tab close path. While the owner tab is open, closed CLI terminals stay in Finished with their recorded exit code when available. Closed terminal scrollback is released with the surface.
- Claude shell and subagent actions are read-only. Berth recognizes recorded TaskStop results and task notifications.

The pane scans the selected Claude transcript incrementally using the same parser as the Conversation capsule. It polls the selected running shell’s output, and watches the selected subagent’s transcript. Format details are in [Claude Code on-disk format](claude-code-format.md#background-tasks).
