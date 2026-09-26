# Local Build & Test Speed — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the Phase 1 quick wins of `docs/superpowers/specs/2026-08-11-local-build-speed-design.md`: measured baselines, Makefile inner-loop targets, two gated experiments (`swift test --parallel`, worktree `.build` clonefile seeding), agent guidance in CLAUDE.md, and a read-only machine-health script.

**Architecture:** No production code changes. Everything is Makefile targets, two standalone shell scripts under `scripts/` with tests under `scripts/tests/` (existing precedent), a spec appendix holding real measurements, and a CLAUDE.md section. Experiments merge only when their measured gate passes; a failed gate is recorded in the appendix and the corresponding artifact is not committed.

**Tech Stack:** GNU make, bash, git worktrees, SwiftPM, Go toolchain.

## Global Constraints

- Everything committed to the repo is in English (owner rule).
- Measurements are recorded with real numbers in the spec appendix; no change is claimed as a win without a before/after measurement (spec: "Measurement first").
- `swift test --parallel` is adopted only after three consecutive clean full runs (spec Phase 1 item 2).
- The seed script merges only if seeded build time ≤ 50% of the cold build baseline (spec Phase 1 item 3).
- `dev-health.sh` prints and never fixes anything (spec Phase 1 item 5).
- Script tests follow the `scripts/tests/test-*.sh` precedent: no real builds, exit non-zero on failure, runnable via `make test-scripts`.
- Never run `swift test`/`swift build` through a `timeout` wrapper (breaks xctest arch); capture real exit codes, do not pipe verification commands through `tail`/`head`.
- Working directory is the worktree root (`.claude/worktrees/local-build-speed`); do not `cd` out of it except into `WatchtowerDesktop/` for swift commands and into scratch dirs explicitly created by a task.

---

### Task 1: Baseline measurements → spec appendix

**Files:**
- Modify: `docs/superpowers/specs/2026-08-11-local-build-speed-design.md` (append an `## Appendix: measurements` section)

**Interfaces:**
- Produces: the appendix section with a `### Baseline (2026-08-11)` subsection containing a markdown table of timings. Task 5 and Task 6 append their experiment results to this same appendix and compare against these numbers (Task 6 uses the "cold `swift build`" row as its denominator).

This worktree was created fresh and has no `WatchtowerDesktop/.build` — it IS the cold-build fixture. Run measurements sequentially, not in parallel (they compete for the same 8 cores).

- [ ] **Step 1: Record machine state**

```bash
sysctl vm.swapusage
uptime
```

Record the swapusage line verbatim in the appendix later — if swap "used" is over ~2 GB, note it: the baseline is polluted and the appendix must say so.

- [ ] **Step 2: Measure Go tests — cached, then cold**

```bash
# warm/cached run (the everyday case):
time go test ./... > /tmp/go-test-cached.log 2>&1; echo "exit=$?"
# cold cache:
go clean -testcache
time go test ./... > /tmp/go-test-cold.log 2>&1; echo "exit=$?"
```

Record both wall-clock times. If exit != 0, STOP and report — the baseline must be green (check the log tail directly, do not pipe the test command itself through anything).

- [ ] **Step 3: Measure cold `swift build`**

```bash
cd WatchtowerDesktop && time swift build > /tmp/swift-build-cold.log 2>&1; echo "exit=$?"
```

Expected: tens of minutes (compiles GRDB, WhisperKit, FluidAudio, MLX from scratch). Record the time. Run this in the background (`run_in_background`), not under any timeout.

- [ ] **Step 4: Measure no-op incremental `swift build`**

```bash
cd WatchtowerDesktop && time swift build > /tmp/swift-build-noop.log 2>&1; echo "exit=$?"
```

- [ ] **Step 5: Measure full `swift test` and filtered `swift test`**

```bash
cd WatchtowerDesktop && time swift test > /tmp/swift-test-full.log 2>&1; echo "exit=$?"
cd WatchtowerDesktop && time swift test --filter WindowPlannerTests > /tmp/swift-test-filtered.log 2>&1; echo "exit=$?"
```

`WindowPlannerTests` is a small pure-logic class — a representative inner-loop target. If the full run has pre-existing failures, record them by name in the appendix and continue (the baseline documents reality), but the filtered run must be green.

- [ ] **Step 6: Write the appendix**

Append to `docs/superpowers/specs/2026-08-11-local-build-speed-design.md`:

```markdown
## Appendix: measurements

All numbers from the dev machine (8 cores, 16 GB RAM), sequential runs.

### Baseline (2026-08-11)

Machine state: `<vm.swapusage line>`, load `<uptime 1-min figure>`.

| Measurement | Wall clock | Notes |
|---|---|---|
| `go test ./...` (cached) | m:ss | |
| `go test ./...` (cold cache) | m:ss | |
| `swift build` (cold, fresh worktree) | m:ss | |
| `swift build` (no-op incremental) | m:ss | |
| `swift test` (full suite) | m:ss | |
| `swift test --filter WindowPlannerTests` | m:ss | |
```

Fill every cell with the measured values — no placeholders left in the table.

- [ ] **Step 7: Commit**

```bash
git add docs/superpowers/specs/2026-08-11-local-build-speed-design.md
git commit -m "docs(spec): record local build/test baseline measurements"
```

---

### Task 2: Makefile inner-loop targets

**Files:**
- Modify: `Makefile` (the `test:` and `test-swift:` targets, the `lint:` area, and the `.PHONY` line)

**Interfaces:**
- Produces: `make test` (quiet full Go tests), `make test-verbose` (old `-v` behavior), `make test-swift [FILTER=X]`, `make lint-diff`. Task 5 modifies the same `test-swift` target again if its gate passes.

- [ ] **Step 1: Edit the targets**

Replace the current `test:` block and `test-swift:` block, and add two targets next to their namesakes:

```make
test:
	go test ./...

test-verbose:
	go test ./... -v
```

```make
# Inner-loop Swift tests: make test-swift FILTER=SomeTestClass runs only that
# class; without FILTER the full suite runs as before.
test-swift:
	cd WatchtowerDesktop && swift test $(if $(FILTER),--filter $(FILTER),)
```

```make
# Inner-loop lint: only issues introduced relative to origin/main.
# The full `lint` target remains the pre-PR gate.
lint-diff:
	golangci-lint run --new-from-rev origin/main ./...
```

Add `test-verbose lint-diff` to the `.PHONY` line.

- [ ] **Step 2: Verify the generated command lines without running them**

```bash
make -n test
make -n test-verbose
make -n test-swift
make -n test-swift FILTER=WindowPlannerTests
make -n lint-diff
```

Expected respectively: `go test ./...`; `go test ./... -v`; `cd WatchtowerDesktop && swift test`; `cd WatchtowerDesktop && swift test --filter WindowPlannerTests`; `golangci-lint run --new-from-rev origin/main ./...`.

- [ ] **Step 3: Run the two cheap targets for real**

```bash
make test > /tmp/make-test.log 2>&1; echo "exit=$?"
make test-swift FILTER=WindowPlannerTests > /tmp/make-test-swift.log 2>&1; echo "exit=$?"
make lint-diff > /tmp/make-lint-diff.log 2>&1; echo "exit=$?"
```

All exit 0 (`make test` should be seconds — Task 1 warmed the Go cache; `lint-diff` on a docs-only branch finds nothing).

- [ ] **Step 4: Commit**

```bash
git add Makefile
git commit -m "build: quiet make test, FILTER for test-swift, lint-diff target"
```

---

### Task 3: `scripts/dev-health.sh` (read-only machine health)

**Files:**
- Create: `scripts/dev-health.sh` (mode 755)
- Test: `scripts/tests/test-dev-health.sh` (mode 755)

**Interfaces:**
- Produces: `bash scripts/dev-health.sh` — prints memory/swap, Docker containers, Claude session count; always exits 0 (it is a report, not a gate). Consumed by humans before heavy builds; referenced from CLAUDE.md in Task 4.

- [ ] **Step 1: Write the failing test**

Create `scripts/tests/test-dev-health.sh`:

```bash
#!/bin/bash
# Tests for scripts/dev-health.sh — a read-only reporter.
#
# Runs the real script with PATH pointing at stubbed docker/pgrep/sysctl
# binaries — no real Docker daemon, no real process list.
#
# Covers:
#   - all sections print their headers
#   - docker daemon unreachable (valid, degenerate) → "docker not running", exit 0
#   - script never exits non-zero (it is a report, not a gate)
#   - script contains no mutating docker/kill commands (read-only contract)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEV_HEALTH="$SCRIPT_DIR/../dev-health.sh"

FAILURES=0
note_fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

bash -n "$DEV_HEALTH" && echo "ok: bash -n" || note_fail "bash -n dev-health.sh"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir "$WORK_DIR/bin"

# Stubs: docker that fails `info` (daemon down); pgrep finding 2 sessions;
# sysctl echoing a fixed swapusage line.
cat > "$WORK_DIR/bin/docker" <<'EOF'
#!/bin/bash
[ "$1" = "info" ] && exit 1
exit 0
EOF
cat > "$WORK_DIR/bin/pgrep" <<'EOF'
#!/bin/bash
printf '111\n222\n'
EOF
cat > "$WORK_DIR/bin/sysctl" <<'EOF'
#!/bin/bash
echo "vm.swapusage: total = 2048.00M  used = 100.00M  free = 1948.00M"
EOF
chmod +x "$WORK_DIR/bin/"*

OUT="$WORK_DIR/out.txt"
if PATH="$WORK_DIR/bin:$PATH" bash "$DEV_HEALTH" > "$OUT" 2>&1; then
    echo "ok: exit 0 with docker down"
else
    note_fail "dev-health.sh exited non-zero with docker down"
fi

for section in "== memory ==" "== docker ==" "== claude sessions =="; do
    grep -qF "$section" "$OUT" && echo "ok: section $section" || note_fail "missing section $section"
done
grep -q "docker not running" "$OUT" && echo "ok: docker-down message" || note_fail "missing docker-down message"
grep -q "vm.swapusage" "$OUT" && echo "ok: swapusage line" || note_fail "missing swapusage line"

# Read-only contract: no mutating commands anywhere in the script.
if grep -nE '(docker (rm|stop|kill|restart)|kill |pkill )' "$DEV_HEALTH"; then
    note_fail "dev-health.sh contains a mutating command"
else
    echo "ok: read-only"
fi

[ "$FAILURES" -eq 0 ] || { echo "$FAILURES failure(s)"; exit 1; }
echo "all dev-health tests passed"
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
bash scripts/tests/test-dev-health.sh; echo "exit=$?"
```

Expected: FAIL (script does not exist yet), exit non-zero.

- [ ] **Step 3: Write the script**

Create `scripts/dev-health.sh`:

```bash
#!/bin/bash
# Read-only machine health report for heavy local builds.
#
# Prints the three known build-speed killers on this machine (see
# docs/superpowers/specs/2026-08-11-local-build-speed-design.md): swap
# pressure, Docker containers (leaked mcp containers pattern), and live
# Claude session processes. It only reports — cleanup order and decisions
# stay with the human (sessions -> containers -> Docker restart).
set -uo pipefail

echo "== memory =="
sysctl vm.swapusage 2>/dev/null || echo "sysctl unavailable"

echo "== docker =="
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker ps --format '{{.Names}}	{{.Status}}'
else
    echo "docker not running"
fi

echo "== claude sessions =="
COUNT=$(pgrep -f "claude" 2>/dev/null | wc -l | tr -d ' ')
echo "live claude processes: ${COUNT}"

exit 0
```

Then `chmod +x scripts/dev-health.sh scripts/tests/test-dev-health.sh`.

- [ ] **Step 4: Run the test, verify it passes; run make test-scripts**

```bash
bash scripts/tests/test-dev-health.sh; echo "exit=$?"
make test-scripts > /tmp/test-scripts.log 2>&1; echo "exit=$?"
```

Both exit 0 (`make test-scripts` auto-discovers the new test via its `scripts/tests/test-*.sh` glob).

- [ ] **Step 5: Commit**

```bash
git add scripts/dev-health.sh scripts/tests/test-dev-health.sh
git commit -m "build: add read-only dev-health.sh machine report"
```

---

### Task 4: CLAUDE.md inner-loop guidance

**Files:**
- Modify: `CLAUDE.md` (add a `## Build & Test` section immediately before `## Database & Migrations`)

**Interfaces:**
- Consumes: the Makefile targets from Task 2 (`test-swift FILTER=…`, `lint-diff`) and `scripts/dev-health.sh` from Task 3 — names must match exactly.

- [ ] **Step 1: Add the section**

Insert into `CLAUDE.md`, before the `## Database & Migrations` heading:

```markdown
## Build & Test

**Inner loop (while iterating — this is the default, full runs are NOT):**
- Go: test only the touched package — `go test ./internal/<pkg>` (add `-run TestName` to narrow further). The Go build/test cache makes this seconds; never add `-count=1` reflexively, it defeats the cache.
- Swift: always filter — `make test-swift FILTER=<TestClass>` (or `cd WatchtowerDesktop && swift test --filter <TestClass>`). An unfiltered `swift test` re-links the whole ML stack and belongs to the gate only.
- Lint: `make lint-diff` (issues introduced vs origin/main). Full `make lint` is the gate.

**Gate (before a PR — local-review runs these):** full `make test`, `make test-swift`, `make lint`.

**Cache hygiene:** never delete `WatchtowerDesktop/.build`; a cold rebuild of the ML dependencies costs tens of minutes. Don't alternate `-c debug`/`-c release` builds in one worktree without need. Before a heavy build on a loaded machine, `bash scripts/dev-health.sh` shows the known killers (swap, leaked containers, stale sessions).
```

- [ ] **Step 2: Verify referenced names exist**

```bash
grep -n "test-swift\|lint-diff" Makefile
ls scripts/dev-health.sh
```

Both resolve (Tasks 2 and 3 landed them).

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: inner-loop build/test guidance in CLAUDE.md"
```

---

### Task 5: `swift test --parallel` experiment (gated)

**Files:**
- Modify: `Makefile` (`test-swift` target — ONLY if the gate passes)
- Modify: `docs/superpowers/specs/2026-08-11-local-build-speed-design.md` (append results to the appendix either way)

**Interfaces:**
- Consumes: Task 1's baseline `swift test` (full suite) row; Task 2's `test-swift` target.
- Produces (gate passed): `test-swift` runs `swift test --parallel $(if $(FILTER),--filter $(FILTER),)`.

- [ ] **Step 1: Three consecutive full parallel runs**

Run sequentially (each is long; use `run_in_background`, wait for each before starting the next; never under `timeout`):

```bash
cd WatchtowerDesktop && time swift test --parallel > /tmp/swift-parallel-1.log 2>&1; echo "exit=$?"
cd WatchtowerDesktop && time swift test --parallel > /tmp/swift-parallel-2.log 2>&1; echo "exit=$?"
cd WatchtowerDesktop && time swift test --parallel > /tmp/swift-parallel-3.log 2>&1; echo "exit=$?"
```

Record each wall-clock time and exit code. Clean = exit 0 AND no test failed that passed in the Task 1 baseline run. If a run fails: identify the failing test class from the log, record it in the appendix as the flake candidate, and the gate FAILS — skip Step 2, do NOT touch the Makefile.

- [ ] **Step 2 (gate passed only): Adopt in Makefile**

```make
test-swift:
	cd WatchtowerDesktop && swift test --parallel $(if $(FILTER),--filter $(FILTER),)
```

Verify: `make -n test-swift` prints the `--parallel` form; then one confirming full run `make test-swift > /tmp/make-test-swift-par.log 2>&1; echo "exit=$?"` → exit 0.

- [ ] **Step 3: Append results to the appendix**

Add under `## Appendix: measurements`:

```markdown
### swift test --parallel experiment (2026-08-11)

| Run | Wall clock | Result |
|---|---|---|
| 1 | m:ss | pass/fail |
| 2 | m:ss | pass/fail |
| 3 | m:ss | pass/fail |

Verdict: adopted in `make test-swift` (X% faster than the m:ss serial baseline) /
rejected — flaking class `<Name>`, serialization follow-up candidate.
```

Keep whichever verdict line applies, delete the other, fill real numbers.

- [ ] **Step 4: Commit**

```bash
git add Makefile docs/superpowers/specs/2026-08-11-local-build-speed-design.md
git commit -m "build: adopt swift test --parallel after 3 clean runs"
```

(If the gate failed: `git add` only the spec, message `docs(spec): record swift test --parallel rejection — flaky <Name>`.)

---

### Task 6: Worktree `.build` seeding experiment (gated)

**Files:**
- Create: `scripts/seed-worktree-build.sh` (mode 755 — committed ONLY if the gate passes)
- Test: `scripts/tests/test-seed-worktree-build.sh` (mode 755 — same condition)
- Modify: `docs/superpowers/specs/2026-08-11-local-build-speed-design.md` (append results either way)

**Interfaces:**
- Consumes: Task 1's "cold `swift build`" baseline as the gate denominator.
- Produces (gate passed): `scripts/seed-worktree-build.sh <worktree-root> [--src <build-dir>]` — clones `WatchtowerDesktop/.build` into a worktree that has none.

- [ ] **Step 1: Write the failing test**

Create `scripts/tests/test-seed-worktree-build.sh`:

```bash
#!/bin/bash
# Tests for scripts/seed-worktree-build.sh.
#
# Runs the real script against synthetic source/destination trees in a tmp
# dir, using --src to bypass git discovery — no real repo, no real .build,
# no build. The clonefile copy itself runs for real on a tiny tree (APFS
# /tmp supports cp -c; the script's fallback path covers non-clonefile FS).
#
# Covers:
#   - happy path: source cloned to <dst>/WatchtowerDesktop/.build, exit 0
#   - destination .build already exists (valid, degenerate) → refuses, exit 1,
#     existing content untouched
#   - missing source → clear error, exit 1
#   - missing worktree-root arg → usage error, exit 1
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SEED="$SCRIPT_DIR/../seed-worktree-build.sh"

FAILURES=0
note_fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

bash -n "$SEED" && echo "ok: bash -n" || note_fail "bash -n seed-worktree-build.sh"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

SRC="$WORK_DIR/main/WatchtowerDesktop/.build"
mkdir -p "$SRC/artifacts"
echo "obj" > "$SRC/artifacts/a.o"

DST_ROOT="$WORK_DIR/wt"
mkdir -p "$DST_ROOT/WatchtowerDesktop"

# happy path
if bash "$SEED" "$DST_ROOT" --src "$SRC" > "$WORK_DIR/happy.log" 2>&1 \
   && [ -f "$DST_ROOT/WatchtowerDesktop/.build/artifacts/a.o" ]; then
    echo "ok: happy path"
else
    note_fail "happy path (log: $(cat "$WORK_DIR/happy.log"))"
fi

# destination exists → refuse, keep content
echo "keep" > "$DST_ROOT/WatchtowerDesktop/.build/marker"
if bash "$SEED" "$DST_ROOT" --src "$SRC" > /dev/null 2>&1; then
    note_fail "did not refuse existing destination"
elif [ "$(cat "$DST_ROOT/WatchtowerDesktop/.build/marker")" = "keep" ]; then
    echo "ok: refuses existing destination, content kept"
else
    note_fail "existing destination content was touched"
fi

# missing source
if bash "$SEED" "$DST_ROOT" --src "$WORK_DIR/nope" > /dev/null 2>&1; then
    note_fail "did not fail on missing source"
else
    echo "ok: missing source rejected"
fi

# missing arg
if bash "$SEED" > /dev/null 2>&1; then
    note_fail "did not fail without worktree-root arg"
else
    echo "ok: usage error without args"
fi

[ "$FAILURES" -eq 0 ] || { echo "$FAILURES failure(s)"; exit 1; }
echo "all seed-worktree-build tests passed"
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
bash scripts/tests/test-seed-worktree-build.sh; echo "exit=$?"
```

Expected: FAIL (script missing), exit non-zero.

- [ ] **Step 3: Write the script**

Create `scripts/seed-worktree-build.sh`:

```bash
#!/bin/bash
# Seed a fresh worktree's WatchtowerDesktop/.build from the main checkout
# via APFS clonefile (cp -c) — near-free in disk and time, so a new agent
# worktree skips the tens-of-minutes cold build of the ML dependency stack.
#
# Usage: seed-worktree-build.sh <worktree-root> [--src <build-dir>]
#
# Without --src the source is derived from the worktree's own git metadata
# (the primary checkout owning it). Refuses to overwrite an existing
# destination .build. Falls back to a plain copy on non-APFS filesystems.
set -euo pipefail

usage() { echo "usage: $0 <worktree-root> [--src <build-dir>]" >&2; exit 1; }

[ $# -ge 1 ] || usage
DST_ROOT="$1"; shift
SRC=""
while [ $# -gt 0 ]; do
    case "$1" in
        --src) SRC="${2:?--src needs a value}"; shift 2 ;;
        *) usage ;;
    esac
done

if [ -z "$SRC" ]; then
    COMMON_DIR="$(git -C "$DST_ROOT" rev-parse --path-format=absolute --git-common-dir)"
    MAIN_ROOT="$(dirname "$COMMON_DIR")"
    SRC="$MAIN_ROOT/WatchtowerDesktop/.build"
fi

DST="$DST_ROOT/WatchtowerDesktop/.build"

[ -d "$SRC" ] || { echo "error: source .build not found: $SRC" >&2; exit 1; }
[ -e "$DST" ] && { echo "error: destination already exists, refusing to overwrite: $DST" >&2; exit 1; }
mkdir -p "$(dirname "$DST")"

# cp -c requires same-volume APFS; fall back to a plain copy elsewhere.
if cp -Rc "$SRC" "$DST" 2>/dev/null; then
    echo "seeded (clonefile): $DST"
else
    rm -rf "$DST"
    cp -R "$SRC" "$DST"
    echo "seeded (plain copy): $DST"
fi
```

Then `chmod +x scripts/seed-worktree-build.sh scripts/tests/test-seed-worktree-build.sh`.

- [ ] **Step 4: Run the test, verify it passes**

```bash
bash scripts/tests/test-seed-worktree-build.sh; echo "exit=$?"
```

Expected: exit 0.

- [ ] **Step 5: The measured gate — seed a scratch worktree and build**

```bash
git worktree add /tmp/wt-seed-experiment origin/main
bash scripts/seed-worktree-build.sh /tmp/wt-seed-experiment
cd /tmp/wt-seed-experiment/WatchtowerDesktop && time swift build > /tmp/swift-build-seeded.log 2>&1; echo "exit=$?"
```

Notes: the seed source is the main checkout's `.build` (4.9 GB, debug config). Record seeding time and build time. GATE: seeded build wall clock ≤ 50% of Task 1's cold-build baseline AND exit 0.

Cleanup regardless of outcome:

```bash
git worktree remove --force /tmp/wt-seed-experiment
```

- [ ] **Step 6: Append results to the appendix**

```markdown
### Worktree .build seeding experiment (2026-08-11)

Seed source: main checkout `.build` (debug). Seeding took m:ss.

| Measurement | Wall clock |
|---|---|
| cold `swift build` (baseline, Task 1) | m:ss |
| seeded `swift build` | m:ss |

Verdict: adopted — `scripts/seed-worktree-build.sh` (X% of cold) /
rejected — absolute-path invalidation ate the win (Y% of cold); stable
build-path symlink trick remains the follow-up, script not merged.
```

Keep the applicable verdict, fill real numbers.

- [ ] **Step 7: Commit**

Gate passed:

```bash
git add scripts/seed-worktree-build.sh scripts/tests/test-seed-worktree-build.sh docs/superpowers/specs/2026-08-11-local-build-speed-design.md
git commit -m "build: seed worktree .build via clonefile (measured ≤50% of cold build)"
```

Gate failed: delete the two script files, commit only the spec appendix:

```bash
rm scripts/seed-worktree-build.sh scripts/tests/test-seed-worktree-build.sh
git add docs/superpowers/specs/2026-08-11-local-build-speed-design.md
git commit -m "docs(spec): record .build seeding rejection — path invalidation"
```

---

## Execution notes

- Task order: 1 → 2 → 3 → 4 → (5, 6). Tasks 2–4 are quick and independent of each other; 5 and 6 are long, measurement-bound, and depend on Task 1's baseline. Do not run 5 and 6 concurrently with anything — they need the machine to themselves for honest numbers.
- Subagents must work in THIS worktree (`.claude/worktrees/local-build-speed`) — pass the absolute path in every task brief and require a branch check (`git rev-parse --abbrev-ref HEAD` = `feature/local-build-speed`) before committing (subagents do not inherit the worktree cwd).
- After all tasks: run the local-review skill over the branch before any PR.
