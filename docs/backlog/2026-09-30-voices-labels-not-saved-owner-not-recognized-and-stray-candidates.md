---
type: bug
title: Voices labels not saved, owner not recognized, stray people in the picker
status: done
priority: high
tags: [voice-registry, desktop, transcription, diarization, ux]
context: docs/chat-projects-vision — backlog collection session, item 7 (owner screenshots of Voices → Queue and its person picker); checked against the live DB (redacted here)
created: 2026-09-30
---

The owner labeled the speakers of the last two recordings in the Voices Queue,
yet every card still says "Not recognized", the owner's own voice is not
recognized, and the person picker offers people who were not in the meeting.
What the live database shows (read-only check, 2026-09-30):

**1. The owner's labels never landed.** All 8 `voice_label_queue` rows for the
two recordings are still `status = pending`, `resolved_at` empty, and
`voice_samples` holds only the 4 rows migration `00080` seeded — no new sample
from any confirmation. In the screenshot each card shows a person picked in
the dropdown, but Confirm looks greyed out. Either:
- picking a person in the dropdown is not a save and the owner never pressed
  Confirm (the greyed look may just be `.borderedProminent` in a non-key
  window) — a UX trap: selecting should be enough, or the card must make the
  unsaved state obvious; or
- Confirm is really disabled / the confirm write fails silently.
Reproduce first. Either way the owner's work was lost without any signal.

**2. Why the owner is not recognized.** The registry has exactly one sample of
the owner: the old single-centroid `voice_prints` embedding from 2026-08-03,
carried over by `00080` as an `owner` anchor with `speech_sec = 0`. A single
old centroid is a weak reference (the POC reached 99% precision only with
many owner-verified clusters). Also the meeting was in an office meeting room
(the event books a room resource): 3 of 4 clusters are channel `room`, so the
mic-dominance hint for «Я» does not separate the owner from colleagues at the
same table. Nothing learned from the owner's labels (see 1) could help.
The research POC's ~92 owner-verified clusters were never seeded into the
registry (the owner-run research-seed script is still pending, per the
voice-registry PR notes) — seeding them would fix most of this at once.

**3. Stray people in the picker.** The dropdown lists the event's attendees
plus every person in the registry. The extra names are the other 3 people of
those 4 migrated `voice_prints` rows — voices named manually in the old
rename flow in August, unrelated to this meeting. Options: show attendees
first, then a separator and "Other known voices", or show registry people only
when their voice actually scores close to the cluster. Also the owner appears
in the list under a corp email — make sure the owner row reads as «Я / me»,
not as a colleague.

Also seen: the owner is listed as a normal candidate, so confirming the
owner's voice may go down the colleague path; check that an owner confirm
creates an owner `anchor` sample as the spec requires.

> Original note: «опять же я проставил, но что за хуйня? Почему оно даже меня не распознало. Плюс оно сюда левых людей втащило. <picker screenshot> — [two colleagues] — какого хуя они вообще тут. Каким ветром?»

**Fixed (fix/voices-confirm):** (1) Root cause: the owner's picks were never
confirmed — not a broken write. Reproduced against a copy of the live
database: `VoiceRegistryCenter.confirm` on a real pending task wrote the
owner anchor and closed the task, and a hosted `VoicesWindowView` with that
data accepted a picker selection plus Enter and closed its task. Not one of
the 37 pending tasks had ever been closed by any disposition, so Confirm
was simply never pressed: picking a name looked like the save. Queue and Train
cards now show "Not saved until you press Confirm" whenever a pick is
confirmable. Still open (deferred): an unconfirmed pick lives only in the
card's view state, so closing the window or switching segment drops it
without a prompt — the hint makes that visible, it doesn't prevent it.
(2) Not a code defect: the owner had one 2026-08 anchor, and import never
creates owner samples (registry invariant 2), so the research seed cannot
teach the owner's voice — only confirms (Queue/Train) can. With (1) fixed,
each confirm of the owner's own voice adds an owner anchor. (3) The picker
offered every registry person (31 after the seed import). It now shows titled
groups: "In this meeting" (the owner as "Me", then invited attendees —
unregistered first, then registered), "Similar voices" (registry people
whose nearest *active* sample scores ≥ `unsureFloor` against the cluster,
closest first) and "Other known voices". The owner is never offered as a
colleague: a registry or attendee row carrying a connected Google account's
email reads "Me (…)" and comes first (Train's picker flags it the same way).
Owner call left open: "Other known voices" still lists the rest of the
registry (grouped and labeled, not removed), since any registry person may be
the speaker. The owner confirm path already mints an `owner`/`anchor`
sample for the owner's person (unchanged; `VoiceLabelingQueries.confirm`).

