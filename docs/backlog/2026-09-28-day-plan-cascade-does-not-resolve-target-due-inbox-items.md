---
type: bug
title: "Day-plan cascade closes a target but leaves its target_due inbox items pending"
status: open
priority: med
tags: [targets, day-plan, inbox, swift, dual-path]
context: found while fixing Desktop parent-progress recompute (fix/bl-target-progress)
created: 2026-09-28
---

**Where:** WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/DayPlanQueries.swift (`markItemDone`/`markItemPending` → private `cascadeTaskStatus`, ~lines 167-189) vs `TargetQueries.updateStatus` (WatchtowerCore/Database/Queries/TargetQueries.swift) and Go `UpdateTargetStatus` (internal/db/targets.go).

Marking a day-plan item done with `cascadeToTask: true` sets the linked target's status to `done` with a direct `UPDATE targets SET status = ?`. It now recomputes progress (leaf + parent chain), but it does not run the INBOX-02 cascade that `TargetQueries.updateStatus` and Go `UpdateTargetStatus` run: the target's pending `target_due` inbox items stay `pending` even though the target is closed. The owner then has to close the same thing twice, which is exactly what INBOX-02 exists to prevent.

Scenario: a target with a pending `target_due` inbox item is on today's day plan as a backlog task item; the owner ticks the item done in the Day Plan view. The target shows done, its `target_due` item still shows as needing attention in every `inbox_items` reader (Catch-Up `needs_you`, briefing).

Fix sketch: route `cascadeTaskStatus` through `TargetQueries.updateStatus` so status, progress and the INBOX-02 resolution share one writer. INBOX-02 is Enforced (docs/inventory/inbox-pulse.md), and this would add a writer to its cascade, so it needs an owner call before implementing. Pin with a Tests/Core case: day-plan item done with cascade → target_due item resolved with `resolved_reason = 'target_closed'`; `markItemPending` → no inbox change.
