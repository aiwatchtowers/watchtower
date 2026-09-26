# Architectural Issues — 2026-07-05 Audit

The audit covers an architectural slice of the Watchtower project: cohesion and boundaries of the Go backend packages (`internal/*`, `cmd/*`), duplication of cross-cutting mechanisms (the AI subsystem, LLM response parsing, token accounting), and the structure of the macOS app (`WatchtowerDesktop/`, the MVVM Models→Queries→ViewModel→View layer, duplication of business logic between Go and Swift). Method: several specialized finder agents (`arch-go`, `arch-swift`) independently gathered findings, after which each finding went through separate adversarial verification with code tracing; only confirmed findings are listed below (refuted ones were removed). Result: 16 confirmed findings — 0 critical, 3 high, 6 medium, 7 low.

## High

### Prompt customization is a silent no-op for digest, tracks, inbox, briefing, guide, catchup

- **Where:** `cmd/sync.go:294`
- **Verification status:** ✅ confirmed
- Every pipeline exposes `SetPromptStore`, and its `getPrompt()` only reaches into the DB-backed prompt store if the store is non-nil (e.g. `internal/digest/pipeline.go:222-247`, `internal/inbox/pipeline.go:805-813`, `internal/briefing/pipeline.go:274-292`). However, the only production call to `SetPromptStore` in the entire repo is `cmd/sync.go:294`, for the dayplan pipeline. Neither the daemon wiring (`cmd/sync.go:277-291`), nor the `generate` CLI commands (`cmd/digest.go:338`, `cmd/inbox.go:389`, `cmd/briefing.go:139`, `cmd/tracks.go:617`, `cmd/people.go:352`, `cmd/catchup.go:97`, `cmd/meeting.go:88`), nor `runPostSyncPipelines` (`cmd/sync.go:485-508`) pass a store. As a result, the entire user-facing feature `watchtower prompts show/reset/rollback` + `watchtower tune --apply` (`cmd/prompts.go`) writes prompt versions to the DB that no pipeline except dayplan ever reads: a user tunes `digest.channel`, gets a confirmation and a new version in the history, and the daemon just keeps using the built-in default forever — with no warning whatsoever.

```go
// cmd/sync.go:293-295 — the only SetPromptStore call in production
dayPlanPipe := dayplan.New(...)
dayPlanPipe.SetPromptStore(prompts.New(database, nil))

// digest getPrompt (pipeline.go:228-246): silent fallback to default when store is nil
if p.promptStore != nil { ... } // Fallback to default
```

- **Recommendation:** Move prompt-store injection into a shared constructor/wiring path used to build every pipeline (both in the daemon wiring and in the `generate` CLI commands, and in `runPostSyncPipelines`), or make the store a required parameter of the pipeline factory so it can't be forgotten. At minimum, log a warning when a pipeline runs without a store while its prompt has a custom version stored in the DB.

### The inbox watermark advances by wall-clock time even when Slack sync or detectors fail — mentions/DMs are lost forever

- **Where:** `internal/inbox/pipeline.go:329`
- **Verification status:** ✅ confirmed
- `inbox.Pipeline.Run` unconditionally advances the processing watermark to `now-30min` at the end of every run (lines 321-331), regardless of whether detection succeeded. Two concrete loss scenarios: (1) the daemon deliberately keeps running pipelines when Slack sync fails (`internal/daemon/daemon.go:218-220`: "sync had errors, but running pipelines on existing data"). If sync stays broken longer than the 30-minute buffer (expired/revoked token, network failure on an awake machine), every cycle still moves `inbox_last_processed_ts` to `now-30m`; once sync recovers and inserts the missed messages, their `ts_unix` will fall below the watermark, and `FindPendingMentions`/`FindPendingDMs` (called with `lastTS` as the lower bound, lines 435/440) will never see them — the mention silently never reaches the inbox and is never retried. (2) `detectAll` swallows detector errors (lines 407-421, log-and-continue), so a transient SQLite error during detection likewise causes the watermark to advance past those messages. This violates the documented INBOX-03 contract (`docs/inventory/inbox-pulse.md`): "If 200 messages flow past me in a day and one needed a reaction, Inbox surfaces it." The watermark should be derived from sync progress (like `search_last_date`), not from wall-clock time.

```go
// pipeline.go:325-331 — unconditional watermark advance after detectAll
bufferTS := float64(time.Now().Add(-30 * time.Minute).Unix())
if bufferTS < lastTS { bufferTS = lastTS }
if err := p.db.SetInboxLastProcessedTS(bufferTS); ...
// detectAll: errors are only logged
if n, err := p.detectSlackTriggers(...); err != nil { p.logger.Printf(...) }
```

- **Recommendation:** Tie the inbox watermark to actually-processed sync progress (analogous to `search_last_date`) rather than to `time.Now()`, and only advance it when detection has no errors. When sync or a detector fails, the watermark must not move — otherwise messages that land in the DB after recovery with their original (past) `ts_unix` will be skipped. Add a guard test for the "sync down > 30 min, then recovers" scenario.

### The DB schema hand-copied into `TestDatabase.swift` has drifted from reality — tests stay green on SQL against dropped tables

- **Where:** `WatchtowerDesktop/Tests/Helpers/TestDatabase.swift:469`
- **Verification status:** ✅ confirmed
- The Swift test fixture keeps its own copy of the schema across 39 tables instead of deriving it from `internal/db/schema.sql` or running the Go migration CLI that production uses (`DatabaseManager.runCLIMigrations`). The fixture still contains the dropped `tasks` table (with the old, pre-`targets` column set) — which is exactly why `DayPlanQueriesTests` and `ChannelStatsTests` pass, while the same SQL fails against any real DB. This is the mechanism behind the runtime bugs in `ChannelStatsQueries.fetchValueSignals` (FROM tasks) and `DayPlanQueries.cascadeTaskStatus` (UPDATE tasks). Structurally, this undermines any future Go migration: any table/column rename (the `add-migration` skill flow) silently leaves the Desktop test schema — and therefore the Desktop SQL — unvalidated against reality.

```sql
-- TestDatabase.swift:469 — table no longer exists in schema.sql / migrations
CREATE TABLE IF NOT EXISTS tasks (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    ...
    source_type     TEXT ... CHECK(source_type IN ('track','digest','briefing','manual','chat','inbox'))
);
```

- **Recommendation:** Replace the hand-maintained schema with a single source of truth — run the real Go migrations (or embed `internal/db/schema.sql`) when creating the test DB, so Desktop SQL is validated against the same schema as production. As an immediate step, remove `tasks` and all references to it, so the affected queries start failing in tests the same way they do in production.

## Medium

### Codex model routing is dead code: context-key type mismatch between the digest and codex packages

- **Where:** `internal/codex/generator.go:20`
- **Verification status:** ✅ confirmed
- Every pipeline tags AI calls via `digest.WithSource(ctx, "inbox.prioritize")`, which stores the source under the unexported type `digest.sessionSourceKey` (`internal/digest/pooled.go:69-73`). `CodexGenerator.Generate` can't reference that unexported key, so it redeclares its own `type sessionSourceKey struct{}` and reads `ctx.Value(codex.sessionSourceKey{})`. Context keys compare by dynamic type, and `codex.sessionSourceKey` is a different type than `digest.sessionSourceKey`, so the lookup ALWAYS returns nil. The result: when `ai.provider=codex`, `ModelForSource` (`internal/codex/models.go:13`, which routes `inbox.prioritize` / `digest.channel_batch` / `people.batch` / `catchup.peel` / `customtrack.*` to `gpt-5.4-mini`) never fires — every call in every pipeline goes to the default `gpt-5.4` model instead. The comment on codex's `ModelForSource` even claims it "Honors digest.SourceLight as the cross-harness contract" — but it can never see it. Claude routing works only because `digest/generator.go` is in the same package as the key. The defect degrades cost/latency, not output correctness, hence medium.

```go
// codex/generator.go:17-20
// sessionSourceKey is the context key used by digest.WithSource. We re-declare it here...
type sessionSourceKey struct{}
// :38
if s, ok := ctx.Value(sessionSourceKey{}).(string); ok { ... }

// vs digest/pooled.go:69,73 — different package → different type → Value() misses
type sessionSourceKey struct{}
context.WithValue(ctx, sessionSourceKey{}, source)
```

- **Recommendation:** Export a typed accessor from the `digest` package (e.g. `digest.SourceFromContext(ctx) (string, bool)`) and make codex use it instead of its redeclared local key. This eliminates the dead routing and kills the second, diverging model-routing table.

### `internal/digest` is a de-facto AI-abstraction hub: Generator/Usage/WithSource/routing live inside a specific pipeline, coupling 10+ packages

- **Where:** `internal/digest/pipeline.go:38`
- **Verification status:** ✅ confirmed
- The cross-cutting AI seam (the `Generator` interface, the `Usage` struct, context tagging via `WithSource`/`SourceLight` in `pooled.go`, `ModelForSource` routing in `models.go`, `LearnedPreferencesBlock` in `preferences.go`) is defined inside `internal/digest` — a specific ~2000-line pipeline. Every other pipeline (guide, dayplan, inbox, customtracks, tracks, targets, briefing, meeting, catchup) plus `internal/codex` import digest purely for these types. Concrete costs already visible: (1) tracks can't be imported into digest (a cycle), so the dependency is patched twice — via the `TrackLinker` interface (`pipeline.go:93-98`) for the CLI path AND via the daemon mutating the exported field `digestPipe.TrackContext` (`daemon.go:447-452`), two diverging mechanisms for the same data; (2) codex was forced to duplicate the unexported context key and broke it (see the finding above); (3) the routing tables `digest/models.go` and `codex/models.go` have to be maintained by hand in parallel. Adding a method to `Generator` (streaming, cancellation, a per-call model override) touches 11 packages; renaming or extracting the digest package is effectively frozen. The daemon likewise holds concrete `*digest.Pipeline`/`*tracks.Pipeline`/… fields; only dayplan got an interface (`DayPlanRunner`, `daemon.go:34`), so daemon tests are forced to construct full real pipelines for every other phase (`daemon_test.go:406-455`).

```go
// digest/pipeline.go:38
type Generator interface { Generate(...) }
// pipeline.go:95
// Defined as an interface to avoid import cycles (tracks imports digest)
// daemon.go:448-451 — a second, duplicate mechanism for passing the same context
if trackCtx, err := d.tracksPipe.FormatActiveTracksForPrompt(); ... {
    d.digestPipe.TrackContext = trackCtx
}
```

- **Recommendation:** Extract the AI seam (`Generator`, `Usage`, `WithSource`/`SourceLight`, `ModelForSource`, `LearnedPreferencesBlock`) into a separate neutral package (e.g. `internal/aiseam` or `internal/llm`) that every pipeline and both providers depend on, leaving `internal/digest` as just one concrete implementation. This breaks the tracks↔digest cycle (removing the dual `TrackLinker`/`TrackContext` mechanism) and lets codex reuse the context key and routing table without duplication.

### The Claude CLI subprocess stack is duplicated in `internal/ai` and `internal/digest` with behavioral drift: CLAUDECODE handling and cwd differ

- **Where:** `internal/ai/client.go:173`
- **Verification status:** ✅ confirmed
- `internal/ai/client.go` and `internal/digest/generator.go` each contain their own copy of `cliResponse`, `cliUsage`, `parseCLIOutput`, `limitedWriter`, `classifyError`, and exec-environment/TCC setup (and `internal/codex` holds a third copy of `limitedWriter`/`classifyError`). They have already diverged: `digest/generator.go:211-219` strips the `CLAUDECODE` environment variable ("avoid nested-session detection when launched from a parent process that is itself a Claude Code session") and runs from `~/.config/watchtower`, whereas `ai.Client.Query`/`QuerySync` (lines 173-175, 253-255) keeps `CLAUDECODE` and runs from `os.TempDir()`. That means `watchtower ask`/chat/REPL/jira-board-analyzer calls (which use `ai.Client`), launched from a daemon spawned by a Claude Code session, hit exactly the nested-session failure that the digest side was patched to avoid. Given that TCC responsibility-chain fixes are P0 in this project's history, every such fix now has to be found and applied in 2-3 places, and one (CLAUDECODE) on the `ai.Client` side has already been missed.

```go
// digest/generator.go:203-213
// - Remove CLAUDECODE to avoid "nested session" detection...
if strings.HasPrefix(e, "CLAUDECODE=") { continue }

// ai/client.go:173-175 — no equivalent, only PATH
cmd.Env = append(os.Environ(), "PATH="+claude.RichPATH())
```

- **Recommendation:** Extract Claude CLI subprocess construction (env setup, cwd, `parseCLIOutput`, `limitedWriter`, `classifyError`) into a single shared helper used by both `ai.Client` and `digest.ClaudeGenerator`, so TCC/env fixes (including stripping `CLAUDECODE`) are applied in one place. Immediately, replicate the `CLAUDECODE` strip and correct cwd on the `ai.Client` side.

### Stripping the markdown "fence" from AI JSON responses has been reinvented ≥7 times with diverging edge-case behavior

- **Where:** `internal/inbox/pipeline.go:962`
- **Verification status:** ✅ confirmed
- Every pipeline manually extracts JSON from a markdown fence: `inbox.parseAIResult` (`pipeline.go:962-978`, drops both the first AND last line whenever the response starts with ```` ``` ````  — corrupts a response whose closing fence isn't on the last line), `briefing.parseBriefingResult` (`pipeline.go:635-653`, uses `LastIndex("```")`), `tracks.cleanJSON` (`pipeline.go:1755`), `meeting.cleanJSON` (`pipeline.go:507`), `guide.extractJSON` (`pipeline.go:1068`), `jira.extractJSON` (`board_analyzer.go:746`), `dayplan.parseResponse` (`prompt.go:171`), plus `inbox/pinned_selector.parsePinnedResponse` (`pinned_selector.go:113`) and `targets.parseExtractResponse`/`parseLinkResponse`. All of them implement the same contract ("the model may wrap JSON in a fence / add prose"), with differing tolerance for prose before/after the fence, so the same model output parses successfully in one pipeline and fails in another. Tellingly, the canonical tolerant helper `prompts.ExtractJSONObject` (`internal/prompts/json.go`) already exists but is adopted at only ONE call site (`targets/nextstep.go`) — the intent to consolidate is proven but unfinished. When a provider starts prefacing its response with a phrase before the fence (a known Codex/Claude behavior shift), the fix will have to be found and applied across 7+ copies; applied to just one, it will leave the rest silently dropping AI results — and for inbox/briefing that means the run gets logged as a parse error and its tokens are wasted every cycle.

```go
// inbox/pipeline.go:964-971 — drops both the first AND last line
if strings.HasPrefix(response, "```") {
    lines := strings.Split(response, "\n")
    if len(lines) > 2 { lines = lines[1 : len(lines)-1] ... }
}
// vs briefing/pipeline.go:637-645 — SplitN + LastIndex, a different algorithm for the same job
lines := strings.SplitN(response, "\n", 2) ...
if idx := strings.LastIndex(response, "```"); idx >= 0 { response = response[:idx] }
```

- **Recommendation:** Move all call sites onto the existing `prompts.ExtractJSONObject` and delete the local copies, leaving a single tolerant algorithm (fence with any language tag + fallback on outermost braces). Add a shared test for "prose before and after the fence."

### Behavioral contracts are implemented twice (Go + Swift) with no shared enforcement — one mirror has already drifted and broken

- **Where:** `WatchtowerDesktop/Sources/Database/Queries/TargetQueries.swift:228`
- **Verification status:** ✅ confirmed
- There are at least 8 self-declared "Mirrors Go" business-logic duplications in Swift: the INBOX-02 target-close→inbox-resolve cascade (`TargetQueries.updateStatus` vs `internal/db/targets.go UpdateTargetStatus`), the catch-up acknowledge cascade (`CatchUpQueries.acknowledge:76` vs `internal/catchup/pipeline.go:443`), rule derivation from inbox feedback (`InboxFeedbackQueries.record:11` vs `internal/inbox/feedback.go:14`), channel value signals (`ChannelStatsQueries:169` — already drifted), the Jira board's SHA256 `ComputeConfigHash` (`JiraBoard.swift:100`), the external-link allowlist (`TargetQueries:200`), thread context (`MessageQueries:65`). None of them has a cross-language equivalence test. Verification uncovered two real discrepancies: (1) Go's `GetChannelValueSignals` (`internal/db/channel_stats.go:137,145`) reads `FROM targets`, while the Swift mirror `ChannelStatsQueries.fetchValueSignals` reads `FROM tasks` (the table doesn't exist → runtime failure); (2) Swift's `TargetQueries.updateStatus` (line 217) omits the sheet/parent progress recalculation that Go's `UpdateTargetStatus` (`targets.go:261`) performs — so the Desktop "Done" path leaves progress stale. The inventory files (`docs/inventory/`) catalogue these contracts as load-bearing, doubling the blast radius of every change.

```swift
// Mirrors the Go-side cascade in `UpdateTargetStatus`
// (internal/db/targets.go); Desktop "Done" bypasses Go, so the two
// paths must stay in sync (same dual-path convention as
// `CatchUpQueries.acknowledge`).
```

- **Recommendation:** For each "Mirrors Go" contract, add a cross-language golden test: a fixed input → serialized result, checked identically in `go test` and `swift test` (a shared JSON fixture). Fix the `FROM tasks`→`FROM targets` discrepancy immediately, and add the missing progress recalculation to Swift's `updateStatus`.

### The AI chat stack is duplicated five times: the stream-dedup loop is copied 5×, the LINKING RULES system-prompt block 4× (3 Swift + 1 Go)

- **Where:** `WatchtowerDesktop/Sources/Views/Tracks/TrackChatView.swift:8`
- **Verification status:** ✅ confirmed
- The identical `sawTurnComplete`/`turnComplete` stream-deduplication state machine is copied into `ChatViewModel` (twice: lines 167 and 561), `OnboardingChatViewModel:277`, `TargetChatViewModel:223`, and `TrackChatViewModel:166` — the last one being a full ~380-line ViewModel defined inside a file under `Views/`, with its own persistence helpers duplicating `ChatMessageQueries`/`ChatConversationQueries` handling. The `=== LINKING RULES ===` prompt block (the format of slack:// links) is separately maintained in `ChatViewModel:454`, `TargetChatViewModel:564`, `TrackChatView.swift:351`, and `internal/ai/prompt.go`. The drift this finding warns about is already real: the LINKING RULES in `ChatViewModel` ("ALWAYS include Slack links as descriptive markdown," flat message format) differ materially from `TrackChatView` ("ALWAYS use markdown links with descriptive text," with separate `thread_ts` and web-permalink rules), so link-rendering guidance already diverges between tabs. Fixing the known "chunk after turnComplete" edge case, adding a new `AIStreamEvent` case, or changing the deep-link format all require 4-5 synchronized edits across two languages.

```swift
// TrackChatView.swift:166 — byte-for-byte identical to ChatViewModel:167 and :561,
// OnboardingChatViewModel:277, TargetChatViewModel:223
var sawTurnComplete = false
...
case .turnComplete(let text): fullText = text; sawTurnComplete = true
```

- **Recommendation:** Extract the stream-dedup state machine into a single shared type (e.g. `ChatStreamAccumulator`), and the LINKING RULES block into a single source (a shared Swift system-prompt builder + one Go source) from which every chat tab is generated. Move `TrackChatViewModel` out of `Views/` into the ViewModels layer and reuse the shared query helpers.

## Low

### Systemic MVVM violation: numerous direct `dbPool.write` calls in View files; whole features implemented inside Views

- **Where:** `WatchtowerDesktop/Sources/Views/Calendar/MeetingNotesView.swift:457`
- **Verification status:** ✅ confirmed
- The project's documented architecture (`.claude/skills/add-desktop-feature`: Model → Queries → ViewModel → View, "writes via await dbPool.write" in the ViewModel) is violated pervasively: a grep shows 90 mentions of `dbPool` in `Sources/Views` across 30 files, including synchronous `try db.dbPool.write` call sites executed on the main actor (the UI hangs whenever the Go daemon holds the write lock, `busy_timeout=5000ms`). `MeetingNotesView` has no ViewModel at all — note CRUD, toggling, deletion, and cross-feature target creation (`TargetQueries.create` + `MeetingNoteQueries.setTaskID`) all live in the View. Verification refined this: there are actually 23 write sites (19 synchronous), not 24, and two flagship "whole feature in the View" cases were partly mischaracterized (`createTargetAndPromote` is async and delegates batch-promote to the canonical `TargetsViewModel`) — so severity was downgraded to low. Still, a synchronous main-thread write blocking for up to 5s while the daemon holds the write lock is genuinely reachable and bypasses the documented pattern.

```swift
private func createTask(from note: MeetingNote) {
    ...
    let taskID = try db.dbPool.write { dbConn in
        let id = try TargetQueries.create(dbConn, text: note.text, ...)
        try MeetingNoteQueries.setTaskID(dbConn, noteID: noteID, taskID: Int64(id))
        return id
    }  // business flow + synchronous main-thread write inside a SwiftUI View, no ViewModel
}
```

- **Recommendation:** Move Views' writes to `await dbPool.write` (off-main) inside the appropriate ViewModels; for `MeetingNotesView`, create a `MeetingNotesViewModel` encapsulating CRUD and target creation. At minimum, make every `dbPool.write` in Views asynchronous to remove the main-actor block.

### Daemon pipeline phases aren't isolated from panics; a panicking pipeline goroutine kills the whole daemon

- **Where:** `internal/daemon/daemon.go:233`
- **Verification status:** ✅ confirmed
- `runSync` launches `phaseTracksAndRollups` and `phasePeopleCards` in "bare" goroutines (`daemon.go:233-240`), and `trackedPipelineRun` has no `recover()`; the only `recover` calls in the non-test backend are around the `TrackLinker` call inside `digest.Pipeline` (`pipeline.go:386`) and in the sync CLI goroutine (`cmd/sync.go:391`), which proves the authors are aware panics can happen — yet the daemon's own phases aren't protected. A panic in either goroutine takes down the whole process (goroutine panics in Go can't be caught by the parent), irrecoverably halting the sync cycle (`Run`, lines 176/187/190) until a manual restart. Verification refuted the specific "already-live trigger" claim (`usage.Model` — both production generators and both mocks always return a non-nil `*Usage`), so this is a preventive hardening item rather than a live crash — hence low.

```go
// daemon.go:233-240 — no recover anywhere in daemon.go
go func() { defer phasesWg.Done(); d.phaseTracksAndRollups(ctx) }()
```

- **Recommendation:** Wrap each pipeline phase (including the goroutines) in `trackedPipelineRun` with a `defer recover()` that logs the stack trace and marks the phase as failed, so one pipeline's panic doesn't take down the entire sync cycle.

### Daily rollup tokens are never accounted for anywhere: they accumulate after the "digests" pipeline-run row has already closed, then get reset on the next cycle

- **Where:** `internal/daemon/daemon.go:457`
- **Verification status:** ✅ confirmed
- The daemon writes the "digests" `pipeline_runs` row from the `Usage` returned by `RunChannelDigestsOnly` (`phaseChannelDigests`, `daemon.go:378-395`). Later in the same cycle, `RunRollups` performs the daily-rollup LLM call, which accumulates into the digest pipeline's internal atomic counters (`accumulateUsage` via `runDailyRollupForDate`), but doesn't return usage to the daemon or get attributed to any `pipeline_runs` row. On the next cycle, `RunChannelDigestsOnly` resets the counters (`pipeline.go:336-338`), wiping the rollup usage entirely. A user auditing AI spend via `pipeline_runs` (which is exactly what those items/input_tokens/output_tokens/cost-per-run columns exist for) sees daily-rollup token consumption as a permanent zero, even though a Sonnet-class call runs every cycle against fresh digests; token accounting is systematically understated.

```go
// daemon.go:456-460 — not wrapped in trackedPipelineRun, AccumulatedUsage never read
if d.digestPipe != nil {
    if err := d.digestPipe.RunRollups(ctx); err != nil { d.logger.Printf("rollup error: %v", err) }
}
// digest/pipeline.go:335-338 — accumulator reset at the start of the next run
// Reset accumulated usage from previous run ...
p.totalInputTokens.Store(0)
```

- **Recommendation:** Wrap `RunRollups` in `trackedPipelineRun` with its own `pipeline_runs` row (e.g. "daily-rollup") and read its usage before the counters reset — or have `RunRollups` return the rollup usage and accumulate it into the "digests" row before that row closes.

### Usage-accounting boilerplate is duplicated 6× with inconsistent semantics (accumulated vs. last-run, atomic vs. plain int)

- **Where:** `internal/inbox/pipeline.go:180`
- **Verification status:** ✅ confirmed
- Six pipelines each implement their own `AccumulatedUsage() (int,int,float64,int)` plus reset-on-Run and `LastStep*` progress fields: digest, tracks, and guide use `atomic.Int64`; inbox uses plain ints, mutated in `aiPrioritizeNewItems` (safe only as long as it stays single-threaded — meanwhile its doc comment still claims "accumulated across all Generate calls," even though it resets on every Run); briefing and dayplan silently return only the LAST run's usage under the same method name. The `float64` in the signature is a permanently-0 dead `CostUSD`, copy-pasted into every implementation. The daemon consumes all six identically through `trackedPipelineRun`. Adding cost or cache-token reporting (the `Usage` struct already carries `TotalAPITokens`/`Model`) means editing six near-identical copies and their reset points; a partial edit produces mixed metrics in `pipeline_runs` — exactly the class of drift that already exists between the "accumulated" and "last-run" semantics.

```go
// inbox/pipeline.go:179-182 — "accumulated" contract, plain int
// AccumulatedUsage returns the total token usage accumulated across all Generate calls.
// briefing/pipeline.go:87-91 — same name, different contract
// AccumulatedUsage returns the token usage from the last Run call.
// digest/pipeline.go:184-186 — atomic variant
```

- **Recommendation:** Move usage accumulation into a shared type (a usage recorder) or into `PooledGenerator`, which already sees every call and its source tag, and reuse it across all pipelines — then semantics and type become uniform, and adding cost/cache metrics requires a single edit.

### The digest-read→decisions-read cascade invariant is enforced at the call site in Swift but encapsulated in Go — the batch `markRead` already lacks it

- **Where:** `WatchtowerDesktop/Sources/Database/Queries/DigestQueries.swift:88`
- **Verification status:** ✅ confirmed
- The Go function `MarkDigestRead` (`internal/db/digests.go:232`) internally cascades into `markDigestDecisionsRead`, so no Go caller can forget it. Swift, however, splits the invariant into two functions that every call site must pair manually — `TrackQueries.swift:113-114`, `CatchUpQueries.swift:80+85` (whose comment admits "Mirrors the other markDigestRead call sites"), `DigestViewModel.swift:296+298` and `341+343`. The batch `markRead(_:ids:)` at line 88 already omits the cascade; it isn't called anywhere today, but the very next future caller (e.g. a toolbar "mark all read" action, which `DigestViewModel` currently implements as a per-item loop) will leave decisions stuck in the unread count on the Decisions feed — exactly the bug the Go-side cascade exists to prevent (CATCHUP-01).

```swift
/// Marks multiple digests read in one write. No-op on empty input.
static func markRead(_ db: Database, ids: [Int]) throws {
    ... // UPDATE digests SET read_at = ... — no markAllDecisionsRead cascade,
        // unlike Go's MarkDigestRead, which calls db.markDigestDecisionsRead(id) internally
}
```

- **Recommendation:** Build the decisions-read cascade into `markRead(_:ids:)` (and any other Swift function that marks a digest read), so the invariant is encapsulated the same way it is in Go, instead of relying on call-site discipline.

### The sidebar recommendations badge is computed from different inputs than the Channels screen it links to

- **Where:** `WatchtowerDesktop/Sources/ViewModels/SidebarCountsViewModel.swift:140`
- **Verification status:** ✅ confirmed
- `SidebarCountsViewModel` computes the recommendations badge via `computeRecommendations(from: allStats)` with default `signals: [:]`, while `ChannelStatsViewModel.load` computes the on-screen list via `computeRecommendations(from: allStats, signals: fetchValueSignals(db))`. The `signals` parameter adds "high-value channel" recommendations (the `decisionCount >= 5 || activeTrackCount >= 2` branch in `ChannelStatsQueries.swift:153`), so once the `fetchValueSignals` table bug is fixed, the badge count will stop matching the on-screen recommendation count. On top of that, it re-runs the full `fetchAll` aggregation on every observed change across 7 tables just to output a single integer for the badge.

```swift
let allStats = try ChannelStatsQueries.fetchAll(db, currentUserID: uid)
recCount = ChannelStatsQueries.computeRecommendations(from: allStats).count
// vs ChannelStatsViewModel.swift:68-69 — passes signals: fetchValueSignals(db)
```

- **Recommendation:** Compute the badge with the same call and the same `signals` as the screen (extract the computation into a shared method/ViewModel), so the badge count and the on-screen list never diverge and the recommendation threshold is tuned in one place.

### `DatabaseManager` mixes infrastructure with domain logic: starred-channels/people CRUD is duplicated 4× inside the connection manager

- **Where:** `WatchtowerDesktop/Sources/Database/DatabaseManager.swift:168`
- **Verification status:** ✅ confirmed
- `DatabaseManager` (pool setup, schema validation, CLI-migration subprocess) also contains four nearly identical domain methods — `addStarredChannel`/`removeStarredChannel`/`addStarredPerson`/`removeStarredPerson` — each manually repeating the same fetch-JSON → decode → mutate → encode → UPDATE `user_profile` round trip, instead of living in `ProfileQueries` next to the rest of the `user_profile` access. `ProfileQueries` already owns the same `starred_channels`/`starred_people` columns and uses the codebase's standard `strftime('%Y-%m-%dT%H:%M:%SZ','now')`, while `DatabaseManager` uses `ISO8601DateFormatter` — the methods are both in the wrong layer and inconsistent with that layer's convention. Adding a "starred people" TTL or a third starred list would mean a fifth copy in the wrong layer.

```swift
func addStarredChannel(_ channelID: String, for userID: String) throws {
    try dbPool.write { db in
        let sql = "SELECT starred_channels FROM user_profile WHERE slack_user_id = ?"
        ... channels = (try? JSONDecoder().decode([String].self, from: data)) ?? [] ...
        // the same block repeated 4× inside the connection manager
    }
}
```

- **Recommendation:** Move the four starred-item methods into `ProfileQueries`, unify the `updated_at` format on `strftime('%Y-%m-%dT%H:%M:%SZ','now')`, and leave `DatabaseManager` purely infrastructural (pool, schema, migrations).
