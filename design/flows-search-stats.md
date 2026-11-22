# Search index and Stats

Moved from CLAUDE.md.

## Search index

Search index (`TranscriptSearchIndex`, built lazily on the first search or Stats, then updated on every scan, one document per file path): per listed transcript, typed prompts and non-sidechain assistant text blocks only (no tool results, meta, commands, task notifications or compact summaries), capped at 512 KB per session, stored once as-is and once folded (case and diacritics) and matched as an AND of words with `memmem`. Lines are streamed in 1 MB chunks and prefiltered on raw bytes before any JSON decode (that took the build from 36 s to under 3 s).

Growth is read from the last consumed offset; a moved or shrunk file is re-read. Files are indexed newest first in batches of 10 off the main thread, and results refresh after each batch ("Indexing 60/234" in the footer). Queries are debounced 100 ms. The same pass reads every file to the end (text stops at the cap, scanning doesn't) and keeps each typed prompt's time and each assistant message's `message.usage` (input, output, cache read, cache write tokens; streaming repeats a record per content block with the same `message.id`, so only the first of a run counts, carried across incremental reads).

Subagent transcripts (`<slug>/<sessionId>/subagents/agent-*.jsonl`, all `isSidechain`, about half the tokens and 2.2 of the 3 GB) are indexed for usage only, attributed to the parent session, after all main transcripts. The prefilter checks `"type":"user"` first: tool-result lines are most of the bytes and match it early. Measured on 234 sessions + 888 subagent files (3 GB): Release 2.1 s for the main transcripts, 4.8 s with subagents (was 2.6 s, main only and stopping at the text cap); Debug 5.5 s; ~16 MB of text (stored twice), ~25 MB footprint growth, 10-100 ms per query in Debug.

## Stats

Stats (⇧⌘S, View ▸ Show Stats, also in the palette): a `Window` scene `stats` (suppressed at launch, never restored) opened via `Store.isStatsRequested` → `ContentView`'s `openWindow`, so `AppAction` stays the one source. Swift Charts over the last 30 local days, recomputed off the main thread only when the index is idle: tokens per day (input + cache writes + output; cache reads are ~97% of all tokens so they are only in the totals line), stacked by project (folder name, top 6 by tokens + Other), with a hover tooltip; sessions per project; a weekday × hour heatmap of typed prompts; tiles for sessions and prompts this week (calendar week), longest session (active time: gaps of at most 15 min between prompts and replies) and most active project (prompts).

Series colours are `GhosttyTheme.series`: palette 6/1/4/3/5/2 (ordered for colour-blind separation of neighbours, worst adjacent ΔE 10.8 on Atom One Dark), each falling back to a system colour below 3:1 or when the theme repeats it; Other is the foreground at 35%. Dedup is per file, so message ids repeated across files (forked or copied transcripts, a symlinked one; 214 ids) count once per file: 30-day output reads ~0.8% above a global id dedup (15.02M vs 14.91M), checked with Python.
