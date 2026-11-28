# Worktrees and the Go build cache stop eating the disk — design

**Target:** #2403 (project level). **Session:** #294, a sub-session of #293 (disk investigation).
**Out of scope:** the global automatic cleanup (`internal/sessioncleanup`, the daemon) — that is #2402 in session #293. This spec only names the build-folder contract it relies on (§6).

## 1. Problem

Measured on 2026-11-25 in session #293:

- **Go.** `~/Library/Caches/go-build` had grown to 54 GB. Builds run without `-trimpath`, so cmd/go hashes the package's absolute directory into every compile action id (`buildActionID`: `dir <p.Dir>` when `-trimpath` is off). Every worktree under `.claude/worktrees/` therefore rebuilds the whole module — the cgo SQLCipher amalgamation included — and stores its own copy: one 87 MB `internal/sqlcipher` archive sat in the cache 81 times. Go trims only entries untouched for 5 days, and the worktrees touch all of them. The self-hosted CI runners have the same problem: each runner checks out under its own `_work` path, so each one keeps a copy of the cache too.
- **Swift.** 11 worktrees held a `WatchtowerDesktop/.build` of 7–11 GB (a `cp -R` of main's, per the `worktree-swift-build-cache` memory rule), most also `WatchtowerKit/.build` (~1.4 GB) and `WatchtowerChat/.build` (~1.1 GB), plus a per-worktree phone DerivedData of 1.7–2.9 GB under ad-hoc names (`.build-mobile-dd*`, `.derived`, `.derived-mobile`, `.derived2`, `build/`) that the cleanup does not recognise.

## 2. Measurements behind the design

Two fresh worktrees of the same commit (A, B), each mode with its own empty `GOCACHE`; the workload is `go build ./... && go test -count=1 -run '^$' ./internal/db ./cmd`:

| mode | A: time / cache | B (second tree): time / cache | B adds |
|---|---|---|---|
| no `-trimpath` | 98 s / 909 MB | 43 s / 1412 MB | **+503 MB** |
| `-trimpath` | 49 s / 903 MB | 27 s / 917 MB | **+14 MB** |

With `-trimpath`, a second worktree reuses every compile action of the first. The rest of B's time goes to linking the test binaries.

APFS clone copy (`cp -cR`) against a plain `cp -R` of a 1.1 GB build tree: the clone took 3 s and no measurable free space (`df`), the plain copy took 12 s and 1.1 GB. `du` counts a clone at full size; `df` is the truth.

Full `go test ./...` under `-trimpath`: 10 failures in 4 packages (`cmd`, `internal/db`, `internal/digest`, `internal/slackmanifest`), all from one cause — four places find the repository root with `runtime.Caller(0)`, which under `-trimpath` returns the module-relative `watchtower/<pkg>/<file>.go` instead of an absolute path. Every other package passed.

## 3. Go: `-trimpath` everywhere the repository builds

There is no per-module flag file in Go (`go.mod` takes no build flags; `go.env` and `go env -w` are global), so the flag is set at each entry point the project owns:

1. **Makefile** — `export GOFLAGS := $(strip $(filter-out -trimpath,$(GOFLAGS)) -trimpath)`: every `make` recipe and every process it starts (`make test-swift`'s Swift tests that `go build .`, golangci-lint's `go list`) builds trimmed. A `GOFLAGS` the developer already set is kept.
2. **`.claude/settings.json`** (new, tracked with `git add -f` because `.claude/` is ignored): `{"env": {"GOFLAGS": "-trimpath"}}`. Every Claude Code session started in the repository or in one of its worktrees — the worktree checks out the same file — runs the CLAUDE.md inner loop (`go test ./internal/<pkg>`) trimmed. Personal settings stay in `settings.local.json`. The main checkout has no untracked `.claude/settings.json` today (checked 2026-11-25); because `.claude/` is gitignored, a clone that already has its own untracked `.claude/settings.json` would see git overwrite it silently on pull (git treats ignored files as expendable), so the umbrella PR description tells such clones to move their content to `settings.local.json` first.
3. **CI** — a workflow-level `env: GOFLAGS: -trimpath` in `ci.yml`, `linux-build.yml` and `release.yml`. The runners share one cache across their checkout paths, and CI tests in the same mode as the dev loop, so a new path-dependent test fails in CI instead of only on a laptop.
4. **Release scripts** — `scripts/build-app.sh` and `scripts/build-linux.sh` call `go build` directly; they pass `-trimpath` explicitly, so the shipped binaries carry no local absolute paths either (a public-repo hygiene gain: panics print `watchtower/internal/…/x.go:12`).
5. **Tests** — the four `runtime.Caller` root lookups (`repoRootForPromptScan` in `cmd/prompt_store_scan_test.go`, also used by `cmd/sync_loggers_test.go`; `repoRootForOwnerScan` in `internal/db/owner_scan_test.go`, used by four db guards; `repoRoot` in `internal/digest/tier_scan_test.go`; the two inline ones in `internal/slackmanifest/manifest_test.go`) switch to `os.Getwd()` (`go test` runs a package's tests in its source directory) walking up to `go.mod`. They then pass with and without `-trimpath`. Several are inventory guard tests (`TestOwner01_…`, `TestSearchIdx01_…`, `TestProj17_…`): only the root lookup changes, no assertion is touched.
6. **CLAUDE.md** — one line under Build & Test: Go builds are trimmed (Makefile, `.claude/settings.json`, CI); a bare `go` in a terminal without it still works but keeps a second cache copy per worktree; tests locate files through `os.Getwd()`/`testdata`, never `runtime.Caller`.

What does not change: `gopls` and GoLand run their own `go` processes without these settings (an IDE debugger keeps absolute paths, so breakpoints work);  the test result cache keeps working — a test that reads files records their paths and contents, so a result cached in one worktree is reused in another only when the inputs match.

**Exception: golangci-lint runs without `-trimpath`** (found by the umbrella gate). Under `-trimpath` cmd/go stops keying cgo actions by directory, but the cgo-generated files in the cache keep `//line` directives with the absolute path of the worktree that produced them; `go list -compiled` in another worktree returns them, and go/packages tools open that other worktree's raw cgo sources — failing once it is deleted, silently linting its content while it lives. The Makefile's `lint`/`lint-diff` recipes strip `-trimpath` for golangci-lint and CI's `go-lint` job sets `GOFLAGS` empty. Lint only runs cgo preprocessing, so its per-worktree cache cost is small. gopls in an agent session sees the same `GOFLAGS`; it is not used for checks this repo relies on.

**Failure modes.** `make … GOFLAGS=<x>` on the command line still builds trimmed: the Makefile assigns GOFLAGS with `override`. A `GOFLAGS` persisted only through `go env -w` is shadowed inside make; none is set on this machine, and `go env -w` is not a mechanism this spec uses. A developer or agent runs `go test` outside these entry points (a codex session, a plain terminal): correct results, only the old per-tree cache cost. A new test reintroduces `runtime.Caller`: it fails in CI (point 3) and in every agent run. A `GOFLAGS` containing `-trimpath` twice is harmless (a bool flag). No writers race: these are build settings, not data.

## 4. Swift: copy only where Swift is built, and copy as a clone

The `worktree-swift-build-cache` rule changes:

- A worktree gets a package's `.build` only when its task builds that package (`WatchtowerDesktop`, `WatchtowerKit`, `WatchtowerChat`, `WatchtowerChatText`, `WatchtowerInterface` alike); a Go-only or docs-only worktree gets none.
- The copy is an APFS clone, `cp -cR`, never `cp -R`: it costs no disk until the build rewrites a file, so a lane pays only for what it recompiles. The `ModuleCache` removal after the copy stays. One rule for every package, because a clone is free whatever its size.

This is a process rule (CLAUDE.md "Cache hygiene" plus the memory note), not code: worktrees are made by agents, and there is no seeding script to change.

## 5. Phone: one DerivedData path per worktree, by default

The Makefile's phone recipes always pass `-derivedDataPath $(MOBILE_DD)`, with `MOBILE_DD ?= WatchtowerMobile/DerivedData` (gitignored; not under `build/`, which `scripts/app-swap.sh` replaces wholesale on every `make app`, and outside xcodegen's `Sources`). Every checkout — main and each worktree — then builds into its own folder with no extra flag, which also removes the stale-Kit cross-lane bug the `mobile-derived-data-per-worktree` memory works around with a brief instruction. `mobile-run`'s `-showBuildSettings` gets the same path. The recipes that take it: `mobile-build`, `mobile-test`, `mobile-run`, `mobile-shots` — the ones that use `$(MOBILE_XCB)`. `mobile-archive` and `mobile-testflight` (the release path, cut on main) stay on Xcode's global DerivedData; they are not worktree work and changing the release path is not asked for.

A different folder is given as `make mobile-test MOBILE_DD=<dir>`. `MOBILE_XCB_EXTRA` no longer carries `-derivedDataPath`: the Makefile stops with `$(error …)` naming `MOBILE_DD` when `MOBILE_XCB_EXTRA` contains it, so an old brief that still passes it fails at once with the fix in the message instead of handing xcodebuild the option twice. The ad-hoc names stop being needed; the memory and CLAUDE.md say to use the default.

Cost: the main checkout's phone build moves from `~/Library/Developer/Xcode/DerivedData` to `WatchtowerMobile/DerivedData` — one cold phone build once. Xcode opened by hand keeps its own DerivedData.

**Failure modes.** A build stopped half-way leaves a half-written `WatchtowerMobile/DerivedData`; xcodebuild resumes it on the next run as it does today. Two phone runs in the same worktree at once share a folder, which is the same situation as today's shared global folder, limited to one worktree.

## 6. Contract with the automatic cleanup (#2402)

The cleanup (`internal/sessioncleanup/builds.go`) prunes folders named `.build` (with `workspace-state.json`) and `DerivedData` (with `info.plist` and `Build/`). After this change every project build folder has one of these names: `WatchtowerDesktop/.build`, `WatchtowerKit/.build`, `WatchtowerChat/.build`, `WatchtowerChatText/.build`, `WatchtowerInterface/.build`, and `WatchtowerMobile/DerivedData`. `findBuildDirs` walks the whole worktree, so `WatchtowerMobile/DerivedData` is found as it is; session #293 is told this list so #2402 keeps it. Old ad-hoc folders in existing worktrees go with their worktrees, and this spec deletes nothing by hand.

## 7. Non-goals

- A shared SwiftPM package cache: SwiftPM already keeps its repository mirrors in `~/Library/Caches/org.swift.swiftpm`; `checkouts` are small next to the build products.
- Sharing one `.build` between worktrees: SwiftPM's `.build` is path-bound (the `ModuleCache` problem), so a clone per worktree is the safe form.
- `GOCACHE` limits or trimming the cache: with one copy per package, Go's own 5-day trim is enough.

## 8. Verification (each tied to a plan task)

| promise | check |
|---|---|
| a second worktree adds ~no Go cache | the §2 two-tree measurement repeated on the umbrella branch through `make` (Makefile flag in force) |
| agent sessions build trimmed | `go env GOFLAGS` in a Claude Code session started in a worktree prints `-trimpath` |
| tests pass both ways | `go test ./cmd ./internal/db ./internal/digest ./internal/slackmanifest` with and without `GOFLAGS=-trimpath` |
| CI uses it | the gate's local CI run shows `GOFLAGS=-trimpath` in the job env |
| release binaries carry no local paths | `strings` on a `scripts/build-app.sh`-style build finds no `/Users/` path; `scripts/tests/test-build-*.sh` pass |
| golangci-lint unaffected | `make lint-all` green; `make -n lint`/`lint-diff` run golangci-lint without `-trimpath` and ci.yml's `go-lint` sets `GOFLAGS` empty (scripts/tests case) |
| phone builds land in `WatchtowerMobile/DerivedData` | `make mobile-build` in a worktree creates `WatchtowerMobile/DerivedData/info.plist`; `make -n mobile-archive` carries no `-derivedDataPath` |
| `mobile-run` installs the app just built | `make -n mobile-run` shows `-derivedDataPath WatchtowerMobile/DerivedData` on its `-showBuildSettings` call (a `scripts/tests` case), and one real `make mobile-run` in the task's worktree installs the `.app` from `WatchtowerMobile/DerivedData/Build/Products` |
| an old `MOBILE_XCB_EXTRA=-derivedDataPath …` fails clearly | `make -n mobile-build MOBILE_XCB_EXTRA='-derivedDataPath x'` exits non-zero with the `MOBILE_DD` message (a `scripts/tests` case) |
| the Swift copy rule and the new defaults are written down | the plan's docs task: CLAUDE.md "Cache hygiene" and Build & Test lines, the `worktree-swift-build-cache` and `mobile-derived-data-per-worktree` memory notes say `cp -cR`, only the packages the task builds, and `MOBILE_DD`; the task's review checks the text against §3–§5 |

## Decisions

- Project-scoped `-trimpath` through the Makefile and the project's Claude Code settings, never through `go env -w`/`go.env` (global) — conversation (brief from #293).
- Do not touch the global automatic cleanup; ask #293 for any contract it needs — conversation (brief from #293).
- Delete nothing by hand in other worktrees — conversation (brief from #293).
- Copy a package's `.build` only into a worktree whose task builds that package — conversation (brief from #293); the copy is an APFS clone for every package — spec review ask #1852.
- Phone `mobile-archive`/`mobile-testflight` keep Xcode's global DerivedData — author's call (scope: the release path was not asked for; the ambiguity was raised in spec review ask #1852).
- `-trimpath` for agents' bare `go` commands through a tracked `.claude/settings.json` — ask #1855.
- The inventory guard tests switch only their repository-root lookup from `runtime.Caller` to `os.Getwd()`; no assertion changes — ask #1855.
- Release binaries (`scripts/build-app.sh`, `scripts/build-linux.sh`, `release.yml`) build with `-trimpath` too — ask #1855.
- Phone `make` recipes default to a per-checkout DerivedData in every checkout, main included — ask #1855; the folder is `WatchtowerMobile/DerivedData`, not `build/DerivedData` as first written, because `build/` is swapped by `make app` — author's call during Task 3 review.
