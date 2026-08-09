---
name: watchtower-why-decision
description: Use when asking why something is built the way it is, doing archaeology on a constraint, revisiting a design choice, or before "cleaning up" code that looks wrong — finds the decision and its provenance.
x-watchtower-pack: v1
---

# Why This Decision (Watchtower)

Code that looks wrong is often code that was argued about. Find the argument before changing the code.

## Steps

1. Call `list_ideas` with `kind: "decision"` and a `query` naming the subject — the registry searches mention quotes, not just titles. Expand promising hits with `get_idea` to get the mention trail.
2. Call `memory_recall` for the same subject — the memory vault holds beliefs and episodes the registry does not.
3. Call `list_messages` with a `query` for the original discussion.
4. Call `list_transcripts` with `query` naming the subject — it full-text searches meeting content and returns matches with a snippet. Pull the full text with `get_transcript` when a hit looks load-bearing.

## Present

For each decision found:

- **What was decided**, in one sentence.
- **Who decided it, where, and when** — the provenance, always. A message ref, a meeting, a ticket.
- **What the alternative was**, if the material says.
- **What has happened since** that might have invalidated it.

## Rules

- **Every claim carries provenance.** An unprovenanced "we decided X" is worse than no answer, because it will be believed and repeated.
- Distinguish a *recorded decision* from *someone's opinion in a thread*. Both are useful; conflating them is not.
- If nothing is found, say so plainly. Do not reconstruct a plausible rationale from the code — that is invention, and it is exactly what this skill exists to prevent.
- When the dev is about to change something and you found a decision that covers it, lead with the decision.
