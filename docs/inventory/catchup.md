# Behavior Inventory — Catch-up

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/catchup/`, `internal/db/catchup.go`,
> `internal/db/catchup_store.go`, or
> `WatchtowerDesktop/Sources/{Views,ViewModels}/CatchUp*`, read this file
> first. Any proposed change that would break a guard test or remove a
> contract must be raised as a question before touching code.

**Module:** `internal/catchup/` + `internal/db/catchup.go` + `internal/db/catchup_store.go` + `WatchtowerDesktop/Sources/{Views,ViewModels}/CatchUp*`
**Last full audit:** 2026-09-04

**What it is.** Catch-up is an on-demand absence recap: one persisted document per time window answering "what did the company do while I was away." A run (`watchtower catchup run`) resolves a window — **auto** (from the most recently *acknowledged* recap's `period_to`, or `now − 24h` when none exists), a **preset** (`today`/`yesterday`/`3d`/`week`, local time), or **custom** `--from`/`--to` — capped at 31 days and rejected when `from` does not precede `to`. When the window's `to` is within 5 minutes of now, the run first **tops up** coverage by calling the same channel-digest and Gmail/Jira stream-digest pipelines the daemon already runs (`digest.Pipeline.RunChannelDigestsOnly`, `ideas.Pipeline.RunStreamDigests`), gated by their own feature flags; a gated-off or already-past window skips the top-up (`coverage.topup = "skipped"`), and a failing top-up is recorded but never fails the run (CATCHUP-03). The pipeline then **gathers** eight window-scoped areas — channel digests, Gmail/Jira stream digests, meeting recaps, ad-hoc transcript summaries, decisions, actionable inbox items, updated tracks, and due/overdue targets — each capped by `catchup.caps.*`, and renders them into one strong-tier `catchup.compose` call (source tag `catchup.compose`; the system prompt always carries `prompts.Directive(digest.language)`, CATCHUP-02). Go validates every `[area#id]` ref the model cites against the gathered set before persisting: an unknown ref is dropped and counted, and an item left with zero valid refs is dropped outright (CATCHUP-04). An empty gather short-circuits to a `ready`, empty-bodied recap with no AI call. Every run inserts a **new** `catchup_recaps` row (migration 00061); nothing is edited in place except by an explicit `--regen <id>`, which rebuilds the *same* window as a new row carrying `regen_of_id`. A single **"I'm caught up"** action marks the whole window read across five `read_at` surfaces — `digests`, `stream_digests`, `tracks`, `inbox_items`, `briefings` — in one transaction, idempotently (CATCHUP-01). Per-topic 👍/👎 with a comment still derives learned rules for the source pipelines (`catchup feedback`), and a presentation-correction comment triggers a whole-recap regen.

**Two implementations, one behavior.** As before the rewrite, the acknowledge logic exists **twice**: Go (`Pipeline.Acknowledge`, CLI `catchup ack`) and Swift (`CatchUpQueries.acknowledge(recap:)`, the Desktop "I'm caught up" button, which writes the shared DB directly and never calls Go). Every contract below that mentions acknowledge must hold on **both** paths; guard lists pair the Go and Swift tests deliberately. The Swift-side guards for the rewritten window ack are not written yet — a later task (Task 13) adds `WatchtowerDesktop/Tests/Core/CatchUpQueriesTests.swift`; they are cited below as planned, marked "(Swift path, Task 13)".

**Implementation notes (constrain future edits to `internal/db/catchup.go`).**
- The DB pool has `MaxOpenConns(1)` (`db.Open`): a query issued inside an open `rows` loop deadlocks against itself. `ListCatchupDigests` therefore drains its digest-row cursor fully before issuing the per-digest `GetDigestTopics` follow-up query; any future per-row enrichment in this file must keep the same two-pass shape.
- `ListCatchupMeetings` applies `catchup.caps.meetings` to its two sub-queries (`meeting_recaps` and ad-hoc `meeting_transcripts`) independently, so a window can gather up to 2× the configured cap in meeting items.
- `targets.due_date` is stored `YYYY-MM-DDTHH:MM` in **UTC** (the `targets.go` convention); `ListCatchupTargets` converts the window bounds to UTC before comparing — not local time.
- `catchup.max_prompt_chars` bounds the compose user message in **characters** (runes), enforced with `utf8.RuneCountInString` — a byte budget would over-trim Cyrillic content roughly twofold.
- `catchup.learn` (the feedback-comment interpreter) is absent from `digest.TierForSource`'s light list, so — like `catchup.compose` — it falls through to the **strong** tier by that function's default branch; this is unchanged from before the recap rewrite.
- A `CatchupCoverage` read error fails the recap row rather than reporting a zero, which would read in the UI as a real coverage gap.
- `Pipeline.Run` returns a Go error not only for an invalid window, a missing `--regen` source, or a failed `InsertCatchupRecap`, but also when the terminal `FinishCatchupRecap` or `FailCatchupRecap` write itself fails — in that last case the row can be left stuck at `status='building'` with no error recorded on it. `RunResult.Status` is never claimed as `ready`/`failed` unless that status is what the row actually holds.

## CATCHUP-01 — Caught up once here, read everywhere

**Status:** Enforced (Go path); Swift path guards planned, Task 13

**Observable:** Acknowledging a recap (`Pipeline.Acknowledge` / CLI `catchup ack`, or the Desktop's "I'm caught up" button writing the shared DB directly) marks read everything **inside its window** on the five `read_at` surfaces — `digests` (`period_to` in `(from, to]`), `stream_digests` (same, ISO `period_to`), `tracks` (`updated_at` in `(from, to]` and not dismissed; also clears `has_updates`), `inbox_items` (`created_at` in `(from, to]`), `briefings` (`date` between the window's local dates) — plus stamps the recap's own `acknowledged_at` (first stamp wins). All six writes run in one transaction, set-based. Items outside the window are left untouched, and a second ack changes nothing (every predicate already excludes the rows it marked). Selection is by **window**, not by the refs the compose call happened to cite: an item the model dropped for lacking a valid ref, or content the AI simply never mentioned, still gets marked read — "caught up" means "up to date until T," not "reviewed everything the AI surfaced."

**Why locked:** Catch-up's entire promise is a single action that means "I'm caught up until this moment." If acknowledging left window items unread on their own surfaces, the operator would have to re-clear everything twice and the unread badges would lie.

**Test guards:**
- `internal/db/catchup_store_test.go::TestCatchup01_AcknowledgeMarksWindowRead`
- `internal/db/catchup_store_test.go::TestCatchup01_AcknowledgeIsIdempotent`
- `WatchtowerDesktop/Tests/Core/CatchUpQueriesTests.swift::testAcknowledgeMarksWindowReadOnFiveSurfaces` (Swift path, Task 13)
- `WatchtowerDesktop/Tests/Core/CatchUpQueriesTests.swift::testAcknowledgeLeavesItemsOutsideWindowUnread` (Swift path, Task 13)
- `WatchtowerDesktop/Tests/Core/CatchUpQueriesTests.swift::testAcknowledgeIsIdempotent` (Swift path, Task 13)

**Locked since:** 2026-09-04

## CATCHUP-02 — Catch-up speaks my configured language

**Status:** Enforced

**Observable:** The `catchup.compose` system prompt always carries `prompts.Directive(cfg.Digest.Language)` (`fmt.Sprintf(p.getPrompt(prompts.CatchupCompose), prompts.Directive(...))`), regardless of the language of the underlying Slack/Jira/meeting material — the operator's configured `digest.language` (default Russian) is never silently dropped in favor of English.

**Why locked:** The operator picked a response language once; a surface that randomly answers in English breaks the product's "reads in my language" promise, and is jarring exactly when the source material is mixed-language. The predecessor prompts regressed on this once already (titles in one language, narratives in another) because a prompt constant shipped without the directive.

**Test guards:**
- `internal/catchup/pipeline_test.go::TestCatchup02_ComposePromptCarriesLanguageDirective`

**Locked since:** 2026-09-04

## CATCHUP-03 — Coverage top-up never sinks the recap

**Status:** Enforced

**Observable:** A failing or gated-off coverage top-up (channel digests / Gmail-Jira stream digests) is recorded in `coverage_json` (`topup: "failed"` + `topup_error`, or `"skipped"`) and the run still reaches `status='ready'`, composed from whatever coverage already exists — a top-up error is logged and never returned to the caller as a run failure. The two top-up calls are attempted independently: a channel-digest failure does not skip the stream-digest attempt.

**Why locked:** Top-up is a best-effort freshness pass over pipelines the daemon already runs on its own schedule; making the recap itself fail on a top-up hiccup would turn a transient digest-generation blip into a lost catch-up run.

**Test guards:**
- `internal/catchup/pipeline_test.go::TestCatchup03_TopUpFailureStillProducesRecap`

**Locked since:** 2026-09-04

## CATCHUP-04 — An invented reference never persists

**Status:** Enforced

**Observable:** `validateBody` keeps only `[area#id]` refs present in the window's gathered set (filling the label from the gathered row); every other tag is dropped and counted toward `refs_rejected` in the CLI envelope. A topic / decision / meeting / needs-you item left with zero valid refs after that filter is dropped from `body_json` entirely — no provenance, no claim. The validated body, never the model's raw output, is what gets persisted.

**Why locked:** The recap's whole value is "click through to the source." An unvalidated ref could point nowhere, or resolve to the wrong row once ids get reused, silently breaking that promise.

**Test guards:**
- `internal/catchup/pipeline_test.go::TestCatchup04_InventedRefsAreDroppedNotPersisted`

**Locked since:** 2026-09-04

## Changelog

- 2026-09-04 ([OWNER] confirmed): **Catch-Up rebuilt as an absence recap**, replacing the read-state review-session model (unread-item peel/expand into themes reviewed one at a time with a Done button) end to end. Schema: `catchup_sessions`/`catchup_themes` dropped, `catchup_recaps` added (migration 00061). Pipeline: `internal/catchup/` keeps its name; `peel`, `expandOne`, `RegenTheme`, per-theme `Acknowledge`, `markLeftoverRead`, `GetUnread*`, `FetchItemSnippet`, and the old session/theme store contents of `internal/db/catchup_store.go` are all retired, replaced by `resolveWindow → insert(building) → topUp → gather → compose → validate → persist`. Acknowledge is now **window-scoped**, not per-theme-snapshot-scoped (CATCHUP-01, rewritten in place). CATCHUP-02 (language directive) carries the same intent forward, now pinned to the single `catchup.compose` call instead of the old `peelSystemPrompt`. **The old CATCHUP-03 ("one bad theme never sinks the run") has no counterpart** — there are no more per-theme AI calls to isolate; the new CATCHUP-03 instead covers coverage top-up. **New CATCHUP-04** (invented-ref rejection) has no predecessor — the old per-theme expand pass did not cite refs. The Go-only `Pipeline.Acknowledge` → `MarkDigestRead` → `decision_reads` cascade (documented in the old CATCHUP-01 as "vestigial... harmless") is **not carried into the window ack**: decisions have lived in the ideas ledger (`seen_at`) since 2026-08-12, and none of the window ack's five surfaces is `decision_reads`. `MarkDigestRead` itself (`internal/db/digests.go`) and its own unit guards `TestMarkDigestRead_CascadeDecisions`/`TestMarkDigestRead_NoDecisionsIsNoop` (`internal/db/digests_test.go`) are **untouched** — the function is simply no longer called from `Pipeline.Acknowledge`, which now calls the new `AcknowledgeCatchupWindow` instead. Retired Go guards (deleted along with the per-theme code they pinned): `TestCatchup14_AcknowledgeMarksDigestDecisionsRead`, `TestCatchup24_AcknowledgeReviewedCountIsIdempotent`, `TestCatchup13_PromptsCarryLanguageDirective`, `TestCatchup21_PerThemeExpandFailureDoesNotFailRun` (`internal/catchup/pipeline_test.go`). The Swift session-model tests (`testAcknowledgeCascadesMarkReadAndFlipsReviewState`, `testAcknowledgeDoesNotCascadeToDecisionReads`, `testAcknowledgeReviewedCountIsIdempotent`, plus the rest of `CatchUpQueriesTests.swift`/`CatchUpViewModelTests.swift`) are **not yet removed as of this entry** — they still target the now-dropped `catchup_sessions`/`catchup_themes` schema and are slated for replacement in Task 13 alongside the new Swift `CatchUp*` code and the CATCHUP-01 Swift guards planned above. See `docs/superpowers/specs/2026-09-04-catchup-absence-recap-design.md` (supersedes `2026-06-20-catch-up-review-mode-design.md` and `2026-06-25-catchup-iterative-peel-design.md`).
- 2026-08-12 ([OWNER] confirmed): decisions-split — the Desktop Decisions segment (`DigestListView`/`DecisionsListView`/`DecisionDetailView`) now reads the consolidated ideas ledger (`ideas WHERE kind = 'decision'`, tracked via `seen_at`) instead of scanning `digests.decisions` JSON. `CatchUpQueries.acknowledge`'s digest→`decision_reads` cascade is removed (nothing on the Swift side reads that table anymore); `decision_reads` stays in the schema, unused on that path, non-destructive. The Go path (`Pipeline.Acknowledge`/`MarkDigestRead`) is untouched and still cascades — CATCHUP-01 now applies fully to Go, partially to Swift (digests/tracks/inbox/briefings still cascade there too). Old Swift guard `testAcknowledgeMarksDigestDecisionsRead` replaced by `testAcknowledgeDoesNotCascadeToDecisionReads`, which pins the new (non-)behavior. See `docs/superpowers/specs/2026-08-12-decisions-split-cross-source-digests-design.md`.
- 2026-06-25: outline pass replaced by a sequential peel-off loop (one theme per round until the model returns `{"done":true}`); removed the 3–8 theme ceiling and raised gather caps (150/80/120/20). New source tag `catchup.peel` routed to the light model tier on both providers. CATCHUP-02 guard extended to cover the new `peelSystemPrompt`. New behaviour: pool items the model judges noise on a clean/done exit are marked read (reusing the `MarkXRead` primitives, so the digest-decision cascade still holds); on an error/safety-cap exit the leftover stays unread. `Acknowledge` refactored to share a `markAreaRead` helper — behaviour unchanged. Contracts CATCHUP-01/03 unchanged.
- 2026-06-22: file created with 3 contracts (CATCHUP-01..03), all Enforced. CATCHUP-01 added alongside the fix that made acknowledge cascade digest **decisions** read on both the Go (`MarkDigestRead`) and Swift (`CatchUpQueries.acknowledge`) paths — previously digests were marked read but their decisions stayed stuck in the Decisions feed's unread count. CATCHUP-02 records the language-directive invariant after the outline/expand prompts shipped without one and generated English on a Russian workspace.
