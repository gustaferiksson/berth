# CLAUDE.md changes for review-panel-flows

- Panel tabs: `ReviewPanelTab` is `changes`, `files` only, a segmented `Picker` (32 pt row, hairline below). A stored `comments` or `preview` falls back to `changes`. `-snapshotReviewPanelTab changes|files`.
- Comments: a glass bar pinned at the bottom of the panel on every tab while any comment is pending: a Comments disclosure (`ReviewModel.showsCommentList`, in memory; the list scrolls past 220 pt, double-click opens the comment, × deletes) and a prominent Send N Comments. There is no Comments tab; the snapshot edit-comment hook sets `showsCommentList` and double-clicks the row at 100,90 (bottom-left origin).
- Preview moved out of the panel into the diff column: `ReviewModel.isPreviewOpen` / `isPreviewSelected` (in memory), a Preview tab after the file tabs (globe, ×) and an Open Preview glass button in the strip when it is closed. Assigning `selectedTabID` deselects it. ⌘W / `Store.closeDiff()` closes it when selected. `-snapshotPreview <address>` opens it first.
- `IconTabBar` is only the session sidebar's status filter now: 24 pt buttons with a 10% rounded fill on the selected one.
