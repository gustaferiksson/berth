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
| `sidebarTwoLineRows` | `-bool` | `NO` | Show the repository folder and branch beneath each session title. Settings > Sidebar > Two-line rows. |
| `groupingMode` | `-string` | `project` | `project`, `repository`, `recent` or `flat`. Read at launch. |
| `showsCustomGroups` | `-bool` | `true` | Show custom groups in the sidebar. Read at launch. |
| `reviewEnabled` | `-bool` | `false` | Turn on Review (⇧⌘R). |
| `languageServersEnabled` | `-bool` | `false` | Run language servers in Review. Needs `reviewEnabled`. |
| `languageServers` | `-string` | unset | JSON array of server entries, see below. Unset means the built-ins. |
| `reviewSyntaxColors` | `-string` | `terminal` | `terminal` or `vscode` (token colours from the active VS Code theme, read once at launch, in Review and Conversation code; falls back to terminal when unreadable or light/dark differs). |
| `reviewColorScheme` | `-string` | `terminal` | `oneDark`, `oneLight`, `gitHubDark`, `gitHubLight` or `terminal` (match the Ghostty theme). |
| `reviewFontFamily` | `-string` | empty | A monospaced font family; empty uses the terminal font. |
| `reviewFontSize` | `-float` | `0` | Points; `0` uses the terminal font size. Settings offers 9 to 24. |
| `reviewLineHeight` | `-float` | `1.3` | Line height multiple, 1.0 to 2.0. |
| `reviewShowsMinimap` | `-bool` | `true` | Show the diff minimap. |
| `reviewShowsBlame` | `-bool` | `true` | Show inline Git blame on the caret line in the working-tree editor. |
| `reviewWrapsLines` | `-bool` | `false` | Soft-wrap long lines in the diff and file viewer instead of scrolling horizontally (strip button, View ▸ Wrap Lines, ⌥⌘Z). |
| `reviewDiffLayout` | `-string` | `auto` | `auto` (side by side from 760 pt of diff column), `sideBySide` or `inline`. |
| `reviewTerminalBelow` | `-bool` | `false` | Put the Claude terminal under the diff instead of beside it. |
| `conversationBodyFont` | `-string` | `system` | Conversation text: `system`, `monospaced` (the terminal font) or `custom`. Settings > Conversation (Style presets Clean, Spacious, Reading and Terminal write these keys together). |
| `conversationBodyFamily` | `-string` | empty | Font family used when `conversationBodyFont` is `custom`. |
| `conversationBodySize` | `-float` | `16` | Points; `0` uses the terminal font size. Settings offers 11 to 20. |
| `conversationLineSpacing` | `-string` | `relaxed` | `compact`, `normal`, `comfortable`, `relaxed` or `spacious` (line height multiples 0.9, 1, 1.15, 1.3, 1.45). |
| `conversationMessageWidth` | `-string` | `narrow` | `narrow` (680 pt), `normal` (860 pt) or `full`. |
| `reviewTerminalBelowRatio` | `-float` | `0.6` | The diff's share of the height in that layout, written by dragging the divider. |
| `reviewChangesAsTree` | `-bool` | `false` | Show Uncommitted and Committed as a folder tree instead of a list. |
| `reviewBaseBranches` | `-dict` | unset | The base picked in Review's header, per repository root: `{"<root>" = {"<branch>" = "<ref>";};}`. Unset branches use the PR's base, else `gh-merge-base` or an upstream on another branch, else the nearest branch towards the default branch. |
| `windowTransparency` | `-float` | `0` | How much of the desktop shows through behind the sidebars and through the gaps around cards with Theme or Darker. The range is 0 to 0.8, with `0` opaque. Settings > Terminal. |
| `windowBackground` | `-string` | `theme` | Background behind the cards. Use `theme` for the window's chrome colour, `glass` for Liquid Glass or `darker` for the cards' theme background colour. Unknown values use `theme`. Settings > Terminal. |
| `pullRequestPrompt` | `-string` | `Summarize PR #{number} ({url}).` | First prompt of a session Berth opens for a pull request (also from an issue). `{number}`, `{url}` and `{repo}` (owner/name) are replaced; empty sends no prompt. Settings > General. |
| `controlEnabled` | `-bool` | `false` | Agent Control: sessions in tabs opened afterwards get `BERTH_SOCKET`, `BERTH_TAB_ID` and `BERTH_TOKEN` and can run `berth`. Settings > General installs the command, skill and hook. |
| `browserSearchEngine` | `-string` | `duckDuckGo` | What the Browser pane's address field searches with: `duckDuckGo`, `google`, `bing`, `kagi` or `startpage`. Settings > Browser. |
| `browserKeepsWebsiteData` | `-bool` | `false` | The Browser pane uses the default persistent website data store, so logins stick. Off, all tabs share one non-persistent store. Applies to tabs opened afterwards. |
| `conversationLinksOpenIn` | `-string` | `defaultBrowser` | Where http and https links clicked in the Conversation view open: `defaultBrowser` or `berth` (a new tab in the session's Browser pane). The GitHub toggle can also open GitHub links in Berth. |
| `browserAppearance` | `-string` | `auto` | Appearance of web pages in the Browser pane (their `prefers-color-scheme`): `auto` follows the macOS system appearance (not Berth's own), `light` or `dark` overrides it. Browser chrome always follows the app. Settings > Browser. |
| `agentBrowserControl` | `-string` | `ask` | Whether agents may run `berth browser` and `berth open-url`: `ask` prompts once per Claude session (Allow for This Session or Deny, kept until Berth quits), `allow` skips the prompt and `off` refuses every command. A command waits up to 2 minutes for the answer. A tab an agent drives shows an Agent badge whose menu stops access. Settings > Browser. |
| `githubLinksOpenInBerth` | `-bool` | `false` | Open http and https links to `github.com` and `www.github.com` in a new tab in the current session’s Browser pane. Without a session, links open in the default browser. Settings > Browser. |
| `remoteEnabled` | `-bool` | `false` | Berth Remote. Turn it on in Settings, which creates the token; a `defaults write` alone does nothing. |

## Terminal overrides

`~/.config/berth/ghostty` holds Ghostty settings that apply only inside Berth. It is read after your Ghostty config, so its keys win (a `theme` there also drives Berth's colours). Edit it from Settings > Terminal, or by hand; edits apply right away. Berth never creates it on its own. If Ghostty rejects the file (an unknown key, say), Berth ignores it, keeps your own config and shows the error in red in Settings.

```
font-size = 14
theme = Atom One Dark
cursor-style = bar
```

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
still run. Settings > Review > Servers then says how many were skipped, and keeps them
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

**View ▸ Show Tasks Pane** (⇧⌘A) opens the current session’s background tasks. The toolbar shows Tasks when the session has task history or Tasks is selected. This mode is available with Review off.

## Stored state

Moved from CLAUDE.md.

The sidebar is read from `~/.claude` on every change; the app persists only UI state in UserDefaults. Behind the `persistsTabs` gate (snapshots set it off, so they never write these): open tabs (`openTabs`: kind, folder, session id, `isSelected`, and the optional `isTaskTerminal` flag for reattaching an owned terminal), archived sessions (`archivedSessions`: session id to archive time), pins (`pinnedSessions`, ordered `[String]`), unread (`seenSessions`: session id to last seen), flags (`flaggedSessions`), dismissed failing checks (`dismissedFailures`: session id to the PR head SHA whose failure was dismissed), `groupingMode`, `showsCustomGroups`, custom groups (`customGroups`, a JSON string), Collapse/Expand All's `collapsedGroups`, `tasks` (`TaskState` JSON `{"version":1,"tasks":[…],"dismissed":[…]}`, read per task so an unreadable entry is kept on write-back), the remembered layout, written only from user drags and the same for every session (`trailingSidebarWidth`, `leadingSidebarWidth`, `panelSidebarWidth` for the Changes, Files, Browser and Terminal list, `paneSessionWidth` for the session column beside the pane, `reviewTerminalBelowRatio` for the pane height with the terminal below), the Browser pane's pinned tabs (`browserPinnedTabs`, JSON `[{url, title}]`) and session tabs (`browserSessionTabs`, JSON session id to `[{url, title}]`, dropped when the session is marked done), `showsReviewPanel` and `rendersMarkdown` (rendered Markdown in Review's file viewer, strip button, View ▸ Show Rendered Markdown, ⇧⌘M).

Plain `@AppStorage`, not gated: `collapsedGroups` (chevron clicks), `archivedExpanded`, `sidebarTwoLineRows`, `sidebarPosition`, `richPreviews`, `windowTransparency`, `windowBackground`, `showsTrailingSidebar`, `settingsTab`, `notifiesWhenSessionNeedsYou`, `unloadIdleSessionsAfter`, `startsInWorktree`, `pullRequestPrompt`, `keepsSessionsRunning`, `controlEnabled`, `reviewEnabled`, `languageServersEnabled`, `languageServers` (JSON `[LanguageServerEntry]`), `reviewColorScheme`, `reviewSyntaxColors`, `reviewFontFamily`, `reviewFontSize`, `reviewLineHeight`, `reviewShowsMinimap`, `reviewShowsBlame`, `reviewWrapsLines`, `reviewDiffLayout`, `reviewTerminalBelow`, `reviewTerminalBelowRatio`, `reviewReferencesSplitRatio`, `reviewSplitRatio`, `reviewChangesAsTree`, `reviewBaseBranches` (root → branch → picked base ref; an unresolvable pick is removed on load only while `persistsTabs` is on), `remoteEnabled`, `remoteToken`, `conversationShellCompletions`, `browserSearchEngine`, `browserKeepsWebsiteData`, `conversationLinksOpenIn`, `githubLinksOpenInBerth`, `browserAppearance`, `updateSwapFailure`; plus the window frame.

Review stores accordion state in `collapsedReviewSections` behind `persistsTabs`. The comma-separated ids are `pullRequest`, `reviewThreads`, `uncommitted`, `committed`, `commits`, `history`, `files`, `otherPullRequests` and `sessionFiles`. A bare id collapses the section and `+id` opens a section that defaults to collapsed. A legacy `reviewPanelTab` of `preview`, `comments`, `files` or `graph` is applied once.

Agents use plain `@AppStorage`: `claudeEnabled` (unset reads as on) and `codexEnabled` (unset reads as off), `launchModel.<agent>` (model slug or alias) and `launchEffort.<agent>` (effort) for `claude` and `codex`, and `newSessionAgent` (`claude` or `codex`, the default for ⌘N and the launcher; ignored while that agent is disabled). Empty or unset strings leave the launch option at the CLI's default. At least one agent stays enabled (Settings disables the last toggle). A disabled agent's sessions leave the sidebar but their stored pins, flags, archive, seen and snoozes are kept (`claudeSessionIDs`, `codexSessionIDs`).

GitHub Projects uses `projectsEnabled`, `projectsMineOnly` and `projectsAllowsEditing` (all Booleans that default to false). `projectsSelected` stores the selected project node IDs in selection order as a JSON array of strings, with an empty selection by default. Berth writes this key only when `persistsTabs` is on. Project lists and boards are cached in memory.

Changing settings from a terminal (`defaults`, the `languageServers` JSON, linter examples): `docs/SETTINGS.md`. `languageServers` is decoded per entry (`LanguageServerEntry.stored`): unreadable entries are skipped, counted in Settings and kept when Settings writes the list back (`storage(_:keeping:)`).