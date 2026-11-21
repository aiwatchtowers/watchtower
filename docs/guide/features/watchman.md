# Watchman

Watchman learns how you decide in a workbench and tests, on your own past decisions, how often a stand-in would have chosen what you chose. It answers only for the sessions you hand it, until you take them back.

## Why use it

A session stops whenever it needs you: an ask, a permission prompt, a review. Before anything answers for you, Watchman checks the idea against your own record: a number, not a hope.

## How it works
<!-- learn
id: watchman-learning
title: See how well a stand-in would decide
text: Press **Start Learning** in Settings → Profile → Watchman to test how often it would choose what you chose.
area: development
level: power
kind: feature
since: 0.29.0
-->

Watchman reads only your own decisions in one workbench: asks you answered, your comments and verdicts in diff and spec reviews, permission prompts you allowed or denied, your own lines to agents (needs **Agent analytics** on, and Start Learning turns it on), and your own commits (made with the folder's git email) and merged pull requests in the workbench folder. Automations, dismissed asks, colleagues' and agents' commits are left out. Secrets are blanked; each text is cut to 2,048 characters.

Each decision is filed under one of eight categories: design, scope, UX text, tests, code review, document review, permission and finish. Where a source does not say which, a light AI model labels it, so learning costs tokens; one it cannot place is not stored.

Once a week the daemon turns each category's recent decisions into a short list of rules and works out your sleep window, the usual quiet stretch between 20:00 and 12:00 from your activity in the last 28 days (it needs seven active days).

Only real decisions are tested: a line that answers nothing, and anything Watchman never does alone (merging, releasing, messaging people), stay examples. Earlier decisions are sorted once first; while that runs Settings shows "Sorting earlier decisions: N left" and **Run Backtest Now** is off.

The backtest hides your 30 newest such decisions of a category, lets the stand-in decide each from older decisions only, and has a strong AI model grade each answer next to yours: the same, acceptable (a different path you could live with) or bad (you would have had to undo it), per question for an ask with several. Code review is measured on your review comments only. The stand-in may hand an item back only when it needs your hands (a token, a sign-in); a justified handoff lands in the **Handed** column, an unjustified one counts as bad. Each category ends as one of three:

- **Strong**: at most 5 % of its decisions are bad, and none of the bad ones was taken while it was sure ("high" confidence).
- **Weak**: it was measured and missed that bar.
- **Not measured**: fewer than 30 decisions exist, or fewer than 20 are left to score after the handed ones ("Not measured: N of 30 handed to you").

The verdict is **go** when at least three categories are strong and one is permission, design or scope, otherwise **stop**. It does not gate this version: Watchman answers for the sessions you hand it either way and marks every decision **Unsure**.

## Using it

1. Open **Settings → Profile → Watchman** and find the workbench. It first shows an estimate: the number of decisions and labelling's token cost.
2. Press **Start Learning**. The daemon learns the workbench in one go; the line reads "Learning… N of M".
3. When learning is done, press **Run Backtest Now** (the daemon also reruns it weekly). The screen lists each category with its numbers, its base rate and its rating; the verdict and the cost are printed by `watchman backtest` in a terminal, which also saves a report in the workspace's `watchman` folder.
4. A run that fails shows its error with **Retry**; the last finished result stays below.

### Edit what it learned and its limits
<!-- learn
id: watchman-settings-editing
title: Edit Watchman's rules and limits
text: In Settings → Profile → Watchman, press **Edit** on a category's rules, or **Add a Limit…** under Your hard limits.
area: development
level: power
kind: feature
since: 0.29.0
-->

Under **What Watchman learned**, **Edit** opens a category's rules (one per line, at most 20); **Save** pins them, so the weekly rebuild leaves them alone until you press **Unpin**. The sleep window edits the same way, as `HH:MM-HH:MM`. Under **Your hard limits**, **Add a Limit…** takes a command's first words (`terraform apply`) or a tool's name (`create_jira_issue`), and Watchman parks it for you. **Remove** takes only your own rows; the built-in ones stay.

From a terminal, `watchtower watchman learn --workbench N` prints the estimate (add `--start` to begin), `watchman profile --workbench N` shows what it learned, `watchman limits list|add|remove` manages your limits, and `watchman backtest --workbench N` runs a backtest once learning is done (`--force` runs it earlier). From an AI agent's session, `learn --start`, `backtest`, `profile set|unpin`, `limits add|remove`, `arm` (not `arm --check`) and `disarm` are refused.

### Hand a session to Watchman
<!-- learn
id: watchman-hand-over
title: Hand a session to Watchman
text: Press **Hand to Watchman** on a session's strip and Watchman answers its asks for you until you press **Take back**.
area: development
level: power
kind: feature
since: 0.29.0
-->

**Hand to Watchman** on a session's strip hands that session over; on a target's panel, every session under the target, also later ones; **Hand all running sessions to Watchman** in the menu bar, every running agent session. Until you press **Take back**, Watchman answers their asks and spec reviews (and permission prompts in Claude Code sessions) and reviews a session's changes before it may finish, whether you are at the Mac or not. The strip reads "Watchman · since 01:40".

Each hand-over takes an optional instruction Watchman follows within its limits; **Instruction…** by the chip edits it.

An agent idle with nothing running is nudged after 3 minutes, three times at most, then parked.

**Take back** stops new decisions; one already under way still finishes. On a session also handed over through its target, Take back on the strip removes only the direct hand-over.

The first time on a workbench the sheet shows what turns on: Agent analytics and learning, with its estimate. Questions asked until it finishes wait for it, or you answer them; permission prompts come to you. It warns when main is not protected on GitHub, the git guard cannot go into a repository, or a session's folder lacks Watchman's guard (Repair the workbench, restart the session). Merging pull requests, pushing to main, tags, releases, messages to people and your own limits stay yours: Watchman parks them, and a guard stops the agent doing them itself. Not caught: deletes or messages from a script, code the agent writes that runs later (hooks, tests, Makefiles), and commands hidden from the guard.

### Read the night's journal
<!-- learn
id: watchman-journal
title: Read what Watchman decided overnight
text: Open **Inbox → Watchman** in the morning to see each night's decisions, what waits for you and what it cost.
area: development
level: power
kind: feature
since: 0.29.0
-->

Everything Watchman handled lands in **Inbox → Watchman**, one night per entry from 12:00 to 12:00 the next day. Home shows last night as one line, such as "Overnight Watchman decided 14 — 2 unsure, 2 waiting for you", which opens the journal.

- **WAITING FOR YOU**: what Watchman parked for you (a hard limit, a failure, an agent idle after three nudges) or handed back because it needs your hands.
- **Decided**: each decision with what it chose, why, the earlier decisions it leaned on and its confidence (**Unsure** in this version).
- **Checks nobody ran**: checks a session asked for that Watchman passed on.

The night's header shows its span, when the Mac slept ("the Mac slept from 02:10 to 03:05, nothing ran") and the cost. While Watchman works, a "Deciding: …" line shows its current item; when the daemon is stopped, "Watchman is not running — the daemon is stopped" sits above the last night. A menu narrows it to one workbench.

### OK and Correct…
<!-- learn
id: watchman-feedback
title: Teach Watchman from its night
text: In **Inbox → Watchman**, press **OK** on a decision you agree with, or **Correct…** to say what you would have decided.
area: development
level: power
kind: feature
since: 0.29.0
-->

**OK** keeps a decision and teaches it to Watchman. **Correct…** asks what you would have decided: the text goes to the session as a typed line, or, if the session ended, a new session starts on its target with it (not handed to Watchman). Your words are saved first, so a failed send shows "Not sent — …" with **Retry**. **Open session** shows the session; **Mark done** clears a check you ran or a waiting item you dealt with.

## When it's empty or wrong

- **No night yet** in the journal: no session was handed to Watchman yet.
- **Not measured** on a category: too few decisions yet. It fills as you keep working.
- Finish looks thin: handover asks count as ordinary questions.
- An agent's commit without its `Co-Authored-By` line can count as yours.
- Your sleep window is a rough guess if you are rarely active.
- A busy backtest is already running elsewhere.

## Related

- [Agent analytics](agent-analytics.md)
- [Agent coach](agent-coach.md)

For developers: docs/features/watchman.md
