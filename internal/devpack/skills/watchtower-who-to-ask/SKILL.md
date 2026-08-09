---
name: watchtower-who-to-ask
description: Use when the user is blocked, does not know who owns a subsystem, asks "who knows about X" or "who do I ask", or is about to guess at unfamiliar code — finds who knows, who decides, and how to approach them.
x-watchtower-pack: v1
---

# Who To Ask (Watchtower)

"I don't know who to go to" is an information problem *and* a social one. Answer both.

## Steps

1. **Work out what kind of question it is.**
   - About a file or a piece of code → run `git log --format='%ae' -20 -- <path>` (and `git blame` where a specific region matters) to collect author emails, then call `find_experts` with `emails: [...]`.
   - About a topic → call `find_experts` with `topic: "..."`.
   - About a ticket → call `find_experts` with `issue_key: "PROJ-123"`.
   - You may combine inputs in one call when the question spans them.
2. Read the `evidence` on each candidate and the `weights` that ordered them. If the ordering does not match the evidence you would weigh, say so and reorder — the weights are a default, not an authority.
3. Expand the top candidates with `get_person` when you need more on how to approach them.

## Present three answers, never one

1. **Who knows.** Cite the evidence. Weight conversational signal alongside authorship: the person who wrote the code two years ago may have left the team; the person arguing about it last week is in it.
2. **Who decides.** From `decision_role` on the candidate, the Jira assignee, and track ownership. Asking the knower when you needed the decider is a common and expensive mistake — call it out explicitly when they are different people.
3. **How to approach.** Channel versus DM, their observed active hours, and the `communication_guide` / `communication_style` from their people card. Phrase this as what tends to work with this person, not as instructions about them.

## Rules

- Never assert expertise the evidence does not support. "Three messages six months ago" is a weak signal — say so rather than promoting them.
- If `unmatched_emails` comes back non-empty, report it: those authors could not be resolved to people, so the code signal is incomplete.
- `active_hours` is *observed activity*, not a calendar. Never present it as free/busy.
- If nothing scores well, say the honest thing: nobody in the data clearly owns this, and suggest the channel where the topic lives instead.
