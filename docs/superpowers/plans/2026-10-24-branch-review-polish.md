# Branch review polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Six owner fixes to Branch review: folded hunks, a changed-files tree with code navigation, AI risks instead of the lens checklist, the session agent's chat beside the diff, whole-chapter Viewed, and an Approve / Request changes verdict.

**Architecture:** Mostly Desktop (SwiftUI + the Monaco diff page `diff.js`); Approve adds one Go migration column, a guarded DB transaction, a CLI verb, a pinned delivery line with a Swift twin, and a skill-pack section. Navigation reuses the code viewer's index and centres through a new "navigation destination" seam in `WorkbenchesViewModel`.

**Tech Stack:** Go 1.26 (goose SQL migrations, cobra), SwiftUI/GRDB (`WatchtowerCore` + app target), Monaco 0.57 AMD page.

**Spec:** `docs/superpowers/specs/2026-10-24-branch-review-polish-design.md` (approved, ask #559). Read it before any task; section numbers below refer to it.

## Global Constraints

- Monaco stays pinned at 0.57; `diff.html` CSP unchanged (`default-src 'none'`, no network).
- REVIEW-01…05 hold (`docs/inventory/review.md`); REVIEW-04 is amended (Task 4) to cover Approve — no assertion relaxed, no guard renamed.
- Fold options exactly: `contextLineCount: 3, minimumLineCount: 6, revealLineCount: 20`.
- Migration `00154_review_round_outcome.sql`: `outcome TEXT NOT NULL DEFAULT '' CHECK (outcome IN ('', 'changes', 'approved'))`.
- Approved line, verbatim: `Review round #<id> approved — the owner approved this branch; finish it the way your methodology says (read get_review <id> using the watchtower-workbench skill).`
- Brief line for an undelivered approved round: `Review round #<id> approved → get_review <id>`.
- Ask-agent quote cap: 40 lines, then a `…` line.
- Desktop rules: `docs/review/review-rules.md` (Swift section), design kit + `docs/design/desktop-style-guide.md`.
- Inner loop only per task (CLAUDE.md "Agent-driven runs"): `go test ./internal/<pkg>`, `make test-swift FILTER=…`, `make lint-diff` (Go) and `make lint-swift` (Swift — lint-diff never checks Swift). The full gate runs once per phase by the controller.
- No background builds; tests that spawn processes reap them.

## Review Focus

1. A comment, note or Undo hunk on a line inside a folded region — it must be visible (region revealed) and `wt.focus` must reach it. Pinned in Task 5.
2. Approve racing another window that already sent the round — Go answers `ok:false`, nothing is typed, the toolbar shows the closed state. Pinned in Task 4.
3. A renamed (`old_path`) or deleted file in the tree, and a single-file folder chain — the tree shows it once, under the new path, compacted. Pinned in Task 8.
4. A ⌘-click in the diff while the Files pane is the key pane, or with no review pane registered — the jump goes to the Files pane exactly as today. Pinned in Task 9.
5. Ask agent on a 500-line selection and on a selection in the old side — the quote is capped at 40 lines and says `(old side)`. Pinned in Task 11.

## Lanes and dependencies

| Task | Depends on | Lane |
|---|---|---|
| 1 Go: outcome column + ApproveReviewRound | none | Go |
| 2 Go: approve CLI, line, brief, get_review | 1 | Go |
| 3 Go: skill pack v14 | 2 | Go |
| 4 Swift: Approve / Request changes | 2 | Approve |
| 5 Fold + Full file | none | Diff page |
| 6 Chapter viewed | none | Chapters |
| 7 Checklist out, risks in | none | Chapters (after 6, same files) |
| 8 Changed-files tree | none | Tree/nav |
| 9 Navigation destination seam + preview | 8 | Tree/nav |
| 10 Navigation in the diff page | 5, 9 | Tree/nav |
| 11 Chat panel + Ask agent | 5, 7 | Chat |
| 12 Docs: feature note, guide, shortcuts | 1–11 | controller |

`diff.js` is touched by 5, 10, 11 and `ReviewChangesPaneView.swift` by 4, 6, 7, 9, 11: the controller merges lanes in table order.

---

### Task 1: Go — round outcome and the guarded approve

**Files:**
- Create: `internal/db/migrations/00154_review_round_outcome.sql`
- Modify: `internal/db/review_rounds.go` (`SendReviewRound`, `reviewRoundCols`, `scanReviewRound`, `ReviewRound` struct), `internal/db/schema.sql`
- Test: `internal/db/review_rounds_test.go`
- Regenerate: `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`

**Interfaces:**
- Produces: `ReviewRound.Outcome string`; `func (db *DB) ApproveReviewRound(projectID, id int64, resolveOpen bool) (ok bool, err error)` — every refusal is `ok:false`, as Send.

- [ ] **Step 1: Write the failing tests**
  - `TestReview04_ApproveIsGuardedAndStoredBeforeTheLine`: open round, no drafts → `ok=true`, row `status='sent'`, `outcome='approved'`, `sent_at` set; a second call → `ok=false`, row unchanged.
  - `TestApproveReviewRound_Refusals` (table): drafts present; carried row present and `resolveOpen=false`; outdated row present and `resolveOpen=false`; round of another workbench; round not open; `session_id` NULL → each `ok=false` and no row of `review_rounds`/`review_comments` changed.
  - `TestApproveReviewRound_ResolveOpen`: carried + outdated rows, `resolveOpen=true` → `ok=true`, both rows `status='resolved'`, in the same tx (simulate: the round update fails → comments unchanged; use a closed-round variant).
  - `TestReviewRounds_SendSetsOutcomeChanges`: after `SendReviewRound` → `outcome='changes'`.
- [ ] **Step 2: Run** `go test ./internal/db -run 'Approve|SendSetsOutcome'` — Expected: FAIL (undefined `ApproveReviewRound`).
- [ ] **Step 3: Migration + schema mirror.** Plain `ALTER TABLE review_rounds ADD COLUMN outcome …` (Up), Down drops it via SQLite ≥3.35 `DROP COLUMN`. Mirror in `schema.sql`.
- [ ] **Step 4: Implement `ApproveReviewRound`** in `review_rounds.go` beside `SendReviewRound`, one `db.Begin()` tx: count drafts → refuse; count `carried`/`outdated` → refuse unless `resolveOpen`, else set them `resolved` with `updated_at`; then `UPDATE review_rounds SET status='sent', outcome='approved', sent_at=… WHERE id=? AND project_id=? AND status='open' AND session_id IS NOT NULL`; `RowsAffected != 1` → rollback, `ok=false`. Order the round UPDATE first so a refused round writes no comment. `SendReviewRound` adds `outcome = 'changes'` to its UPDATE.
- [ ] **Step 5: Regenerate snapshot + Swift test schema** (command above); run `go test ./internal/db` — Expected: PASS.
- [ ] **Step 6: Commit** `feat(review): round outcome column and guarded approve (#964)`.

### Task 2: Go — approve CLI, approved line, brief and get_review

**Files:**
- Modify: `internal/reviewdiff/line.go`, `cmd/workbench_review.go`, `cmd/workbench_brief.go`, `internal/tools/workbench_review.go`
- Create: `internal/reviewdiff/testdata/lines/approved.json`
- Test: `internal/reviewdiff/line_test.go`, `cmd/workbench_review_test.go`, `cmd/workbench_brief_test.go` (or the file that tests `reviewWaitingLine`), `internal/tools/workbench_review_test.go`

**Interfaces:**
- Consumes: `db.ApproveReviewRound`, `ReviewRound.Outcome` (Task 1).
- Produces: `func ApprovedLine(roundID int64) string` (`reviewdiff`); CLI `watchtower workbench review approve --round R [--resolve-open]` → `reviewEnvelope{OK, Sent, Line}` (Comments omitted); fixture `{"round_id":9,"kind":"approved","line":"…"}`.

- [ ] **Step 1: Failing tests**
  - `TestDeliveryLine_Fixtures` extended: a fixture with `"kind":"approved"` is checked against `ApprovedLine` (fixtures without `kind` stay `DeliveryLine`).
  - `TestWorkbenchReview_Approve`: approve on an open round → JSON `ok:true, sent:true, line:<ApprovedLine>`; second call → `sent:false`, no `line`; `--resolve-open` passes through.
  - Brief: an undelivered approved round renders `Review round #9 approved → get_review 9`; a `changes` round keeps the waiting line.
  - `get_review` on an approved round: text starts with `Outcome: approved — no changes requested` before the comment list; `Outcome` also in the JSON view as `outcome`.
- [ ] **Step 2: Run** `go test ./internal/reviewdiff ./internal/tools -run 'DeliveryLine|GetReview' && go test ./cmd -run 'WorkbenchReview_Approve|Brief'` — Expected: FAIL.
- [ ] **Step 3: Implement** `ApprovedLine` (copy the Global Constraints text verbatim); `workbenchReviewApproveCmd` registered next to `send`, flag `--resolve-open`; `reviewWaitingLine` takes the round and picks the approved form when `Outcome == "approved"`; `reviewText` prepends the outcome line; `reviewView.Outcome string \`json:"outcome,omitempty"\``.
- [ ] **Step 4: Run** the Step 2 commands — Expected: PASS. `make lint-diff`.
- [ ] **Step 5: Commit** `feat(review): workbench review approve and the approved line (#964)`.

### Task 3: Go — skill pack v14: approved rounds

**Files:**
- Modify: `internal/devpack/workbenchskill/watchtower-workbench/SKILL.md` (frontmatter `x-watchtower-pack: v14`, section "Review rounds"), `internal/devpack/workbenchskill/watchtower-flow/SKILL.md`, `.claude/skills/watchtower-workbench/SKILL.md` and `.claude/skills/watchtower-flow/SKILL.md` if they are copies (check `skill_symlink_test.go`)
- Create: `internal/devpack/testdata/watchtower-workbench-v13.md` (the v13 text, as earlier bumps did — follow `git log -S 'x-watchtower-pack: v13' --oneline` for the pattern)
- Test: `internal/devpack/pack_test.go` / `workbench_test.go` (whatever pins the current version and the upgrade from v13)

**Interfaces:** Consumes the line text from Task 2.

- [ ] **Step 1: Failing test** — the existing version/upgrade test expects v14 and an install over a v13 file upgrades it; a content assertion: the workbench skill contains `Review round #N approved` and `finish_session`.
- [ ] **Step 2: Run** `go test ./internal/devpack` — FAIL.
- [ ] **Step 3: Edit the skills.** Workbench skill "Review rounds" gains a bullet: *An `approved` round* (the line `Review round #N approved …`, or `Outcome: approved` in `get_review`): the owner accepted the branch — read it with `get_review`, then do the methodology's finishing steps (PR and merge, targets `done`, cleanup, `finish_session`) without asking for another review. Flow skill: one sentence in "Running a plan"/review text saying the same.
- [ ] **Step 4: Run** `go test ./internal/devpack` — PASS.
- [ ] **Step 5: Commit** `feat(devpack): skill pack v14 — approved review rounds (#964)`.

### Task 4: Swift — Approve / Request changes

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Review/ReviewDeliveryLine.swift`, `…/WatchtowerCore/Models/ReviewModels.swift` (`ReviewRoundInfo.outcome`), `Sources/Services/WorkbenchCLI.swift` (beside `reviewSend`, line ~920), `Sources/ViewModels/ReviewChangesModel.swift` (`// MARK: - Send`), `Sources/Views/Workbench/Review/ReviewToolbar.swift`, `Sources/Views/Workbench/Review/ReviewChangesPaneView.swift` (banner)
- Create: `Sources/Views/Workbench/Review/ReviewApprovePopover.swift`
- Modify: `docs/inventory/review.md` (REVIEW-04: Approve path + new guards + changelog line)
- Test: `Tests/Core/ReviewDeliveryLineTests.swift`, `Tests/ReviewChangesModelTests.swift`, `Tests/WorkbenchCLIReviewTests.swift`, `Tests/ReviewPresentationTests.swift`

**Interfaces:**
- Consumes: CLI `review approve` envelope (Task 2).
- Produces: `ReviewDeliveryLine.approved(roundID:) -> String`; `WorkbenchCLI.reviewApprove(projectID:roundID:resolveOpen:) async throws -> ReviewEnvelope`; `ReviewChangesModel.approve(resolveOpen: Bool) async`; `ReviewChangesModel.openEarlierComments: [ReviewComment]` (carried + outdated of the open round); `ReviewChangesModel.approvalBlocker: String?` (nil = Approve enabled; `"Send or delete the N drafts first"`, `"The session is gone"`); `ReviewToolbar.canApprove(_:) -> Bool`.

- [ ] **Step 1: Failing tests**
  - `testMatchesGoFixtures` reads `approved.json` (`kind`) and checks `ReviewDeliveryLine.approved`.
  - `testReview04_ApproveTypesOnce`: approve → one `deliverLine(.review(id))` with the approved line; `round.outcome == "approved"`, status `sent`; second call types nothing.
  - `testApproveRefusedTypesNothing`: CLI answers `sent:false` → nothing typed, `lastError == alreadySentMessage`, round shown closed.
  - `testApprovalBlockerWithDrafts` / `…NoSession`; `testOpenEarlierCommentsListsCarriedAndOutdated`.
  - Toolbar: `canApprove` false with drafts, while sending/refreshing, on a closed round; the prominent label reads `Request changes (N)`.
- [ ] **Step 2: Run** `make test-swift FILTER='ReviewDeliveryLineTests|ReviewChangesModelTests|WorkbenchCLIReviewTests|ReviewPresentationTests'` — FAIL.
- [ ] **Step 3: Implement.** `approve` mirrors `send()` (same `sending` guard, `flushState`, `checked`, `lineDelivery.deliverLine(…, key: .review(info.id), …)`, `lastSend`). Toolbar: rename the Send button label to `Request changes (N)`; add **Approve** (prominent) → popover (`ReviewApprovePopover`: title `Approve <branch>?`, next-step sentence, warnings: unviewed chapters count + lines from `model.progress`, Wrap-up items `partial`/`not_done`, `openEarlierComments` listed; button `Approve` or `Resolve N and approve` → `approve(resolveOpen: N > 0)`). On a closed round the toolbar shows the outcome text (`Approved` / `Changes requested`) instead of both buttons; Start next round stays where it is today. Banner (spec §6 "After Approve") in the pane above the diff when `round.outcome == "approved"`, delivery text from `lastSend` as Send's footer does today.
- [ ] **Step 4: Inventory** — REVIEW-04 Observable gains the Approve path (same order: stored first, then the line through `LineKey.review`); guards list gains `TestReview04_ApproveIsGuardedAndStoredBeforeTheLine` and `testReview04_ApproveTypesOnce`; changelog line dated 2026-10-24, "approved by the owner, ask #559".
- [ ] **Step 5: Run** Step 2 again — PASS; `make lint-swift`; `make desktop-shots DESKTOP_SHOTS=<dir>` and look at the toolbar and popover.
- [ ] **Step 6: Commit** `feat(review): Approve and Request changes in Branch review (#964)`.

### Task 5: Fold unchanged regions, Full file switch

**Files:**
- Modify: `WatchtowerDesktop/Sources/CodeEditorWeb/diff.js`, `diff.html` (protocol header), `Sources/Views/Workbench/Review/MonacoDiffView.swift`, `ReviewFileHeader.swift`, `ReviewChangesPaneView.swift`
- Test: `Tests/Core/CodeEditorPageProtocolTests.swift`, `Tests/ReviewChangesModelTests.swift` (or a new `ReviewFullFileTests` if state lives in the view), `make editor-bridge-check`

**Interfaces:**
- Produces: page call `wt.setFullFile(bool)`; `MonacoDiffView` input `fullFile: Bool`; pane state `fullFile` reset on `selectedPath` change.

- [ ] **Step 1: Failing tests** — protocol test lists `wt.setFullFile` as a declared Swift→page call; a test that switching `selectedPath` resets `fullFile` to false.
- [ ] **Step 2: Run** `make test-swift FILTER='CodeEditorPageProtocolTests|ReviewChangesModelTests'` — FAIL.
- [ ] **Step 3: Implement.** In `createDiffEditor` options: `hideUnchangedRegions: { enabled: true, contextLineCount: 3, minimumLineCount: 6, revealLineCount: 20 }`. `wt.setFullFile(on)` → `editor.updateOptions({ hideUnchangedRegions: { enabled: !on } })`. Reveal rule (zones on folded lines — Review Focus 1): first spend ≤ 30 min checking whether 0.57 exposes a public way to unfold one hidden region (e.g. the reveal of a hidden line through the modified editor). If it does, after `onDidUpdateDiff` unfold each region holding a comment/note/Undo zone line, and make `wt.focus(line)` unfold before scrolling. If it does not, use the fallback: when any zone line of the shown file lies in a folded run (a line farther than 3 lines from every change), render that file with `enabled:false` and show the header switch on **Full file**; `wt.focus` on a folded line does the same. Record which path was taken in a comment and in Task 12's feature note. Header: `Changes | Full file` segmented control (design kit).
- [ ] **Step 4: Run** Step 2 + `make editor-bridge-check` — PASS. Manual: `make desktop-shots` on a long file shows fold bars; a comment inside a fold is visible (Review Focus 1).
- [ ] **Step 5: Commit** `feat(review): fold unchanged regions, Full file switch (#959)`.

### Task 6: Mark a whole chapter viewed

**Files:**
- Modify: `Sources/ViewModels/ReviewChangesModel.swift` (beside `toggleViewed`, `selectChapter`), `Sources/Views/Workbench/Review/ReviewChapterListView.swift`, `ReviewChangesPaneView.swift` (footer bar)
- Create: `Sources/Views/Workbench/Review/ReviewChapterFooter.swift`
- Test: `Tests/ReviewChangesModelTests.swift`

**Interfaces:**
- Produces: `func setViewed(_ paths: [String], on: Bool) async throws` (one write batch through `ReviewQueries.setViewed`); `func markChapterViewed(_ key: String) async throws`; `func toggleChapterViewed(_ key: String) async throws`; `func nextUndoneChapter(after key: String) -> String?`.

- [ ] **Step 1: Failing tests**
  - `testMarkChapterViewedMarksEveryFileAndMovesOn`: 3 chapters, chapter 1 partly viewed → all its files viewed, `currentChapterKey` = chapter 2.
  - `testMarkChapterViewedSkipsDoneChaptersAndWraps`; `testMarkLastChapterGoesToWrapUp` (all done → `phase == .wrapup`).
  - `testToggleChapterViewedOnDoneChapterUnviewsAllAndStays`.
  - `testChangedFileUnmarksTheChapter` (content sha moves → `ReviewChapters.done` false).
  - Sent round: marks are refused like `toggleViewed` today (same `run`/open-round rule).
- [ ] **Step 2: Run** `make test-swift FILTER=ReviewChangesModelTests` — FAIL.
- [ ] **Step 3: Implement.** `setViewed` writes each path's `contentKey` (or nil) in one `write` closure and reloads `viewed`; `markChapterViewed` = `setViewed(unviewed paths, on: true)` then `nextUndoneChapter(after:)` → `selectChapter`, or `setPhase(.wrapup)` when none. Footer: `Chapter i of n · v of f files viewed · Chapter viewed →`, shortcut ⌥⌘↓, shown in the Chapters phase. Chapter row checkbox → `toggleChapterViewed`.
- [ ] **Step 4: Run** — PASS; `make lint-swift`.
- [ ] **Step 5: Commit** `feat(review): mark a chapter viewed and move on (#963)`.

### Task 7: Lens checklist out, AI risks in

**Files:**
- Delete: `Sources/Views/Workbench/Review/ReviewChecklistView.swift`
- Create: `Sources/Views/Workbench/Review/ReviewChapterRisksView.swift`
- Modify: `ReviewChangesPaneView.swift` (line ~191 mount; comment sheet lens picker ~35/58/315), `ReviewChangesModel.swift` (`risk(for:)` → `risks(for:)`, new `chapterRisks(_:)`, `offerAIChapters`), `ReviewFileListView.swift` (badge uses the highest level)
- Test: `Tests/ReviewChangesModelTests.swift`, `Tests/ReviewPresentationTests.swift`

**Interfaces:**
- Produces: `func risks(for path: String) -> [ReviewOverview.Risk]`; `func chapterRisks(_ key: String) -> [ReviewOverview.Risk]`; `func highestRisk(for path: String) -> ReviewOverview.Risk?`; `ReviewChapterRisksView(model:onComment:onAsk:)` where `onAsk: (ReviewOverview.Risk) -> Void` (wired by Task 11; until then a no-op closure and the button hidden).

- [ ] **Step 1: Failing tests**
  - `testChapterRisksListsEveryRiskOfItsFiles` (two risks on one file both listed).
  - `testHighestRiskPicksHighLevel`.
  - `testAIChaptersHeldBackOnceAChapterFileIsViewed` and `…OnceAChapterHasAComment` (replaces the checks signal); `testAIChaptersAppliedWhenNothingStarted`.
  - `addComment` called without a lens stores `lens == ""`.
- [ ] **Step 2: Run** `make test-swift FILTER='ReviewChangesModelTests|ReviewPresentationTests'` — FAIL.
- [ ] **Step 3: Implement.** `offerAIChapters` "started" = any path of the shown chapters is viewed in `viewed`, or any comment of this round on such a path. Risks view: header "What to look at in this chapter"; row = level chip, `why`, `path` link (selects the file → first hunk), **Comment…** (design comment pre-filled `path — why`), **Ask agent**; empty overview → one line + **Run AI overview** (`makeOverview()`). Remove the lens picker from the compose sheet (keep `lens:` params with default `""`). Go side untouched (spec §3 "UI-only removal").
- [ ] **Step 4: Run** — PASS; `make lint-swift`; `make desktop-shots`.
- [ ] **Step 5: Commit** `feat(review): AI risks per chapter replace the lens checklist (#961)`.

### Task 8: Changed-files tree

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Review/ReviewFileTree.swift`, `Sources/Views/Workbench/Review/ReviewFileTreeView.swift`
- Modify: `ReviewFileListView.swift` (the "Files" section renders the tree; Summary card and Folded group stay)
- Test: `WatchtowerDesktop/Tests/Core/ReviewFileTreeTests.swift`

**Interfaces:**
- Produces: `package struct ReviewFileTree { package indirect enum Node: Equatable { case folder(name: String, path: String, children: [Node]); case file(path: String) }; package static func build(_ paths: [String]) -> [Node] }` — compacts single-child folder chains (`a/b/c/x.swift` alone → folder `a/b/c`), folders first then files, each by localized standard compare. Folder row counts come from the view (`model.isViewed`, comment counts) — not stored in the tree.

- [ ] **Step 1: Failing tests** — `testBuildsFoldersFirstSorted`, `testCompactsSingleChildChains`, `testRootFilesStayAtTop`, `testRenamedFileAppearsOnceUnderItsNewPath` (input is `files.map(\.path)`), `testEmpty`.
- [ ] **Step 2: Run** `make test-swift FILTER=ReviewFileTreeTests` — FAIL.
- [ ] **Step 3: Implement** `build`, then the view: `OutlineGroup`/`DisclosureGroup` over nodes, file rows reuse `ReviewFileListView.row(file:model:)`, folder rows show `unviewed` count and summed comment badge; folders start expanded, expansion state per round in `@State`.
- [ ] **Step 4: Run** — PASS; `make lint-swift`; `make desktop-shots`.
- [ ] **Step 5: Commit** `feat(review): changed files as a folder tree (#960)`.

### Task 9: Navigation destination seam and the read-only preview

**Files:**
- Modify: `Sources/ViewModels/WorkbenchesViewModel+Panel.swift` (`showLocation`, `openFile(at:root:beside:)`), `Sources/Services/CodeNavigationCenter.swift` (`currentLocation`)
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Review/ReviewPathMap.swift`, `Sources/Views/Workbench/Review/ReviewCodePreview.swift` (read-only code viewer page host), `Sources/Services/CodeLocationDestination.swift`
- Modify: `ReviewChangesPaneView.swift` (centre area shows the preview when set; "← Back to diff")
- Test: `Tests/Core/ReviewPathMapTests.swift`, `Tests/WorkbenchesViewModelNavigationTests.swift` (new)

**Interfaces:**
- Produces:
  - `@MainActor protocol CodeLocationDestination: AnyObject { var isKeyDestination: Bool { get }; func show(_ location: CodeNavLocation, root: CodeRoot) -> Bool; var currentLocation: CodeNavLocation? { get } }`
  - `WorkbenchesViewModel.registerDestination(_:workbenchID:)` / `unregisterDestination(_:workbenchID:)`; `showLocation` and `openFile` first ask the registered destination when `isKeyDestination` and it returns `true` from `show`; otherwise today's Files path. `CodeNavigationCenter.currentLocation` prefers the key destination's `currentLocation`.
  - `package struct ReviewPathMap { init(repoPrefix: String) ; func toRoot(_ repoPath: String) -> String?; func toRepo(_ rootPath: String) -> String }` (`repoPrefix` = the workbench folder inside the repository, `""` at the top).
  - `ReviewChangesModel.preview: CodeNavLocation?` and `func showLocation(_:) -> Bool` (diff file → `select` + reveal line; other → `preview = location`); `closePreview()`.
- [ ] **Step 1: Failing tests**
  - Path map: top-level folder identity; subfolder `apps/web` → `apps/web/x.ts` ↔ `x.ts`; a repo path outside → nil.
  - Navigation: no destination registered → Files pane opened (existing behaviour); destination registered but not key → Files pane; key destination returning true → Files pane untouched (Review Focus 4).
  - Model: `showLocation` on a diff path selects it and records the line; on another path sets `preview`.
- [ ] **Step 2: Run** `make test-swift FILTER='ReviewPathMapTests|WorkbenchesViewModelNavigationTests|ReviewChangesModelTests'` — FAIL.
- [ ] **Step 3: Implement.** The Branch review pane registers its model (wrapped) as destination for its workbench on appear, unregisters on disappear; `isKeyDestination` = the pane's window is key and the review pane holds focus (track with the pane's focus state). Preview = the code viewer's `index.html` page in read-only mode (reuse the existing editor host with `readOnly`), path resolved against the session's `CodeRoot`, header "path · not changed in this branch · current files · ← Back to diff". The preview page keeps its definition/usages messages (it is the code viewer page), so walking the code works.
- [ ] **Step 4: Run** — PASS; `make lint-swift`.
- [ ] **Step 5: Commit** `feat(review): navigation lands in Branch review with a read-only preview (#960)`.

### Task 10: Navigation in the diff page

**Files:**
- Modify: `WatchtowerDesktop/Sources/CodeEditorWeb/diff.js`, `diff.html` (protocol header), `Sources/Views/Workbench/Review/MonacoDiffView.swift`
- Test: `Tests/Core/CodeEditorPageProtocolTests.swift`, `make editor-bridge-check`, `Tests/ReviewChangesModelTests.swift`

**Interfaces:**
- Consumes: `CodeLocationDestination`, `ReviewPathMap`, `ReviewChangesModel.showLocation` (Task 9); `CodeNavigationCenter.goToDefinition(_:root:anchor:)`, `CodeUsagesCenter.showUsages(of:root:)`.
- Produces: page→Swift messages on the modified editor only: `definition {req,id,word,line,col,x,y}`, `usages {id,word,line,col}` (same shapes as `editor.js`); Swift→page `definitionDone(req)`; `MonacoDiffView` conforms to `CodeDefinitionPage` and `CodeUsagesPage` and registers with both centres for the workbench while the review pane is the key destination (so menu ⌘-B/usages commands reach it).
- [ ] **Step 1: Failing tests** — protocol test declares the new messages for `diff.html`; a model test: a `definition` message for path `x` maps through `ReviewPathMap.toRoot` and calls the centre with the session root; an old-side request is ignored.
- [ ] **Step 2: Run** `make test-swift FILTER='CodeEditorPageProtocolTests|ReviewChangesModelTests'` — FAIL.
- [ ] **Step 3: Implement** — port `editor.js`'s ⌘-click and usages actions (same keybindings, context-menu entries) onto `editor.getModifiedEditor()`; `id` = the file's root-relative path; Open Quickly needs nothing new (it goes through `openFile`, Task 9).
- [ ] **Step 4: Run** Step 2 + `make editor-bridge-check` — PASS. Manual: ⌘-click a symbol defined in another changed file → that file selected at the line; defined in an unchanged file → preview; ⌃⌘← returns.
- [ ] **Step 5: Commit** `feat(review): go to definition and usages inside the diff (#960)`.

### Task 11: Chat panel and Ask agent

**Files:**
- Modify: `WatchtowerDesktop/Sources/CodeEditorWeb/diff.js`, `diff.html`, `MonacoDiffView.swift` (`onAsk`), `ReviewChangesPaneView.swift` (right panel), `ReviewToolbar.swift` (panel toggle), `ReviewChapterRisksView.swift` (wire `onAsk`)
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Review/ReviewAskQuote.swift`, `Sources/Views/Workbench/Review/ReviewAgentChatPanel.swift`
- Test: `Tests/Core/ReviewAskQuoteTests.swift`, `Tests/Core/CodeEditorPageProtocolTests.swift`

**Interfaces:**
- Consumes: `WorkbenchesViewModel.workchat(sessionID:) -> WorkchatModel?`, `SessionChatView(vm:sessionID:projectID:)`, `WorkchatModel.draft`.
- Produces: `package enum ReviewAskQuote { package static func code(path: String, side: String, startLine: Int, endLine: Int, lines: [String]) -> String; package static func risk(path: String, level: String, why: String) -> String; package static let maxLines = 40 }`; page action `wt.ask` (context menu "Ask agent", ⇧⌘A) posting `{type:"ask", side, startLine, endLine}`.
- [ ] **Step 1: Failing tests**
  - `testCodeQuoteFormat`: ``Re `a/b.swift:31–34`:`` + fenced block with a language-neutral fence; old side adds ` (old side)`.
  - `testCodeQuoteCapsAt40Lines` (500 lines → 40 + `…`), `testSingleLineUsesOneNumber` (`:31`).
  - `testRiskQuote`.
  - Protocol test declares `ask`.
- [ ] **Step 2: Run** `make test-swift FILTER='ReviewAskQuoteTests|CodeEditorPageProtocolTests'` — FAIL.
- [ ] **Step 3: Implement.** Panel: `SessionChatView` for `round.sessionID`, 360 pt default, toggle in the toolbar + ⌥⌘C (check the main menu for a clash first; pick another and note it if taken), open state and width in `@AppStorage("review.chatPanel.<workbenchID>")`; no `WorkchatModel` → "The session is not running". Ask: Swift reads the lines from `currentSides` (old/new by side), builds `ReviewAskQuote.code`, prepends it to `draft` followed by a blank line, opens the panel, focuses the composer. Risks' **Ask agent** uses `ReviewAskQuote.risk`.
- [ ] **Step 4: Run** — PASS; `make editor-bridge-check`; `make lint-swift`; `make desktop-shots`.
- [ ] **Step 5: Commit** `feat(review): session agent chat beside the diff, Ask agent on lines (#962)`.

### Task 12: Docs

**Files:**
- Modify: `docs/features/diff-reviewer.md` (new section "Polish (#958, 2026-10-24)" summarising Tasks 1–11 with file names), `docs/guide/features/workbench/diff-review.md` (fold, Full file, tree, navigation, chat, Chapter viewed, Approve / Request changes — per `docs/guide/WRITING.md`), `docs/guide/reference/keyboard-shortcuts.md` (⇧⌘A, ⌥⌘↓, the chat toggle), `CLAUDE.md` (append "; polish #958: …" to the Diff reviewer feature line)
- Test: `go test ./docs/guide` (8 KB cap)

- [ ] **Step 1:** Write the sections.
- [ ] **Step 2: Run** `go test ./docs/guide` — PASS.
- [ ] **Step 3: Commit** `docs(review): Branch review polish (#958)`.
