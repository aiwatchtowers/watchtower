# Worktrees and the Go build cache stop eating the disk — plan

**Spec:** `docs/superpowers/specs/2026-11-25-build-cache-disk-design.md`
**Target:** #2403. **Umbrella branch:** `feature/build-cache-disk` (worktree `.claude/worktrees/build-cache-disk`, locked). Each task gets its own branch and worktree off the umbrella, is gated locally and merged into the umbrella with `git merge`; one PR umbrella → main at the end.

No Swift source changes anywhere in this plan. Swift is still built by the gate (`make test-swift`, whose tests `go build` the CLI and so pick up the new `GOFLAGS`) and by Task 3 (`make mobile-run`/`mobile-test`), and since every task's gate runs `make test-swift` (all five Swift packages), every task worktree builds Swift at its gate. Each worktree therefore may get, as an APFS clone (`cp -cR`, then drop `ModuleCache`) per spec §4, the `.build` of each package the gate builds, made just before the gate runs — not at the task's start, so the edit loop of Tasks 1, 2 and 4 (Go, scripts, docs) runs without one.

---

## Task 1 — Test root lookups work with and without `-trimpath`

**Depends on:** none. **Spec:** §3 point 5, Decisions (ask #1855: guards change only the root lookup).

Files:
- `cmd/prompt_store_scan_test.go` — `repoRootForPromptScan` (also used by `cmd/sync_loggers_test.go`).
- `internal/db/owner_scan_test.go` — `repoRootForOwnerScan` (used by `TestOwner01_…`, `TestSearchIdx01_…`, `TestProj17_…`, `TestInitTestTemplate_…`).
- `internal/digest/tier_scan_test.go` — `repoRoot`.
- `internal/slackmanifest/manifest_test.go` — the two inline `runtime.Caller(0)` lookups.

Steps:
1. Reproduce first: `GOFLAGS=-trimpath go test ./internal/slackmanifest` fails with `stat watchtower/go.mod`.
2. Replace each lookup with `os.Getwd()` (the package directory under `go test`) and walk up until a directory holds `go.mod`; keep the existing "does not contain go.mod" `t.Fatal` when none is found. `slackmanifest`'s manifest read uses the package directory from `os.Getwd()` directly. Each package keeps its own small helper (no new shared package — four call sites, different packages). Drop the then-unused `runtime` import.
3. Do not touch any assertion, test name or guard-test structure (inventory rule; owner approved only the root lookup in ask #1855).
4. Verify both modes: `go test ./cmd -run 'TestPromptStoreWiring|TestSyncWiring' ./internal/db -run 'TestProj17|TestOwner01|TestSearchIdx01|TestInitTestTemplate' ./internal/digest -run TestTierForSource ./internal/slackmanifest`, once plain and once with `GOFLAGS=-trimpath` (run per package if `-run` differs). Then `git grep -n 'runtime.Caller(0)' -- '*_test.go'` is empty.
5. `make lint-diff`.

## Task 2 — `-trimpath` at every Go entry point

**Depends on:** Task 1 (CI and the gate run trimmed and need the fixed tests). **Spec:** §3 points 1–4, Decisions (ask #1855: tracked settings; release trimmed).

Files: `Makefile`, `.claude/settings.json` (new), `.gitignore` (unchanged — the file is added with `git add -f`), `.github/workflows/ci.yml`, `.github/workflows/linux-build.yml`, `.github/workflows/release.yml`, `scripts/build-app.sh`, `scripts/build-linux.sh`, `scripts/tests/` (new case).

Steps:
1. Makefile, near the top-level exports: `export GOFLAGS := $(strip $(filter-out -trimpath,$(GOFLAGS)) -trimpath)` with a comment pointing at the spec (§1 numbers: the path is part of the cache key without it).
2. `.claude/settings.json`: `{"env": {"GOFLAGS": "-trimpath"}}`; `git add -f`. Claude Code's `env` replaces a variable, it cannot append, so a session's own `GOFLAGS` is replaced by this value; anyone who needs more flags sets the full value (`-trimpath` included) in their `settings.local.json`. The CLAUDE.md line of Task 4 says so. Confirm the main checkout has no untracked file of that name before merging into main (it had none on 2026-11-25).
3. Each workflow: a top-level `env:` block (before `jobs:`) with `GOFLAGS: -trimpath`; if a workflow already has a top-level `env:`, add the key to it.
4. `scripts/build-app.sh` and `scripts/build-linux.sh`: add `-trimpath` to their `go build` line.
5. New `scripts/tests/test-build-trimpath.sh` in the style of the neighbouring `test-build-*.sh`: greps that both build scripts' `go build` carries `-trimpath`, that `make --eval 'p:;@echo $$GOFLAGS' p` prints `-trimpath` (also with `GOFLAGS=-mod=mod` in the environment, which must survive), and that each `.github/workflows/*.yml` sets `GOFLAGS: -trimpath`.
6. Release binary check (spec §8): build `go build -trimpath -o <scratch>/wt .` and confirm `strings <scratch>/wt | grep -c '/Users/'` is 0 (do not commit the binary). A non-zero count stops the task: list each hit and its source (Go file paths are a missing flag; a C `__FILE__` from the SQLCipher amalgamation or a toolchain path is a separate cause), fix what comes from our build tree, and if a hit cannot be removed inside this scope, report it as a blocker to the controller, who files an ask — the task is not merged on a non-zero count.
7. Run `make test-scripts` (covers the new case and `test-build-app-*`/`test-build-linux.sh`), `make lint-diff`.

## Task 3 — Phone recipes build into `WatchtowerMobile/DerivedData`

**Depends on:** none. **Spec:** §5, §6, Decisions (ask #1855: everywhere, main included; ask #1852: archive/testflight keep the global folder).

Files: `Makefile`, `scripts/tests/` (new case).

Steps:
1. `MOBILE_DD ?= WatchtowerMobile/DerivedData`; `MOBILE_XCB := SWIFT_ENABLE_EXPLICIT_MODULES=NO -derivedDataPath $(MOBILE_DD) $(MOBILE_XCB_EXTRA)`. Update the comment above it (`MOBILE_XCB_EXTRA` no longer for `-derivedDataPath`; `MOBILE_DD=<dir>` instead).
2. Guard: `ifneq (,$(findstring -derivedDataPath,$(MOBILE_XCB_EXTRA)))` → `$(error MOBILE_XCB_EXTRA must not carry -derivedDataPath; pass MOBILE_DD=<dir> instead)`.
3. `mobile-run`'s `-showBuildSettings` call takes `$(MOBILE_XCB)` (or `-derivedDataPath $(MOBILE_DD)`) so it reports the same products path; `mobile-shots` already uses `$(MOBILE_XCB)` — confirm.
4. Leave `mobile-archive` and `mobile-testflight` as they are.
5. New `scripts/tests/test-mobile-derived-data.sh`: `make -n mobile-run` shows `-derivedDataPath WatchtowerMobile/DerivedData` on its `-showBuildSettings` call; `make -n mobile-build` contains `-derivedDataPath WatchtowerMobile/DerivedData`; `make -n mobile-test MOBILE_DD=x` contains `-derivedDataPath x`; `make -n mobile-build MOBILE_XCB_EXTRA='-derivedDataPath y'` exits non-zero and its output names `MOBILE_DD`; `make -n mobile-archive` contains no `-derivedDataPath`.
6. One real `make mobile-run` (it runs `mobile-build` first) in this task's worktree to confirm `WatchtowerMobile/DerivedData/info.plist` appears and the installed app comes from `WatchtowerMobile/DerivedData/Build/Products` (the phone app builds through Xcode into `WatchtowerMobile/DerivedData`, so it needs no SwiftPM `.build` copy). Then `make test-scripts`.

## Task 4 — Rules written down, measurement repeated

**Depends on:** Tasks 2 and 3. **Spec:** §3 point 6, §4, §5, §8.

Files: `CLAUDE.md`, `docs/features/README.md` only if a summary mentions DerivedData/-trimpath (grep first), the memory notes `worktree-swift-build-cache.md` and `mobile-derived-data-per-worktree.md` in the project's Claude Code auto-memory directory (`~/.claude/projects/<project-slug>/memory/`) (outside the repo — the controller edits them after the merge, not the implementer).

Steps:
1. CLAUDE.md Build & Test, Go inner loop: Go builds are trimmed (Makefile, `.claude/settings.json`, CI, release scripts); a bare `go` elsewhere still works but keeps a second cache copy per worktree; tests find files through `os.Getwd()`/`testdata`, never `runtime.Caller`.
2. CLAUDE.md iPhone line: phone `make` recipes build into `WatchtowerMobile/DerivedData` per checkout (`MOBILE_DD=<dir>` to change; not through `MOBILE_XCB_EXTRA`).
3. CLAUDE.md "Cache hygiene": a worktree gets a package's `.build` only when its task builds that package, copied as an APFS clone `cp -cR` (then drop `ModuleCache`), never `cp -R`; `du` over-counts clones, `df` is the truth.
4. Controller, before the task's review starts: rewrite the two memory notes to match (and their `MEMORY.md` hooks), and put their new text into the reviewer's brief next to the CLAUDE.md diff, so the review checks both against spec §3–§5; then send session #293 the build-folder contract (spec §6) if it was not delivered.
5. Measurement (spec §8 row 1): two fresh worktrees of the umbrella, one empty `GOCACHE`, `make build` + `go test -run '^$' ./internal/db ./cmd` through make's env (or `GOFLAGS` from settings), second tree adds ≤ ~20 MB to the cache and its build takes less time than the same workload without `-trimpath` measured in the same run (both numbers, before and after, for size and second-tree time); record them in the umbrella PR body (no live-install data). Check `go env GOFLAGS` in a fresh Claude Code session in a worktree prints `-trimpath`.

---

## Gate

Per task before its merge into the umbrella: the full gate from CLAUDE.md — `make test`, `make test-swift` (always: its Go-CLI-building tests run under the new `GOFLAGS`), `make lint-all`, `make test-scripts`, `scripts/leak-check.sh`, and each `.github/workflows/*.yml` job's command. Task 3's gate adds `make mobile-test`. A job that cannot run locally is named in the report. Once more on the umbrella before the PR into main.
