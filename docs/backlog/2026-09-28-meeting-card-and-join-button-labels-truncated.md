---
type: bug
title: Meeting card, Join button and recorder labels are truncated
status: open
priority: med
tags: [desktop, sidebar, calendar, recorder, layout, ui]
context: fix/settings-storage-size-off-main — owner screenshot of the bottom of the main window during a recording
created: 2026-09-28
---

Several labels at the bottom of the main window are clipped:

1. **Next-meeting card in the main sidebar footer** (above "Jira connected"):
   the meeting title is cut to a few characters ("<title prefix> Ta…") and the
   countdown wraps over three lines ("34 min, / 7 secs"). The countdown also
   shows seconds, which makes the text wider and jittery — minutes are enough
   until the last minute.
2. **Join button on the same card** is squeezed to "J…" — the button label
   does not fit next to the title. Either give the button a fixed minimum width
   and truncate the title instead, or drop to an icon-only join button with a
   tooltip.
3. **Recorder capture pill** (bottom right): the trailing red control is a
   blank red block — its label (Stop?) is clipped, and the pill itself runs
   under the window's right edge.

4. **Meeting reminder banner** (the floating "<meeting title> · in 1:55"
   popup with Record and close): the button between the title and Record is
   an empty grey capsule — no label, no icon. Almost certainly the same Join
   control losing its label (same shape as item 2), which points at a shared
   join-button component rendering its title as empty/clipped rather than at
   each call site. The banner also floats over the chat transcript.

Also visible in the same status bar: the version reads "vv0.10.1-…" — a
doubled "v" prefix (the build string already starts with "v" and the view
prepends another).

Expected: the reminder banner's Join button shows its label; sidebar footer card lays out at the sidebar's minimum width with a
single-line countdown and a readable Join control; the recorder pill fits in
the window; the version shows a single "v".

Related: [[2026-09-28-recording-pills-cover-chat-composer]].

> Follow-up note (reminder banner screenshot): «в догонку к какому-то пункту — поебаны надписи»

> Original note: «чет надписи поебаные на митах и на джойне поебаны»
