# Berth

Berth is a native macOS terminal for your local Claude Code sessions: one window whose sidebar groups every session under its project (newest activity first), with live working, needs-you and running-elsewhere badges, and a libghostty terminal on the right that resumes a session with `claude --resume` or opens a plain shell, using your own Ghostty config. It keeps no database of its own; everything comes from `~/.claude`.

Requires macOS 26 and the `claude` CLI.

## Install

```sh
brew install --cask gustaferiksson/tap/berth
```

Or download `Berth-<version>.zip` from [Releases](https://github.com/gustaferiksson/berth/releases/latest). Berth updates itself from GitHub Releases; Berth ▸ Check for Updates… checks right away.

## Shortcuts

| Shortcut | Action |
|---|---|
| ⌘N | New session in a folder (⌘O in the launcher browses for one) |
| ⌘K | Command palette |
| ⇧⌘F | Search every session's prompts and replies |
| ⌘T | New terminal in the panel |
| ⌘J | Show or hide the terminal panel |
| ⌥⌘K | Clear the terminal |
| ⇧⌘S | Stats |
| ⌃⌘1 / ⌃⌘2 / ⌃⌘3 | Group by project, repository or recent |
| ⌘1 to ⌘8, ⌘9 | Select a tab, the last tab |
| ⇧⌘] / ⇧⌘[ or ⌃⇥ / ⌃⇧⇥ | Next or previous tab |
| ↑ / ↓, Return | Move through the sidebar, open the session |
| ← / → | Collapse or expand a sidebar group |
| ⌘, | Settings |

## Build from source

```sh
brew install xcodegen
./build.sh                                # Release into dist/Berth.app, ad-hoc signed without a .env
swift test --package-path Packages/BerthCore
```

## License

MIT
