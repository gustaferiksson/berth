# 0005 System glass on chrome only, never on content or inside glass

## Context

macOS 26 Liquid Glass should look native. Hand-built materials and tints drift from the system, and glass inside glass reads muddy.

## Decision

The session sidebar column and the Review panel show the system's untinted glass: `glassSidebarTint` only hides the list background, and the window behind is `GhosttyTheme.chrome`. The terminal and the diff stay opaque cards. Grouped icon buttons use `GlassCapsule` (one 24 pt capsule). The sidebar footer is one `GlassEffectContainer` holding the usage bar and filter field. The launcher, hover card and toolbar capsules are their own glass surfaces, never nested in another glass surface. Custom SwiftLint rules reject hand-rolled materials, bar backgrounds and colour literals.

Details: design/flows-sidebar.md (Glass).

## Rejected alternatives

- Hand-rolled materials, tints or bar backgrounds (now lint errors).
- Glass behind the terminal or diff: content stays opaque for legibility.
