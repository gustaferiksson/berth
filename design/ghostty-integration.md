# Ghostty integration

Moved from CLAUDE.md.

## Config and resources

libghostty-spm points `GHOSTTY_RESOURCES_DIR` at its own bundle, which has no themes, and rejects the whole config on any diagnostic. `GhosttyConfig` therefore inlines the user's `theme = X` file (from `~/.config/ghostty/themes` or Ghostty.app) at the top of a generated config. `theme = light:X,dark:Y` picks by the system appearance at load. `~/.config/berth/ghostty` (Berth-only overrides, Settings > Appearance > Terminal Overrides, `docs/SETTINGS.md`) is appended after the user's lines, so its keys win (a `theme` there drives the app colours too); when libghostty rejects the config with it, Berth rebuilds without it and Settings shows the issue.

## Theme and app colours

App colours come from the resolved Ghostty config (`GhosttyTheme`): colour scheme from background luminance, palette 1/2/3/5/6/13 for closed PR, working and open PR, needs you, merged PR, branch, shell attached (13 falls back to system pink also when it repeats palette 5), each falling back to a system colour below WCAG AA (4.5:1) against the background. Config edits (Ghostty's and the override file, watched under `~/.config`) re-theme live via FSEvents; `reloadTheme` reloads the whole config through `updateConfigSource`.

## Terminal theme

Pass `TerminalTheme()` (empty) to the controller; the package default theme overrides the user's colours.

- The Conversation view uses the terminal font: the configured family, else the bundled JetBrains Mono (Ghostty's default, registered from Resources/Fonts at launch, OFL), at the terminal font size, with font-feature settings applied and no extra line spacing (GhosttyTheme.font).
