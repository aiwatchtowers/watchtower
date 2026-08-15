# Slack mention markup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Restore @mention detection, which has produced nothing since migration 00048: three call sites build Slack mention markup (`<@U123>`) out of a namespaced id (`1:U123`), and that string cannot occur in `messages.text`.

**Architecture:** No schema change, no data migration. Three call sites reduce the id to its raw form before it is embedded in mention markup, using the existing `slack.SplitAccountID`. This is the same boundary rule the previous branch established and documented in CLAUDE.md — ids are namespaced inside the system, raw at the boundary with surfaces that carry raw ids (Slack message text, model-authored text).

**Tech Stack:** Go 1.25, modernc.org/sqlite.

## Background (verified on a live database, not assumed)

`messages.text` stores what Slack sent: `<@U0118BRJH54>`, and no migration rewrites it — it is source data. Migration 00048 namespaced `slack_accounts.current_user_id` to `1:U0118BRJH54`, and every site that builds mention markup from that id now searches for `<@1:U0118BRJH54>`, which cannot exist.

Live evidence: 1020 messages contain the owner's real mention markup, 61 of them in the last week; **0** match the pattern the code searches for. The `mention` inbox trigger's last item is 2026-07-30; migration 00048 applied 2026-08-03; every other trigger type (dm, stream, thread_reply, email) is still producing items daily. Nothing logs an error — a miss is indistinguishable from "nobody mentioned you".

The three sites:

| # | Site | What breaks |
|---|------|-------------|
| 1 | `internal/db/inbox.go:435-436` `FindPendingMentions` | **P0** — no Slack @mention has created an inbox item since 00048 |
| 2 | `internal/db/channel_stats.go:44` `GetChannelStats` | per-channel `mention_count` is always 0 |
| 3 | `internal/tracks/pipeline.go:1457` `scoreChannel` | TRACKS-02's +2 mention signal never fires |

Site 3 has a second, independent cause: no digest topic contains `<@` markup at all (0 of 7334 rows), because the model does not reproduce it. Fixing the id shape there is correct but will not on its own revive the signal — say so in the code comment rather than implying a behaviour change.

## Global Constraints

- Everything committed (code, comments, commit messages) is in English. Comments state the constraint, never the history of the bug.
- Read the "Swift / Desktop conventions" and Go sections of `docs/review/review-rules.md` before writing code. `docs/inventory/inbox-pulse.md` (INBOX-01..09) and `docs/inventory/tracks.md` (TRACKS-02) cover the affected modules — read both and treat each entry as load-bearing.
- **Do not weaken or re-key a guard test.** TRACKS-02's guard is `TestScoreChannel`; INBOX guards live in `internal/db/inbox_test.go` and `internal/inbox/`. If a fix requires changing what a guard asserts, stop and report it.
- In `FindPendingMentions` the same function needs **both** forms: the raw id for the text patterns, the namespaced id for `m.user_id != ?` (a scalar column comparison). Do not collapse them into one.
- No schema change, no migration, no change to what is stored.
- Verify from the worktree root `/Users/user/PhpstormProjects/watchtower/.claude/worktrees/slack-mention-markup`, always redirecting output to a file and checking the exit code explicitly (never pipe through `tail`/`head`): `go build ./...`, `go vet ./...`, `go test ./internal/db/ ./internal/inbox/ ./internal/tracks/`, and `gofmt -l .` (expect empty).
- Commit per task; verify `git branch --show-current` prints `fix/slack-mention-markup` before each commit. End messages with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: A single seam for mention markup

**Files:**
- Modify: `internal/slack/namespace.go`
- Modify: `internal/slack/namespace_test.go`

**Interfaces:**
- Produces: `func MentionPatterns(userID string) (strict, pipe string)` — returns the two SQL LIKE patterns (`%<@U123>%` and `%<@U123|%`) for a user id in either form, and `func MentionTag(userID string) string` returning `<@U123>`. Tasks 2 and 3 consume these.

Rationale for a helper rather than three inline `SplitAccountID` calls: the two LIKE patterns encode a documented invariant (the closing `>` / `|` boundary that stops `U_ME` matching `U_MEOW` — see the comment above `FindPendingMentions` and its test at `internal/db/inbox_test.go:308`), and that invariant is currently duplicated across sites. One seam, one place to get the boundary right.

- [ ] **Step 1: Write the failing test** in `internal/slack/namespace_test.go`, table-driven, matching the file's existing style:

```go
func TestMentionPatterns(t *testing.T) {
	tests := []struct {
		name           string
		userID         string
		wantStrict     string
		wantPipe       string
	}{
		{"namespaced id reduces to raw", "1:U123", "%<@U123>%", "%<@U123|%"},
		{"bare id passes through", "U123", "%<@U123>%", "%<@U123|%"},
		{"multi-digit account prefix", "12:U123", "%<@U123>%", "%<@U123|%"},
		{"empty id", "", "%<@>%", "%<@|%"},
	}
	// assert both returned patterns per case
}

func TestMentionTag(t *testing.T) {
	// "1:U123" -> "<@U123>"; "U123" -> "<@U123>"
}
```

- [ ] **Step 2: Run it, expect FAIL** (undefined): `go test ./internal/slack/ -run 'TestMention' > /tmp/gt1.log 2>&1; echo "exit=$?"`.
- [ ] **Step 3: Implement both functions** in `internal/slack/namespace.go`, next to `RawIDsJSON`. Each reduces the id via `SplitAccountID` and then builds the string. Doc comment states the constraint: Slack message text carries raw ids, so an id read from the database must be reduced before it is embedded in markup.
- [ ] **Step 4: Run again, expect PASS.**
- [ ] **Step 5: Commit.** `feat(slack): one seam for building mention markup from a stored id`

---

### Task 2: Fix the two database call sites

**Files:**
- Modify: `internal/db/inbox.go` (`FindPendingMentions`, lines ~434-440)
- Modify: `internal/db/channel_stats.go` (`GetChannelStats`, line ~44)
- Modify: `internal/db/inbox_test.go`, `internal/db/channel_stats_test.go`

**Interfaces:**
- Consumes: `slack.MentionPatterns` / `slack.MentionTag` from Task 1.

- [ ] **Step 1: Write the failing tests first.**
  - In `internal/db/inbox_test.go`, alongside the existing boundary test: seed a message whose text is `"hey <@U_ME> look"` written by another user, and call `FindPendingMentions("1:U_ME", 0)` — i.e. the id in the shape `GetCurrentUserID` actually returns post-00048. Expect one candidate. Also assert the existing boundary invariant still holds with a namespaced id: a message mentioning `<@U_MEOW>` must NOT match `FindPendingMentions("1:U_ME", ...)`.
  - Add the own-message case: a message containing `<@U_ME>` authored by `1:U_ME` itself must not be returned (this is the `m.user_id != ?` half, which must stay namespaced — the test fails if someone "simplifies" both parameters to the raw form).
  - In `internal/db/channel_stats_test.go`: a channel with a message mentioning `<@U1>` and `GetChannelStats("1:U1")` reports `MentionCount` 1 (check the field's real name in `ChannelStatRow`).
- [ ] **Step 2: Run them, expect FAIL** with a zero count / no candidate: `go test ./internal/db/ -run 'Mention|ChannelStats' > /tmp/gt2.log 2>&1; echo "exit=$?"`. Confirm the failure is the missing match, not a compile error, before implementing.
- [ ] **Step 3: Implement.** `FindPendingMentions` builds its two LIKE patterns via `slack.MentionPatterns(currentUserID)` while keeping `currentUserID` itself for the `m.user_id != ?` bind. `GetChannelStats` builds `mentionPattern` via the same helper (it needs only the strict form). Check for an import cycle first — `internal/slack` must not import `internal/db`; if it does, stop and report rather than working around it.
- [ ] **Step 4: Run the package** — `go test ./internal/db/ > /tmp/gt3.log 2>&1; echo "exit=$?"`.
- [ ] **Step 5: Commit.** `fix(db): match Slack mention markup against the raw user id`

---

### Task 3: Fix the tracks signal, honestly

**Files:**
- Modify: `internal/tracks/pipeline.go` (`scoreChannel`, line ~1457)
- Modify: `internal/tracks/pipeline_test.go`

- [ ] **Step 1: Write the failing test.** In `TestScoreChannel`, add a sub-test (do NOT alter the existing "user mention = 2" or "multiple signals additive" cases — they are TRACKS-02's guard and were deliberately restored to their main form): topic `KeyMessages` containing raw `"<@U1> please review"`, probed with the namespaced userID `"1:U1"` → expect 2. Run it, expect FAIL (score 0).
- [ ] **Step 2: Implement** — `mentionTag := watchtowerslack.MentionTag(userID)`. Comment states the constraint and, in one clause, that topic text is model-authored and today contains no mention markup at all, so this keeps the signal correct rather than making it fire.
- [ ] **Step 3: Run** `go test ./internal/tracks/ > /tmp/gt4.log 2>&1; echo "exit=$?"` — the pre-existing guard sub-tests must still pass untouched.
- [ ] **Step 4: Commit.** `fix(tracks): build the mention tag from the raw user id`

---

### Task 4: Docs + full gate

**Files:**
- Modify: `docs/inventory/inbox-pulse.md` — add a dated note under the existing changelog/notes convention recording that mention detection was inert between 00048 and this fix. Do NOT create a new INBOX-NN contract; extend the existing narrative only (see the inventory maintenance rule in `CLAUDE.md`).
- Modify: `CLAUDE.md` — the Slack Multi-Account bullet already carries the boundary rule from the previous branch; extend that same clause to name Slack message text as the other raw surface, next to model-authored text. One clause, no new section.

- [ ] **Step 1: Write the doc edits.**
- [ ] **Step 2: Full gate.** `gofmt -l .` (expect empty), `go vet ./...`, `go build ./...`, `go test ./...`, each redirected with the exit code checked. Swift is untouched.
- [ ] **Step 3: Commit.** `docs: record the mention-markup boundary in the inbox notes`

## Self-review notes

- **Correction (final branch review, before merge): the "complete set" claim above was false.** `grep -rn '"<@"' --include="*.go" internal/` only matches `<@` inside a Go *double*-quoted string literal, so it is structurally blind to two other shapes the same bug takes: a Swift file (`--include="*.go"` excludes every `.swift` file outright) and a SQL string built with single-quoted concatenation inside a Go backtick literal, e.g. `'%<@' || u2.id || '>%'` — the quotes touching `<@` there are single, not double. Both blind spots hid real sites. The real sweep is `<@` across both `*.go` and `*.swift`, including SQL string concatenation, read manually rather than grepped for one quoting style. Sites now covered, across both directions of the mismatch:
  - Builds `<@...>` markup from a stored (possibly namespaced) id: `internal/db/inbox.go` `FindPendingMentions`, `internal/db/channel_stats.go` `GetChannelStats`, `internal/tracks/pipeline.go` `scoreChannel` (this plan's three sites); `WatchtowerDesktop/Sources/Database/Queries/ChannelStatsQueries.swift` `ChannelStatsQueries.fetchAll` (the Swift twin of `GetChannelStats`, live via Desktop's Mute/Favorite recommendations, fixed with a new `SlackAccountID.raw` helper in `WatchtowerCore`); `internal/db/user_analyses.go` `ComputeUserInteractions` (`mentToRows` and `mentFromRows`, both dormant — no production caller — reduced via SQL `substr`/`instr` and `slack.SplitAccountID` respectively).
  - The inverse — resolves a raw id parsed *out of* markup, rather than building markup from a stored id, and was hiding the same root mismatch behind a different symptom (silently dropping the mention instead of never matching it): `internal/inbox/pipeline.go` `enrichSnippet`, which looked up a raw id parsed from `<@U123>` via `UserNameByID` (an exact match against the namespaced `users.id`) and returned `""` on a failed lookup; fixed with a new `db.UserNameByRawID` sibling and by keeping `"@" + rawID` instead of dropping the mention.
- Each task's test is written to fail against today's code for the right reason, which is the only thing that distinguishes a real pin from a fixture that agrees with itself — the failure mode this whole class of bug was hiding behind.
