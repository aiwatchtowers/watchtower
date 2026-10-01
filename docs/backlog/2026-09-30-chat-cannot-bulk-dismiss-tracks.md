---
type: idea
title: Chat cannot bulk-dismiss tracks
status: open
priority: med
tags: [chat, agent-actions, tracks, bulk, desktop]
context: docs/chat-projects-vision — backlog collection session, item 5 (owner screenshot of the main AI Chat)
created: 2026-09-30
---

The owner asked the main AI Chat to "dismiss every track except the newest one,
start from scratch". The assistant had to refuse: from chat it can only create
and read tracks (`create_track` is the only track write tool, `internal/tools/tracks.go`),
it cannot close or dismiss one. It also noted it could not even list them all —
the first 200 active tracks did not fit into one answer — and suggested the
owner either click through the Tracks tab by hand or ask the developers for a
bulk archive. On a real install there are well over a thousand tracks, almost
all `origin = auto`, so doing it by hand is not realistic.

What should work:

- **A chat write tool to dismiss tracks**, e.g. `dismiss_tracks` taking either a
  list of ids or a filter (all except ids X, `origin = auto`, older than a date,
  no updates since…). It goes through the agent-actions registry like every
  other write: one proposal card that states the count ("Dismiss 1 284 tracks,
  keep #N") with a preview of a few titles, applied on Approve, exactly once.
  Default trust `ask`; a bulk destructive op should probably never auto-execute.
- Dismiss = the existing soft dismiss (`dismissed_at`, `TrackQueries.dismiss` on
  the Swift side), non-destructive and reversible — not a hard delete. The Go
  side needs its own writer for it (today the dismiss is Swift-only).
- **A count/filter read path** so the assistant can answer "how many tracks,
  which kinds" without paging 200 rows into its context.
- In the Tracks tab itself: multi-select + "Dismiss selected" / "Dismiss all
  auto tracks", so the owner is not dependent on chat for this.

Related thought: the fact that auto tracks pile up into the thousands is itself
worth a look (auto-expiry of stale auto tracks?), separate finding if needed.

> Original note: «надо чтобы умел такое делать» (with screenshot: «а давай все треки кроме последнего ебнем. Я ебал вникать что там. Начнем с нуля»)
