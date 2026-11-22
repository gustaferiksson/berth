# 0002 Keep every terminal surface mounted

## Context

Removing a `TerminalSurfaceView` tears down its shell. Tabs switch constantly, and Review's split and orientation changes move views around.

## Decision

Every tab's surface stays mounted (opacity 0 and `isSurfaceVisible = false` while hidden). `TerminalSplit` is an `NSSplitViewController` whose items are `NSHostingController`s, so the terminal item and its surfaces are created once; Review's below-diff mode flips `isVertical` in place instead of recreating items. Because AppKit picks a drag destination by registered types and ignores opacity, `VisibleDropTerminalView` unregisters its drag types while hidden.

## Rejected alternatives

- Mounting only the selected surface and recreating the others on selection: kills the shell and its scrollback on every switch.
- Letting a hidden surface keep its drag types: a hidden tab stacked above took the drop.
