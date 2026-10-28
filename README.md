# Berth

Berth is a native macOS terminal for your local Claude Code sessions: one window whose sidebar groups every session under its project (newest activity first), with live working, needs-you and running-elsewhere badges, and a libghostty terminal on the right that resumes a session with `claude --resume` or opens a plain shell, using your own Ghostty config. It keeps no database of its own; everything comes from `~/.claude`.
