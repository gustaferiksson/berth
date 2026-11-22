# 0001 Lists for the sidebar and Review, plain VStack for the remote transcript

## Context

The session sidebar needs sections that collapse, hover and selection fills, drag reordering and keyboard navigation over hundreds of rows. A `ScrollView` with `LazyVStack` was tried in #35.

## Decision

The sidebar is a `List` in the `.sidebar` style and every section is a `Section(isExpanded:)`, so collapsing is the system disclosure with no custom animation. Rows draw their own selection and hover fills (`RowChrome`). Review's lists are `.plain` Lists with zero row insets. Berth Remote's transcript is a plain `VStack`.

Details: design/flows-sidebar.md, design/review-implementation.md, design/remote.md.

## Rejected alternatives

- `ScrollView` + `LazyVStack` for the sidebar (#35): expand and collapse got worse on screen. Offscreen snapshot timings do not reflect on-screen feel, so judge this on screen.
- `LazyVStack` for the phone transcript: it re-placed its items forever (main thread at 100%) when the keyboard came up or a turn expanded while scrolled up.
- The system `Section(isExpanded:)` header in Review: it ignored clicks on screen, so Review's headers are one `Button` with their own chevron.
