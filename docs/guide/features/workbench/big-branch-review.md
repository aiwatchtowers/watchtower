# Reviewing a big branch

When a branch merges many lanes or touches hundreds of files, Branch review splits it into chapters at once, puts the dangerous ones first and has the AI describe each chapter as it goes. It is the same [Branch review](diff-review.md), only built for size.

## Why use it

You start on the risky part within seconds instead of waiting for one long AI call. One chapter that keeps failing never leaves you without the rest, or without a summary.

## How it works

### Chapters at once, danger first
<!-- learn
id: big-branch-review-chapters
title: Read a big branch danger first
text: In **Deep**, Branch review splits a big branch into chapters and lists **Breaking and significant** ones first.
area: development
level: next
kind: feature
since: 0.28.0
action: nav:projects
-->
<!-- learn
id: big-branch-review-patterns
title: Teach Branch review what is risky
text: List globs under `## Breaking` or `## Can skip` in `.watchtower/review-map.md` to change the chapter order.
area: development
level: power
kind: tip
since: 0.28.0
action: nav:projects
-->

Opening Branch review builds the chapters without AI: by the lanes and tickets merged into the branch, split by package inside a large lane, by package when there are no lanes. Each file and chapter gets a danger level from what it touches: migrations, removed public API, deleted tests, dependencies and CI, auth and tokens.

The list shows **Breaking and significant** first, then **Other changes**. Fixtures, golden, generated and lock files go into **Can skip**, folded and never sent to the model. A row shows its lane (a board ticket like `#219`, a Jira key, or the branch), its signals, a **Breaking** or **Significant** mark and its size; files carry badges like **API removed** or **Migration edited**.

A repository can add its own patterns in `.watchtower/review-map.md`: under `## Breaking`, `## Significant` or `## Can skip`, one `- <glob>` per line. A branch with one chapter shows no list: the file column looks as before, with the badges.

### The AI describes each chapter as it finishes

In **Deep**, chapters are described in parallel calls, and each row fills in on its own: **Describing…**, **Described**, or a one-line failure with **Retry**. The card on top of the list says how many are done and what the summary waits for. The provider's own error text sits behind **Provider's message**.

The summary is made at the end of every run from what was described. A chapter that failed or was not reached is listed under **Not covered** in **1 Meaning**, and the summary saw only its title, files and signals. Described chapters are saved, so **Retry**, a relaunch or **Refresh** redo only what changed.

### One run at a time

Branch review and the agent never describe the same branch at once. While the agent's run goes, the card says **The agent is describing this branch — chapters appear as it finishes them**, and rows fill in as that run saves them; then Branch review describes only what is left. A **Retry** pressed during a run shows **Queued — Retry runs after the current run**.

## Using it

1. Open Branch review on the session, switch to **Deep** and open **2 Chapters**.
2. Read from the top. The counter (**N chapters / M files left**, **Can skip** not counted) has **Next:**, the next unviewed chapter in danger order.
3. On a failed chapter, press **Retry** on its row or above its diff; it redoes only that chapter, then the summary.
4. If the card shows **Describe N remaining**, press it to describe only the chapters the run did not reach.
5. If the summary failed, press **Retry** on its card in **1 Meaning**; it remakes only the summary.

## When it's empty or wrong

- **"Chapters could not be built. The files and the diff are shown without them."** Press **Retry** on the banner. No AI overview starts without chapters.
- **"This branch is past the reviewer's size limit (50,000 changed lines); the files after it are not shown."** Review what is shown, and open the rest in the [code viewer](code-viewer.md).
- **"Not described — not covered by the summary".** The chapter could not be described. Read it yourself, or press **Retry**.
- **"Another overview of this branch is still running."** Another run held the branch for 50 minutes. Press **Retry**.
- **The agent cannot finish its session.** Its finish check needs the summary. Press **Retry** on the summary's card.

## Related

- [Branch review](diff-review.md), [Sessions](sessions.md)
- [Workbench](README.md)

For developers: [docs/features/diff-reviewer.md](../../../features/diff-reviewer.md)
