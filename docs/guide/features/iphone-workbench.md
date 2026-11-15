# iPhone: the workchat

On the Watchtower iPhone app, a Workbench session opens as its chat: what you and the agent said, the prompts and asks waiting on you, and a field to write to the session. It is for anyone who already linked a phone (see [iPhone](iphone.md)).

## Why use it

You leave your desk while an agent works through a target. On the phone you follow its progress, add "and keep the old header" while it is still busy, and answer its question when it stops.

## How it works

The phone never gets terminal output. The Mac sends the session's dialog only while the screen is open, plus five minutes, and refreshes it every few seconds while the agent works. You see your lines, the agent's text, subagents and Watchtower's notes, never tool calls; the newest 300 entries, with **N earlier messages — open on the tower** above them.

A Claude Code session takes your line while it works and reads it at its next step. A Codex session takes your line when it is idle: while it works, the Mac holds the line and sends it once Codex stops (an older Mac shows no field for Codex: write to it on the Mac). If the Mac refuses a line, the line shows the Mac's reason, for example **The session is not running on your tower**. Writing needs **Type into sessions from this phone** and the Mac's **Allow…**; see [Let the phone do more](iphone.md#let-the-phone-do-more).

## Using it

### Now and sessions
<!-- learn
id: iphone-now-answer-chips
title: Answer from Now in one tap
text: A question's suggested answers are chips on the phone's **Now**; finished sessions move to **Ended**.
area: iphone
level: basics
kind: feature
since: next
-->

**Now** starts with your tower: **MacBook Pro · online**, or **asleep · last seen 40 min ago** once its heartbeat is over 35 minutes old. Then:

- **Waiting for you**, newest first across workbenches: asks, permission prompts, failed runs you can **Continue**. A question's suggested answers are chips, one tap each; with many or long answers, **Answer…** opens the ask. Once answered, the row shows **Sending answer…**, **Answer waiting to send**, or **Answer not delivered** with **Retry**. The first 20 show; the rest are **N more on your tower**.
- **Working**: sessions whose agent is working, each with its timer (**as of 40 min ago** while the Mac is asleep).
- **Ended**: sessions that stopped, finished or failed in the last 24 hours. A session with an open ask shows only as that ask. **Clear** hides them all on this phone; touch and hold a row for **Seen** to hide one.
- **Next meeting**, with **Record** from 10 minutes before it starts to 10 minutes after.

The **Now** tab's badge counts what waits for you on the tower on screen; the app icon's, on all your towers.

A workbench opens on its sessions: **Waiting for you** (an ask, a permission prompt, a check, a failed session to continue), **Working**, **Ended** (stopped, finished or failed in the last 24 hours), then **N older** folded. **N closed** at the end holds answered asks. The board's counts show on **Board**; a group there counts its sub-targets as **0/2 · 1 archived**: done of those on the board, then those in the archive, and **N more on the tower** for any the phone does not hold.

### Follow a session
<!-- learn
id: iphone-workchat
title: Steer a session from your iPhone
text: Tap a session on the phone to follow its chat, answer what waits and send it a line while it works.
area: iphone
level: next
kind: feature
since: 0.26.0
replaces: [iphone-session-chat]
changed: A session's chat on the phone now takes your lines and answers.
-->
<!-- learn
id: iphone-session-next-step
title: See what a session needs next
text: A session on the phone ends with a card: its summary and **Report**, or **Continue** after an error.
area: iphone
level: next
kind: tip
since: next
-->

Tap a session in **Now** or a workbench. The top shows the workbench, the title and one state line: a timer like **Working · 3:14** while the agent works, an age like **Needs approval · 1m** while it waits on you. Your lines sit on the right, the agent's text on the left. **Brief** opens what the session was told at start, and a subagent row opens that subagent's own chat, which is read-only.

Under it, once the turn is over, a card says what's next, even before the chat loads: a finished session's summary, PR and **Report**; after an error, **Continue** (sends "Continue") and **New session** on its target; a session no longer running, **New session**. The phone can't restart a session.

### Answer what waits at the bottom

A permission prompt and the session's open asks sit at the end of the chat. **Allow once** and **Deny** answer the prompt (see [iPhone: permission prompts and interrupts](iphone-agent-prompts.md)). A question with suggested answers takes one tap; other asks have **Open** for the full form.

Under its title the full form has **Open session**, which goes to the chat that asked, and **Task #N** for its board target; each shows only when the phone has it. If you had that chat open in the last few minutes, the agent's last message before the ask shows above the question.

### Write to the session
<!-- learn
id: iphone-write-to-codex
title: Write to a Codex session from the phone
text: Send a line to a Codex session from the phone; the Mac hands it over once Codex finishes its turn.
area: iphone
level: next
kind: tip
since: 0.27.0
-->

Type into **Message the session…** and send. Your line shows under it:

- **Queued · the agent reads it at its next step**: a Claude Code session took it while working.
- **Sent**: the agent was idle and got it at once.
- **Queued · sends when the agent stops**: the Mac holds it until the session can take it, with **Cancel**.
- **Typed into the session — press Return on the tower**: text was already typed there.

### Stop, finish or see the report

The **⋯** menu has **Stop**, **Finish** (asks the agent to wrap up), **Interrupt**, **Report and timeline** and **Open board target**. A Codex session takes no **Interrupt** from the phone; stop it on the Mac. The report shows the targets' progress, the pull requests and the session's milestones. Tasks not done yet whose branch is already merged into the branch of the task above them are counted apart, as on the Mac: "1 / 3 targets · 1 merged".

### Find a target on the board
<!-- learn
id: iphone-board-find
title: Find a task on the phone's board
text: Search the phone's **Board** by title, `#number` or branch, or tap **Waiting for me** for what needs you.
area: iphone
level: next
kind: feature
since: next
-->

The **Board** opens on **Waiting for me** (an ask or permission prompt on the target or its session), else **Sessions running**, else **All**. **High**, **Blocked**, **Done** and **Archive** sit beside them. Search by title, `#number` or branch covers the whole board, archive too. Lanes follow the Mac's columns. Under **All**, groups and the **Backlog** and **Done** lanes start folded; the phone remembers what you open.

### Run an automation

<!-- learn
id: iphone-workbench-run-automation
title: Run workbench automations from iPhone
text: Open a workbench's **Automations** tab on the phone and press **Run**; the Mac runs it now.
area: iphone
level: next
kind: feature
since: 0.26.2
-->

A workbench with automations has an **Automations** tab beside **Sessions** and **Board**. **Run** starts one on the Mac right away, the same as **Run now** there. A recipe that asks before it runs asks on the phone. Each row shows its last run, and **Running** while one is in progress. Only running works from the phone: confirm, edit or turn recipes on and off on the Mac, and read their results in the Mac's **Inbox**. Running needs the same allow as starting sessions (see [Let the phone do more](iphone.md#let-the-phone-do-more)).

### Keep the Mac awake for the phone
<!-- learn
id: iphone-keep-mac-awake
title: Keep the Mac awake for the phone
text: While a session runs and the phone is in touch, the Mac stays awake; switch it in Settings → **Mobile**.
area: iphone
level: power
kind: tip
since: 0.26.0
-->

While a session runs and the phone has been in touch in the last 24 hours, the Mac does not sleep on its own. Turn this off under Settings → **Mobile** → **Keep this Mac awake for the iPhone**. A closed lid on battery still sleeps it.

## When it's empty or wrong

- **Asking your tower…** then **Your tower has not sent this chat yet. Is it awake?**: it is asleep or offline; the chat appears once it answers.
- **Unlock this iPhone to see the chat.**: the chat is sealed until the phone is unlocked.
- **<tower> is asleep · last seen 40 min ago. New lines go when it wakes.** above the chat, **Waiting for your tower** under the field and your line, and a state line that reads **as of 40 min ago**: no check-in for over 35 minutes. The line goes when it is back.
- **Answer the request above** or **Needs approval on the tower** instead of the field: the agent waits on a permission prompt, and nothing else goes to it until that is answered.
- No field at all: typing is off for this phone; the bar says why, with **Turn On**. On a Codex session with a Mac that has not been updated, the bar says **Write to Codex sessions on the tower.**
- **Confirm on the tower** beside an automation: it changed since you last confirmed it; confirm it in its Automations tab. **Off** means it is turned off there. **Not allowed**: the Mac has not allowed this phone to start sessions. If the Mac refuses a run, the row shows why in red; **Dismiss** clears it.

Phone not syncing? See [The iPhone is not syncing](../troubleshooting/iphone-not-syncing.md).

## Related

- [iPhone](iphone.md)
- [iPhone: permission prompts and interrupts](iphone-agent-prompts.md)
- [Sessions](workbench/sessions.md)
- [iPhone: work alerts](iphone-alerts.md)

For developers: [docs/features/mobile-companion.md](../../features/mobile-companion.md)
