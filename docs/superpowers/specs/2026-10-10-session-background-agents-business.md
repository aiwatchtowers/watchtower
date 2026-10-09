# Session state: background agents (board #411) — business spec

**For:** the owner. One page. The tech spec is `2026-10-10-session-background-agents-design.md`.

## The problem

When the main agent of a workbench session hands work to background subagents and ends its turn, the Desktop
says the session is **Stopped** (grey pause) — or **Waiting for you** (orange) when an ask is open — while
the terminal says "Waiting for 1 background agent to finish" and agents are writing code for twenty minutes.
Grey and orange both tell you "nothing moves until you act". Here that is false.

## What you will see

- A new state, **Agents working**: green, like Working, with a gently pulsing dot and a "two people" glyph.
  The caption carries the count when Claude Code tells us: "2 agents working". With open asks it reads
  "2 agents working · 1 ask open", with the "?" glyph and the ask count — the same way Working shows asks.
  Never orange, never the grey pause.
- The count goes down as agents finish ("3 agents working" → "2 agents working").
- When the last agent finishes, the main agent wakes up on its own (Claude Code hands it the results). The row
  shows Working for that turn, and when that turn ends with nothing left in the background, the row turns
  **Stopped** — or **Waiting for you** if an ask is still open. You get the usual "stopped" notice **once**, at
  that point — not when the agents were launched.

## The order of states (first match wins)

Needs approval → Error → Working → **Agents working** → Finished → Waiting for you (open ask) → Stopped.

In words: a permission dialog or an error always shows first; the main agent working beats everything else;
agents working in the background beat "finished", "waiting for you" and "stopped".

## What does not change

- The "Waiting for you" stack, the ask banner and the ask notices — they still show every open ask.
- Answering an ask while agents work: the answer is typed **and submitted** right away, as today when the
  session is stopped. It wakes the main agent, which reads it.
- Code hand-offs into the session behave as for a stopped session (the main agent is at its prompt).
- Needs approval, Error, Finished, Working: same meaning, same look.

## Edge cases, in plain words

- **An agent crashes or hangs.** The main agent normally wakes when an agent ends either way. If Claude Code
  stops reporting anything about the session's agents for 30 minutes, the row falls back to Stopped
  (with its one notice) — "Agents working" cannot stick forever.
- **You restart or resume the session.** The new run starts clean: background agents of the old process are
  gone, and so is the state.
- **An older Claude Code** that does not report background work: the session shows Stopped as today. Nothing
  gets worse.
- **Long-lived teammates and background shells** (for example a `tail -f`) do not count as agents working —
  only subagents do. Otherwise a session with a log tail would look busy forever.
- **A background agent asks for a permission:** Needs approval, as today.

## What you need to do once

Existing workbench folders need **Re-run Setup** (or Repair in the header) once, to add one new hook entry
that keeps the count live. Without it the state still works; the count only updates when the main agent's turn
ends.

## Proposed contract change (PROJ-11 amendment)

**Old rule (PROJ-11, 2026-10-03/04):** the stored `waiting` means the turn is over and shows **Stopped**
(grey); the order is approval > error > working > finished > open ask > stopped > running > not started; a
subagent's tool result alone never changes the state (it writes only over `approval`).

**New rule:** the stored `waiting` still means *the main agent's turn is over*. When the Stop hook of that turn
reports in-flight background **subagents** (Claude Code's `background_tasks`, entries of type `subagent`), the
row also stores their count, and the Desktop shows **Agents working** (green; "?" and the ask count when asks
are open) instead of Stopped or Waiting for you. Only a Stop hook can start Agents working; a later event can
only lower the count or end it (the main agent's next turn, the idle notice, a new run, or 30 minutes with no
report about the agents). The order becomes approval > error > working > **agents working** > finished > open
ask > stopped > running > not started. A subagent's tool result still never changes the state, the turn's end
time, or "finished" (it only refreshes the "agents still alive" time). Agents working is never announced; the
following Stopped / Finished is announced once. The ask answer's Return and code hand-offs treat Agents working
exactly as Stopped.

## Your decisions (recommended answers in bold, details in the tech spec §9)

1. Count only subagents — **yes** / also workflows / every background task.
2. Fallback to Stopped after **30 min** / 60 min / never, with no report about the agents.
3. After the count drops to zero, keep "Agents working" up to **2 min** waiting for the main agent to wake / 0 / 5 min.
4. Add the live-count hook (needs Re-run Setup once) — **yes** / no, count only at turn end.
5. Older Claude Code: **show Stopped as today** / guess "Agents working" from subagent activity.
