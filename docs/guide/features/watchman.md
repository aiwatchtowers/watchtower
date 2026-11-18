# Watchman

Watchman learns how you decide in a workbench and tests, on your own past decisions, how often a stand-in would have chosen what you chose. It is for the person who wants to hand agents a task and leave, and first wants to know whether a stand-in could be trusted. In this version Watchman only learns and measures. It answers nothing, approves nothing and writes nothing on your behalf.

## Why use it

Today a session stops whenever it needs you: an ask, a permission prompt, a review. Before anything is allowed to answer for you, Watchman checks the idea against your own record, so you get a number instead of a hope.

## How it works
<!-- learn
id: watchman-learning
title: See how well a stand-in would decide
text: Press **Start Learning** in Settings → Profile → Watchman to test how often it would choose what you chose.
area: development
level: power
kind: feature
since: next
-->

Watchman reads only your own decisions in one workbench: asks you answered, your comments and verdicts in diff and spec reviews, permission prompts you allowed or denied, your own lines to agents (needs **Agent analytics** on, and Start Learning turns it on), and your own commits (made with the folder's git email) and merged pull requests in the workbench folder. Automations' asks and sessions, dismissed asks, colleagues' commits and the agents' own commits are left out. Secrets are blanked and each stored text is cut to 2,048 characters.

Each decision is filed under one of eight categories: design, scope, UX text, tests, code review, document review, permission and finish. Where a source does not say which, a light AI model labels it, so learning costs tokens. A decision it cannot place is counted and not stored.

Once a week the daemon turns each category's recent decisions into a short list of rules and works out your sleep window, the usual quiet stretch between 20:00 and 12:00 from your activity in the last 28 days (it needs seven active days).

Only real decisions are tested: a line to an agent that answers nothing, and anything Watchman would never do alone (merging into main, pushing, releasing, messaging people, deleting outside the worktree), stay as examples and are not tested. Earlier decisions are sorted once first; while that runs Settings shows "Sorting earlier decisions: N left" and **Run Backtest** is off.

The backtest hides your 30 newest such decisions of a category, rebuilds the rules from what came before, lets the stand-in decide each one using only older decisions, and has a strong AI model grade each answer next to yours: the same as yours, acceptable (a different path you could live with) or bad (you would have had to undo it). An ask with several questions is graded per question. Review outcomes, undone hunks, merges and your rewrites are not tested yet, so code review is measured on your review comments only. The stand-in may also hand an item back, but only when it needs your hands (a token, a sign-in, a command on your side). The model judges each handoff: a justified one is shown in the **Handed** column and is not scored, an unjustified one counts as one bad decision. Handing back never makes a category strong, because a category needs at least 20 scored decisions. Each category ends as one of three:

- **Strong**: at most 5 % of its decisions are bad, and none of the bad ones was taken while it was sure ("high" confidence). Matching you exactly is not required.
- **Weak**: it was measured and missed that bar.
- **Not measured**: fewer than 20 decisions could be scored, so no verdict is given. The row reads "Not measured: N of 30 handed to you" when the stand-in handed the rest back.

The overall verdict is **go** when at least three categories are strong and one of them is permission, design or scope, otherwise **stop**. Go only means a later version may be planned. Nothing acts yet.

## Using it

1. Open **Settings → Profile → Watchman** and find the workbench. Before you start, it shows an estimate, such as the number of decisions and the tokens labelling will cost.
2. Press **Start Learning**. The first pass runs up to five minutes; the daemon continues in its next cycles and the line reads "Learning… N of M".
3. When learning is done, press **Run Backtest Now**. A run shows its progress and can take a while, and the weekly run repeats it once learning is done. The screen lists each category with its numbers, its base rate and its rating; the verdict and the cost are printed by `watchman backtest` in a terminal, which also saves a report of the grades and reasons in the workspace's `watchman` folder.
4. If a run fails or is interrupted, the error is shown with **Retry**, and the last finished result stays below it.

From a terminal, `watchtower watchman learn --workbench N` prints the estimate (add `--start` to begin), `watchman profile --workbench N` shows the learned rules and sleep window, and `watchman backtest --workbench N` runs a backtest (it waits for learning to finish; `--force` runs it earlier). Starting and backtesting are yours to run: an AI agent's session is refused.

## When it's empty or wrong

- **Not measured** on a category: fewer than 20 of its 30 hidden decisions could be scored, because there are too few or the stand-in handed many back to you. It fills as you keep working.
- Finish looks thin: a handover ask is learned as an ordinary question and is not always filed under finish.
- A commit by an agent that left out its `Co-Authored-By` line can count as yours.
- Your sleep window is a rough guess from sparse activity; an edge near 20:00 or 12:00 can be off.
- A backtest that says busy is already running, from the app, the terminal or the daemon.

## Related

- [Agent analytics](agent-analytics.md)
- [Agent coach](agent-coach.md)

For developers: docs/features/watchman.md
