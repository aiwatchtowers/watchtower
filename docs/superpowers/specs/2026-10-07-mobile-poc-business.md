# Watchtower on the phone: proof of concept (sub-projects A–C)

**Date:** 2026-10-07 · **Board:** umbrella #420; A #423, B #424, C #425 · **Screens:** the owner-approved canvas https://claude.ai/artifact/Upy7STMTaizvSR75Z4Z2Qd · **Technical spec:** `2026-10-07-mobile-poc-design.md`

## The problem

Claude Code sessions on the Mac stop and wait for you: a question, a review, a check, or the end of a task. Today you only find out when you are back at the Mac, so the work stands still while you are away. Meetings work the same way. If you are not at the Mac you cannot record one, and the recap waits until you sit down.

## What you will see and do

- **One push, only when a session asks you something.** If the question is simple, long-press the push and pick the recommended answer. Anything else opens the ask.
- **Now tab:** what is waiting for you across all workbenches, your next meeting with a Record button, and a count of your sessions by state.
- **Workbench tab:** the same panel as on the Mac. First the list of workbenches, then one workbench with its waiting-for-you cards and its sessions (state dot, report line, progress). A Sessions | Board switch shows the board.
- **Session detail:** what the session is on, its open asks, its report, and a timeline of what happened. You can also tell the session something, but only if you turned that on for this phone. The raw transcript is never shown.
- **Answer asks:** questions (with the recommended option marked), reviews (read the document, comment on a passage, Approve or Request changes) and checklists. Your answer travels the same way as an answer typed on the Mac.
- **Board:** the target tree with filters (Open, In progress, Blocked, Archive). You can change status and priority, comment, add a new target, and start a session on a target. You choose whether the Mac brings the session window forward (off by default) and whether the agent plans first and asks you (on by default).
- **Calendar:** the agenda, event details with prep and Join, and Record. Recording keeps going while the phone is locked. The Mac transcribes it with the same pipeline as a desktop recording. The recap and transcript then come back to the phone.
- **When the Mac sleeps:** you can still read everything already on the phone. What you do is queued and applies when the Mac wakes, and the app tells you so. Sessions and transcription run only on the Mac.

## Decisions already made

Product for everyone · your own iCloud, no server of ours · updates reach the phone 2–15 s after the Mac sees them, faster on session state changes · pushes only for new asks · typing into sessions is off by default and turned on per phone · the phone never answers Claude Code permission prompts (it says "needs approval on the Mac") · one iCloud container for every build. The Mac hub is off until you turn it on in Settings → Mobile. Corp builds show a one-line notice that work data goes to your personal iCloud · native iOS look, system blue accent, orange only for "waiting for you" · tabs Now, Workbench, Calendar, More (More = Settings for now).

## Decisions still open (recommendation first)

1. **Rule for typing into a session from the phone.** This is a new promise and needs your approval. (a) **Recommended:** a new contract, PROJ-16. It covers only what is new: phone typing works only from a phone you allowed, only while the agent is idle, and never into a permission prompt. Delivery reuses the existing ask-answer rule (PROJ-12) unchanged. (b) Extend PROJ-12 itself to cover phone text.
2. **Allowing a phone to type.** (a) **Recommended:** you turn it on on the phone, then confirm it once on the Mac ("Allow <phone name> to type into sessions?"). (b) The phone toggle alone. With (b), any device signed into your Apple ID could type into sessions.
3. **Subagent steps in the session timeline.** The Mac does not record them today. Recording them needs new Claude Code hook entries (a "Re-run setup" for every workbench and an inventory change). (a) **Recommended:** leave them out of the proof of concept and add them later. (b) Add them now.

## Out of scope

- D, targets on the phone (#426): paused while the targets model is reworked. Only the board's targets are in B.
- E, the old tabs redesigned (#427: Now in full, Catch up, AI Chat, digests, tracks, briefing, day plan, people, ideas): comes after A–C with its own spec.
- #428, chat without the Mac (own API key or long-lived token): a separate brainstorm.
- Also out: the raw session transcript, answering permission prompts, "Make target" from meeting action items (hidden until D), and Android or iPad layouts.

## How we know it is done

- **A:** a signed Mac build and a real iPhone exchange data through your iCloud on day one of the build. The phone shows the Mac's status.
- **B:** you answer an ask from the lock screen and the agent continues. You start a session from the board while the Mac's screen stays as it was. You see the session move to Finished within 15 s.
- **C:** you record a meeting with the phone locked. The recap arrives on the phone after the Mac wakes and transcribes it.
- **Every action you take while the Mac sleeps applies exactly once when it wakes.**
