# Workbench owner asks — plan (2026-10-03)

**Spec:** `docs/superpowers/specs/2026-10-03-workbench-owner-asks-design.md` (Parts referenced as §N).
**Board:** feature target #314; the §9 inventory amendments were approved by the owner on 2026-10-03.
**Branch:** one plan branch, `feature/workbench-owner-asks`. Go tasks may run in parallel lanes
where `Depends on` allows. Swift tasks run one at a time, in one worktree.
**Before starting:** the owner approves the inventory amendments of §9. Until then, Tasks 2–4
must not touch a PROJ guard's assertions.

Every task runs only its inner loop (`go test ./internal/<pkg>`,
`make test-swift FILTER=…`, `make lint-diff`). The full gate is Task 14. The reviewer checklist
is `docs/review/review-rules.md`; the implementer self-reviews against it before hand-back.

---

## Phase 1 — Go

### Task 1 — `internal/asks`: validation, answer, rendering, delivery line
- **Files:** `internal/asks/{asks.go,answer.go,render.go,line.go}`,
  `internal/asks/testdata/{cards,answers,lines}/*.json`, tests.
- **Produces:**
  - `asks.Input`, `asks.Validate(Input) (Payload, error)` (§3 table; error `field: reason`).
  - `asks.Payload{Focus, Questions, Checklist}`.
  - `asks.Answer` plus `asks.ParseAnswer([]byte) (Answer, error)`.
  - `asks.Render(kind, Payload, Answer) string` (the `answer_text` of §4).
  - `asks.DeliveryLine(id, kind, Answer) string` (§5).
  - Constants `MaxOpenPerWorkbench = 30` and `MaxSnapshotBytes = 2 << 20`.
- **Depends on:** none.
- **Tests:**
  - Each §3 bound at limit and limit+1: title 120/121 runes, 4/5 questions, 1/5 options,
    30/31 checklist items, focus 5/6.
  - Kind rules: `question` without questions is rejected; checklist on `review` is rejected;
    `heading` on a `check` focus is rejected; `changes` without `previous_ask_id` is rejected.
  - Duplicate ids are rejected. Missing ids default to their 1-based position.
  - Every `testdata/cards/*.json` is accepted or rejected exactly as its file name says
    (`valid_*`/`invalid_*`).
  - Answer: a review without a verdict is rejected; a broken item without a note is rejected;
    an unknown state is rejected; a question missing from `answers` is rejected.
  - Render golden per kind.
  - `DeliveryLine`: a title containing `\n`, `\r`, ESC or a C1 control character comes out as
    one line with spaces. The goldens in `testdata/lines` match.

### Task 2 — kb file sets + workbench folder listing (PROJ-08 amended)
- **Files:** `internal/kb/fileset.go` (new); `internal/kb/source_workbench.go` (rewritten onto
  file sets, key `wbdoc:<project>:<rel>`); `internal/workbenchdocs/list.go` (new
  `ListTextFiles(ctx, folder) ([]File, error)`); the PROJ-08 tests (renamed per §9, assertions
  kept).
- **Produces:**
  - `kb.FileSet{Source, Container, Root, Files}` and `kb.IndexFileSet(ctx, d, FileSet) (docs, changed int, err)`.
  - `kb.IndexWorkbenchDocs(ctx, d, projectID)` (same signature, folder-driven).
  - `workbenchdocs.ListTextFiles`.
- **Consumes:** `gitbin`, `workbenchgit` env rules, `resolveInside`, `privacyProtected`,
  `markdownSections`.
- **Depends on:** none. Does not read `project_documents` any more; the table is left for Task 4.
- **Tests:**
  - In a git repo: a tracked `.md`, an untracked non-ignored `.txt` and an ignored `.md`. The
    first two are indexed, the ignored one is not.
  - `.claude/worktrees/x/a.md` (ignored) is not indexed.
  - Outside git: the walk skips `node_modules` and `.git`, and does not follow a symlink to
    outside the folder.
  - 2001 files: the 2000 newest are indexed, and the cut is logged.
  - A file removed from disk loses its entry on the next pass. A newly ignored file loses its
    entry.
  - Changing the mtime backwards re-renders.
  - A failing git run (fake `gitbin` path that exits 1) returns an error and keeps the
    existing entries.
  - Visibility: the renamed `TestProj08_ProjectDocsOnlyInTheirOwnProjectSession` passes with
    unattached files.
  - A `privacyProtected` folder is skipped by the daemon pass and indexed by an explicit
    `IndexWorkbenchDocs`.
  - 2 MiB+1 is `truncated`; a FIFO is `unreadable` and never opened blocking.

### Task 3 — Go removal of attached documents
- **Files:**
  - `internal/tools/workbench_docs.go`: `attach_document` is removed; the `list_comments`
    `document_id` refusal of §4 is added.
  - `internal/tools/workbenches.go`: `workbench_board` drops documents.
  - `internal/db/workbench_comments.go` and `workbenches.go`: the document reads and writes go.
  - `cmd/workbench.go`: `import-docs`, `attach-doc` and the import in `create` are removed; the
    `create --json` keys of §7 are removed.
  - `cmd/workbench_resync.go`: the import is replaced by an index run (`index_ok`/`index_error`).
  - `workbench brief`: the documents parts go.
  - `internal/workbenchdocs/{import,scan}.go`: deleted, apart from what `ListTextFiles` reuses.
- **Depends on:** Task 2.
- **Tests:**
  - `list_comments {document_id: 1}` returns the §4 error text.
  - `attach_document` is not in the workbench registry and is unknown under `mcp --workbench`.
  - `workbench create --json` has no `docs_import_*` keys.
  - `resync --json` has `index_ok` true on a fixture folder, and `index_error` set when git
    fails.
  - `workbench brief` golden without documents.
  - `TestProjectResync_IsAdditive` still passes (no new targets, sources untouched).

### Task 4 — Migration `00100_owner_asks` (written as `00097`, renumbered after main's `00099` on the 2026-10-03 merge) + `internal/db/owner_asks.go`
- **Files:** the migration, `internal/db/schema.sql`, the goldens, `TestAllTablesExist`,
  `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (generated),
  `internal/db/owner_asks.go`.
- **Produces:**
  - `db.InsertOwnerAsk(tx, OwnerAsk) (id, superseded int64, err)`, with the 30-open cap and
    supersede in the same transaction.
  - `db.GetOwnerAsk(projectID, id)`.
  - `db.ListOwnerAsks(projectID, filter)`.
  - `db.WithdrawOwnerAsk(projectID, id, reason)`, returning `ErrAskNotOpen`.
  - `db.MarkOwnerAskDelivered(projectID, id) (bool, error)`.
  - `db.AnsweredAsksForBrief(projectID, sessionID)`.
- **Depends on:** Task 3 (no Go reader of `project_documents` or the anchor columns remains).
- **Tests:**
  - Up on a DB holding documents, document comments with replies, target comments and
    `project_doc` kb rows. Afterwards: target comments and their replies survive; document
    comments and their replies are gone; `project_documents` is gone; `kb_fts` has no rows for
    the deleted chunks (an FTS query for a unique word from them returns 0).
  - Down then up is clean.
  - CHECKs: a review without `doc_path` is rejected; `answered` without an answer is rejected;
    a bad `withdrawn_reason` is rejected.
  - The 31st open ask is refused.
  - Supersede marks the previous open ask `withdrawn/superseded`, and an answered previous ask
    is left alone.
  - `MarkOwnerAskDelivered` on `open` is false and on `answered` is true once (a second call is
    false).
  - `DeleteWorkbench` removes the asks (PROJ-02 test extended).
  - A deleted session row sets `session_id` NULL.
  - Another workbench's id is not found.

### Task 5 — MCP tools `ask_owner`, `get_ask`, `list_asks`, `withdraw_ask`
- **Files:** `internal/tools/workbench_asks.go` plus its test; `buildToolRegistry` wiring;
  legacy-mode registration (same names).
- **Consumes:** Tasks 1 and 4; `tools.ResolveWorkbenchDocumentPath`; the env
  `WATCHTOWER_TERMINAL_SESSION_ID` (read through an injectable getter); `kb.IndexFileSet` for
  the one file (best-effort, `index_warning`).
- **Depends on:** Tasks 1, 2, 4.
- **Tests:**
  - **Env binding:**
    - A valid env pointing at this workbench's row binds the session (`session_bound` true).
    - An env pointing at another workbench's row, a garbage env or no env gives NULL and
      `session_bound` false.
  - **Review:**
    - It snapshots the file text exactly.
    - A path outside the folder, a symlink escaping it, a `.go` file, a 2 MiB+1 file and
      non-UTF-8 content are each refused.
    - The ask never writes the folder (`TestProj03_AskOwnerNeverWritesTheFolder`: tree hash and
      mtimes unchanged).
  - **Supersede:** `previous_ask_id` from another workbench is refused; `superseded` is
    returned.
  - **`get_ask`:**
    - On `open` it returns no answer and does not change the status.
    - On `answered` it returns `answer` and `answer_text` and sets `delivered`.
    - From another workbench it returns `no ask with id N`.
  - **`list_asks`:** the default order is answered-undelivered first, then open.
  - **`withdraw_ask`:** on an answered ask it returns `ask N is answered`.
  - **Audit:** an `agent_actions` audit row is written per write tool.
  - **Removed tool:** `attach_document` is absent.

### Task 6 — Brief: "Answered asks for you"
- **Files:** `cmd/workbench_brief.go` (+ session env read, shared with
  `workbench_brief_session.go`), golden tests.
- **Depends on:** Task 4.
- **Tests:**
  - The brief with env = session S lists S's answered asks and the NULL or gone-session ones,
    plus the count line for others.
  - Delivered asks are not listed.
  - With a full board at the 4000 cap the section still shows at least one row (PROJ-12 part; spec "PROJ-11", renumbered).
  - With no answered asks the section is absent.

### Task 7 — Ask guard: skill v2, Stop prompt hook, PreToolUse command hook
- **Files:**
  - `internal/devpack/workbenchskill/watchtower-workbench/SKILL.md` (rewritten per §6.1, pack
    marker `v2`).
  - `internal/devpack/askguard_prompt.md` (embedded, §6.2 text).
  - `internal/devpack/workbench_settings.go`: the prompt hook upsert, has and remove keyed on
    the marker; the PreToolUse spec.
  - `internal/devpack/workbench.go`: install, remove and status.
  - `cmd/workbench_askguard.go`: `workbench ask-guard --workbench N --pre-tool-use`.
  - `cmd/integrate_workbench.go`: `ask_guard`/`ask_tool_block` in `integrate status --json`.
  - Desktop `WorkbenchCLI` Repair condition (one line, decode only).
- **Depends on:** Task 5.
- **Tests:**
  - **Prompt hook:**
    - Install writes a `type: prompt` Stop hook whose prompt starts with the marker for N and
      equals the golden after substitution.
    - Re-install replaces in place (no duplicate).
    - An owner-edited prompt whose marker is intact is replaced, while the owner's own
      unrelated Stop hooks and keys are byte-kept (PROJ-04).
    - A malformed settings file is left byte-identical and reported.
  - **PROJ-13** (spec "PROJ-12", renumbered): the golden contains the `stop_hook_active` and
    filed-ask (`last_assistant_message` names `ask #<number>`) pass clauses.
  - **PreToolUse command:**
    - It prints exactly the §6.3 JSON for a live workbench.
    - For a deleted workbench, a bad id or a panic it prints nothing and exits 0.
    - It finishes within 2 s with a locked DB (busy timeout bounded).
  - **Remove:** both hooks go and the owner's PreToolUse entries stay (PROJ-02 test extended).
  - **Status:** `integrate status --json` reports both keys; the Desktop decodes and offers
    Repair when either is false.
  - **Skill:**
    - The skill contains no `attach_document`, and names `ask_owner`, `get_ask`,
      `withdraw_ask`.
    - The DEV-04 digest changes, so an unedited v1 copy is upgraded and an edited one is kept
      as `drifted`.

## Phase 2 — Desktop (one lane, in order)

### Task 8 — Core: asks model, queries, answer encoder, prompt line, stack, diff; drop document Core
- **Files (WatchtowerCore):**
  - `Models/OwnerAsk.swift`, `Database/Queries/OwnerAskQueries.swift`.
  - `Services/OwnerAskAnswer.swift`, `Services/OwnerAskPrompt.swift`,
    `Services/OwnerAskStack.swift`, `Services/OwnerAskSnapshotDiff.swift`.
  - Removed: the document parts of `Workbench.swift`, `WorkbenchQueries`,
    `WorkbenchDocumentGrouping.swift` and the document drafts of `WorkbenchCommentDrafts`.
- **Depends on:** Task 4 (generated test schema), Task 1 (fixtures).
- **Tests (Tests/Core):**
  - `OwnerAskAnswer` encodes each `internal/asks/testdata/answers/*.json` case byte-equal after
    key sort.
  - Every `testdata/cards` file decodes through `ChatQuestionCard`'s decoder with the same
    accept/reject as Go.
  - `OwnerAskPrompt` reproduces `testdata/lines`.
  - `answer(_:with:)` on an ask withdrawn meanwhile throws `.notOpen` and writes nothing.
  - Stack: ordering by `created_at`; per-session counts; session-less asks grouped.
  - Diff: added, removed and changed headings listed; identical snapshots give "no changes".

### Task 9 — Desktop: remove the Documents pane; badge and notifications
- **Files:**
  - `WorkspaceLayout`/`WorkspacePane`: `.documents` removed, decoding to `.default`.
  - `WorkbenchPageView` header.
  - Views and ViewModels deleted per §8.
  - `WorkbenchTargetDetailCard` shows the target's asks.
  - `WorkbenchNotificationPolicy` and its snapshot: `askOpened` added, document kinds removed.
  - The sidebar badge query.
- **Depends on:** Task 8.
- **Tests:**
  - A saved layout naming `documents` decodes to `.default`.
  - Notification policy:
    - One new open ask yields one `askOpened`; three or more coalesce.
    - The owner's own answer is not announced.
    - A pre-change persisted snapshot announces nothing on its first poll.
  - The badge equals open asks plus unread agent target comments.
  - No document symbol is left (a source scan test like CHAT-05's for the removed type names).

### Task 10 — `OwnerAsksViewModel`: polling, drafts, answering, delivery
- **Files:** `ViewModels/OwnerAsksViewModel.swift` (owned by `WorkbenchesViewModel`),
  `Services/OwnerAskDrafts` (Core if pure), the quit-with-drafts prompt hook-up.
- **Consumes:** `OwnerAskQueries`, `TerminalCenter.sendPrompt`, `OwnerAskPrompt`.
- **Depends on:** Task 8.
- **Tests:**
  - Start an answer, navigate away and come back: the drafts are intact (the
    async-state-survives-navigation rule).
  - Answer with the session running: one DB write, then exactly one `sendPrompt` with the line;
    focus moves to the terminal.
  - `.copied` shows the clipboard hint.
  - `.noSession` writes the answer, types nothing and says "уйдёт в brief".
  - Answering an ask the agent withdrew meanwhile writes nothing, keeps the drafts and shows
    the notice.
  - A double-click on Send writes once.
  - A poll fingerprint change reloads; an unchanged one does not.
  - Quitting with drafts asks first.

### Task 11 — Views: stack, session counts, banner, drawer, question and check bodies, answer bar
- **Files:** `Views/Workbench/Asks/{OwnerAskStackSection,OwnerAskBanner,OwnerAskDrawer,OwnerAskHeaderCard,OwnerAskChecklistBody,OwnerAskAnswerBar,OwnerAskClosedList}.swift`;
  `WorkbenchSessionsPanel`, `WorkbenchSessionView` integration; `ChatQuestionCardView` reused
  (only the adaptation needed to take picks from `OwnerAskDrafts`).
- **Depends on:** Tasks 9 and 10.
- **Tests (ViewModel-level plus pure presentation helpers):**
  - Clicking a stack row selects its session and opens the drawer on that ask; "k из N ›" moves
    to the next ask and switches session when needed.
  - The answer bar label per kind and the check summary text (`1 ок · 1 сломано · 1 не
    отмечено`).
  - Answer is disabled until every question has a pick and a review has a verdict; it is
    enabled for a check with unmarked items.
  - A closed ask renders read-only with the answer, and withdrawn ones carry their reason.
  - The drawer width is persisted.

### Task 12 — Review body: typography, margin comments, focus, diff
- **Files:** `Views/Workbench/Asks/{OwnerAskReviewBody,OwnerAskMarginComments,OwnerAskDiffSheet}.swift`;
  `ReviewTypography` (the style mapping applied by `DocumentTextView`, column ≤ 680 pt);
  `CommentableDocumentText` reused over `doc_snapshot`.
- **Depends on:** Task 11.
- **Tests:**
  - `ReviewTypography`: font sizes and paragraph spacing per `DocumentStyle`, and table cells
    are mapped to `NSTextTable` blocks (pure attribute inspection).
  - Margin layout (pure `OwnerAskMarginLayout`): two comments anchored on overlapping lines do
    not overlap, and with zero comments the margin width is 0.
  - A focus `heading` resolves to its heading's range; a focus `quote` not found in the
    snapshot is listed in the header without a link.
  - A comment's anchor is taken against the snapshot text (`CommentAnchor`) and round-trips
    into the answer's quote, prefix, suffix and heading.

## Phase 3 — Docs and gate

### Task 13 — Docs and inventory
- **Files:**
  - `docs/features/workbench.md`: the documents bullets are replaced by an **Owner asks**
    bullet; Rename and Code viewer references to Documents are updated.
  - `docs/app-guide.md`: Workbench section.
  - `docs/inventory/workbench.md`: PROJ-02/03/04/08 amended, PROJ-12/13 added (the spec's
    PROJ-11/12, renumbered), as §9 approved plus the implementation rulings, with guard test
    names.
  - `docs/inventory/dev-surface.md` (DEV-06: fourteen tools, asks in rule 1, the `doc_path`
    rule, `get_ask`'s unaudited `delivered`), `docs/inventory/agent-actions.md` (AGENT-06
    scope note), `docs/inventory/knowledge-search.md` and `docs/features/knowledge-search.md`
    (`project_doc` wording).
  - The CLAUDE.md feature line.
- **Depends on:** Tasks 1–12 and the owner's approval of §9.
- **Tests:** none; `make lint` covers the markdown links.

### Task 14 — Gate and manual check
- `make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`, run once by the
  controller.
- Manual check on a dev build, written into the PR body:
  1. In a workbench session ask the agent to write a tiny spec. It files a review ask (and is
     caught by the Stop hook if it only asks in text). The stack shows it; open it next to the
     terminal, comment, request changes; the line is typed unsubmitted; Return; the agent
     calls `get_ask`; the ask is `delivered`.
  2. A check ask with one broken item.
  3. A question ask answered while its session is stopped: start the session; the brief lists
     it.
  4. Ask the agent to use `AskUserQuestion`: it is denied and files an ask.
  5. `search_knowledge` in the session finds an unattached `docs/` file; the main AI Chat does
     not.
  6. Re-run Setup on a pre-change folder: the skill becomes v2, both hooks are present and
     Repair is gone.
