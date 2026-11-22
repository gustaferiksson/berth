# 0003 Keep every TextKit 2 layout fragment in the Review diff

## Context

Review's two diff views rely on arithmetic row positions (`top(ofRow:)`) so inline views, minimap and ruler never query layout. TextKit 2's `layoutViewport` flushes fragments outside the viewport, which come back at estimated positions off `top(ofRow:)`. NSTextView's `textContainerOrigin` getter (also through `super`) then lays out the whole document again, which caused 1.6 s stalls on many frames when scrolling a 29k-line file (a text view frame that changed almost every frame from estimated usage bounds, then a full `ensureLayout` and a full rendering-attributes pass; findings of 2026-11-18). Reading `NSTextView.layoutManager` silently switches the view to TextKit 1.

## Decision

`makeSide` switches each text view's layout manager to `ReviewTextLayoutManager` with `object_setClass`. Its no-op override of the private `flushTextLayoutFragmentsFromLocation:direction:` keeps every fragment, and both sides lay out fully once (`ensureLayout`, about 70 ms per 5,000 lines), so their heights match and scroll sync is the clip view's y. `ReviewTextView.layoutManager` returns nil so nothing reads the TextKit 1 one.

Risk: if a macOS release renames that selector, the stalls return. A `-snapshotReview` wheel scroll through a large package-lock file shows it (see docs/SNAPSHOTS.md); do not run it on every change.

## Rejected alternatives

- Overriding the `textContainerOrigin` getter, or pinning the text view's frame: left jumps and the document end at estimated positions.
- Letting TextKit 2 flush and re-estimate (the default): the 0.45 s per side scroll stall, later 1.6 s stalls.
