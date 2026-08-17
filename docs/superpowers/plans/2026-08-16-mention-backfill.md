# Mention backfill — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Recover the Slack @mentions that were never turned into inbox items while mention detection was broken, without re-processing everything else that happened in that window.

**Architecture:** A one-shot `Pipeline.BackfillMentions(ctx, since)` that runs **only** the mention detector, per connected account, against an explicit timestamp instead of the watermark — creating items and leaving `inbox_last_processed_ts` untouched. No AI call. A `watchtower inbox backfill-mentions --since <date>` CLI wrapper with `--dry-run`.

**Tech Stack:** Go 1.25, modernc.org/sqlite.

## Why this shape (facts established before writing this plan)

- **The watermark cannot simply be rewound.** It is shared by every detector and by triage, so rewinding it re-processes two weeks of DMs, thread replies and ordinary channel traffic — an AI bill and a flood — to recover a few hundred mentions.
- **The dedup guard makes re-runs safe.** All four detectors carry `NOT EXISTS (… ii.channel_id = m.channel_id AND ii.message_ts = m.ts)`, so a mention that already produced an item is never duplicated, however many times the backfill runs.
- **Backfilled items do not need triage to be useful.** `inbox_items.item_class` defaults to `'actionable'` (`internal/db/schema.sql:488`), and triage's only power over a trigger item is to *downgrade* it to ambient (INBOX-01). So an untriaged backfilled mention lands in the conservative class — the right bias for something the owner explicitly asked to recover.
- **The composer picks them up on its own.** `ListUncomposedSignals` (`internal/db/situations.go:238-240`) selects on `status='pending' AND composed_at IS NULL`, **not** on a watermark, so the next daemon cycle folds these items into situations with no further help. That is what keeps this command AI-free.
- **They will not be instantly archived.** `ArchiveExpiredAmbient` and `ArchiveStaleActionable` (`internal/db/inbox.go:815,829`) key off the item's `created_at`/`updated_at`, not the message timestamp, so a freshly created item for an old message starts its clock now.
- **Detection is per-account since PR #110**, so the backfill must loop accounts exactly as `detectSlackAccounts` does, using each account's own `current_user_id`.

## Global Constraints

- Everything committed (code, comments, commit messages) is in English. Comments state the constraint, never the history of the bug.
- `docs/inventory/inbox-pulse.md` INBOX-01..09 are load-bearing — read the file first. **INBOX-09 is the contract this feature must not touch:** the backfill reads an explicit `since` and MUST NOT read, advance, or reset `inbox_last_processed_ts`. A test pins that. Do not weaken, rename or re-key any guard test.
- No schema change, no migration, **no AI call** — this command must never invoke a model.
- Follow `cmd/ideas.go`'s backfill command for CLI shape (flag naming, JSON envelope on stdout, error handling). Read it before writing the command.
- Verify from the worktree root `/Users/user/PhpstormProjects/watchtower/.claude/worktrees/mention-backfill`, always redirecting to a log file and checking the exit code explicitly (never pipe through `tail`/`head`): `go build ./...`, `go vet ./...`, `gofmt -l .` (expect empty), `go test ./internal/inbox/ ./internal/db/ ./cmd/`.
- Commit per task; verify `git branch --show-current` prints `feat/mention-backfill` before each commit. End messages with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: `Pipeline.BackfillMentions`

**Files:**
- Modify: `internal/inbox/pipeline.go` (or a new `internal/inbox/backfill.go` if that reads better — decide by looking at the file's size and how `detectSlackAccounts` is laid out, and say which you chose)
- Modify/create: the matching `_test.go`

**Interfaces:**
- Produces: `func (p *Pipeline) BackfillMentions(ctx context.Context, since time.Time, dryRun bool) (BackfillMentionsResult, error)` where the result carries, at minimum, per-account and total counts of candidates found and items created, plus the accounts skipped for having no identity. Task 2 renders it.

- [ ] **Step 1: Write the failing tests.** Cover:
  - two enabled accounts, each with a mention older than the watermark → both produce items, and `inbox_last_processed_ts` is **byte-identical** before and after (read it, run, read it again — this is the INBOX-09 pin);
  - running it twice creates nothing the second time (the dedup guard);
  - `dryRun` reports the same counts but creates **zero** rows;
  - an account with an empty `current_user_id` is skipped, not an error (mirroring `detectSlackAccounts`), and does not abort the other account;
  - a mention **newer** than `since` is included and one older is not — i.e. `since` really drives the window, not the watermark.
- [ ] **Step 2: Run them, expect FAIL** (undefined, then wrong counts): `go test ./internal/inbox/ -run Backfill > /tmp/gt1.log 2>&1; echo "exit=$?"`.
- [ ] **Step 3: Implement.** Loop `ListEnabledSlackAccounts()`; for each, call `FindPendingMentions(accountID, acct.CurrentUserID, float64(since.Unix()))` and create an item per candidate exactly the way `detectSlackTriggers` does — reuse its creation path rather than writing a second one; if that path is not reusable as-is, say so in your report rather than duplicating it silently. Join per-account errors like `detectSlackAccounts` does. Never read or write the watermark. In dry-run, do everything except the insert.
- [ ] **Step 4: Green, then the packages** — `go test ./internal/inbox/ ./internal/db/ > /tmp/gt2.log 2>&1; echo "exit=$?"`.
- [ ] **Step 5: Commit.** `feat(inbox): one-shot mention backfill against an explicit timestamp`

---

### Task 2: The CLI command, docs and the gate

**Files:**
- Modify: `cmd/inbox.go`
- Modify: `docs/inventory/inbox-pulse.md`, `docs/app-guide.md`, `CLAUDE.md` (only where each already describes the inbox detectors or the CLI surface — check each before editing)

- [ ] **Step 1: Add the command.** `watchtower inbox backfill-mentions --since <YYYY-MM-DD> [--dry-run]`. `--since` is **required** — no default, so nobody can accidentally sweep all history. Print a one-line JSON envelope on stdout in the shape `cmd/ideas.go`'s backfill uses (read it and match: field naming, error field, exit-code convention). Include per-account counts, the total created, and the accounts skipped, so a dry run is readable on its own.
- [ ] **Step 2: A test in `cmd/`** following the package's existing command-test style: `--since` missing is an error; a valid run prints an envelope whose created-count matches what was inserted; `--dry-run` inserts nothing.
- [ ] **Step 3: Docs.** In `docs/inventory/inbox-pulse.md`, add a dated changelog entry in the file's existing convention recording the command and — this is the load-bearing part — that it deliberately does **not** move the watermark, so INBOX-09 is untouched. No new INBOX-NN. In `docs/app-guide.md` and `CLAUDE.md`, add the command to whatever list already enumerates inbox CLI commands; if neither has such a list, say so and skip rather than inventing a section.
- [ ] **Step 4: Full gate.** `gofmt -l .`, `go vet ./...`, `go build ./...`, `go test ./...`, each redirected with the exit code checked. Swift is untouched.
- [ ] **Step 5: Commit.** `feat(cli): watchtower inbox backfill-mentions`

## Self-review notes

- The command is deliberately mention-only. Thread replies and reactions were also blind for accounts 2+ before PR #110, but those are *new* detections rather than a recovery of something the owner watched break, and sweeping them would widen the flood this design exists to avoid. If the owner wants them too, the same function generalises — do not build that speculatively.
- No AI call means the recovery costs nothing beyond the composer's normal next-cycle work, which is capped by `MaxComposeSignals`.
