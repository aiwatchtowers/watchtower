# Reviewing a spec or plan

When an agent asks you to review a spec or a plan, a second, independent agent has already read it against what you actually said. The agent fixes what the reviewer finds before you see the ask, so you open it with the corrections already made and only the real disagreements left. It is for anyone who wants to approve a plan without rereading the whole conversation.

## Why use it

A plan can read well and still drift from your idea: it answers a question you never asked, or settles a choice you never made. The reviewer looks for exactly that, so you spend your time on the places that need a human.

## How it works
<!-- learn
id: spec-review-reviewer
title: Have specs checked against your words
text: A spec or plan the agent sends for review comes with an independent reviewer's findings against what you said.
area: development
level: next
kind: feature
since: 0.25.0
action: nav:projects
-->

The reviewer starts at once when the agent files a review ask for a spec or a plan. It reads the document, the session's conversation, your answers to earlier asks, the task and its comments, the spec's Decisions section and any linked mockups. It also reads the code, read-only. It cannot change anything and the ask is filed whether or not it finishes.

It checks every claim against a quote. A finding whose quote it cannot show in the sources is dropped.

### The agent answers the reviewer first
<!-- learn
id: spec-review-author-loop
title: Let the agent answer the reviewer
text: For a session's spec or plan, the agent fixes the reviewer's findings first; you see only the disputes.
area: development
level: next
kind: feature
since: 0.26.0
action: nav:projects
-->

For a spec or a plan the agent works on, the ask stays hidden while the reviewer and the agent go back and forth. The reviewer's findings go straight to the agent, which either fixes the document or disagrees with a reason. The reviewer then checks the new version. The loop runs at most three reviewer rounds. The session row shows **Spec review: round 2 of 3** meanwhile, and nothing reaches your notifications.

The ask appears when nothing is left for the agent: every finding is fixed or disputed. It also appears at once if the reviewer fails or cannot start, the session is gone, or the agent does not answer a round within 30 minutes. In those cases the unanswered findings show as disputes, with the reason at the top.

Specs and plans from a session with no reviewer, other documents and asks that were already open keep the plain review ask.

## Using it
<!-- learn
id: spec-review-findings
title: Go through the reviewer's findings
text: Open the review ask and mark each finding **Fine as is** or **Comment**, then send the round or **Approve**.
area: development
level: next
kind: tip
since: 0.25.0
action: nav:projects
-->

### After the agent's loop

You open one ask. **Disputed** comes first: each card shows the finding, the reviewer's position and the agent's reason. Press **Reviewer is right** to make the agent fix it, or **Author is right** to keep the document; a comment is optional. Below it, **Fixed by the author** is folded: every finding the agent fixed on its own, with its note and round, so you can see what changed. **Reopen** turns one into a dispute.

**Approve** is one press. A dispute you left open counts as **Author is right**. After an early end, approving with unanswered findings asks once. Findings you marked **Reviewer is right** go to the agent as comments to apply; it does not start another review round for them. On the iPhone the one-line summary reads, for example, "Reviewer and author disagree on 2 · 5 fixed by the author".

### The review without a loop

Open the review ask. The drawer shows three steps.

1. **Meaning.** The ask's own summary, the points to look at, what changed since the last round and any questions the agent asked (answer them here). Then your idea next to the document's goal with a verdict, a spec's Decisions list (a plan has none: its agreements come from its spec), counts and a summary. On a later round it also shows which of your earlier comments are resolved.
2. **Chapters.** Each section of the document, with the reviewer's findings as cards: **As agreed**, **Differs**, **Missing**, **Decided alone** and **Blind spot**. Press **Fine as is** on a card you accept, or **Comment** to tell the author what to change. When the reviewer ran checks on a chapter, its **Checklist** sits under the cards. Mark the chapter **Viewed** when you are done with it.
3. **Wrap-up.** Everything you marked, **From the previous run** (with the finding each comment was about), and a note for the author. **Send round to the author** returns your comments; **Approve** accepts the document. Both send the margin comments you wrote under **Read the spec** too. If items are still unmarked, approving asks once before it goes ahead.

**Read the spec** always opens the classic document view with margin comments, whatever state the reviewer is in. Its **Request changes** and **Approve** also send your comments on findings, so nothing you wrote on either screen is lost. An answer from your phone sends them too.

**Re-run reviewer** starts a fresh review of the same document. **Run reviewer** appears instead when the reviewer failed or was skipped.

The spec screen opens only for open asks. A closed ask shows the classic read-only view.

## When it's empty or wrong

- **No findings yet.** While the reviewer works, the drawer shows its progress with **Read the spec**, and the findings open there when it is done. If you opened the ask before the reviewer started, you stay in the classic view and a banner offers the findings when they are ready.
- **Only the classic view, with a reason above it.** The reviewer failed or was skipped. Press **Run reviewer** to start it.
- **Nothing about the code.** With Ollama the reviewer cannot read files, so it judges from the document and the conversation alone, and says so.
- **On the iPhone** you see a one-line reviewer summary above the classic review. The findings screen is on the Mac.

## Related

- [Asks](asks.md), [Workbench overview](README.md)

For developers: [docs/features/spec-review.md](../../../features/spec-review.md)
