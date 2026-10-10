# Owner asks v2 — fewer asks, one-tap answers, asks on the phone (for the owner)

**Date:** 2026-10-10 · **Board:** #395, #501, #503 (+ #412 keyboard) · **Technical spec:** `2026-10-10-owner-asks-v2-design.md`

## The problem

Every question the agent has for you becomes an ask in the drawer, even "snake_case or camelCase?" asked while you are looking at the terminal. You open a drawer for a one-word answer, the agent files asks you did not need (things it could check itself, process questions with an obvious default), files three asks in a row instead of one, and re-files asks it withdrew. And an ask can only be answered at the Mac.

## What changes for you

**Three levels of question.**
- **Chat** — while you are in the session (its terminal on screen, the Watchtower window in front), the agent may ask a short question in plain text and you answer in the terminal, as in a normal conversation. The end-of-turn check no longer sends it back.
- **Quick ask** — one decision with 2–3 short options. It appears in the banner over the terminal with a button per option (the recommended one highlighted) and **Reply…** for a one-line answer. One tap, no drawer. The same card with buttons sits in the "Waiting for you" stack.
- **Full ask** — a review, a manual check, or several related decisions: the drawer, as today.

**When you are away, nothing waits unseen.** If you are not in the session when the agent asks, it has to file an ask (Quick or Full). If you were in the session but did not answer for **10 minutes**, or you left it (switched session, app or window, locked the screen), the text question turns into a Quick ask by itself, with the same options and a mark "From chat · 12 min". Your one tap goes to the agent the same way answers do today.

**Fewer asks.** The skill gets a "don't ask" list (process questions with a default, things the agent can run or screenshot itself, clarifications the conversation already answers), collects pending decisions into one ask (up to 4 questions), and may re-file a withdrawn ask only as a revision that says what is new — Watchtower refuses a plain re-file.

**Phone-ready.** Each ask carries its level (Quick/Full) and its "from chat" mark in the data, so the mobile app can show a push with the same buttons and send the answer back; the Mac delivers it to the session.

You will need to press **Repair** once on each existing workbench to get the new check and skill.

## Decisions for you

| # | Question | Options | Recommendation |
|---|---|---|---|
| D1 | Where the end-of-turn check runs | (a) Watchtower runs it itself, knowing whether you are in the session; (b) keep Claude Code's built-in check — it cannot see you, so a Chat question is bounced once and the agent spends an extra turn looking you up | **(a)** — no bounce, no extra agent turns, same cost per turn as today |
| D2 | How a 10-minute / left-session question becomes a Quick ask | (a) Watchtower files it itself from the question it read at the end of the turn — nothing typed into the terminal, no agent turn; (b) the app types a nudge into the idle session and the agent files the ask | **(a)** — faster, no visible typing, no extra cost; the agent wakes when you answer |
| D3 | How an ask's level is decided | (a) Watchtower computes it from the shape (one question, ≤3 short options) and stores it; the agent can only force "Full"; (b) the agent declares it; (c) each app (Mac, phone) computes it itself | **(a)** — one rule, one place, the phone reads the same answer |
| D4 | What counts as "in the session" | Recommended: the session's terminal on screen in the focused Watchtower window, with the drawer open counting as in; screen locked, display asleep, app in the background or another session on screen counting as left; a blip under 2 s ignored; an idle keyboard not counted (the 10 minutes covers it) | **as described** |
| D5 | Claude Code's own multiple-choice question tool | (a) keep blocking it always (the app can never answer its dialog for you) and tell the agent to ask in text or file an ask; (b) allow it while you are in the session | **(a)** |
| D6 | An answer sent from the phone | (a) the Mac delivers it to the session at once, like an answer in the app; (b) only the next session's brief shows it | **(a)** |
| D7 | A chat question with no options ("what is the staging host?") after 10 min | (a) a Quick ask with only Reply…; (b) leave it in the terminal | **(a)** |

## Out of scope

The phone app itself, its push service and how it reaches the Mac (this repo only provides the data, the level and two commands to read and answer). Answering Full asks from the phone. Detecting that you are idle at the keyboard. Raising a question whose session was closed. Watchtower withdrawing a raised ask by itself — the agent does that if you answered in the terminal.

## How we will know it is done

- With the terminal on screen and the window focused, a short text question stays in the terminal; with the window in the background or another session open, it comes back as an ask.
- A text question unanswered for 10 minutes becomes a Quick ask with the same options and "From chat · 10 min"; leaving the session does that immediately.
- A one-question ask with up to three options is answered with one click in the banner and reaches the agent exactly as a drawer answer does (including the automatic submit); "Reply…" sends a free answer; other asks open the drawer as now.
- The skill has the three levels, the "don't ask" list, one-ask-for-several-decisions and the re-file rule; Repair installs it on existing workbenches.
- The contracts behind the guard (PROJ-13) and answer delivery (PROJ-12) are rewritten with your approval and their tests are updated, never weakened; the phone contract and a handoff note are written.
- Keyboard: the stack, the drawer and Quick ask buttons work from the keyboard (digits for options), with hints on screen.
