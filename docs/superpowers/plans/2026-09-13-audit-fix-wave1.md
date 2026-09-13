# Audit fix wave 1 — stop the bleeding

**Spec / authority:** `docs/audit/2026-09-13-feature-audit/README.md` (root causes + the sixteen owner decisions; decisions 1, 2, 7, 10 bind this wave) and the domain reports beside it (`runtime-live.md`, `memory.md`, `core-pipelines.md`, `silent-failures.md`).

**Branch:** `fix/audit-wave1` off `origin/main` @ `4cc3bade`. Worktree `.claude/worktrees/audit-wave1`.

**Goal:** the pipelines that are losing data on the owner's live install right now stop losing it. Nothing in this wave changes product shape; every task is a root-cause fix with a regression test, plus the operator tooling needed to recover the live memory vault.

## Global constraints

- Everything committed to the repo is in English (code, comments, tests, docs, commit messages).
- One commit per task, message in the house shape `fix(<area>): <what>` with a body naming the audit finding id (C1, C2, C4, H7, H8, H11) and the owner decision number.
- Inner loop only: `go test ./internal/<pkg>` (add `-run` to narrow), `make test-swift FILTER=<Class>`. Never unfiltered `swift test`, never `-count=1`, never delete `WatchtowerDesktop/.build`.
- **Never run the `watchtower` binary against the owner's live workspace** (`~/.local/share/watchtower/whitebit`) and never open its SQLite database. Tests use their own temp DBs / temp vaults.
- Behaviour-inventory contracts (`docs/inventory/*.md`) are load-bearing. This wave touches areas covered by MEM-01..16, INBOX-09, TRACKS-*, FEAT-03. A change must not weaken a guard test (`Test<Module>NN_*`); if a task seems to require it, stop and report `BLOCKED`.
- Slack ids: internally everything is namespaced `"<accountID>:<rawID>"` (`slack.Namespace` / `slack.SplitAccountID` in `internal/slack/namespace.go`). Model output and raw message text carry the bare form. Every fix that compares the two must accept both forms and must have a test for both.
- Do not add config keys unless a task says so. Timeouts and caps in this wave are package constants with a doc comment.
- `CLAUDE.md` feature notes are updated only where a task says so; do not rewrite unrelated sections.

## Task 1 — Channel digests: accept the model's bare channel id (C1, decision 2)

**Files:** `internal/digest/pipeline.go` (`persistBatchResults` ~L931, the batch prompt assembly ~L1541–1588), `internal/digest/prompt.go` (`channelBatchDigestPrompt` example ~L70), `internal/digest/pipeline_test.go` or a new `internal/digest/batch_persist_test.go`.

**Problem:** `persistBatchResults` builds `entryMap` keyed by the namespaced `batch[i].channelID` (`"1:C…"`), while the model echoes the bare `C…` from the prompt example → every result logs `digest: batch result for unknown channel …, skipping` and `0 saved`. Live since migration 00048 landed (2026-08-03).

**Fix:**
1. In `persistBatchResults`, resolve `r.ChannelID` against the batch by BOTH forms: exact namespaced match first, then the raw form (`slack.SplitAccountID(entry.channelID)` → compare `rawID`). Build the map once with both keys (namespaced and raw) pointing at the same entry; a raw id that is ambiguous across two accounts in the same batch (two entries with the same raw id, different account prefixes) must NOT be matched — log it as ambiguous and skip, exactly once.
2. In the prompt's channel block header (`--- #%s (%s) ---`) and the JSON example, tell the model to echo the id exactly as given in the block header. Keep the example id in the bare form (`C123ABC`) — the header is the source of truth, the example is illustrative. Do not bump the DB prompt version for this (the example is only in the compiled fallback); if the same text also lives in `internal/prompts/defaults.go` as a DB-seeded prompt, apply the identical wording there and bump that prompt's version by one.
3. Tests: (a) a batch of two namespaced entries, results echo bare ids → both saved; (b) results echo namespaced ids → both saved; (c) two entries `1:C1` and `2:C1`, result `C1` → neither saved, one ambiguity log line, no panic; (d) unknown id → skipped as before. Use the existing test harness for the digest pipeline (look at how `persistBatchResults` is exercised today; if it isn't, test it directly with an in-memory DB from `internal/db` test helpers).

**Operator step (document in the commit body and the PR notes, do NOT execute):** after deploying, the owner runs `watchtower features enable slack-digests` — `features.FastForward("slack-digests")` stamps the digest fast-forward floor to now (FEAT-03), which is decision 2's "fast-forward, no backfill". Verify by reading `cmd/features.go` that the hook runs even when the key is already true; if it does not, add a `--fast-forward` flag or make the hook unconditional and say so in the report.

## Task 2 — Memory seeder: idempotency over all aliases, index before commit (C2, decision 1)

**Files:** `internal/memory/seed.go` (`SeedEntities` ~L67–140), `internal/memory/index.go` (`upsertIndexNode`), `internal/memory/seed_test.go` (+ new cases), possibly `internal/db/memory.go` (alias lookup helpers).

**Problem:** `SeedEntities` checks idempotency only via `LookupMemoryAlias(c.aliases[0])`. After 00048, `aliases[0]` for a person is the namespaced `1:U…`; the legacy page carries bare `U…` plus the e-mail. Lookup misses → a new node is minted → `v.WriteNodes` COMMITS it to git → `upsertIndexNode` fails on the e-mail alias `UNIQUE` → `SeedEntities` returns error → `Run` aborts before steps 3–7. Next cycle `Reconcile` quarantines the orphan file and the loop repeats. Live: 800k `UNIQUE constraint failed: memory_aliases` log lines, 46k duplicate entity files, watermark frozen at 2026-08-01.

**Fix (both halves are mandatory):**
1. **Idempotency over every alias, with stitching.** For each candidate, look up EVERY alias (case-insensitive, matching the `COLLATE NOCASE` grammar). If any alias resolves to an existing node: do not create; instead, if the existing node lacks any of the candidate's aliases, append the missing aliases to that node (frontmatter `aliases`) and include it in this run's write set as an update — this is how a legacy bare `U…` page acquires its `1:U…` alias. If aliases resolve to TWO different existing nodes, do not touch either; log once (`memory: seed: candidate %q spans nodes %s and %s, skipping`) and continue — a merge is the semantic tier's job, not the seeder's.
2. **Index before commit.** Reorder so the SQLite index write happens inside one transaction BEFORE `v.WriteNodes` commits to git; if the git write fails, roll the transaction back. If a transactional helper does not exist for `upsertIndexNode`, add one (`database.WithTx` or the house equivalent — check `internal/db` for the existing transaction pattern). The invariant to state in a comment: *a node is never in git history without being in the index for the same run; a failed run leaves neither.* If the vault layer cannot be made transactional against SQLite in one step, the acceptable fallback is: validate every alias of every new node against the index FIRST (so a UNIQUE collision is impossible by construction), then write git, then index — and say in the report which shape you chose and why.
3. **Regression tests (Go, temp vault + temp DB):**
   - (a) A person seeded with bare alias `U123` + `a@x.test`; second run offers the same person as `1:U123` + `a@x.test` → no new node, the existing node gains alias `1:U123`, `SeedEntities` returns 0 created, `Run` does not error, one vault commit at most (the alias update).
   - (b) Two existing nodes hold `U123` and `a@x.test` separately; candidate offers both → neither modified, no new node, no error, one log line.
   - (c) Simulate an index failure after git write is impossible by construction → assert via (a)/(b) that `SeedEntities` never returns a `UNIQUE constraint` error for any alias arrangement (table-driven over the alias forms).
   - Keep the existing `seed_test.go` cases green.

**Do not** touch `MEM-*` guard tests. `docs/inventory/memory.md` gains a one-paragraph 2026-09-13 changelog entry under the existing changelog section describing the seeder's stitching behaviour (no new contract number).

## Task 3 — Vault recovery + Slack-id backfill tooling (decision 1)

**Files:** `cmd/memory.go` (two new subcommands), `internal/memory/recover.go` (new), `internal/memory/slackids.go` (new), tests for both, `docs/inventory/memory.md` changelog line, `CLAUDE.md` Memory section CLI list.

**Why tooling, not a hand procedure:** the live vault has ~44 600 duplicate entity files committed since 2026-08-03 and a 553 MB `.git`; the owner decided to reset history to the last good commit (`memory(map)` on 2026-08-01) and reseed with the Task 2 seeder. That must be repeatable and dry-runnable, never a hand-typed `git reset` on the owner's data.

**Subcommand A — `watchtower memory reset-to <commit> [--dry-run]`:**
1. Refuses to run while the daemon holds `memory.lock` (reuse the existing flock helper; print the pid and exit non-zero).
2. Validates `<commit>` exists in the vault repo and is an ancestor of HEAD.
3. `--dry-run` prints: current HEAD, target commit, number of commits to be discarded, number of files that disappear, and stops.
4. Otherwise: hard-reset the vault working tree + HEAD to the commit (go-git, the same library the vault already uses); `DropMemoryIndex` + full reindex (reuse `watchtower memory reindex`'s code path, do not duplicate it); then fast-forward the memory extraction watermarks via `features.FastForward("memory", …)` so consolidation resumes from now (FEAT-03; the six-week backlog is not re-extracted — decision 2's shape applied to memory, recorded as a controller ruling in the plan ledger).
5. Prints a summary and exits 0. Any failure after the reset leaves a clear message that the index must be rebuilt (`watchtower memory reindex`).

**Subcommand B — `watchtower memory migrate-slack-ids [--dry-run]`:**
1. Walks every vault node; for each alias matching a bare Slack id (`^[UWCGD][A-Z0-9]{8,}$`, the same character class `slack.MentionPatterns` accepts) that is NOT already namespaced, rewrites it to `slack.Namespace(accountID, raw)` where `accountID` is the single connected Slack account's id; with two or more `slack_accounts` rows (including removed/disabled) the command refuses and says why — cross-account attribution is not guessable.
2. Also rewrites bare Slack ids inside `## Provenance` refs of the `""`-scheme (message refs `channel_id/ts`), since `memory_provenance` is rebuilt from those lines on reindex.
3. One vault commit `memory(migrate): slack ids → namespaced (N nodes)` with `Cause: "migrate"`, then reindex. `--dry-run` prints the counts per node type and a sample of 10 rewrites.
4. Idempotent: a second run finds nothing to do and makes no commit.

**Tests:** temp vault + temp DB for both. Reset: dry-run makes no change; real run leaves HEAD at the target and the index equal to a fresh reindex (the existing MEM-02 reindex-equivalence guard shape — read it, reuse its comparison, do not weaken it). Migrate: bare→namespaced on aliases and provenance, idempotent second run, refusal with two accounts.

**Operator runbook** (append to `docs/audit/2026-09-13-feature-audit/README.md` under a new "Wave 1 operator steps" heading; the controller will run these with the owner, not the implementer): stop the daemon → `watchtower memory reset-to <sha of memory(map) 2026-08-01> --dry-run` → real → `watchtower memory migrate-slack-ids --dry-run` → real → start the daemon → `watchtower features enable slack-digests`.

## Task 4 — Slack search sync: window from the watermark, cap separately (C4, decision 7)

**Files:** `internal/sync/search_sync.go` (`syncViaSearch` ~L35–75, watermark advance ~L199–207), `internal/sync/search_sync_test.go`, `internal/config/defaults.go` (doc comment on `DefaultInitialHistDays` only).

**Problem:** `initial_history_days` is applied as a permanent floor: `searchAfter = max(search_last_date − 2d, now − initial_history_days)`, so a daemon that was down longer than that window (owner's value: 7 days) silently skips the gap and then stamps the watermark to today.

**Fix:**
1. `initial_history_days` applies only when `search_last_date` is empty (true first run).
2. Otherwise `searchAfter = search_last_date − 2d` (keep the indexing-delay overlap).
3. New package constant `maxSearchCatchUpDays = 30` with a doc comment (Slack search's practical depth; not a config key). If `now − searchAfter` exceeds it: clamp `searchAfter` to `now − maxSearchCatchUpDays`, log at warning level `search sync: gap of N days exceeds the %d-day catch-up cap; messages between %s and %s were not fetched`, and record the same sentence on the account row's `error` column via the existing `slack_accounts` setter (status stays as it is — this is a data gap, not an auth failure; read `SetSlackAccountAuthState`'s contract and use the narrowest setter that writes only `error`; add one if none exists).
4. The watermark advance stays as is (today, only when every page completed).
5. Tests: table-driven over (`lastDate` empty | 1 day ago | 10 days ago | 45 days ago) asserting `searchAfter`, the clamp, the log line, and the `error` column write only in the 45-day case. Extract the window computation into a pure function (`searchWindow(now, lastDate, initialDays) (after string, gapDays int, clamped bool)`) so the test needs no Slack client.

## Task 5 — Daemon bounds: archived items out of the reactions sync; AI call timeout (H7, H8, decision 10)

**Files:** `internal/db/inbox.go` (`GetInboxItems`/`InboxFilter` ~L165), `internal/sync/orchestrator.go` (`syncInboxReactions` ~L364), a new `internal/digest/timeout_generator.go` (or the equivalent spot in `cmd/sync.go` wiring), tests in `internal/db`, `internal/sync`, `internal/digest`.

**Part A — archived pending items.** `GetInboxItems{Status:"pending"}` returns 2 522 archived-but-pending rows on the live install; the reactions sync then issues one `reactions.get` per unique message every cycle (~2 000 calls, ~52 of each ~70-minute cycle).
1. `InboxFilter` gains `IncludeArchived bool` (default false). `GetInboxItems` adds `archived_at IS NULL` unless it is set. Audit the five callers (`internal/inbox/pipeline.go:254`, `:857`, `internal/meeting/pipeline.go:259`, `internal/sync/orchestrator.go:364`, `cmd/inbox.go:148`): none of them wants archived rows by default; `cmd/inbox.go` gets an `--include-archived` flag mirroring the filter so the CLI can still list them.
2. Test in `internal/db`: two pending rows, one archived → default filter returns one; `IncludeArchived` returns two.

**Part B — AI subprocess wall-clock timeout.** No daemon AI call has a deadline; a hung `claude`/`codex` freezes the whole sequential cycle while holding `sync.lock`.
1. Add a decorator over the generator interface the daemon pipelines consume (find the interface — `digest.AIGenerator` or equivalent — and how `cmd/sync.go` wires the generator into pipelines): `WithCallTimeout(gen, d time.Duration)` wraps `Generate` (and any sibling streaming/tool method the interface has) in `context.WithTimeout(ctx, d)`; on `context.DeadlineExceeded` it returns an error whose text names the timeout (`ai call exceeded %s`). Package constant `DaemonAICallTimeout = 10 * time.Minute` with a doc comment. Wire it ONLY on the daemon path (`cmd/sync.go`), never on the interactive chat client (`internal/ai/client.go`) — interactive calls are bounded by the user.
2. Test: a fake generator that blocks until ctx is done → the decorator returns within the (short, test-sized) timeout with the named error; a fast fake passes through unchanged including usage.

## Task 6 — Desktop `DaemonManager.restart()`: never leave the system without a daemon (H11, decision 10)

**Files:** `WatchtowerDesktop/Sources/WatchtowerCore/Services/DaemonManager.swift` (`restart()` ~L180, `stopDaemonBounded`, `isDaemonRunning`), `WatchtowerDesktop/Sources/Services/FeatureManagerService.swift` (~L240, the "applied" report), the other `restart()` callers only if the signature change forces it, `Tests/Core/DaemonManager*Tests.swift`.

**Problem:** `restart()` runs `sync stop` then `sync --daemon --detach`. When `sync stop` returns non-zero because the daemon did not exit within its 10 s SIGTERM grace (normal while an AI call is in flight), `--detach` is refused with "already running", the old daemon then dies anyway, and there is no daemon until the app relaunches. `FeatureManagerService.apply` reports the toggle as applied regardless. Main already logs both failures (`d49f7ce0`); it still does not wait, retry, or tell the UI.

**Fix:**
1. `restart()` returns a result (`Result<Void, DaemonRestartError>` or throws — match the house style used by `stopDaemon`'s `errorMessage` path) instead of `Void`.
2. After `sync stop` returns non-zero, poll `isDaemonRunning()` (pid liveness) up to a bounded `restartStopGrace` (60 s, constant with doc comment) in 250 ms steps; proceed to `--detach` as soon as the pid is dead. If it is still alive at the deadline, return a `.stopTimedOut(pid)` error without attempting `--detach` (a second daemon must never be started next to a live one).
3. If `--detach` exits non-zero, return `.startFailed(status, stderr)` using the existing `startFailureMessage`.
4. `FeatureManagerService.apply` (and any other caller that reports success to the user — grep for `await DaemonManager.restart()`) surfaces the error string in its existing error channel instead of reporting success; callers that fire-and-forget may keep ignoring the result but must not swallow it silently — at minimum `NSLog` (most already do).
5. Tests (`Tests/Core`, no ML link): the pure pieces — extract the "wait for pid death with deadline" loop into a testable function taking an `isAlive: () -> Bool` closure and a clock/step, and test: dies at step 3 → proceeds; never dies → `.stopTimedOut`. Keep the process-spawning parts untested (house precedent).

## Not in this wave (recorded so nobody "helpfully" adds them)

Per-channel digest watermark, tracks all-failed error, ideas floors/prefs/empty rows, Catch-Up reap, feed recap NOT NULL, Gmail transient-loss, `jira.features.*`, key detector wiring, strong-tier cost knobs, reaction-commands FastForward seed, recap prompt bump, calendar cleanup guard, `TargetBriefCenter` queue, Inbox shape, no-Slack identity. They are waves 2–5 and the parked items in the audit README.
