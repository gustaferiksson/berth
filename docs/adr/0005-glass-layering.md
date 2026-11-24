# 0005 System glass on chrome only, never on content or inside glass

## Context

macOS 26 Liquid Glass should look native. Hand-built materials and tints drift from the system, and glass inside glass reads muddy.

## Decision

The session sidebar column and the Review panel show the system's untinted glass. `glassSidebarTint` hides the list background, and the window behind uses `GhosttyTheme.chrome`. Grouped icon buttons use `GlassCapsule` (one 24 pt capsule). The sidebar footer is one `GlassEffectContainer` holding the usage bar and filter field. The launcher, hover card and toolbar capsules each use a separate, unnested glass surface. Custom SwiftLint rules reject hand-rolled materials, bar backgrounds and colour literals.

Window Background (Settings > Terminal, `windowBackground`) controls the surface behind the detail cards. Theme (`theme`, the default) restores the chrome fill used before #343. Glass (`glass`) opts into regular system glass. The glass extends under the toolbar and scales beyond the window edges so the rim is clipped offscreen. Darker (`darker`) fills the detail column with the cards' theme background colour. The terminal, conversation and diff cards stay opaque in all three modes.

Window Transparency (Settings > Terminal, `windowTransparency`, default 0) makes the window itself translucent. `WindowBackdrop` draws the chrome colour at reduced opacity over a behind-window `NSVisualEffectView`, and `WindowChrome` sets `isOpaque = false`. The desktop shows through behind the sidebar and Review panel in every mode. With transparency above zero, Theme reveals the window backdrop and Darker fades its fill to an opacity of `1 - windowTransparency`. Glass keeps the system material at its own opacity. The terminal ignores Ghostty's `background-opacity`.

Details: design/flows-sidebar.md (Glass).

## Rejected alternatives

- Hand-rolled materials, tints or bar backgrounds (now lint errors).
- Glass as the terminal or diff's own background. Opaque cards keep content legible.
