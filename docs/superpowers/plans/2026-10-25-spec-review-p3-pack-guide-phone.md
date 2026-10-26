# Spec review — Plan 3 of 3: skill pack, guide, phone line Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Agents produce documents the reviewer can check: `doc_type` is set, every spec has a `## Decisions` section with sources, and agreed mockups are committed and linked. The guide explains the new screen, and the phone shows the reviewer's one-line summary above today's review view.

**Architecture:** Text changes in the two embedded skills (pack version bump plus fixtures), one guide page update, and an additive field on the mobile ask slice that the Kit model and `ReviewAskView` read.

**Tech Stack:** Go embed (`internal/devpack`), Markdown guide (`docs/guide`), Swift (MobileHub slice, WatchtowerKit, WatchtowerMobile).

**Spec:** `docs/superpowers/specs/2026-10-25-spec-review-design.md` (sections 6, 10, 11). **Depends on:** Plan 1 Task 3 (`doc_type`) and Task 1 (`spec_reviews`). Tasks 1–2 here do not depend on Plan 2; Task 3 reuses Plan 2 Task 1's `SpecReviewQueries`/`SpecReviewPresentation.countsLine` if it has landed, else it reads the row directly.

## Global Constraints

- Pack version: `watchtower-workbench` v13 → v14, and `watchtower-flow` v10 → v11. Keep the old version as a fixture under `internal/devpack/testdata/` as the repo does for v10–v12, and follow the existing resync tests.
- Guide edits follow `docs/guide/WRITING.md`. `go test ./docs/guide` must pass (page size cap 8 KB).
- The phone change is additive: an older phone ignores the new field, and a newer phone without it shows today's view.
- Inner loop per task. The full gate (`make test`, `make test-swift`, `make lint-all`, `make mobile-test`) runs at the end of this plan.

## Review Focus

- **An agent files a spec review without `doc_type`, at a non-standard path.** The path inference in Plan 1 must catch `-design.md`, and the skill now always sets it. Test in Task 1 (pack text contains the instruction).
- **An old pack in a folder after upgrade.** The resync must update both skills, and the brief's version check must not loop. Covered by the existing resync tests, extended in Task 1.
- **The phone gets a slice whose ask has a failed or skipped reviewer.** It shows "Reviewer failed: …" in grey, never an empty line. Test in Task 3.
- **The guide page grows past 8 KB.** Split per WRITING.md. Covered by `go test ./docs/guide`.
- **Mockups with live data committed by an agent.** The pack text repeats the public-repo hygiene rule for mockups. Test in Task 1.

---

### Task 1: Skill pack v14 / flow v11

**Files:**
- Modify: `internal/devpack/workbenchskill/watchtower-workbench/SKILL.md` ("Asking the owner" → "When to ask": `doc_type: spec|plan` on a review of a spec or plan; one sentence that an independent reviewer reads it first and the owner's comments come from the reviewer's findings), `internal/devpack/workbenchskill/watchtower-flow/SKILL.md` ("Features, specs and plans": every spec carries `## Decisions`, one line per owner decision with its source `ask #N` or `conversation`; mockups agreed in a brainstorm are committed to `docs/design/mockups/<feature>/` and linked from the spec, with no live-install data in them; a plan names its spec in a `**Spec:**` header line)
- Create: `internal/devpack/testdata/watchtower-workbench-v13.md`, plus the flow v10 fixture if the repo keeps flow fixtures
- Test: the existing `internal/devpack` and `cmd` resync tests, plus `TestFlowSkill_SpecReviewRules` (the text contains `doc_type`, `## Decisions`, `docs/design/mockups/`, `**Spec:**`)
- [ ] **Step 1:** Write `TestFlowSkill_SpecReviewRules`. Run `go test ./internal/devpack -run FlowSkill`. Expected: FAIL.
- [ ] **Step 2:** Edit both skills and bump the versions.
- [ ] **Step 3:** Run `go test ./internal/devpack ./internal/workbenchmethod ./cmd -run 'Pack|Skill|Resync|Method'`. Expected: PASS.
- [ ] **Step 4: Commit** `feat(devpack): pack v14 — doc_type, Decisions section, committed mockups for spec review`

### Task 2: Guide

**Files:**
- Modify: the guide page that covers owner asks and reviews in the workbench (find it with `grep -rl "ask" docs/guide/features | xargs grep -l -i "review"`; if no page covers review asks, add `docs/guide/features/workbench-spec-review.md` and link it from the workbench page and `docs/guide/README.md`)
- [ ] **Step 1:** Write the section "Reviewing a spec or plan": what the reviewer checks, the three steps, **Fine as is** / **Comment**, **Read the spec**, **Re-run reviewer**, what reaches the agent, and v1 limits (phone shows a summary only; Ollama does not read code).
- [ ] **Step 2:** Run `go test ./docs/guide`. Expected: PASS.
- [ ] **Step 3: Commit** `docs(guide): reviewing a spec or plan with the reviewer agent`

### Task 3: Phone summary line

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/MobileHub/Slices/OwnerAskSlice.swift` (add `spec_review: {status, line}?` per review ask), `WatchtowerKit/Sources/WatchtowerKit/Models/OwnerAsk.swift` (`specReview: SpecReviewLine?`, optional, `decodeIfPresent`), `WatchtowerMobile/Sources/Features/Asks/ReviewAskView.swift` (a line above the document)
- Test: `WatchtowerKit/Tests/…/OwnerAskDecodingTests` (`testDecodesWithAndWithoutSpecReview`), a Desktop slice test (`testSliceCarriesSpecReviewLine`)

**Interfaces:**
- Produces: `struct SpecReviewLine: Codable, Equatable { status: String; line: String }`. `line` is built on the Mac: the counts line for `done`, "Reviewer is reading…" for queued/running, "Reviewer failed: <reason>" or "Reviewer skipped: <reason>" otherwise.
- [ ] **Step 1:** Write both tests. Run `make kit-test FILTER=OwnerAskDecodingTests` and `make test-swift FILTER=OwnerAskSlice`. Expected: FAIL.
- [ ] **Step 2:** Implement.
- [ ] **Step 3:** Run the same commands, then `make mobile-build` and `make lint-all`. Expected: PASS.
- [ ] **Step 4: Commit** `feat(mobile): reviewer summary line on a spec or plan review ask`
- [ ] **Final gate (controller):** `make test`, `make test-swift`, `make lint-all`, `make mobile-test`.
