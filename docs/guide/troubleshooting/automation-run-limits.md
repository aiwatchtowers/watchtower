# An automation run stopped at a limit

An automation run failed or ended early with one of the limit messages below, or it succeeded with a note that its journal is incomplete.

## What you see

On the automation's card, under **History**, the run shows one of these messages in red:

- "the run made more than 2000 SDK calls": the run failed.
- "already made 50 outputs" or "already started 10 sessions": a step failed. The run may still have succeeded if the script caught the error.
- "the run succeeded, but its journal is incomplete": the run succeeded.
- "the run could not be finished as …": the run failed.

## Why

Every run has fixed limits on top of its token and minute budget. It can make at most 2,000 calls (`llm`, `tool`, `state`, `output`, `log` and the rest together), file at most 50 outputs to Inbox, reports or the briefing, and start at most 10 sessions with `session()`. A `session()` call that was refused or could not start does not count. A session pauses the run's minute budget while it works, so the count of sessions is what keeps a run from opening them without end. 10 covers a busy round of the **PR review rounds** template, which leaves any further pull requests for its next round.

The other two messages come from the database. If Watchtower cannot write a step to the run's history, the run still saves its results, so the next run does not do the same work again. If Watchtower cannot save the end of a run even after retrying, it ends the run as failed and does not save its state or outputs.

## Fix

1. **More than 2000 SDK calls.** This usually means a loop that never ends. The script cannot catch this error. Fix the loop, or split the work across runs: keep what is done in `state`.
2. **50 outputs or 10 sessions.** The script can catch these errors. Put several items in one output, or leave the rest for the next run, as the PR review rounds template does.
3. **Journal is incomplete.** Nothing to fix in the recipe. The run's results were saved; only some steps are missing from **History**. If it keeps happening, another program is holding the database busy: check `watchtower db lockstats`.
4. **Could not be finished.** The run's state and its Inbox, report and briefing outputs were not saved, so the next run starts from the previous state. What the run already did outside Watchtower is not undone: its `shell()` commands ran, its sessions started, and its proposed writes wait in **Actions**. The next run may do them again, so check **Actions** before you approve a second copy.

## How to check

Use **Run now** on the card. The new run in **History** ends without the message.

## If it didn't help

Ask the assistant to change the recipe with **Change in words**, and name the message. If "could not be finished" keeps coming back, run `watchtower db lockstats` and `watchtower logs` in a terminal ([Command line](../reference/cli.md)) to see what holds the database.
