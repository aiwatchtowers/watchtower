---
type: bug
title: Chat does not auto-follow a streaming reply
status: done
priority: high
tags: [desktop, chat, scroll, streaming, ux]
context: fix/settings-storage-size-off-main — owner screenshot of the main AI Chat right after sending a message
created: 2026-09-28
---

After the owner sends a message in the main AI Chat, the transcript does not
follow the assistant's streaming reply: the new text grows below the fold and a
"Jump to latest" button appears instead, even though the owner never scrolled
away. The pinned-to-bottom state seems to be lost on send (or the growing
streamed message is not treated as "still at bottom").

Expected (standard chat behavior):
- Sending a message always pins the view to the bottom.
- While pinned, streaming text, tool steps and artifact blocks keep the view
  scrolled to the latest content.
- If the owner scrolls up during streaming, auto-follow stops and they can read
  in peace; "Jump to latest" shows only in that case, and tapping it (or
  scrolling back to the bottom) re-pins.

Check the "at bottom" detection threshold against content that grows inside a
single message (text deltas) rather than only new rows being appended.

> Original note: «написал сообщение в чат и он не фолоапит что бот пишет. Надо чтоб по умолчанию скролило, но я мог бы если что подскролить вверх и читать спокойно»

Resolution: the follow state used to be derived from one number — how far a
trailing sentinel sat below the viewport — so one streamed paragraph taller
than the 40 pt threshold read exactly like the owner scrolling up, and the
state stuck off across sends. `ChatFollowTracker` (WatchtowerCore,
`ChatAutoScrollPolicy.swift`) now reads consecutive measurements of the whole
thread content: content growing below the viewport only moves its bottom edge
and keeps a following view pinned, pulling it down on every growth (streamed
text, tool steps, artifact blocks, action cards alike) and never otherwise; a
scroll up is read from the content's top edge moving down against a baseline
that advances only on a real move, so even a slow sub-point drag adds up and
stops following; scrolling back down near the bottom or tapping "Jump to
latest" re-pins. Starting a turn (send, regenerate, edit, continue) always
re-pins (`turnStarted`). A ⌘K search hit — including one that switches the
conversation in the same update — lands on the message and does not follow;
a plain switch lands at the bottom (`threadChange`, one handler for both).
Pinned by `ChatAutoScrollPolicyTests` (multi-measurement runs: streaming, slow
drag, growth while reading, re-pin on scroll down, overscroll, shrink, reset
following/not following, repin, thread-change classification).
