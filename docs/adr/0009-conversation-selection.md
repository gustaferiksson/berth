# 0009 One selection across the Conversation transcript

## Context

The Conversation transcript is a `LazyVStack` of separate views: each reply is its own TextKit 2 `ConversationNSTextView` (one per reply since #326), prompts were SwiftUI `Text` with `.textSelection`, and tool rows, folds and cards sit between them. `NSTextView.mouseDown` runs its own tracking loop and only selects inside itself, and AppKit has no selection that spans views, so a drag stopped at the edge of the item it started in, and Select All and Copy only saw that item. #326 merged paragraphs, code blocks and tables of one reply into one view, which fixed selection inside a reply but not across replies, prompts or tool rows.

## Decision

`ConversationSelection` (one per transcript: the Conversation view and the subagent view) owns the selection in model terms: an anchor and a focus, each an item id and a character offset, where the items are the turn prompts and replies in model order. Coordinated text views handle single clicks and drags themselves instead of calling `NSTextView.mouseDown`: mouse down sets the anchor (Shift moves the focus), drags hit-test the window point against the mounted text views in item order (a point between items lands at the start of the next one) and autoscroll, and every mounted view draws its own slice of the range, so all slices share one selection colour. A view mounted later by `LazyVStack` draws its slice when it registers. Copy and Select All go through the responder chain to the coordinator, which builds the text from the model's rendered strings, so items `LazyVStack` has unmounted still copy. Double and triple clicks and link clicks still go to `NSTextView` and are adopted afterwards.

Prompt bubbles are `ConversationNSTextView`s too, sized to their text, with image tags as attachments that copy as their `[Image #N]` token. Tool rows, folds, cards, shell output and diffs stay outside the range: a drag passes over them and the copy skips them. Character positions come from `NSTextLayoutFragment` and `NSTextLineFragment`; `layoutManager` is never read (docs/adr/0003).

`-snapshotConversationSelect` (docs/SNAPSHOTS.md) proves it offscreen: synthesized mouse events sent to the window, Copy and Select All through the responder chain, a private pasteboard, and a heavy-fixture Select All that covers unmounted turns.

## Rejected alternatives

- One `NSTextView` for the whole transcript, with tool rows, folds, cards, approval and images as attachment view providers: native selection for free, but every interactive row would become an attachment with its own sizing and state, and the transcript would lose `LazyVStack` laziness, which the session switch times from #374 depend on.
- Per-item `.textSelection` or `NSTextView` selection: cannot cross items (#326 shipped this and selection still stopped at each reply).
- A SwiftUI drag gesture over the transcript: it does not know text positions, and it competes with the scroll view and the row buttons for the mouse.
- Native `NSTextView` selection in every view: views that are not first responder draw it in the inactive grey, so one drag showed two colours.

## Consequences

A drag has to start on text, not in the gap between items or on a tool row. Dragging text out of the transcript is not supported.
