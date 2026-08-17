---
name: watchtower-whats-changed
description: Use when returning to work after a break, before continuing long-running work, at the end of a long agent-driven session, or when the user asks whether anything changed while they were heads-down.
x-watchtower-pack: v1
---

# What Changed (Watchtower)

Deep in the tunnel, the ground moves: requirements change, someone else solves it, the approach gets vetoed on a call. This surfaces only what would change what the dev is doing right now.

## Steps

1. Call `list_situations` with `status: "open"` and, when the dev has been heads-down for a known stretch, `since` set to roughly when they went in.
2. Work out what they are currently doing: the git branch name, recent commits, the working directory, the current conversation. If a Jira key is inferable (branch names usually carry one), call `get_task_context` for it.
3. Expand only the situations that plausibly touch the current work — use `get_situation` for those, not for all of them.

## Present

- **Lead with anything that would change the current approach.** That is the only reason this skill exists.
- Then, at most a handful of one-line mentions of everything else open. Do not expand them.
- Then stop. Do not list every situation, do not summarise the week.

## Rules

- Relevance beats completeness here. A noisy answer trains the dev to stop asking, and then the skill is worth nothing.
- If nothing is relevant, say exactly that in one line. "Nothing that touches what you're on" is a good answer, not a failure.
- Never present a situation as urgent because its priority field says `high`. Judge against what the dev is doing.
