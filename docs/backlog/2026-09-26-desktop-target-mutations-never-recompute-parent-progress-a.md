---
type: bug
title: "Desktop target mutations never recompute parent progress (a concrete dual-path divergence)"
status: done
priority: med
tags: [targets, swift, dual-path, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track architecture
created: 2026-09-26
---

**Where:** WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/TargetQueries.swift:199 (create), :253 (updateStatus), :361 (updateProgress), :468 (delete); Views/Targets/SuggestLinksSheet.swift:129; internal/db/targets.go:75,119-123,368,388,457
**Confidence:** med

On the Go side, `CreateTarget`, `UpdateTarget` (for both the old and the new parent on a reparent), `UpdateTargetStatus`, `DeleteTarget` and `PromoteSubItemToChild` all call `RecomputeParentProgress`, which walks up the ancestor chain and averages the progress of non-dismissed children. The Swift writers do none of this, and no Swift code contains a recompute. `updateStatus` even documents that it mirrors the Go INBOX-02 cascade, yet it skips the progress half. Scenario: in the Desktop, dismiss one of two children (progress 0.0 and 1.0) or drag a child's progress slider. The parent keeps its old average, or keeps counting the dismissed child, until some Go-side write happens to touch that subtree. "Apply parent" in SuggestLinksSheet leaves both the old and the new parent stale. Fix: port `recomputeParentProgressOn` into `TargetQueries`, call it inside the same write transaction, and pin it with a shared fixture test.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»

Resolution: ported Go's `recomputeParentProgressOn` to `TargetQueries.recomputeParentProgress` (new `TargetQueries+Progress.swift`, same average/dismissed/own-status/`progress != ?`/cycle/depth-20 rules), plus `applyStatusProgress` (the leaf-progress half of `UpdateTargetStatus`) and `updateParent` (old + new parent). Every Desktop writer now calls them inside its own write transaction: `create`, `updateStatus`, `updateProgress`, `snooze`, `delete`, the day-plan task cascade and SuggestLinksSheet's "Apply parent". `create` without an explicit progress now derives it from status like Go `CreateTarget`. Pinned by the shared fixture `internal/db/testdata/target_progress_cases.json`, replayed by Go `TestRecomputeParentProgress_SharedFixture` and Swift `TargetProgressFixtureTests`, plus Swift-only `TargetQueriesParentProgressTests` for the writers without a Go twin.
