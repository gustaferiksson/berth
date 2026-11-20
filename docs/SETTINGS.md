# Settings

Berth keeps its settings in UserDefaults under the bundle id `dev.gustaf.berth` (Release and
Debug builds share it). Everything here can be set in Settings (⌘,); this guide is for changing
it from a terminal with `defaults`, for example to add a language server or linter to Review.

```sh
ID=dev.gustaf.berth
defaults read $ID reviewEnabled
defaults write $ID reviewEnabled -bool true
```

Changes apply to a running Berth without a relaunch, except where the table says otherwise.

## Settings

| Key | Type | Default | What it does |
| --- | --- | --- | --- |
| `notifiesWhenSessionNeedsYou` | `-bool` | `true` | Notify when a session open in Berth starts waiting for you. |
| `unloadIdleSessionsAfter` | `-float` | `14400` | Seconds before an idle Claude tab is unloaded; `0` is never. Settings offers 3600, 14400 and 86400. |
| `startsInWorktree` | `-bool` | `false` | Start new sessions in a git repo with `claude -w`. |
| `sidebarPosition` | `-string` | `left` | `left` or `right`. |
| `sidebarDensity` | `-string` | `comfortable` | `comfortable`, `cozy` (tighter rows) or `compact` (one line per row, the pull request beside the title). Settings > Appearance. |
| `groupingMode` | `-string` | `project` | `project`, `repository` or `recent`. Read at launch. |
| `showsCustomGroups` | `-bool` | `true` | Show custom groups in the sidebar. Read at launch. |
| `reviewEnabled` | `-bool` | `false` | Turn on Review (⇧⌘R). |
| `languageServersEnabled` | `-bool` | `false` | Run language servers in Review. Needs `reviewEnabled`. |
| `languageServers` | `-string` | unset | JSON array of server entries, see below. Unset means the built-ins. |
| `reviewColorScheme` | `-string` | `oneDark` | `oneDark`, `oneLight`, `gitHubDark`, `gitHubLight` or `terminal` (match the Ghostty theme). |
| `reviewFontFamily` | `-string` | empty | A monospaced font family; empty uses the terminal font. |
| `reviewFontSize` | `-float` | `0` | Points; `0` uses the terminal font size. Settings offers 9 to 24. |
| `reviewLineHeight` | `-float` | `1.3` | Line height multiple, 1.0 to 2.0. |
| `reviewShowsMinimap` | `-bool` | `true` | Show the diff minimap. |
| `reviewDiffLayout` | `-string` | `auto` | `auto` (side by side from 760 pt of diff column), `sideBySide` or `inline`. |
| `reviewTerminalBelow` | `-bool` | `false` | Put the Claude terminal under the diff instead of beside it. |
| `reviewTerminalBelowRatio` | `-float` | `0.6` | The diff's share of the height in that layout, written by dragging the divider. |
| `reviewChangesAsTree` | `-bool` | `false` | Show Uncommitted and Committed as a folder tree instead of a list. |
| `reviewBaseBranches` | `-dict` | unset | The base picked in Review's header, per repository root: `{"<root>" = {"<branch>" = "<ref>";};}`. Unset branches use the PR's base, else `gh-merge-base` or an upstream on another branch, else the nearest branch towards the default branch. |
| `remoteEnabled` | `-bool` | `false` | Berth Remote. Turn it on in Settings, which creates the token; a `defaults write` alone does nothing. |

Remove a key with `defaults delete $ID <key>` to go back to its default.

## Language servers and linters

Review runs language servers for diagnostics, hover and ⌘-click go to definition. Both
`reviewEnabled` and `languageServersEnabled` must be `true`. `languageServers` is a JSON string
holding an array of entries:

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `id` | string | required | Unique id. An entry with a built-in's id replaces that built-in. |
| `name` | string | required | Shown in Settings, and as the diagnostic's source when the server sends none. |
| `command` | string | required | Executable name, absolute path, or `~/` path. |
| `languages` | [string] | required | File extensions (`vue`) or language ids. Ids: `javascript`, `javascriptreact`, `typescript`, `typescriptreact`, `swift`, `rust`; any other extension is its own id (`json`, `css`). |
| `arguments` | [string] | `[]` | Arguments, e.g. `["--stdio"]`. |
| `rootMarkers` | [string] | `[]` | Files that mark the server's root, e.g. `["biome.json"]`. |
| `settings` | string | none | JSON, as a string, for the server's configuration. |
| `isDiagnosticsOnly` | bool | `false` | `true` for linters: never asked for hover or definition. |
| `isEnabled` | bool | `true` | `false` turns the entry off. |

An entry that can't be read (a required field missing, a wrong type) is skipped and the others
still run. Settings > General > Language Servers then says how many were skipped, and keeps them
(after the readable entries) when it writes the list back.

- **Built-ins.** SourceKit-LSP (`sourcekit-lsp`), rust-analyzer (`rust-analyzer`) and TypeScript
  (`typescript-language-server`) are always there. Stored entries come first, then each built-in
  whose id isn't stored. Hover and definition ask servers in that order and take the first answer;
  diagnostics from every matching server are merged.
- **Root.** For each file Berth walks up from its folder to the repository root and uses the first
  folder holding one of `rootMarkers`. If none holds one, that server doesn't run for the file.
  Empty `rootMarkers` means the repository root.
- **Command.** An absolute or `~/` path is used as is. A name is looked up in
  `<root>/node_modules/.bin`, then `PATH`, then known install folders for the built-ins (such as
  `~/.cargo/bin`), then `/opt/homebrew/bin` and `/usr/local/bin`. A script with a `node` shebang
  runs with a `node` found on `PATH`, in `~/.nvm`, Homebrew or Zed, since an app opened from
  Finder has a bare `PATH`.
- **Settings.** The parsed `settings` answer the server's `workspace/configuration` requests by
  dotted section and are sent once as `workspace/didChangeConfiguration`.

### Read, add, remove

Read the current entries:

```sh
defaults export $ID - | plutil -extract languageServers raw -o - - | jq .
```

Add or replace an entry by id, keeping the others (`ENTRY` from the examples below):

```sh
defaults write $ID languageServers -string "$(
  { defaults export $ID - | plutil -extract languageServers raw -o - - 2>/dev/null || echo '[]'; } |
  jq -c --argjson entry "$ENTRY" 'map(select(.id != $entry.id)) + [$entry]'
)"
```

Remove one (removing a built-in's override brings the built-in back):

```sh
defaults write $ID languageServers -string "$(
  defaults export $ID - | plutil -extract languageServers raw -o - - | jq -c 'map(select(.id != "biome"))'
)"
```

`jq` ships with macOS. The linters below resolve from the repository's `node_modules/.bin`, so
install them there (`npm i -D @biomejs/biome`, `oxlint`, or `eslint vscode-langservers-extracted`).

### Biome

```sh
ENTRY='{"id":"biome","name":"Biome","command":"biome","arguments":["lsp-proxy"],"languages":["javascript","javascriptreact","typescript","typescriptreact","json","css"],"rootMarkers":["biome.json","biome.jsonc"],"isDiagnosticsOnly":true}'
```

### oxlint

```sh
ENTRY='{"id":"oxlint","name":"oxlint","command":"oxlint","arguments":["--lsp"],"languages":["javascript","javascriptreact","typescript","typescriptreact"],"rootMarkers":[".oxlintrc.json"],"isDiagnosticsOnly":true}'
```

### ESLint

`vscode-eslint-language-server` comes from `vscode-langservers-extracted`. It lints nothing
without settings; these are the minimum:

```sh
ENTRY=$(jq -nc '{
  id: "eslint", name: "ESLint", command: "vscode-eslint-language-server", arguments: ["--stdio"],
  languages: ["javascript", "javascriptreact", "typescript", "typescriptreact"],
  rootMarkers: ["eslint.config.js", "eslint.config.mjs", "eslint.config.ts"],
  settings: ({validate: "on", nodePath: null, experimental: {}, problems: {}, rulesCustomizations: []} | tojson),
  isDiagnosticsOnly: true
}')
```

### Turn off a built-in

Store the built-in under its own id with `isEnabled` false, then run the add command:

```sh
ENTRY='{"id":"typescript-language-server","name":"TypeScript","command":"typescript-language-server","languages":[],"isEnabled":false}'
```

The other built-in ids are `sourcekit-lsp` and `rust-analyzer`.

### Relaunch

Not needed. A running Berth picks up `languageServers` and `languageServersEnabled` while Review
shows a file: new or edited entries start, and removed or disabled ones stop.
