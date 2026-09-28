---
type: bug
title: Meeting card, Join button and recorder labels are truncated
status: done
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
   under the window's right edge. (sub-item 3 fixed in fix/bl-chat-scroll-overlay)

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

**Resolution:** Fixed sub-items 1, 2, 4 and 5 (sub-item 3, the recorder capture
pill, landed separately in PR #13 on `fix/bl-chat-scroll-overlay`):
- Sidebar next-meeting card (1, 2): the countdown is now a single-line,
  pure-function-rendered string (`SidebarView.nextEventCountdownText`) that
  drops seconds once a minute or more remains and shows seconds only inside
  the final minute, instead of SwiftUI's unbounded `Text(_, style: .relative)`
  wrapping across three lines. The shared `JoinButton` gained `.fixedSize()`
  so it keeps its "Join" label at intrinsic size instead of being compressed
  down to "J…" next to the title `Text`.
- Reminder banner Join button (4): the ad-hoc `Button("Join")` in
  `UpcomingMeetingBannerView` (a separate code path from `JoinButton`, as
  suspected) got the same `.fixedSize()` fix in place, keeping its own
  `dismissBanner` side effect rather than switching to the shared component.
- Doubled "v" version (5): `Constants.appVersion` now strips a leading
  "v"/"V" at the source (`Constants.stripLeadingV`) so every caller —
  including `StatusBarView`, which prepends its own "v" — is protected, not
  just the one display site.

Tests: `SidebarSectionTests.testNextEventCountdownShowsWholeMinutesAboveOneMinute`,
`testNextEventCountdownShowsSecondsInTheLastMinute`,
`testNextEventCountdownAtOrAfterStartReadsStartingNow` pin the countdown text;
`ConstantsVersionTests` pins the "v" stripping. `JoinButton`/
`UpcomingMeetingBannerView`'s `.fixedSize()` layout fixes have no pure-logic
surface to unit-test (SwiftUI layout, no XCUITest harness in this repo per
`project_uitest_vm_followup`) and were verified by reading the resulting
layout precedence, matching the same fix shape already used elsewhere in the
file.

Resolution (sub-item 3 only): the recording capsule in
`RecordingIndicatorView` is now `.fixedSize()` — it always takes its ideal
width, so the Stop button's label can no longer be compressed away and the
button no longer spills past the capsule's right end. Layout-only change, no
unit test (not observable without a rendered snapshot); verify by eye while
recording. If the pill still overflows the window with the fix, the parent
(`NavigationRoot` laid out wider than the window) is the next suspect.
