---
type: bug
title: "Briefing \"your day\" target link is dead: Swift decodes task_id, Go emits target_id"
status: open
priority: med
tags: [briefing, desktop, dual-path, namespacing]
context: found while reviewing the briefing id-validation fix (fix/bl-ai-output-validation)
created: 2026-09-28
---

**Where:** WatchtowerDesktop/Sources/WatchtowerCore/Models/Briefing.swift (~64, `YourDayItem.CodingKeys.taskID = "task_id"`) vs internal/briefing/pipeline.go (~42, `YourDayItem.TargetID` tagged `json:"target_id,omitempty"`)
**Confidence:** high

The Go briefing pipeline writes a "your day" item's target as `target_id`, which matches the `briefing.daily` prompt's JSON example. The Swift model decodes that field from `task_id`, a key left over from the tasks→targets rename. As a result `YourDayItem.taskID` is always nil on the Desktop, and `BriefingDetailView.yourDayCard`'s "open target" branch (`appState.navigateToTarget`) never fires. A target item either falls through to the track branch or does nothing. Fix: decode `target_id`. Also accept `task_id` if old rows need it. Rename the Swift property to match, and add a decoding test fed with a Go-shaped JSON fixture so the dual path is pinned.

Related, same file: `team_pulse[].user_id` and `coaching[].related_user_id` are stored exactly as the model wrote them. They are not checked against the people the prompt showed, and a bare Slack id is not resolved to its namespaced form. The Desktop uses them for person navigation. `shownIDs.resolvePerson` (internal/briefing/validate.go) already does exactly this for `attention` items with `source_type = "people"` and could be reused for these two fields.
