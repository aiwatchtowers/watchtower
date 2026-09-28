---
type: bug
title: Recording pills cover the chat composer text
status: done
priority: med
tags: [desktop, chat, recorder, ui, overlay]
context: fix/settings-storage-size-off-main — owner screenshot of the main AI Chat while a meeting recording was running
created: 2026-09-28
---

While a meeting is being recorded, the floating recorder pills rendered by
`RecordingIndicatorView` (the active capture pill with the timer, plus one pill
per queued post-processing job, e.g. "<channel> · Queued") sit in the
bottom-right corner on top of the main AI Chat composer (`ChatInput`). They
overlap the text field and the send/dictation buttons, so the owner cannot see
the end of what they are typing.

Expected: the pills never cover interactive content. Options to weigh: reserve
space for the indicator (inset the chat content/composer by the stacked pills'
height while any are visible), move the indicator to a spot that is not the
composer's (e.g. top trailing / toolbar / sidebar footer), or collapse the job
pills into a single compact badge when the composer is focused. Check every
screen with a bottom composer (main chat, Discuss chats), not just the main one.

> Original note: «чипсы закрывают чат хуй пойми что я там написал»

Resolution: space is reserved rather than the indicator moved, so it stays
visible from every screen. `RecordingIndicatorView` measures its pill stack
and reports `RecordingIndicatorInset.reserved(stackHeight:expandedPanelHeight:)`
to the root view, which injects it as the `recordingIndicatorInset`
environment value. Only the collapsed pills reserve space; the expanded
live-transcript panel is a transient overlay the owner opened and may cover
content. Screens opt in with `.clearsRecordingIndicator()` on their
bottom-most content: the main chat composer (`ChatComposerView`, model pill
included), the target chat pane (below its error labels), the meeting chat tab
(`RecordingChatTab`) and the idea/decision detail panes (below the action bar
under the Discuss input). The shared `ChatInput` reserves nothing, so sheets,
onboarding and the setup assistants are unaffected. Pinned by
`RecordingIndicatorViewTests` (reservation arithmetic incl. the expanded panel,
and a source scan pinning exactly those five call sites). Not covered: the
target extraction pill (`ExtractIndicatorView`, same corner, fixed 72 pt
offset) — separate indicator, not part of this report.
