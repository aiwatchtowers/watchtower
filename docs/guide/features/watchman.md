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

The backtest hides your 30 newest decisions of a category, rebuilds the rules from what came before, lets the stand-in decide each one using only older decisions, and compares. Review outcomes, undone hunks, merges and your rewrites are not tested yet, so code review is measured on your review comments only. Each category ends as one of three:

- **Strong**: it matched you at least 80 % of the time, when it was sure ("high" confidence) it was wrong at most 5 % of the time, and it beat the base rate: how often always giving your most common answer would have matched.
- **Weak**: it was measured and missed either bar.
- **Not measured**: fewer than 30 decisions, so no verdict is given and no model is called.

The overall verdict is **go** when at least three categories are strong and one of them is permission or code review, otherwise **stop**. Go only means a later version may be planned. Nothing acts yet.

## Using it

1. Open **Settings → Profile → Watchman** and find the workbench. Before you start, it shows an estimate, such as the number of decisions and the tokens labelling will cost.
2. Press **Start Learning**. The first pass runs up to five minutes; the daemon continues in its next cycles and the line reads "Learning… N of M".
3. When learning is done, press **Run Backtest Now**. A run shows its progress and can take a while, and the weekly run repeats it once learning is done. The screen lists each category with its numbers, its base rate and its rating; the verdict and the cost are printed by `watchman backtest` in a terminal.
4. If a run fails or is interrupted, the error is shown with **Retry**, and the last finished result stays below it.

From a terminal, `watchtower watchman learn --workbench N` prints the estimate (add `--start` to begin), `watchman profile --workbench N` shows the learned rules and sleep window, and `watchman backtest --workbench N` runs a backtest (it waits for learning to finish; `--force` runs it earlier). Starting and backtesting are yours to run: an AI agent's session is refused.

## When it's empty or wrong

- **Not measured** on a category: fewer than 30 decisions exist there. It fills as you keep working.
- Finish looks thin: a handover ask is learned as an ordinary question and is not always filed under finish.
- A commit by an agent that left out its `Co-Authored-By` line can count as yours.
- Your sleep window is a rough guess from sparse activity; an edge near 20:00 or 12:00 can be off.
- A backtest that says busy is already running, from the app, the terminal or the daemon.

## Related

- [Agent analytics](agent-analytics.md)
- [Agent coach](agent-coach.md)

For developers: docs/features/watchman.md
