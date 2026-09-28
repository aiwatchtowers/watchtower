---
type: bug
title: Recording pills cover the chat composer text
status: open
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
