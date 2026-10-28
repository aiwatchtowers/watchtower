# Spec review severity, readability, comments, footer verdicts — plan

**Spec:** `docs/superpowers/specs/2026-10-28-spec-review-severity-design.md` (board #1184)

## Task 1 — Go: severity in the result and the prompt

Depends on: none.

- `internal/specreview/result.go`: `Severity string \`json:"severity,omitempty"\`` on `Agreement`, `DecidedAlone`, `BlindSpot`, `Check`; `loop.go`: on `AuthorItem`.
- `Parse` (`validate.go`): normalise (trim, lower) to `blocker|major|minor`, else empty; empty on `as_agreed` agreements and non-`concern` checks.
- `Findings` copies severity into author items; `NextRound` keeps a carried item's severity.
- `testdata/result_keys.golden` and the `get_spec_review` pinned keys (wherever pinned) gain `severity` (`-update`).
- `internal/prompts/defaults.go`: `review.spec` v3 — the severity field in the shape, the three level definitions, `severity` on every finding except `as_agreed` and non-concern checks; version map → 3 with the history line.
- Tests: Parse filter cases, Findings copy, NextRound carry, prompt version and level names.
- Checks: `go test ./internal/specreview ./internal/prompts ./internal/tools`, `make lint-diff`.

## Task 2 — Swift Core: decoding and presentation logic

Depends on: none (decodes an optional field).

- Decode optional `severity` on `SpecReviewResult.Agreement/DecidedAlone/BlindSpot/Check` and the loop's author item.
- `SpecReviewPresentation`: `severityBadge`, kind/loop-status chip text (grey), severity sort, counts line with severities, the `changes` split rule (`OwnerAskPresentation` or a small pure helper).
- `SpecReviewModel`: `commentMarkCount` (N), `canSend` = N > 0, `canApprove` = N == 0 && no blocker.
- Tests in `Tests/Core` / existing `SpecReviewViewTests`.

## Task 3 — Swift views

Depends on: Task 2.

- `SpecReviewQuote`: upright, inline Markdown, left bar, stronger label; idea card and resolved list the same; Notes `.callout`.
- Finding cards (chapter, dispute, fix row): severity chip + grey kind chip, sorted; picked states neutral.
- Loop chapters: `SpecReviewMarkControls` in a comment-only mode; Decide: **Add comment** / **Edit** under a picked Fix / Reviewer is right.
- Footer: `OwnerAskAnswerBar` shows **Request changes (N)** / **Approve** (with confirmations and the blocker line) when the spec review screen is up; in-body buttons removed (loop view, Wrap-up).
- Keys ⌘↩ / ⌘⇧↩ routed to the spec review verdicts only with no field focused; test over `OwnerAskDrawerKeys`.
- `OwnerAskHeaderCard`: "Changes since" as a list by the split rule.

## Task 4 — shots and guide

Depends on: Task 3.

- `DesignShotCatalog`: the states listed in the spec's Screens section; `make desktop-shots`.
- `docs/guide/features/workbench/spec-review.md`: severity chips, Comment in a loop, Request changes in the footer; `go test ./docs/guide`.
