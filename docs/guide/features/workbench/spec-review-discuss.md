# Discussing a spec review

Every finding of a spec or plan review, and every point of its short version, can be questioned in place. The assistant answers from the document, the code and the conversation, and can ask the agent that wrote the document when only it knows. It is for anyone who opens a review and thinks "why?".

## Why use it

A finding you do not understand leaves you two guesses: **Fix** or **Skip**. A thread on the card lets you ask first, so you send the agent a fix you agree with, or drop a finding that does not hold. The short version at the top lets you see what a long spec is about before you read any finding.

## How it works

### Who answers you

The assistant in a thread is neither the reviewer nor the agent that wrote the document. It sees what the reviewer saw: the document, the conversation, your answers to earlier asks and the whole review. It reads the code read-only and has no tools that change anything. Its job is to explain the finding, check it, and say plainly when it does not hold. With Ollama it cannot read files and says so.

A thread belongs to its card, not to one ask. When the agent files the document again and the same finding comes back, the card shows the earlier thread and continues it.

### When the assistant asks the agent

When only the agent can answer (what it meant, what it plans), the assistant asks it. The question is typed into the agent's session the way the reviewer's findings are: never in the middle of a turn, and never over text you typed there. The thread shows **Asked the author…**, then the agent's answer, and the assistant carries on from it.

If the agent does not answer within 30 minutes, the thread says **The author did not answer** and the assistant goes on without it. A thread asks one question at a time. Answers that land while the Mac app is closed are picked up when you open the thread again.

### When the conversation finds something new

The assistant can propose a finding the review missed. It shows as a card in the thread, quoting the document or your own words in the thread. Nothing is added until you press **Add to review**. A finding whose quote cannot be found is refused with **not added: quote not found**. An added finding appears in its chapter with the **From discussion** chip and works like any other finding.

## Using it

### Read the short version first
<!-- learn
id: spec-review-discuss-summary
title: Read a spec in a few lines
text: Open a spec review: **In short** sums up the document, and every point opens to its passage and **Discuss**.
area: development
level: next
kind: tip
since: next
action: nav:projects
-->

The **Meaning** step opens with **In short**: three to five lines on what the document builds, for whom and why. Below them its key points, grouped as **Goals**, **Key decisions**, **What changes for you**, **Not in scope** and **Risks**. Click a point to see the passage it comes from, with **Read the spec** and **Discuss**.

### Discuss a finding
<!-- learn
id: spec-review-discuss-thread
title: Ask why about a review finding
text: Press **Discuss** on a spec review finding to ask the assistant about it, in place.
area: development
level: next
kind: feature
since: next
action: nav:projects
-->

1. Press **Discuss** on a finding or a point. The thread opens inside the card, ready to type.
2. Ask your question. The answer quotes the document or the code.
3. Decide with the card's buttons. **Fix** sends the finding to the agent, and on a card with a thread its comment field fills with the assistant's conclusion; edit it or clear it. **Skip** or **Not useful** drops a finding the thread showed does not hold.

Press **Hide** to fold the thread. A folded card shows **thread · N**, and the thread is still there when you reopen the ask.

## When it's empty or wrong

- **No Discuss button.** The ask is still hidden in the agent's loop, so there is nothing to open yet. Use **Show Now** under **Reviewer and author** to open the review early.
- **"Couldn't draft a conclusion" under Fix.** The assistant did not answer within 30 seconds. **Fix** is already marked: type your own comment, or send the finding as it is.
- **The author's session has ended: the question was not sent.** The agent's session is gone. The assistant answers without it.
- **"From the previous run: you can read this thread, but it takes no new messages."** A re-run of the reviewer dropped that finding. The thread stays readable.
- **A reply waits.** Embedded assistants run three replies at a time across the app; yours starts when one ends.
- **On the iPhone** there are no threads and no short version. Open the review on the Mac.

## Related

- [Reviewing a spec or plan](spec-review.md), [Asks](asks.md)

For developers: [docs/features/spec-review.md](../../../features/spec-review.md)
