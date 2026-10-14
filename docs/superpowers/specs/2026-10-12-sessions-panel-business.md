# Sessions panel: finished group, one-gesture delete, "Ready to check" (board #480, #534) — business spec

**For:** the owner. One page. The tech spec is `2026-10-12-sessions-panel-design.md`; the plan is
`docs/superpowers/plans/2026-10-12-sessions-panel.md`.

## The problem

- Finished (blue) sessions sit among the working ones, and removing one takes three steps: right-click →
  Delete… → confirm.
- A session whose agent is done and only waits for you to run a check or read a review looks exactly like one
  whose agent is stuck on a decision: both are orange "Waiting for you" (or "Finished · 1 ask open").

## What you will see

**Finished group (#480, your variant 5).** A finished session with no open ask moves to a folded
**▸ N finished** row at the bottom of SESSIONS — the same fold as "✓ N closed" on the board and "▸ N closed"
under the asks. Watchtower remembers per workbench whether it is open. Inside it the most recently finished
come first. A finished session that still has an open ask stays in the main list until the ask is closed. A new
prompt to a finished session brings it back to its old place in the main list (your drag order is kept). The
session on screen never jumps: it stays where it was while you look at it, and moves when you switch away; if
you open one from the folded group (⌘K), it shows as a single row under the folded header.

**⌘1…⌘9** number the main list first, so folding or unfolding the group never changes them; rows of the group
get numbers only while it is open. The session switcher and ⌘K list the same order: main list, then finished.

**Delete in one gesture (#480, variants 1 + 2).** A **✕** appears when you hover a session whose agent is not
working: Finished, Stopped, Error, or not running. Click it and the session is gone — no dialog. Working, Running,
Needs approval, Agents working and a running session waiting on your answer have no ✕; there **Delete…** in the
menu still asks first. **⌘⌫** does the same for the highlighted session while the keyboard is in the panel (click
an empty spot of the panel, or after a ✕; the terminal and the editor keep their own ⌘⌫). ↑ ↓ move the highlight
there without starting anything, Return opens, Esc returns to the terminal. After a delete the highlight moves
to the next row, so you can clean up in a row.

**Undo instead of a dialog.** After a delete a line at the bottom of the panel says **Session deleted — Undo**
for 5 seconds (⌘Z works too while the keyboard is in the panel). Deleting more within those seconds adds up:
"3 sessions deleted — Undo", and Undo brings all of them back. Undo returns the session fully — its report, its
links to targets and its asks — because nothing is erased until the 5 seconds are over (or you quit Watchtower).
A returned session is not running; click it to resume.

**Ready to check (#534).** When every open ask of a session is a **check** or a **review**, the session shows
**Ready to check · ask #N** (or **Ready for review · ask #N**) in its own colour — purple — with a checklist
symbol, in the panel, the switcher and ⌘K. One open **question** keeps it orange "Waiting for you": a decision
that blocks the agent matters more. The ask's notification says "Ready to check: <title>" instead of "Agent
asks: <title>". A session that is still working (or whose agents still work) stays green, its ask count shown
beside a checklist symbol instead of "?".

**Ready to check and the finished group:** a Ready to check session stays in the **main list**, never in the
group — it still waits for you, just like a finished session with an open ask. Once you answer the check it
moves into the group (if the agent marked it finished). Its open asks already sit in **Waiting for you** above,
so a second "ready" group would only repeat them.

## The order of states (first match wins)

Needs approval → Error → Working → Agents working → **Ready to check** → Finished → Waiting for you → Stopped.

## What you need to decide

1. **Approve the PROJ-11 change** (the new state and its place in the order; exact wording in the tech spec §8).
2. **Approve the new contract PROJ-16** "a deleted session can be undone and then leaves nothing" (tech spec §8).
3. **Open question:** a click on a session row keeps sending the keyboard into its terminal, as today — so ⌘⌫
   needs a click on an empty spot of the panel first. **Recommended: keep it.** The alternative (a row click
   keeps the keyboard in the panel until you click the terminal) makes ⌘⌫ quicker but every session switch
   would need one more click before typing.

## What does not change

Delete… in the menu and its confirmation (after it, Undo is offered too); the asks stack; what a delete
finally removes. The standalone **Terminals** list reports no states, so it gets no ✕ and no group — only the
Undo after its Delete….
