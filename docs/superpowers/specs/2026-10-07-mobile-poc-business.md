# Watchtower on the phone: proof of concept (sub-projects A–C)

**Date:** 2026-10-07 · **Board:** umbrella #420; A #423, B #424, C #425 · **Screens:** the owner-approved canvas https://claude.ai/artifact/Upy7STMTaizvSR75Z4Z2Qd (row 0 is Linking) · **Technical spec:** `2026-10-07-mobile-poc-design.md`

## The problem

Claude Code sessions on the Mac stop and wait for you: a question, a review, a check, or the end of a task. Today you only find out when you are back at the Mac, so the work stands still while you are away. Meetings work the same way. If you are not at the Mac you cannot record one, and the recap waits until you sit down.

## How the phone links to your Mac

1. On the Mac, open Settings → Mobile, turn it on, and click **Use Watchtower on iPhone**. The Mac shows a QR code.
2. On the phone, open the app. It asks you to scan that code.
3. The phone shows **Linked to <your Mac>**, asks to send you notifications, and opens the Now tab.

- **Same Apple ID on both devices:** the scan only confirms which Mac you mean. The data goes through your own iCloud.
- **A different Apple ID on the phone** (for example a work Mac and a personal phone): the code also carries an iCloud share invitation from the Mac. The data then lives in the Mac's iCloud. There is still no server of ours.
- **When linking fails, the app says why:**
  - the phone is not signed into iCloud;
  - the Mac can't show a code because Mobile is off or the Mac is asleep;
  - iCloud is off or blocked by your organisation on that Mac, so mobile isn't available there;
  - the code expired or was already used ("Show a new code on the Mac").
- **Removing a phone:** from the Mac's phone list (Remove), or from the phone itself (Unlink this Mac).

## What you will see and do

- **One push, only when a session asks you something.** If the question is simple, long-press the push and pick the recommended answer. Anything else opens the ask.
- **Now tab:** what is waiting for you across all workbenches, your next meeting with a Record button, and a count of your sessions by state.
- **Workbench tab:** the same panel as on the Mac. The workbench list, each workbench's waiting cards and sessions, and a Sessions | Board switch.
- **Session detail:** what the session is on, its asks, its report, and a timeline. You can tell the session something only if you turned that on for this phone and allowed it once on the Mac. The raw transcript is never shown.
- **Asks:** answer questions, reviews and checklists. Your answer travels the same way as an answer typed on the Mac.
- **Board:** change status and priority, comment, add a target, and start a session on a target. The session window does not jump forward on the Mac unless you ask, and the agent plans first and asks you (on by default).
- **Calendar:** the agenda, event details with prep, Join, and Record. Recording keeps going while the phone is locked. The Mac transcribes it, and the recap and transcript then come back to the phone.
- **When the Mac sleeps:** you can still read what is already on the phone. What you do waits and applies when the Mac wakes. Sessions and transcription run only on the Mac.

## Decisions made

- Product for everyone, with no server of ours.
- Updates arrive in 2–15 s, faster when a session changes state.
- Pushes are sent only for new asks.
- Typing into sessions is off by default. It needs this phone's toggle plus a one-time **Allow** on the Mac, and it falls under a new rule, PROJ-16.
- The phone never answers Claude Code permission prompts.
- Subagent steps stay out of the timeline for now.
- One QR linking flow for everyone, built in A.
- One iCloud container for every build. The Mac side is off until you turn it on, and corp builds show a notice that work data goes to your personal iCloud.
- Native iOS look, orange only for "waiting for you". Tabs: Now, Workbench, Calendar, More.

## Decisions still open

None. A first test run with real devices and two Apple IDs comes before any building. It could still force a choice:

- If iCloud sharing doesn't sync reliably, a phone on a different Apple ID may not be supported in this proof of concept.
- On such a phone, ask notifications may arrive late.

## Out of scope

- D, targets on the phone (#426): paused.
- E, the old tabs (#427): their own spec after A–C.
- #428, chat without the Mac: a separate brainstorm.
- Also out: the raw transcript, permission prompts, "Make target" from meeting action items, and iPad and Android.

## How we know it is done

- **A:** phones on the same Apple ID and on a different one each link by scanning, and show the Mac's status.
- **B:** you answer an ask from the lock screen and the agent continues. You start a session while the Mac's screen stays as it was. You see the session finish within 15 s.
- **C:** you record a meeting with the phone locked, and the recap arrives after the Mac transcribes it.
- **Everything done while the Mac slept applies exactly once.**
