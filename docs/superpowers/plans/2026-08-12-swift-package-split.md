# Swift Package Split (Phase 2, Core-first) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract a `WatchtowerCore` library target (Models + Database + pure Services/Utilities) from the single-executable `WatchtowerDesktop` package, so Core-level tests build and link **without** the WhisperKit/FluidAudio/MLX stack — shrinking the measured 0:35 edit→test cycle for non-ML code.

**Architecture:** Core-first refinement of the spec's Phase 2 (`docs/superpowers/specs/2026-08-11-local-build-speed-design.md`). One new library target `WatchtowerCore` (path `Sources/WatchtowerCore`, deps GRDB + Yams), one new test target `WatchtowerCoreTests` (path `Tests/Core`), one shared test-support library `WatchtowerTestSupport` (path `Tests/Support`, the existing pure helpers). The executable keeps `path: "Sources"` with `exclude: ["WatchtowerCore"]` and gains a dependency on Core. Moved declarations get the `package` access level (SE-0386, available in Swift 5.10) — visible across targets in this package, no public-API commitment; moved tests switch to `@testable import WatchtowerCore` so internal members need no annotation. **DEVIATION FLAGGED FOR OWNER:** the spec's `WatchtowerTranscription` module is deferred — all transcription tests need the ML stack anyway (zero test-link win), its 21-file tree is transitively ML-shaped, and its center (`MeetingRecorderCenter`) is AppState-coupled; the deferral is recorded in the spec appendix in Task 6.

**Tech Stack:** SwiftPM (swift-tools 5.10), GRDB, XCTest. Dependency facts from `.superpowers/phase2-depmap.md` (regenerate with an Explore pass if lost — it is gitignored).

## Global Constraints

- Everything committed to the repo is in English.
- **The compiler is the oracle:** after each file move, unresolved references are fixed by (a) annotating the needed declaration `package`, or (b) moving a PURE dependency file into Core (pure = imports only Foundation/GRDB/Combine/Yams/CryptoKit, no SwiftUI/AppKit/ML import, no `AppState` reference), or (c) if the dependency is app-shaped (AppState/SwiftUI/transcription types) — the moved file goes BACK to the app target and the exclusion is recorded in the task report. Never make an app-shaped file Core by force.
- Never move: `Sources/App/**`, `Sources/ViewModels/**`, `Sources/Views/**`, `Sources/Services/Transcription/**`, `Sources/Models/ChannelStat.swift` (imports SwiftUI), `Sources/Services/{ConfigService,JoinMeetingAction,UpdateService}.swift` (SwiftUI/AppKit), `Sources/Services/{GmailAuthService,GoogleAuthService,GoogleConnectFlow,MeetingRecorderCenter,SpeakerGuessCenter,TrackScanCenter,TranscriptChaptersCenter,TranscriptNotesCenter}.swift` (AppState-coupled), `Sources/Resources/**` (stays with the app).
- Access level for moved API consumed by the app target: `package`, never `public`. Tests use `@testable import WatchtowerCore` (or plain `import` where package access suffices).
- Every task ends green: `cd WatchtowerDesktop && swift build` exit 0 AND full `swift test` exit 0 (both test targets; capture the real exit code, never pipe the command through tail/head, never wrap in the `timeout` binary; long runs → foreground Bash with the tool's timeout parameter at 600000 ms).
- Every task that moves Swift files must leave `make lint-swift` green — regenerate the baseline (`cd WatchtowerDesktop && swiftlint lint --write-baseline .swiftlint-baseline.json` — check `swiftlint --help` for the exact flag spelling of the installed version) ONLY if the move broke path-keyed entries, and say so in the commit body.
- Test files are moved verbatim except the import line(s); never rename a test class or weaken an assertion (house guard-test rule).
- Behavioral contracts in `docs/inventory/` are untouched by design — this plan moves code between targets without changing any runtime behavior. If a change ever requires editing a test's logic (not just its import), STOP and report BLOCKED.
- Working directory: the worktree `/Users/user/PhpstormProjects/watchtower/.claude/worktrees/local-build-speed`, branch `feature/swift-package-split`. Verify with `git rev-parse --abbrev-ref HEAD` before every commit.

---

### Task 1: Package wiring + seed file (prove the topology)

**Files:**
- Modify: `WatchtowerDesktop/Package.swift`
- Move: one seed source file + its test (chosen in Step 1)

**Interfaces:**
- Produces: targets `WatchtowerCore` (library, `path: "Sources/WatchtowerCore"`), `WatchtowerCoreTests` (`path: "Tests/Core"`), executable `exclude: ["WatchtowerCore"]`, test target `WatchtowerDesktopTests` `exclude: ["Core", "Support"]`. Tasks 2–5 move files into these paths. The ML-absence check command from Step 5 is reused by Task 6.

- [ ] **Step 1: Pick the seed.** Criteria: a file under `Sources/Models/` or `Sources/Utilities/` importing only Foundation, referencing no other project type (grep its type names' dependencies), with a matching pure test file (no SwiftUI/ViewInspector import). First candidate to try: `Sources/Utilities/TimeFormatting.swift` + `Tests/TimeFormattingTests.swift`; verify purity with `grep -nE "import |AppState" WatchtowerDesktop/Sources/Utilities/TimeFormatting.swift` — if it fails the criteria, pick another Models file that passes and record the choice in the report.

- [ ] **Step 2: Edit Package.swift.** Add to `targets:`:

```swift
.target(
    name: "WatchtowerCore",
    dependencies: [
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "Yams", package: "Yams"),
    ],
    path: "Sources/WatchtowerCore"
),
.testTarget(
    name: "WatchtowerCoreTests",
    dependencies: [
        "WatchtowerCore",
        "WatchtowerTestSupport",
        .product(name: "GRDB", package: "GRDB.swift"),
    ],
    path: "Tests/Core"
),
.target(
    name: "WatchtowerTestSupport",
    dependencies: [
        "WatchtowerCore",
        .product(name: "GRDB", package: "GRDB.swift"),
    ],
    path: "Tests/Support"
),
```

In the executable target add `"WatchtowerCore"` as the first dependency and `exclude: ["WatchtowerCore"]` (path stays `"Sources"`). In `WatchtowerDesktopTests` add `exclude: ["Core", "Support"]` and dependencies `"WatchtowerCore"`, `"WatchtowerTestSupport"`. Create `Tests/Support/` with a placeholder Swift file if SwiftPM rejects an empty target (e.g. `Tests/Support/TestSupport.swift` containing `// Shared pure test helpers move here in Task 4.`).

- [ ] **Step 3: Move the seed.** `git mv` the source file to `WatchtowerDesktop/Sources/WatchtowerCore/<same-subpath>` and the test to `WatchtowerDesktop/Tests/Core/`. In the test file change `@testable import WatchtowerDesktop` → `@testable import WatchtowerCore`. Annotate the seed's declarations `package` as the compiler demands (the app target may reference it).

- [ ] **Step 4: Build + full test, verify green.**

```bash
cd WatchtowerDesktop && swift build > /tmp/p2-t1-build.log 2>&1; echo "exit=$?"
cd WatchtowerDesktop && swift test > /tmp/p2-t1-test.log 2>&1; echo "exit=$?"
```

If SwiftPM rejects the nested-path + exclude topology (overlapping-sources error), fall back to `path: "CoreSources"` for the Core target (top-level sibling of `Sources/`), record the fallback in the report, and re-run. Both commands exit 0.

- [ ] **Step 5: Prove ML-absence for the Core test bundle.**

```bash
cd WatchtowerDesktop && swift build --build-tests > /tmp/p2-t1-buildtests.log 2>&1; echo "exit=$?"
grep -iE "whisperkit|fluidaudio|qwen3|mlx" /tmp/p2-t1-buildtests.log | grep -i "WatchtowerCoreTests" ; echo "ml-in-core-tests-hits=$?"
otool -L .build/debug/WatchtowerCoreTests.xctest/Contents/MacOS/WatchtowerCoreTests 2>/dev/null | grep -icE "whisper|fluid|mlx"; true
```

Expected: zero hits linking ML into the Core tests bundle (the `WatchtowerDesktopPackageTests` runner may still aggregate — what must be ML-free is the WatchtowerCore module build and its direct link line; if SwiftPM produces a single aggregated `PackageTests` bundle, instead verify via `swift test --filter <SeedTest>` timing plus the absence of ML compile steps in a clean-Core incremental log, and record which proof was used).

- [ ] **Step 6: Commit.**

```bash
git add -A WatchtowerDesktop && git commit -m "build(desktop): add WatchtowerCore/CoreTests/TestSupport targets, seed with one pure file"
```

---

### Task 2: Move Models/ into Core (70 files)

**Files:**
- Move: everything under `WatchtowerDesktop/Sources/Models/` EXCEPT `ChannelStat.swift` → `WatchtowerDesktop/Sources/WatchtowerCore/Models/`
- Modify: moved files (`package` annotations), app-target files only where the compiler demands nothing else works

**Interfaces:**
- Consumes: Task 1's targets.
- Produces: Models types available as `package` API; Task 3 (Database) builds on them.

- [ ] **Step 1: Move.** `git mv WatchtowerDesktop/Sources/Models WatchtowerDesktop/Sources/WatchtowerCore/Models` then `git mv WatchtowerDesktop/Sources/WatchtowerCore/Models/ChannelStat.swift WatchtowerDesktop/Sources/Models/` (recreate the dir). ChannelStat stays app-side.

- [ ] **Step 2: Compiler-driven annotation loop.** `swift build` → for every "cannot find type / X is inaccessible" error in app-target files: annotate the Core declaration (type, member, init) `package`. Structs whose synthesized memberwise init the app uses need an explicit `package init(...)` if the synthesized one is not visible cross-module — add it verbatim-matching the stored properties. If a Models file references an unmoved app-side type (rare; e.g. something in Utilities): apply the Global Constraints oracle rule (move-if-pure / back-out-if-app-shaped). Iterate until `swift build` exit 0. Bound: if after 10 iterations the build still fails on the SAME error, report BLOCKED with the error text.

- [ ] **Step 3: Move the pure Models tests.** Candidates: `Tests/ModelTests.swift`, `Tests/InboxItemTests.swift`, `Tests/TrackModelTests.swift`, `Tests/DayPlanModelTests.swift`, `Tests/SituationTests.swift`, `Tests/TargetTests.swift` and any other test file whose subject types all moved AND which imports neither SwiftUI/ViewInspector nor references transcription/AppState names. For each: `git mv` to `Tests/Core/`, change the import to `@testable import WatchtowerCore` (add `import WatchtowerTestSupport` if it uses helpers — helpers arrive in Task 4, so if a test needs `TestDatabase` LEAVE IT in place for now and note it for Task 4). Compile; a test that will not compile in Core without app types moves back and is listed in the report.

- [ ] **Step 4: Full verification.**

```bash
cd WatchtowerDesktop && swift test > /tmp/p2-t2-test.log 2>&1; echo "exit=$?"
make lint-swift > /tmp/p2-t2-lint.log 2>&1; echo "exit=$?"
```

Both exit 0 (regenerate the swiftlint baseline only if moved paths broke it; state so in the commit body).

- [ ] **Step 5: Commit.**

```bash
git add -A && git commit -m "refactor(desktop): move Models into WatchtowerCore (package access)"
```

---

### Task 3: Move Database/ into Core (51 files)

**Files:**
- Move: `WatchtowerDesktop/Sources/Database/` (entire dir: `DatabaseManager.swift`, `DatabaseObserver.swift`, `Queries/**`) → `WatchtowerDesktop/Sources/WatchtowerCore/Database/`
- Modify: moved files (`package` annotations)

**Interfaces:**
- Consumes: Models types from Task 2 (same module now).
- Produces: all Queries as `package` API; Task 4 moves their tests.

- [ ] **Step 1: Move.** `git mv WatchtowerDesktop/Sources/Database WatchtowerDesktop/Sources/WatchtowerCore/Database`.

- [ ] **Step 2: Compiler-driven annotation loop.** Same procedure and bound as Task 2 Step 2. Watch for: references to `Constants` or other `Utilities/` members from `DatabaseManager` (path resolution) — apply the oracle rule (move the Utilities file if pure; if it drags AppKit/SwiftUI, split is NOT allowed in this task — instead back out `DatabaseManager.swift` alone to the app target if that is what it takes to stay green, and record it; `Queries/**` must land in Core regardless, they are the spec's acceptance surface).

- [ ] **Step 3: Full verification.** Same commands as Task 2 Step 4, logs `/tmp/p2-t3-*.log`, both exit 0.

- [ ] **Step 4: Commit.**

```bash
git add -A && git commit -m "refactor(desktop): move Database + Queries into WatchtowerCore"
```

---

### Task 4: Shared test helpers + move the Queries/DB test files

**Files:**
- Move: `WatchtowerDesktop/Tests/Helpers/TestDatabase.swift`, `Tests/Helpers/FakeCLIRunner.swift`, `Tests/Helpers/MockClaudeService.swift` → `WatchtowerDesktop/Tests/Support/` (they are Foundation/GRDB-only per the dep map). `MeetingRecorderTestSupport.swift` STAYS in `Tests/Helpers/`.
- Move: every test file whose subjects now live in Core → `WatchtowerDesktop/Tests/Core/`
- Modify: moved helpers get `package` declarations (they are now a library target); moved tests get `@testable import WatchtowerCore` + `import WatchtowerTestSupport`; remaining app-side tests get `import WatchtowerTestSupport` where they used the helpers.

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: the bulk CoreTests population — the measured win. Task 5 sweeps stragglers; Task 6 measures.

- [ ] **Step 1: Move the three helpers** to `Tests/Support/`, delete the Task-1 placeholder file, annotate their declarations `package` (a library target's internals are invisible to test targets without it; `@testable import WatchtowerTestSupport` in tests is the alternative — pick ONE approach and apply it uniformly, state which in the report).

- [ ] **Step 2: Build the move list mechanically.** A test file moves iff: filename matches a Queries/DB/Model subject that moved (grep its `@testable`-reachable type usages), AND `grep -L "import SwiftUI\|import ViewInspector"` includes it, AND it references no AppState/ViewModel/transcription/App-target type. Expected population per the dep map: the `*QueriesTests.swift` family (`CalendarAccountQueriesTests`, `CatchUpQueriesTests`, `DayPlanQueriesTests`, `FeedItemQueriesTests`, `IdeaQueriesTests`, `InboxLearnedRulesQueriesTests`, `InboxQueriesTests`, `JiraAccountQueriesTests`, `MeetingTranscriptQueriesTests`, `MemoryQueriesTests`, `SecretaryProfileQueriesTests`, `SituationQueriesTests`, `SlackAccountQueriesTests`, `TargetQueries*Tests` ×4, `TrackEventQueriesTests`, `TrackStateQueriesTests`, `EmailAccountQueriesTests`, `GoogleAccountQueriesTests`), `DatabaseManagerTests`, `DatabaseValidationTests`, `QueryTests`, `TrackQueryTests`, `PromptQueryTests`, `TokenUsageQueryTests`, `InteractionQueryTests`, `FeedbackQueryTests`, plus pure model/logic tests not moved in Task 2. Move each with `git mv`, fix imports. A file that fails to compile in Core moves back (report the reason one-line each).

- [ ] **Step 3: Full verification.** Same commands, logs `/tmp/p2-t4-*.log`, both exit 0. Additionally count and report: `ls WatchtowerDesktop/Tests/Core/ | wc -l` (target: dozens; the dep map's upper bound for eventually-Core-eligible is 119).

- [ ] **Step 4: Commit.**

```bash
git add -A && git commit -m "test(desktop): shared TestSupport target; move DB/Queries/Model tests to CoreTests"
```

---

### Task 5: Pure Services/Utilities sweep (bounded)

**Files:**
- Move: eligible files from `Sources/Services/` (≈33 candidates: the 44 top-level minus 3 UI minus 8 AppState-coupled; plus `Services/Memory/RelevantMemory.swift`) and from `Sources/Utilities/` (per-file: only pure ones) → corresponding subdirs under `Sources/WatchtowerCore/`
- Move: their pure tests → `Tests/Core/`

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces: final Core population. STRICT BOUND: this task moves ONLY files that pass the purity criteria as-is — no refactoring, no protocol extraction, no AppState injection work. Anything needing surgery is listed in the report as future work and left in place.

- [ ] **Step 1: Candidate list.** For each file directly under `Sources/Services/` and `Sources/Utilities/`: run the purity check (imports only Foundation/GRDB/Combine/Yams/CryptoKit; no `AppState` reference; not in the never-move list; `TranscriptionModelProvisioner.swift`, `TranscriptSaveService.swift`, `TranscriptChaptersCenter.swift`, `TranscriptNotesCenter.swift`, `SpeakerGuessCenter.swift` additionally require zero references to `Transcription*`/`WindowedTranscriber`/`StreamingTranscriber`/`SpeakerDiarizing` types — check before moving). Files failing any check stay.

- [ ] **Step 2: Move + annotation loop per ~10-file batch,** compiler-driven as before; a batch member that drags app-shaped dependencies backs out.

- [ ] **Step 3: Move their pure tests** (same criteria as Task 4 Step 2), e.g. `CLIRunnerTests`, `CLIBinaryStoreTests`, `BriefingTests`, `EmojiResolverTests`, `SlackTextParserTests`, `JiraKeyExtractorTests`, `JiraHelpersTests`, `TimeFormattingTests` (if not already the seed) — verified per-file, back out non-compilers.

- [ ] **Step 4: Full verification.** Same commands, logs `/tmp/p2-t5-*.log`, both exit 0. Report final counts: files in Core, tests in CoreTests, files backed out with one-line reasons.

- [ ] **Step 5: Commit.**

```bash
git add -A && git commit -m "refactor(desktop): move pure Services/Utilities into WatchtowerCore"
```

---

### Task 6: Measure, prove, and record

**Files:**
- Modify: `docs/superpowers/specs/2026-08-11-local-build-speed-design.md` (append `### Phase 2 results (2026-08-12)` to the appendix)
- Modify: `CLAUDE.md` (one line in `## Build & Test`)

**Interfaces:**
- Consumes: everything above; Task 1's ML-absence check; the appendix's `0:35` edit→test denominator and `1:12` full-suite baseline.

- [ ] **Step 1: Measure the Core edit→test cycle** (the Phase 2 headline number). Sequential, foreground with tool timeout 600000:

```bash
touch WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/InboxQueries.swift
cd WatchtowerDesktop && time swift test --filter InboxQueriesTests > /tmp/p2-t6-coretest.log 2>&1; echo "exit=$?"
```

(Substitute any moved Queries file/test pair if this one didn't move.) Also re-measure the app-side cycle for contrast: `touch` an unmoved Services file + `time swift test --filter <its app-side test>`. And the full suite: `time swift test > /tmp/p2-t6-full.log 2>&1; echo "exit=$?"` — must stay green.

- [ ] **Step 2: Re-prove ML-absence** with Task 1 Step 5's method on the final tree; save the proof lines.

- [ ] **Step 3: Append the appendix section** — table: Core edit→test (measured) vs 0:35 pre-split vs app-side edit→test post-split; full-suite time; the ML-absence proof method + result; one line recording the `WatchtowerTranscription` deferral and the backed-out file list pointer (task reports). State the % improvement with the loaded-machine caveat if applicable.

- [ ] **Step 4: CLAUDE.md** — in `## Build & Test`, extend the Swift inner-loop bullet with: Core-level code lives in `WatchtowerCore` and its tests in `Tests/Core`, which build without the ML stack — prefer testing there when touching Models/Database/pure Services. Also update the Desktop header line of CLAUDE.md (the one describing the package) if it names the single-target layout.

- [ ] **Step 5: Full gate + commit.**

```bash
cd WatchtowerDesktop && swift build > /tmp/p2-t6-build.log 2>&1; echo "exit=$?"
make test-scripts > /tmp/p2-t6-scripts.log 2>&1; echo "exit=$?"
git add -A && git commit -m "docs(spec): record phase 2 results — Core tests link without the ML stack"
```

---

## Execution notes

- Strict order 1→6; every task is one implementer dispatch; no parallel implementers (they'd fight over Package.swift and the build dir).
- Subagents work in the worktree `/Users/user/PhpstormProjects/watchtower/.claude/worktrees/local-build-speed` on branch `feature/swift-package-split` — absolute path + branch check in every brief.
- Long swift commands: foreground Bash with tool timeout 600000 ms (background completion notifications are unreliable — proven in Phase 1).
- The dep map `.superpowers/phase2-depmap.md` is the factual basis for the file lists; implementers verify per-file before moving (the map is one commit old at best).
- After all tasks: PR stacked on `feature/local-build-speed` (base = that branch until PR #98 merges, then rebase onto main).
