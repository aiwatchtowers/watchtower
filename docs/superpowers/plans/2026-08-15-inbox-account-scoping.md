# Inbox Slack detectors — per-account scoping

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Run the four Slack inbox detectors once per connected Slack account, each with that account's own identity and scoped to that account's messages — closing three defects at once: cross-account duplicates, the owner's own outgoing messages in a second account being read as incoming, and every trigger except mentions being blind to accounts other than #1.

**Architecture:** `Pipeline.Run` currently resolves ONE `currentUserID` (pinned to account #1 by a documented v1 decision) and calls `detectSlackTriggers` once. It becomes a loop over `ListEnabledSlackAccounts()`, each iteration passing that account's `current_user_id` and its account id; the four `db.Find*` queries gain an account predicate. No schema change, no new table.

**Tech Stack:** Go 1.25, modernc.org/sqlite.

## Background (verified in code and on a live database)

Since migration 00048 every scalar Slack id is namespaced `"<accountID>:<rawID>"`, and `messages.channel_id`/`user_id` carry the prefix. But the inbox detectors still take a single `currentUserID` from `resolveCurrentUserID` → `db.GetCurrentUserID()`, which reads **account #1 only**. What each detector does with it today:

| Detector | Predicate | Consequence with ≥2 accounts |
|---|---|---|
| `FindPendingMentions` (`internal/db/inbox.go:440`) | `m.text LIKE '%<@U_ME>%'` — raw markup, account-blind by construction | One mention in a channel synced by both accounts mints **two** items (dedup is `(channel_id, message_ts)` and the copies carry different namespaced channel ids). A raw-id collision across orgs mints a false one. |
| `FindPendingDMs` (`:473`) | `c.type = 'dm'` + `m.user_id != '1:U_ME'` | Returns DMs from **every** account, while excluding only account #1's own id — so the owner's **own outgoing DMs in account #2** look like incoming messages. |
| `FindThreadRepliesToUser` (`:507`) | `participant.user_id = '1:U_ME'` | Account #2 threads never detected. |
| `FindReactionRequests` (`:548`) | `m.user_id = '1:U_ME'` | Reactions to account #2 messages never detected. |

So the exposure is not symmetrical: mentions over-fire, the other three under-fire, and DMs additionally mis-attribute the owner's own messages. All four are silent — a miss is indistinguishable from "nothing happened".

The dedup guard (`NOT EXISTS … ii.channel_id = m.channel_id AND ii.message_ts = m.ts`) is per (channel, ts) and therefore already correct once each account's messages are scoped: the same real conversation stored twice under two accounts is genuinely two rows with two channel ids, and after scoping only the account that owns the channel will consider it.

## Global Constraints

- Everything committed (code, comments, commit messages) is in English. Comments state the constraint, never the history of the bug.
- `docs/inventory/inbox-pulse.md` INBOX-01..09 are load-bearing — read the file before touching the pipeline. **INBOX-09 (watermark) is the one this work can most easily break:** the watermark is per-workspace, not per-account, and this plan does NOT change that. A detector error in ANY account must still freeze the watermark exactly as it does today. Do not weaken, rename or re-key a guard test; if a fix seems to require it, stop and report.
- The other documented v1 decision stands: `db.GetCurrentUserID()` stays pinned to account #1 for everything else (Jira detection, style sample, people cards, `cmd/profile.go`). Only the inbox Slack detectors become per-account. Do not "fix" the other call sites.
- No schema change, no migration, no change to what is stored.
- Verify from the worktree root `/Users/user/PhpstormProjects/watchtower/.claude/worktrees/inbox-account-scoping`, always redirecting to a log file and checking the exit code explicitly (never pipe through `tail`/`head`): `go build ./...`, `go vet ./...`, `gofmt -l .` (expect empty), `go test ./internal/db/ ./internal/inbox/`.
- Commit per task; verify `git branch --show-current` prints `fix/inbox-account-scoping` before each commit. End messages with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Scope the four detector queries to an account

**Files:**
- Modify: `internal/db/inbox.go` (`FindPendingMentions`, `FindPendingDMs`, `FindThreadRepliesToUser`, `FindReactionRequests`)
- Modify: `internal/db/inbox_test.go`

**Interfaces:**
- Produces: each of the four gains an `accountID int64` first parameter — `FindPendingMentions(accountID int64, currentUserID string, sinceTS float64)` and the same shape for the other three. Task 2 calls them per account.

The scoping predicate is on the message's channel: `m.channel_id LIKE ? || ':%'` bound with the account id. Prefer that over deriving the account from `m.user_id`, because a channel belongs to exactly one account while a message's author may be any member — and because `channel_id` is the column the dedup guard already keys on.

- [ ] **Step 1: Write the failing tests** in `internal/db/inbox_test.go`. Seed two accounts' worth of rows and assert per detector:
  - mentions: the same raw markup `<@U_ME>` in `1:C1` and in `2:C1`, called for account 1 → exactly one candidate, from `1:C1`;
  - DMs: a DM in `2:CDM` authored by `2:U_ME` (the owner's own id in the second account) → not returned for account 1 **and** not returned for account 2 (own message);
  - thread replies and reactions: a qualifying row under account 2 → returned when called for account 2, not when called for account 1.
  Keep the existing tests passing by updating their call sites with account 1 — do not change what they assert.
- [ ] **Step 2: Run them, expect FAIL** for the reason claimed (extra/missing candidate, not a compile error once you have added the parameter): `go test ./internal/db/ -run 'Mention|DM|Thread|Reaction' > /tmp/gt1.log 2>&1; echo "exit=$?"`.
- [ ] **Step 3: Implement.** Add the parameter and the predicate to all four. In `FindPendingDMs` the own-message exclusion must use the account's OWN `current_user_id` — that is what Task 2 passes; here just make sure the parameter is used for the exclusion and the new predicate scopes the channel.
- [ ] **Step 4: Green, then the package** — `go test ./internal/db/ > /tmp/gt2.log 2>&1; echo "exit=$?"`.
- [ ] **Step 5: Commit.** `feat(db): scope the Slack inbox detectors to an account`

---

### Task 2: Loop the pipeline over enabled accounts

**Files:**
- Modify: `internal/inbox/pipeline.go` (`Run`, `RunFastDetection`, `detectSlackTriggers`, `resolveCurrentUserID`)
- Modify: `internal/inbox/*_test.go` as needed

**Interfaces:**
- Consumes: Task 1's four signatures.

- [ ] **Step 1: Read `Run` and `RunFastDetection` end to end first**, and note every place `currentUserID` is used after detection — own-message suppression, triage, compose. Only the **Slack detection** part becomes per-account in this task; report anything else that looks account-sensitive rather than changing it.
- [ ] **Step 2: Write the failing test** in `internal/inbox/`: with two enabled accounts, a mention of account 1's user in an account-1 channel and a mention of account 2's user in an account-2 channel both produce an item in one `Run`. Today only the first does.
- [ ] **Step 3: Implement the loop.** `detectSlackTriggers` takes the account (id + its `current_user_id`) and the caller iterates `db.ListEnabledSlackAccounts()`. Zero accounts is a clean no-op, exactly as today's empty-`currentUserID` early return. Sum the created counts across accounts.
- [ ] **Step 4: INBOX-09 fidelity.** One account's detector error must produce the same watermark outcome as today's single-account error: the watermark freezes. Do not let a per-account error be swallowed into a partial success — join the errors and return them the way `Run` already does for its other sources. Add or extend a test that pins this: account 2's detector failing means the watermark does not advance even though account 1 succeeded.
- [ ] **Step 5: Run** `go test ./internal/inbox/ ./internal/db/ > /tmp/gt3.log 2>&1; echo "exit=$?"`.
- [ ] **Step 6: Commit.** `feat(inbox): detect Slack triggers once per connected account`

---

### Task 3: Docs + full gate

**Files:**
- Modify: `docs/inventory/inbox-pulse.md`
- Modify: `CLAUDE.md` (the Slack Multi-Account section's inbox note)

- [ ] **Step 1: Correct the inventory.** The file now says mention detection is account-blind and that `FindPendingDMs` shares that shape — true before this change, false after. Rewrite that passage to describe per-account detection, and add a dated changelog entry in the file's existing convention. **No new INBOX-NN contract** — extend the narrative only.
- [ ] **Step 2: CLAUDE.md.** The Slack Multi-Account section says inbox items "reference `messages.channel_id` directly, so namespacing is inherited for free" and that own-message suppression is a direct string compare against `db.ListOwnerSlackUserIDs()`. Update it to say detection now runs per enabled account. Keep the surrounding v1-decision bullet intact — `GetCurrentUserID` staying account-#1-pinned elsewhere is still true.
- [ ] **Step 3: Full gate.** `gofmt -l .`, `go vet ./...`, `go build ./...`, `go test ./...`, each redirected with the exit code checked. Swift is untouched.
- [ ] **Step 4: Commit.** `docs: record per-account Slack inbox detection`

## Self-review notes

- The four detectors are the complete Slack set in `internal/db/inbox.go` — verified by listing every `func (db *DB) Find*` in that file. Gmail/IMAP/Jira/calendar detectors are separate and already per-account where it matters.
- The watermark stays per-workspace on purpose: making it per-account is a bigger change (INBOX-09 is written in terms of one watermark) and nothing in the observed defects requires it.
