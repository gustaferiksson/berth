# 0005 System glass on chrome only, never on content or inside glass

## Context

macOS 26 Liquid Glass should look native. Hand-built materials and tints drift from the system, and glass inside glass reads muddy.

## Decision

The session sidebar column and the Review panel show the system's untinted glass: `glassSidebarTint` only hides the list background, and the window behind is `GhosttyTheme.chrome`. The detail column shows the same glass full-bleed behind its cards (`.glassEffect(.regular, in: .rect)` ignoring the safe area, so it also runs under the toolbar), so the gaps around the cards read as the same surface as the sidebars at any Window Transparency; the terminal, conversation and diff stay opaque cards on top of it, so no glass sits inside glass. Grouped icon buttons use `GlassCapsule` (one 24 pt capsule). The sidebar footer is one `GlassEffectContainer` holding the usage bar and filter field. The launcher, hover card and toolbar capsules are their own glass surfaces, never nested in another glass surface. Custom SwiftLint rules reject hand-rolled materials, bar backgrounds and colour literals.

Window Transparency (Settings > Terminal, `windowTransparency`, default 0 = opaque) makes the window itself translucent: `WindowBackdrop` is the chrome colour at reduced opacity over a behind-window `NSVisualEffectView`, and `WindowChrome` sets `isOpaque = false`. The desktop then shows through the gaps, the sidebar glass and the Review panel glass. System glass has no tunable transparency, so the slider acts on the window behind it, not on the glass. The terminal and the diff stay opaque whatever the setting, and the terminal does not follow Ghostty's `background-opacity`.

Details: design/flows-sidebar.md (Glass).

## Rejected alternatives

- Hand-rolled materials, tints or bar backgrounds (now lint errors).
- Glass as the terminal or diff's own background: content stays opaque for legibility (glass behind the gaps only is the decision above).
- A flat `chrome` fill in the detail column: it read darker than the glass sidebars.
