---
type: bug
title: Session row progress counts every target the session ever touched
status: open
priority: med
tags: [workbench, sessions, board, progress]
context: Go hub phase 1 work in one long workbench session (owner choice in ask #840)
created: 2026-10-31
---

A workbench session's row shows progress (e.g. "40/72") from the union of every
target the session ever moved, because the session has no `target_id`. A long
session that first worked a relay group (about 35 targets now owned by another
session) and then Go hub phase 1 (33 tasks, 28 done) shows 40/72 instead of the
phase's 28/33, so the row does not tell the owner where the session's own work
stands.

Wanted:
- a session bound to a target counts that target's subtree only;
- a way to set or change a session's target after launch (Desktop, and/or an MCP
  tool for the agent), so a session that drifted to new work can be re-pointed;
- optionally, a way to drop stale target links the session no longer owns.

> Original note: «И тут хочу чтоб верный статус отображался … а не 40/73, я думаю борду надо правильно организовать»
