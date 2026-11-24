# 0011 Browser tabs belong to sessions or the global pinned group

## Context

Links opened while working in Berth often belong to one Claude session, such as a pull request or a local preview. A few pages are useful across sessions. The browser shares the window with the terminal, so the tab layout also determines how much width is available to the web view.

## Decision

Pinned tabs are global. Other tabs belong to the current Claude session, keyed by its session id or by the Berth tab UUID until the session id is known. When that key changes, the model moves the session tabs and their selection to the new key. Closing a Claude tab releases its browser web views and keeps the tab records for when the session reopens. Archiving the session discards its browser tabs. Closing an individual browser tab unloads and removes it.

When `persistsTabs` is enabled, the model saves tab URLs and titles in UserDefaults under `browserPinnedTabs` and `browserSessionTabs`. The session value is keyed by session id. Blank tabs are omitted and selection stays in memory.

The Safari 26-style Liquid Glass header sits on the window background above the opaque web card. Back and Forward have their own circles, followed by the pinned tabs as favicon or initial circles. Session tabs share one capsule, with equal-width segments, hairline separators away from the active tab and an inset tint for the selected tab. The header gives tabs priority over the address field, with segments ranging from 90 to 140 pt and a trailing fade when more tabs can scroll into view. The tab overview menu lists every pinned and session tab, including tabs outside the visible area.

The address field has its own capsule. It shows the selected page's host or title and opens the full URL for editing on click or ⌘L. Reload or Stop sits at the trailing edge. Loading progress fills the address capsule and appears faintly in the active session tab. Share, New Tab, Downloads when present, and Tab Overview use individual glass circles. Below 640 pt, the header moves Share, Open in Default Browser, Copy Link, Back and Forward to the end of Tab Overview. Browser mode hides the mode sidebar and keeps the window toolbar switcher available.

Hovering a session tab reveals its close button. Dragging onto another tab reorders or moves the dragged tab into that group. Dropping at the end of the session capsule or onto New Tab unpins a tab. The context menu also includes pin, unpin and close actions. ⌘1 through ⌘9 and Control-Tab use the order shown in the header.

## Rejected alternatives

- One global list would mix short-lived pages from unrelated sessions and make them harder to find again.
- Vertical tabs in the mode sidebar took a full column from the web view in the layout the user tried. The open tabs usually fit in a single header row.
- Putting the address field inside the selected tab changed tab widths on selection and moved the address field with the selected tab.
