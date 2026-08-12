# Local build & test speed — phased workflow + package split

**Date:** 2026-08-11
**Status:** approved by owner (chat, 2026-08-11)

## Problem

The local development loop is slow on the machine that runs it (8 cores, 16 GB RAM,
shared with a Docker VM and multiple Claude sessions):

- **Swift:** `WatchtowerDesktop` is a single executable target plus one test target of
  ~195 test files. The executable links WhisperKit, FluidAudio, and MLX/speech-swift, so
  *every* `swift test` — even for a one-line change in a GRDB query — recompiles the
  changed files and **re-links the full ML stack**. Full test runs are the default habit
  for both the owner and subagents.
- **Worktrees:** each agent worktree builds its own `.build` from scratch (~5 GB,
  minutes of cold dependency compilation, measured 4:24 in the appendix, on a loaded
  machine). The agent-heavy workflow
  creates worktrees often, so cold builds are a recurring tax, and each worktree also
  duplicates ~5 GB on disk (measured: main checkout 4.9 GB, one worktree 5.0 GB).
- **Go:** 37 packages, 361 test files. `make test` runs `go test ./... -v`, producing
  megabytes of output; the habit of running `./...` instead of the touched package wastes
  the (already working) Go test cache. `make lint` always lints the whole repo.
- **Machine:** the documented swap-thrash pattern (Docker VM + leaked mcp containers +
  stale Claude sessions) degrades link-heavy Swift builds by multiples when active.

Two loops matter, and they have different budgets:

1. **Inner loop** (priority): edit → targeted test, many times per hour, mostly driven by
   subagents.
2. **Pre-PR gate:** `local-review` / `release-check` — full lints + full `go test` + full
   `swift test`. Rare, may stay slow, but should not be gratuitously slow.

## Decision

Two phases in one spec. Phase 1 is workflow/tooling quick wins (days). Phase 2 is the
structural Swift package split — the only real cure for the per-test ML re-link — and
gets its own implementation plan after Phase 1 lands.

### Measurement first

Before any change, record a baseline in `docs/superpowers/specs/` alongside this spec
(a short companion file or an appendix section added to this one) with real numbers on
the dev machine, healthy-memory state (`dev-health` clean, see below):

- cold `swift build` in a fresh worktree;
- incremental no-op `swift build`;
- full `swift test`; `swift test --filter <one test class>`;
- full `go test ./...` (cold cache) and fully-cached `go test ./...`.

Every change below is accepted only when a re-measurement shows the win. No
"should be faster" merges.

### Phase 1 — quick wins

1. **Makefile changes.**
   - `make test` drops `-v`; a new `test-verbose` target keeps the old behavior.
   - `make test-swift` accepts an optional `FILTER` variable:
     `make test-swift FILTER=MeetingRecorderCenterTests` → `swift test --filter …`;
     without `FILTER` it runs the full suite as today.
   - New `lint-diff` target: `golangci-lint run --new-from-rev origin/main` for the
     inner loop. Full `lint` stays the gate.
2. **`swift test --parallel` experiment** for the full suite. Acceptance: three
   consecutive clean full runs → adopt inside `test-swift`. Any flake → revert and
   record the offending fixture class in this spec's appendix (candidate for later
   serialization work, not silently retried).
3. **Worktree `.build` seeding — gated experiment.** `scripts/seed-worktree-build.sh`
   copies `WatchtowerDesktop/.build` from the main checkout into a new worktree via APFS
   clonefile (`cp -c`), making the copy nearly free in disk and time. **Known risk, stated
   up front:** SwiftPM/llbuild record absolute paths in the build database, so a `.build`
   copied under a different package root may invalidate most incremental state and
   rebuild anyway. Therefore the script merges only after a measured gate: seeded build
   time ≤ 50% of the cold build time. If paths kill the win, the fallback (a stable
   build-path symlink trick) is investigated as a separate follow-up, and the seed script
   is *not* merged half-working. A fully shared `.build` between concurrent sessions is
   rejected (SwiftPM locks, races — see the two-session lock incident).
4. **Agent guidance.** The CLAUDE.md Build/Test section gains the inner-loop rule:
   targeted `go test ./internal/<pkg>` + `swift test --filter <Class>` while iterating;
   full runs belong to the gate only. This is what actually changes subagent behavior —
   they read CLAUDE.md, not this spec.
5. **Machine hygiene helper.** `scripts/dev-health.sh` prints (never fixes): memory
   pressure / swap usage, running Docker containers matching the leaked-mcp pattern, and
   the count of live Claude session processes. Run manually before heavy builds; the
   documented cleanup order (sessions → containers → Docker restart) stays a human
   decision.

### Phase 2 — Swift package split (separate implementation plan)

Coarse module boundaries, to be refined in the Phase 2 plan:

- **WatchtowerCore** — models, GRDB queries, non-UI services with no ML dependency.
- **WatchtowerTranscription** — the sole owner of WhisperKit / FluidAudio / Qwen3
  (speech-swift) dependencies.
- **WatchtowerDesktop (executable)** — SwiftUI views, app lifecycle; depends on both.

Each library module gets its own test target; ViewInspector-based view tests stay with
the executable's test target. Acceptance criterion: a Queries-level test builds and links
**without** the WhisperKit stack — verified by build log inspection and by the measured
filtered-test time. Phase 2 starts only after Phase 1 lands; Phase 1 wins may reprioritize
it.

Both Phase 1 experiments above were rejected (see appendix): `swift test --parallel` was
flaky and slower, and worktree `.build` seeding broke the build outright on `.pcm`
absolute-path invalidation. Neither leaves a working workaround for the per-test ML
re-link, which confirms Phase 2 as the only remaining cure. The stable build-path symlink
trick is tracked as a Phase-2-adjacent follow-up, alongside parallel-flake fixture
isolation.

## Out of scope

- Go package restructuring (the Go test cache already solves the inner loop there).
- CI pipeline changes — this spec is local-only.
- A shared `.build` between concurrent sessions (rejected above).
- Fixing the machine-level swap pattern itself (documented elsewhere; the helper script
  only surfaces it).

## Testing

- Shell scripts (`seed-worktree-build.sh`, `dev-health.sh`) follow the existing
  `scripts/tests/test-*.sh` precedent: marked blocks exercised against stubbed binaries,
  no real builds.
- Makefile targets are validated by the baseline/after measurements above.
- CLAUDE.md guidance changes are review-only.

## Appendix: measurements

All numbers from the dev machine (8 cores, 16 GB RAM), sequential runs.

### Baseline (2026-08-11)

Machine state: `vm.swapusage: total = 7168.00M  used = 5888.00M  free = 1280.00M
(encrypted)`, load `6.94` (1-min). **Baseline is polluted:** swap used (5.75 GB) is well
over the ~2 GB clean threshold, and load average (6.94/10.09/9.39 on 8 cores) shows the
machine was already busy during measurement. Numbers below are directionally useful but
likely pessimistic versus a quiescent machine — re-measure with `dev-health.sh` clean once
it exists (Phase 1, item 5).

| Measurement | Wall clock | Notes |
|---|---|---|
| `go test ./...` (cached) | 2:34 | exit=0, all packages ok; slower than cold-cache run — contention noise, see machine state above |
| `go test ./...` (cold cache) | 2:22 | `go clean -testcache` first, exit=0, all packages ok |
| `swift build` (cold, fresh worktree) | 4:24 | exit=0; worktree had no `WatchtowerDesktop/.build`; internal `Build complete! (261.90s)` vs. 4:24.18 wall clock (~2s process start/teardown overhead) |
| `swift build` (no-op incremental) | 0:07 | exit=0; internal `Build complete! (6.20s)` |
| `swift test` (full suite) | 1:12 | exit=0; 1946 tests, 1 skipped, 0 failures, 18 test bundles — no pre-existing failures to record |
| `swift test --filter WindowPlannerTests` | 0:07 | exit=0; 10 tests, 0 failures |

### Edit→test cycle (2026-08-12, Phase 2 denominator)

The number Phase 2 exists to shrink: after touching ONE non-ML source file
(`Sources/Services/ConfigService.swift`, warm `.build`), `swift build` takes **0:18**
(module-slice recompile + executable re-link) and the full edit→filtered-test cycle
`swift test --filter ConfigServiceTests` takes **0:35** — of which the test run itself is
~1 s; the rest is recompiling the single 500-file module and re-linking the test bundle
against the full WhisperKit/FluidAudio/MLX stack. Phase 2's module split targets exactly
this link+recompile share: a Core-only edit should compile a small module and link a
test bundle with no ML dependencies. Same loaded-machine caveat as the baseline above.

### swift test --parallel experiment (2026-08-12)

| Run | Wall clock | Result |
|---|---|---|
| 1 | 2:22 | fail |
| 2 | 2:58 | fail |
| 3 | 2:11 | fail |

All three runs exited 1 with real failures absent from the Task 1 serial baseline (0
failures). `AddRuleSheetViewTests.testSaveDispatchesDefaults` and four
`MemoryViewModelTests` methods (`testSaveImportanceOverrideClearsValue`,
`testSaveImportanceOverrideFailsWhileMemoryRunHoldsLock`,
`testSaveImportanceOverrideSetsValue`, `testSelectLoadsBodyRendersLinksAndBacklinks` in
run 1; `testSaveEditWritesFile`, `testSaveFocusRawWritesFileUnderLock`,
`testVaultMissingReportsNotInitialized` plus a repeat of
`testSaveImportanceOverrideFailsWhileMemoryRunHoldsLock` in run 2;
`testBeginFocusEditingOpensWithTemplateWhenFileMissing`,
`testSaveImportanceOverrideSetsValue`, `testSelectLoadsBodyRendersLinksAndBacklinks`,
`testVaultMissingReportsNotInitialized` in run 3) failed in every run — the
`MemoryViewModelTests` failures include `NSCocoaErrorDomain Code=260` file-not-found
errors against a shared `/var/folders/.../T/memory/` temp path, consistent with parallel
workers racing on the same on-disk fixture rather than genuine product bugs. Run 3 also
tripped `DaemonManagerStopTests.testFastExitReturnsWellBeforeTheTimeout` and two
`IdeasViewModelTests` backfill-guard tests, not seen in runs 1-2 — additional timing
sensitivity under heavier CPU contention, not a fixed set of failures.

Verdict: rejected — flaking classes `AddRuleSheetViewTests` and `MemoryViewModelTests`
(consistent across all 3 runs; likely a shared temp-directory fixture not made
parallel-safe), plus `DaemonManagerStopTests`/`IdeasViewModelTests` as secondary,
contention-dependent flakes in run 3 — serialization/fixture-isolation follow-up
candidate. All three parallel runs (2:22, 2:58, 2:11) were also slower than the 1:12
serial baseline, so there was no speed win even setting the failures aside.

### Worktree .build seeding experiment (2026-08-12)

Seed source: main checkout `.build` (debug, 4.9 GB). Seeding took 0:18 via APFS
clonefile (`cp -Rc`), confirmed byte-for-byte present at the destination.

| Measurement | Wall clock |
|---|---|
| cold `swift build` (baseline, Task 1) | 4:24 |
| seeded `swift build` | 0:50 (exit=1, build FAILED) |

The seeded build did not just run slow — it errored out at 50 seconds with
`error: precompiled file '.../ModuleCache/.../SwiftShims-....pcm' was compiled with
module cache path '/Users/user/PhpstormProjects/watchtower/WatchtowerDesktop/.build/...'
but the path is currently '/private/tmp/wt-seed-experiment/WatchtowerDesktop/.build/...'`
followed by `missing required module 'SwiftShims'`, repeated across several modules
(ArgumentParserToolInfo, `_DarwinFoundation2`, `Darwin`). This is exactly the risk
flagged up front in Phase 1 item 3: SwiftPM/llbuild's precompiled Clang module cache
(`.pcm` files) embeds the absolute build-directory path at compile time, and a worktree
under a different absolute path invalidates that cache outright rather than degrading
gracefully to a slower rebuild.

Verdict: rejected — absolute-path invalidation ate the win (worse than the win: it broke
the build outright, exit=1, not merely slow); stable build-path symlink trick remains the
follow-up, script not merged.

### Phase 2 results (2026-08-13)

Final tree (`feature/swift-package-split`, all six tasks landed): `WatchtowerCore` = 139
Swift files (Models/Database/Services/Utilities), `Tests/Core` = 47 test files, app target
(`Sources/`, excluding `WatchtowerCore/`) = 266 files, root `Tests/` (excluding
`Core/`/`Support/`) = 142 files.

Machine state: `vm.swapusage: total = 10240.00M  used = 9265.12M  free = 974.88M
(encrypted)`, 22 live `claude` processes, Docker down (`dev-health.sh`). **Same
loaded-machine caveat as the Phase 1 baseline** — swap sits at 90% of a swap file that has
grown since the 2026-08-11 baseline (7168M → 10240M total), and this measurement ran
inside a busy multi-agent session sharing the machine with sibling work. Numbers below are
directionally useful, not a quiet-machine reference point.

| Measurement | Wall clock | Notes |
|---|---|---|
| Core edit→test — `touch Sources/WatchtowerCore/Database/Queries/InboxQueries.swift` + `swift test --filter InboxQueriesTests` | **0:12** (11.68s) | exit=0, 17/17 passed; build step alone 7.69s (`Compiling WatchtowerCore InboxQueries.swift` → `Emitting module WatchtowerCore`) |
| App-side edit→test (contrast) — `touch Sources/Services/ConfigService.swift` + `swift test --filter ConfigServiceTests` | 0:13 (13.18s) | exit=0, 19/19 passed; build step alone 11.59s |
| No-touch floor — `swift test --filter InboxQueriesTests`, nothing changed | 0:07 (7.17s) | exit=0, 17/17 passed; build step 5.56s — the fixed SwiftPM plan+link floor with zero recompilation |
| Full suite — `swift test` | 0:31 (30.51s) | exit=0; 1946 tests, 1 skipped, 0 failures — identical count to the Phase 1 baseline; test execution itself 23.13s inside one aggregated `WatchtowerDesktopPackageTests.xctest` bundle |
| `swift build` (final gate) | 0:07 (6.50s) | exit=0 |

**Core edit→test vs the 0:35 pre-split denominator: 11.68s vs 35s ≈ 67% faster.** But the
app-side contrast (13.18s) lands nearly as fast as Core (11.68s) — both far below 0:35, and
the gap between them (1.5s) is much smaller than the pre-split story implied. Root cause,
confirmed in the build logs: **`swift test --filter` still produces one aggregated test
product** (`Test Suite 'WatchtowerDesktopPackageTests.xctest'` appears in both runs, no
per-target `.xctest` bundles exist) that links against the full app target — and therefore
the whole WhisperKit/FluidAudio/Qwen3ASR/MLX stack — regardless of which target's source
changed. So the ML-absence proof below is a **module-compilation** guarantee (`WatchtowerCore`
itself never compiles or links ML code) rather than a **test-run-link** guarantee — a
Core-only edit still triggers a relink of the same ML-linked executable an app-side edit
does. The real, measured win is that the app target shrank from the pre-split ~500-file
single module to 266 files, and `WatchtowerCore`'s own incremental recompile is a small,
non-ML slice (139 files, GRDB+Yams only) — so both edit paths now recompile less than the
old single-module baseline, with Core's build step still measurably cheaper than
app-side's (7.69s vs 11.59s). This doesn't undercut the ML-absence finding, but it does mean
the wall-clock win is smaller than "Core tests never touch ML" would suggest — worth
flagging for the owner: a true zero-ML-relink win would require per-target `.xctest`
bundles, which this SwiftPM/toolchain version does not produce. Given the loaded-machine
caveat, treat the 67% figure as directional; the qualitative finding (both edit paths
faster, aggregate-bundle link now dominates over compile) is the more load-bearing result.

**ML-absence proof (final tree).** Method: Task 1 Step 5's fallback path, re-run — this
toolchain aggregates all test targets into one `.xctest` bundle, so there is no per-target
binary to `otool -L`:

```
$ swift build --build-tests                                              → exit=0
$ grep -iE "whisperkit|fluidaudio|qwen3|mlx" buildtests.log \
    | grep -i "WatchtowerCoreTests"                                      → zero matches
$ grep -rliE "whisperkit|fluidaudio|qwen3|mlx" \
    .build/arm64-apple-macosx/debug/WatchtowerCoreTests.build/           → zero matches
```

Plus the structural guarantee: `WatchtowerCore`'s target in `Package.swift` declares
`dependencies: [GRDB, Yams]` only — it cannot link WhisperKit/FluidAudio/Qwen3ASR/MLX by
construction. The second grep (the per-target `.build` object directory, which exists
separately from the aggregated `.xctest` bundle) is a stronger corroboration than Task 1
had: it confirms zero ML strings anywhere in `WatchtowerCoreTests`' own compiled/emitted
artifacts, not just in build-log text.

**Deferred/deviations.** `WatchtowerTranscription` module split was deferred (owner-flagged
in the plan, not attempted this phase). Six Database files stayed app-side and
`EmojiResolverTests`/`RelevantMemoryTests` stayed app-side (both per owner ruling /
`DatabaseManager` coupling) — full file lists are in
`.superpowers/sdd/2026-08-12-swift-package-split/task-{2,3,4,5}-report.md`.
