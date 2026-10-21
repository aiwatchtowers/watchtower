# A waiting automation run survives a daemon restart

**Date:** 2026-10-21 · **Board:** #795 (group #794, under #405) · **Owner decision:** ask #463 ("Да, чинить в движке")

## Problem

A run that waits on the owner — an `ask()`, a write tool's approval (`{wait}`)
or a `session()` — holds its state only in the daemon's memory: a goja
goroutine blocked in `executorWaiter.Wait`. Any daemon restart (an update, the
Desktop restarting the daemon after a connection change, a crash) ends it:

- on stop, `idle` returns a cancel interrupt and the run ends `failed`/`interrupted`;
- on start, `MarkInterruptedAutomationRuns` ends every `running`/`waiting` run
  the same way, and `sweepAsks` withdraws the run's open asks.

Seen on the live install on 2026-10-21: `todo-refill` run #28 finished its
estimation session, filed ask #462 ("Добрать TO DO до недели") and was killed
six minutes later by a daemon restart; the ask vanished from the owner's stack.
`release` lost two runs the same way. A run that waits for hours on a human is
exactly the run most likely to meet a restart, so today a wait is only as
durable as the daemon process.

## Goal

A run that is **waiting** when the daemon stops is not ended. After the next
start it resumes at the same wait — the same ask stays open, the same action
or session is awaited — and continues once the wait is satisfied, as if the
restart had not happened.

Non-goals: a run that is **running** (inside an SDK call or between calls) at
the stop still ends `failed`/`interrupted`, unchanged — we cannot know whether
its in-flight call had its effect. Dry runs are unchanged.

## Approach: deterministic replay from a recorded log

goja cannot serialise a paused VM, so the run resumes by **re-executing the
script from the start** while answering every SDK call that had already
completed from a record of its result, without executing it again and without
writing a new journal step. When the replay reaches the call the run was
waiting in, that call re-enters its wait on the already-created ask / action /
session instead of creating a new one. From there on the run is live.

### 1. The replay log

New table (migration, mirrored in `schema.sql`):

```
automation_run_replay(
  run_id      INTEGER NOT NULL REFERENCES automation_runs(id) ON DELETE CASCADE,
  seq         INTEGER NOT NULL,          -- the journal step's seq
  kind, name  TEXT    NOT NULL,          -- as the step
  args_hash   TEXT    NOT NULL,          -- sha256 of the canonical args JSON
  result_json TEXT,                      -- the full result the script received (not clipped)
  error_json  TEXT,                      -- the thrown error (name, message) when the call threw
  clock_json  TEXT    NOT NULL,          -- Date.now() values the script read since the previous call
  PRIMARY KEY (run_id, seq))
```

- Written by the journal when a step closes, in the same write as the step's
  finish, for live (non-dry) runs only. A step's `result_summary` stays clipped
  as today (AUTO-11 unchanged); only this table holds the full value.
- Size: each `result_json` is capped at 1 MiB; a step whose result is larger
  marks the run **not resumable** (a flag on the run), and that run behaves as
  today on restart.
- Deleted when the run reaches a terminal status (same transaction as the
  finish), so the table holds only the live runs' logs.

### 2. Determinism

The script must make the same calls with the same arguments on replay:

- **Time.** The sandbox's `Date.now()` / `new Date()` read the run's clock
  through one hook. Live, each read is appended to the pending step's
  `clock_json`; on replay, reads return the recorded values in order. Once the
  replay passes the last record, the hook reads the real clock again.
- **`Math.random`** is seeded per run (seed stored on the run row) instead of
  goja's default source.
- **Inputs** the script receives (`trigger`, event payloads) are already
  stored on the run row.

### 3. Divergence check

Each replayed call compares its `kind`, `name` and `args_hash` with the record
at its seq. Any mismatch — or a call past the recorded log that is not the
waiting call — ends the run `failed` with error kind `script` and the message
"the recipe ran differently after the restart (step N); it was not resumed".
Nothing was executed, so nothing is duplicated. The run's open asks are
withdrawn then, as today.

The replay executes the run's own `recipe_snapshot` (taken at claim), so an
edit of the recipe file meanwhile does not change what replays. A run is still
not resumed (ended `interrupted`, as today) when its automation's
`confirmed_hash` is no longer the run's `recipe_hash` (the owner re-confirmed
other permissions, or the recipe is unconfirmed), the automation is disabled or
deleted, or the run is flagged not resumable.

### 4. Lifecycle

- **Stop.** While a run is waiting, a stop (ctx done) returns a new
  `errDaemonStopping` from `Wait` instead of a cancel interrupt. The executor
  sees it, does **not** finish the run, and leaves it `waiting` with its open
  ask/action/session untouched. A running run is interrupted as today.
- **Start.** `MarkInterruptedAutomationRuns` spares `waiting` runs that are
  resumable (their last journal step is the open `waiting` step and the replay
  log covers every earlier step) and sets their new `resume_pending` column to 1
  (status stays `waiting`, so the status CHECK needs no table recreation);
  everything else is ended as today. `sweepAsks` skips asks of those runs.
- **Claim.** `Step` claims a `resume_pending` run like a queued one (same
  `MaxConcurrent` slot rules, oldest first, before queued runs). Replay runs on
  a running slot; when it reaches the wait the run goes back to `waiting` and
  frees the slot, as a live wait does.
- **Budget.** The meter starts from the run's recorded token totals and active
  time; replayed calls spend nothing. `pause_timeout_hours` counts from the
  waiting step's `started_at`, so time spent while the daemon was down counts.
- **Abandon/heap/step caps** apply to the replay as to any run.

### 5. What the owner sees

Nothing new in the normal case: the ask stays in the stack, the card shows the
run waiting, the history shows one run. A log line
`automations: run N resumed after restart (replayed K steps)` goes to the
daemon log. The run's journal is the original steps, then the new ones.

## Contracts

- **AUTO-08 amended (needs owner approval):** "on start the executor ends every
  `running`/`waiting` run `failed`/`interrupted`" becomes "…every `running`
  run, and every `waiting` run that cannot be resumed (§3); a resumable waiting
  run continues at its wait. Every run still reaches exactly one terminal
  status." The guard that pins the sweep of waiting runs is extended with the
  resumable case, not relaxed; the non-resumable cases keep their assertions.
- **AUTO-11 unchanged:** a replayed call writes no step, so each call the
  script made has exactly one step across both daemon lives.
- **AUTO-04 unchanged:** outputs and state stay buffered until the run commits;
  the buffer is rebuilt by the replay itself (the replayed `state.set` /
  `output.*` calls re-buffer, they do not commit).

New guards: resume after a restart at an ask / an approval wait / a session
wait; divergence ends the run without executing anything; a changed recipe is
not resumed; a large result marks the run not resumable; time and `Math.random`
replay; the replay log is gone after the finish; a resumed run's tokens are not
double-counted.

## Size and risk

Go only (no Desktop change: the Desktop already shows `waiting` runs and their
asks). One migration, the replay hook in `Env.Call`, the clock hook, executor
start/claim changes, tests. The main risk is a non-deterministic builtin we
missed; the divergence check turns that into a clean failure, never a
duplicated write.

## Alternatives considered

- **Re-run from scratch on restart.** Repeats every effect before the wait
  (a second estimation session, a second ask). Rejected.
- **Don't restart the daemon while runs wait.** Covers only planned restarts
  from the Desktop; updates and crashes still kill runs. Could be added later
  as a courtesy, not as the fix.
- **Checkpoint the script (`state` + re-entry by label).** Moves the burden to
  every recipe author. Rejected: the owner asked for the engine to handle it.
