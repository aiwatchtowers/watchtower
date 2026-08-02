# Inbox Master-Detail (Catch-Up-style Dashboard) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rework the Dashboard feed tab into a Catch-Up-style master-detail screen (compact situation list left, rich review pane right) and add comment feedback (learning interpreter via CLI) plus source links (Slack per member signal, Target/Track navigation rows).

**Architecture:** Swift-only UI rework of `DashboardView` into `HSplitView` + new `SituationRow`/`SituationReviewPane`; selection and member-signal cache move into the AppState-owned `DashboardViewModel`. Go gains `Pipeline.SubmitSituationFeedback` (mirrors `internal/catchup/learn.go`) exposed as `watchtower inbox feedback`, invoked from Swift only when a comment is present.

**Tech Stack:** Go 1.25 (cobra, modernc.org/sqlite), SwiftUI macOS 14+ / GRDB, XCTest, Go testing + testify.

**Spec:** `docs/superpowers/specs/2026-07-07-inbox-master-detail-design.md`

## Global Constraints

- Branch: `feature/secretary-dashboard`. All GitHub-facing text (commits, PR) in English.
- DASH-01/02/03 and INBOX-01..09 guard tests must stay green and **unmodified** (`docs/inventory/dashboard.md`, `docs/inventory/inbox-pulse.md`). Never weaken/rename a `Test<Module>NN_` test.
- Every AI call goes through `digest.Generator` and must work on BOTH providers (claude + codex) — never shell out to a CLI directly from Go pipelines (`.claude/skills/add-ai-prompt`).
- No schema changes anywhere in this plan. `inbox_feedback.reason` is a CHECK enum — free text never goes there. `feedback.entity_type` CHECK does not include situations — do not write to the `feedback` table.
- Verification commands: never pipe through `tail`/`head` — redirect to a log file and check `$?` explicitly. Swift: `cd WatchtowerDesktop && swift build 2>&1 > /tmp/build.log; echo $?`.
- Swift test schema lives in `WatchtowerDesktop/Tests/Helpers/TestDatabase.swift` — when a test needs a column, verify it exists there (known drift trap vs `internal/db/schema.sql`).

---

### Task 1: Go — `SubmitSituationFeedback` with learning interpreter

**Files:**
- Create: `internal/inbox/situation_feedback.go`
- Test: `internal/inbox/situation_feedback_test.go`

**Interfaces:**
- Consumes: `p.db.GetSituation(id int) (db.DashboardSituation, error)`, `p.db.ListSituationSignals(situationID int) ([]db.InboxItem, error)`, `p.db.UpsertLearnedRule(db.InboxLearnedRule) error`, `p.generator digest.Generator`, `prompts.ExtractJSONObject(raw string) (string, error)` (`internal/prompts/json.go`).
- Produces: `func (p *Pipeline) SubmitSituationFeedback(ctx context.Context, situationID int, rating int, comment string) error` — Task 2's CLI calls exactly this.

Behavior contract (mirror of `internal/catchup/learn.go` + the Swift fast path `SituationQueries.recordFeedback`):
- Unknown situation id → error, nothing written, no AI call.
- Comment empty/whitespace: **never** call the generator. Rating +1 → no-op. Rating -1 → upsert `source_mute` rule (`weight -1.0`, `source 'user_rule'`, scope `channel:<id>`) per DISTINCT member-signal channel — byte-identical outcome to the Swift direct write, keeping the dual paths consistent.
- Comment present: one generator call tagged `inbox.situation_learn` (not in the light-model list in `internal/digest/models.go` → routes to the default strong tier, same as `catchup.learn`; do NOT touch models.go), parse JSON, upsert each valid rule with `Source: "user_rule"` (spec choice: typed user comments are protected from implicit overwrite, unlike catchup's `explicit_feedback`). Skip (log) rules whose `rule_type` is not `source_mute`/`source_boost` or whose `scope_key` is empty.

- [ ] **Step 1: Write the failing tests**

Create `internal/inbox/situation_feedback_test.go`. Reuses package helpers: `newTestDB` (`watchtower_detector_test.go`), `seedInboxItem` (`learner_test.go`), `testConfig` (`pipeline_test.go`).

```go
package inbox

import (
	"context"
	"log"
	"testing"

	"watchtower/internal/db"
	"watchtower/internal/digest"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// countingGen is a digest.Generator that records how many times it was
// invoked, so tests can prove the interpreter is (not) called.
type countingGen struct {
	response string
	calls    int
}

func (g *countingGen) Generate(context.Context, string, string, string) (string, *digest.Usage, string, error) {
	g.calls++
	return g.response, &digest.Usage{}, "", nil
}

// seedSituationWithSignal creates one open situation linked to one inbox item
// from the given sender/channel and returns the situation id.
func seedSituationWithSignal(t *testing.T, d *db.DB, senderID, channelID string) int {
	t.Helper()
	itemID := seedInboxItem(t, d, senderID, channelID, "mention")
	sitID, err := d.CreateSituation(db.DashboardSituation{
		Title: "test situation", Kind: "external", Status: "open",
		Priority: "medium", CardStatus: "none",
	})
	require.NoError(t, err)
	require.NoError(t, d.AddSituationSignals(int(sitID), []int{int(itemID)}))
	return int(sitID)
}

func newFeedbackPipeline(t *testing.T) (*db.DB, *Pipeline, *countingGen) {
	t.Helper()
	d := newTestDB(t)
	gen := &countingGen{}
	return d, New(d, testConfig(), gen, log.Default()), gen
}

func TestDash04_CommentlessFeedbackNeverInvokesInterpreter(t *testing.T) {
	// BEHAVIOR DASH-04 — see docs/inventory/dashboard.md
	// A bare 👎 (no comment) mutes the member-signal channels locally and MUST
	// NOT invoke the AI learning interpreter. Do not weaken or remove without
	// explicit owner approval.
	d, p, gen := newFeedbackPipeline(t)
	sitID := seedSituationWithSignal(t, d, "U1", "C1")

	require.NoError(t, p.SubmitSituationFeedback(context.Background(), sitID, -1, "   "))

	assert.Equal(t, 0, gen.calls, "comment-less feedback must not call the generator")
	r, err := d.GetLearnedRule("source_mute", "channel:C1")
	require.NoError(t, err)
	assert.Equal(t, -1.0, r.Weight)
	assert.Equal(t, "user_rule", r.Source)
}

func TestSituationFeedback_RatingOnlyUpIsNoOp(t *testing.T) {
	d, p, gen := newFeedbackPipeline(t)
	sitID := seedSituationWithSignal(t, d, "U1", "C1")

	require.NoError(t, p.SubmitSituationFeedback(context.Background(), sitID, 1, ""))

	assert.Equal(t, 0, gen.calls)
	_, err := d.GetLearnedRule("source_mute", "channel:C1")
	assert.Error(t, err, "👍 without comment must not create rules")
}

func TestSituationFeedback_CommentDerivesUserRules(t *testing.T) {
	d, p, gen := newFeedbackPipeline(t)
	sitID := seedSituationWithSignal(t, d, "U2", "C2")
	gen.response = `{"rules": [{"rule_type": "source_boost", "scope_key": "sender:U2", "weight": 0.8, "reason": "always show Jane"}]}`

	require.NoError(t, p.SubmitSituationFeedback(context.Background(), sitID, 1, "always show me anything from Jane"))

	assert.Equal(t, 1, gen.calls)
	r, err := d.GetLearnedRule("source_boost", "sender:U2")
	require.NoError(t, err)
	assert.Equal(t, 0.8, r.Weight)
	assert.Equal(t, "user_rule", r.Source)
}

func TestSituationFeedback_MalformedRuleSkippedValidApplied(t *testing.T) {
	d, p, gen := newFeedbackPipeline(t)
	sitID := seedSituationWithSignal(t, d, "U3", "C3")
	gen.response = `{"rules": [
		{"rule_type": "made_up_type", "scope_key": "sender:U3", "weight": -1.0, "reason": "bad"},
		{"rule_type": "source_mute", "scope_key": "", "weight": -1.0, "reason": "bad"},
		{"rule_type": "source_mute", "scope_key": "channel:C3", "weight": -0.9, "reason": "noise"}
	]}`

	require.NoError(t, p.SubmitSituationFeedback(context.Background(), sitID, -1, "this channel is noise"))

	r, err := d.GetLearnedRule("source_mute", "channel:C3")
	require.NoError(t, err)
	assert.Equal(t, -0.9, r.Weight)
	_, err = d.GetLearnedRule("made_up_type", "sender:U3")
	assert.Error(t, err, "invalid rule_type must be skipped")
}

func TestSituationFeedback_UnknownSituationErrors(t *testing.T) {
	d, p, gen := newFeedbackPipeline(t)
	_ = d

	err := p.SubmitSituationFeedback(context.Background(), 9999, -1, "whatever")

	assert.Error(t, err)
	assert.Equal(t, 0, gen.calls, "validation must happen before any AI call")
}
```

Note for the implementer: `seedInboxItem`'s exact parameter order is `(t, database, senderUserID, channelID, triggerType)` — check `learner_test.go:13` before assuming. If `CreateSituation` requires more non-zero fields than shown, copy the minimal set from `internal/db/situations_test.go`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/inbox/ -run 'TestSituationFeedback|TestDash04' > /tmp/go-t1.log 2>&1; echo "exit=$?"; cat /tmp/go-t1.log`
Expected: FAIL — `p.SubmitSituationFeedback undefined`, `countingGen` compiles but package fails to build.

- [ ] **Step 3: Implement `internal/inbox/situation_feedback.go`**

```go
package inbox

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// situationLearnSystemPrompt drives the learning interpreter for dashboard
// situations: given a situation the operator reviewed plus their free-text
// comment and rating, derive targeted inbox learned-rules. Kept as a
// package-private const (same as catchup's learnSystemPrompt) — not
// user-editable, so it does not go through the prompts store.
const situationLearnSystemPrompt = `You are the learning interpreter for a chief-of-staff work dashboard.

The operator just reviewed ONE situation (a cluster of related Slack signals and work updates prepared by their AI secretary) and left a rating (+1 like / -1 dislike) and a free-text comment.

Your job is to turn the comment into durable, targeted learned-rules so the inbox pipeline surfaces things better next time. Be conservative: only derive a rule when the comment expresses a clear, generalizable preference (e.g. "this channel is noise", "always show me anything from Jane"). Vague approval/disapproval with no actionable signal yields no rules.

For each rule produce:
- rule_type: "source_mute" (suppress/down-rank) or "source_boost" (surface/up-rank).
- scope_key: build it ONLY from the channel_id / sender_user_id supplied with the member signals below — never invent ids. Use a BARE key, exactly "sender:<sender_user_id>" or "channel:<channel_id>". If no usable id is supplied for a target, emit no rule for it rather than guessing.
- weight: a float in [-1.0, 1.0]; negative mutes, positive boosts; magnitude = confidence.
- reason: one short sentence grounding the rule in the comment.

Respond with ONLY a JSON object, no markdown fences:
{"rules": [{"rule_type": "source_mute", "scope_key": "channel:Cxxx", "weight": -1.0, "reason": "..."}]}`

// situationLearnResult is the interpreter's output shape.
type situationLearnResult struct {
	Rules []situationLearnRule `json:"rules"`
}

type situationLearnRule struct {
	RuleType string  `json:"rule_type"`
	ScopeKey string  `json:"scope_key"`
	Weight   float64 `json:"weight"`
	Reason   string  `json:"reason"`
}

func parseSituationLearn(raw string) (situationLearnResult, error) {
	var out situationLearnResult
	s, err := prompts.ExtractJSONObject(raw)
	if err != nil {
		return out, fmt.Errorf("parsing situation learn output: %w", err)
	}
	if err := json.Unmarshal([]byte(s), &out); err != nil {
		return out, fmt.Errorf("parsing situation learn output: %w", err)
	}
	return out, nil
}

// SubmitSituationFeedback records 👍/👎 for a dashboard situation. Without a
// comment it mirrors the Desktop fast path (Swift SituationQueries.recordFeedback):
// rating -1 upserts a source_mute user_rule per distinct member-signal channel,
// rating +1 is a no-op, and no AI call is ever made (DASH-04). With a comment
// it runs the learning interpreter and persists the derived rules as
// source='user_rule' (protected from implicit overwrite, INBOX-05).
func (p *Pipeline) SubmitSituationFeedback(ctx context.Context, situationID int, rating int, comment string) error {
	situation, err := p.db.GetSituation(situationID)
	if err != nil {
		return fmt.Errorf("situation %d: %w", situationID, err)
	}
	signals, err := p.db.ListSituationSignals(situationID)
	if err != nil {
		return fmt.Errorf("situation %d signals: %w", situationID, err)
	}

	if strings.TrimSpace(comment) == "" {
		if rating >= 0 {
			return nil
		}
		seen := map[string]bool{}
		for _, sig := range signals {
			if sig.ChannelID == "" || seen[sig.ChannelID] {
				continue
			}
			seen[sig.ChannelID] = true
			if err := p.db.UpsertLearnedRule(db.InboxLearnedRule{
				RuleType:      "source_mute",
				ScopeKey:      "channel:" + sig.ChannelID,
				Weight:        -1.0,
				Source:        "user_rule",
				EvidenceCount: 1,
			}); err != nil {
				return fmt.Errorf("persisting mute rule for channel %s: %w", sig.ChannelID, err)
			}
		}
		return nil
	}

	user := buildSituationLearnUserMessage(situation, signals, rating, comment)
	raw, _, _, err := p.generator.Generate(
		digest.WithSource(ctx, "inbox.situation_learn"), situationLearnSystemPrompt, user, "")
	if err != nil {
		return fmt.Errorf("situation learn: %w", err)
	}
	parsed, err := parseSituationLearn(raw)
	if err != nil {
		return err
	}
	for _, lr := range parsed.Rules {
		if (lr.RuleType != "source_mute" && lr.RuleType != "source_boost") || lr.ScopeKey == "" {
			p.logger.Printf("inbox: skipping malformed learned rule %+v from situation %d", lr, situationID)
			continue
		}
		if err := p.db.UpsertLearnedRule(db.InboxLearnedRule{
			RuleType:      lr.RuleType,
			ScopeKey:      lr.ScopeKey,
			Weight:        lr.Weight,
			Source:        "user_rule",
			EvidenceCount: 1,
		}); err != nil {
			return fmt.Errorf("persisting learned rule %s: %w", lr.ScopeKey, err)
		}
	}
	return nil
}

// buildSituationLearnUserMessage renders the situation plus its member
// signals' real Slack ids (so the interpreter can build scope keys the inbox
// pipeline actually matches on) and the operator's rating/comment.
func buildSituationLearnUserMessage(s db.DashboardSituation, signals []db.InboxItem, rating int, comment string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "SITUATION: %s\n", s.Title)
	if strings.TrimSpace(s.Summary) != "" {
		fmt.Fprintf(&b, "SUMMARY: %s\n", strings.Join(strings.Fields(s.Summary), " "))
	}
	fmt.Fprintf(&b, "PRIORITY: %s\n", s.Priority)
	b.WriteString("MEMBER SIGNALS (use the supplied ids to build scope keys):\n")
	if len(signals) == 0 {
		b.WriteString("(none)\n")
	}
	for _, sig := range signals {
		b.WriteString("-")
		if sig.ChannelID != "" {
			b.WriteString(" channel_id=" + sig.ChannelID)
		}
		if sig.SenderUserID != "" {
			b.WriteString(" sender_user_id=" + sig.SenderUserID)
		}
		fmt.Fprintf(&b, " snippet=%s\n", strings.Join(strings.Fields(sig.Snippet), " "))
	}
	verdict := "dislike"
	if rating > 0 {
		verdict = "like"
	}
	fmt.Fprintf(&b, "\nOPERATOR RATING: %s\n", verdict)
	fmt.Fprintf(&b, "OPERATOR COMMENT: %s\n", strings.TrimSpace(comment))
	return b.String()
}
```

Implementer notes: the Pipeline's generator field is `generator digest.Generator` and its logger `logger *log.Logger` (`pipeline.go:129`). `UpsertLearnedRule` without a `Pipeline` field matches `feedback.go`'s existing usage (defaults to `'inbox'`). If `prompts.ExtractJSONObject` has a different signature than `(string) (string, error)`, check `internal/prompts/json.go:12` and adapt.

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/inbox/ > /tmp/go-t1b.log 2>&1; echo "exit=$?"; cat /tmp/go-t1b.log`
Expected: exit=0, all inbox tests (including existing INBOX-NN/DASH-NN guards) PASS.

- [ ] **Step 5: Vet + commit**

```bash
go vet ./... && gofmt -l internal/inbox/
git add internal/inbox/situation_feedback.go internal/inbox/situation_feedback_test.go
git commit -m "feat(inbox): situation feedback with comment-driven learning interpreter"
```

---

### Task 2: Go — `watchtower inbox feedback` CLI subcommand

**Files:**
- Modify: `cmd/inbox.go` (command vars + `init()` at line ~80 + new `runInboxFeedback`)

**Interfaces:**
- Consumes: `Pipeline.SubmitSituationFeedback(ctx, situationID, rating, comment)` (Task 1), `parseRating(string) (int, error)` (already in `cmd/catchup.go`, same package), `cliPooledGenerator(cfg, logger)`, `applyProviderOverride(cfg)`, `inbox.New(...)`.
- Produces: CLI `watchtower inbox feedback <situation-id> --rating up|down [--comment "…"]` — Task 4's Swift code invokes exactly these args.

- [ ] **Step 1: Add the command**

In `cmd/inbox.go`, add alongside the existing command vars:

```go
var (
	inboxFeedbackRating  string
	inboxFeedbackComment string
)

var inboxFeedbackCmd = &cobra.Command{
	Use:   "feedback <situation-id>",
	Short: "Record feedback on a dashboard situation (--rating up|down [--comment])",
	Args:  cobra.ExactArgs(1),
	RunE:  runInboxFeedback,
}
```

In `init()` extend the existing `AddCommand` call:

```go
inboxCmd.AddCommand(inboxShowCmd, inboxResolveCmd, inboxDismissCmd, inboxSnoozeCmd, inboxGenerateCmd, inboxTaskCmd, inboxFeedbackCmd)
```

and register the flags next to the other flag registrations:

```go
inboxFeedbackCmd.Flags().StringVar(&inboxFeedbackRating, "rating", "", "up or down")
inboxFeedbackCmd.Flags().StringVar(&inboxFeedbackComment, "comment", "", "free-text comment; derives learned rules via the AI interpreter")
```

Add the runner (shape mirrors `catchupPipeline` in `cmd/catchup.go:77` — no pre-sync; feedback does not need fresh messages):

```go
func runInboxFeedback(cmd *cobra.Command, args []string) error {
	situationID, err := strconv.Atoi(args[0])
	if err != nil || situationID <= 0 {
		return fmt.Errorf("invalid situation id %q", args[0])
	}
	rating, err := parseRating(inboxFeedbackRating)
	if err != nil {
		return err
	}

	cfg, err := config.Load(flagConfig)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	applyProviderOverride(cfg)
	if err := cfg.ValidateWorkspace(); err != nil {
		return fmt.Errorf("invalid config: %w", err)
	}

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	logger := log.New(cmd.ErrOrStderr(), "[inbox] ", log.LstdFlags)
	gen, closeGen := cliPooledGenerator(cfg, logger)
	defer closeGen()

	pipe := inbox.New(database, cfg, gen, logger)
	if err := pipe.SubmitSituationFeedback(cmd.Context(), situationID, rating, inboxFeedbackComment); err != nil {
		return err
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Recorded feedback on situation %d.\n", situationID)
	return nil
}
```

Implementer notes: `strconv` may need adding to the import block. `parseRating` lives in `cmd/catchup.go` and maps `up`→1 / `down`→-1 — verify its exact name/behavior there before use; do not duplicate it.

- [ ] **Step 2: Build + run cmd tests**

Run: `go build ./... && go test ./cmd/ > /tmp/go-t2.log 2>&1; echo "exit=$?"; cat /tmp/go-t2.log`
Expected: exit=0.

- [ ] **Step 3: Smoke-check help output**

Run: `go run . inbox feedback --help`
Expected: usage shows `feedback <situation-id>` with `--rating` and `--comment` flags.

- [ ] **Step 4: Commit**

```bash
git add cmd/inbox.go
git commit -m "feat(cli): inbox feedback subcommand for situation ratings and comments"
```

---

### Task 3: Swift VM — selection state, member-signal cache, post-action successor

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/DashboardViewModel.swift`
- Test: `WatchtowerDesktop/Tests/DashboardViewModelTests.swift`

**Interfaces:**
- Produces (Task 5's views bind to these):
  - `var selectedSituationID: Int?`
  - `var selectedSituation: Situation? { get }`
  - `func select(_ situationID: Int?)` — sets selection and lazily loads member signals into the cache.
  - `func memberSignals(for situationID: Int) -> [InboxItem]` and `func memberSignalsLoaded(_ situationID: Int) -> Bool`
  - Existing `done(_:)`/`dismiss(_:)`/`snooze(_:until:)`/`markConverted(...)` now also advance selection.

- [ ] **Step 1: Write the failing tests**

Append to `DashboardViewModelTests.swift` (patterns identical to the existing tests in this file; `TestDatabase.insertSituation` returns `Int64`):

```swift
    // MARK: - selection (master-detail)

    func testLoadSelectsFirstSituationWhenNothingSelected() throws {
        try dbManager.dbPool.write { db in
            _ = try TestDatabase.insertSituation(db, title: "Top", rank: 9)
            _ = try TestDatabase.insertSituation(db, title: "Second", rank: 1)
        }
        let vm = DashboardViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(vm.selectedSituation?.title, "Top")
    }

    func testLoadKeepsSelectionWhenStillOpen() throws {
        try dbManager.dbPool.write { db in
            _ = try TestDatabase.insertSituation(db, title: "Top", rank: 9)
            _ = try TestDatabase.insertSituation(db, title: "Second", rank: 1)
        }
        let vm = DashboardViewModel(dbManager: dbManager)
        vm.load()
        let secondID = vm.situations[1].id
        vm.select(secondID)

        vm.load()

        XCTAssertEqual(vm.selectedSituationID, secondID)
    }

    func testDoneOnSelectedSelectsNextSituation() throws {
        try dbManager.dbPool.write { db in
            _ = try TestDatabase.insertSituation(db, title: "A", rank: 9)
            _ = try TestDatabase.insertSituation(db, title: "B", rank: 5)
            _ = try TestDatabase.insertSituation(db, title: "C", rank: 1)
        }
        let vm = DashboardViewModel(dbManager: dbManager)
        vm.load()
        vm.select(vm.situations[0].id)

        vm.done(vm.situations[0])

        XCTAssertEqual(vm.selectedSituation?.title, "B")
    }

    func testDismissOnLastSelectedSelectsPrevious() throws {
        try dbManager.dbPool.write { db in
            _ = try TestDatabase.insertSituation(db, title: "A", rank: 9)
            _ = try TestDatabase.insertSituation(db, title: "B", rank: 1)
        }
        let vm = DashboardViewModel(dbManager: dbManager)
        vm.load()
        vm.select(vm.situations[1].id)

        vm.dismiss(vm.situations[1])

        XCTAssertEqual(vm.selectedSituation?.title, "A")
    }

    func testDoneOnOnlySituationClearsSelection() throws {
        try dbManager.dbPool.write { db in
            _ = try TestDatabase.insertSituation(db, title: "Solo", rank: 1)
        }
        let vm = DashboardViewModel(dbManager: dbManager)
        vm.load()
        vm.select(vm.situations[0].id)

        vm.done(vm.situations[0])

        XCTAssertNil(vm.selectedSituationID)
        XCTAssertNil(vm.selectedSituation)
    }

    func testDoneOnUnselectedRowLeavesSelectionAlone() throws {
        try dbManager.dbPool.write { db in
            _ = try TestDatabase.insertSituation(db, title: "A", rank: 9)
            _ = try TestDatabase.insertSituation(db, title: "B", rank: 1)
        }
        let vm = DashboardViewModel(dbManager: dbManager)
        vm.load()
        vm.select(vm.situations[0].id)

        vm.done(vm.situations[1])

        XCTAssertEqual(vm.selectedSituation?.title, "A")
    }

    func testSelectLazyLoadsMemberSignalsOnceAndCaches() throws {
        let situationID = try dbManager.dbPool.write { db -> Int64 in
            let sid = try TestDatabase.insertSituation(db)
            let item = try TestDatabase.insertInboxItem(db, channelID: "C1", messageTS: "1700000100.000000", snippet: "hello")
            try TestDatabase.linkSituationSignal(db, situationID: sid, inboxItemID: item)
            return sid
        }
        let vm = DashboardViewModel(dbManager: dbManager)
        vm.load()

        vm.select(Int(situationID))

        XCTAssertTrue(vm.memberSignalsLoaded(Int(situationID)))
        XCTAssertEqual(vm.memberSignals(for: Int(situationID)).map(\.snippet), ["hello"])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd WatchtowerDesktop && swift test --filter DashboardViewModelTests > /tmp/swift-t3.log 2>&1; echo "exit=$?"; tail -30 /tmp/swift-t3.log` (log inspected via the file, exit code checked explicitly)
Expected: build FAILURE — `selectedSituationID`/`select` undefined.

- [ ] **Step 3: Implement in `DashboardViewModel`**

Add stored/computed state after the existing `errorMessage` property:

```swift
    /// Master-detail selection (left list ↔ review pane). Lives here — the VM
    /// is AppState-owned — so selection survives tab/sidebar navigation.
    var selectedSituationID: Int?

    /// Member signals per situation, loaded lazily on selection and cached so
    /// re-selecting doesn't re-hit the DB (was view-local state in the old
    /// in-feed expansion UI).
    private var memberSignalsCache: [Int: [InboxItem]] = [:]

    var selectedSituation: Situation? {
        guard let id = selectedSituationID else { return nil }
        return situations.first { $0.id == id }
    }

    func select(_ situationID: Int?) {
        selectedSituationID = situationID
        guard let id = situationID, memberSignalsCache[id] == nil else { return }
        memberSignalsCache[id] = loadMemberSignals(id)
    }

    func memberSignals(for situationID: Int) -> [InboxItem] {
        memberSignalsCache[situationID] ?? []
    }

    func memberSignalsLoaded(_ situationID: Int) -> Bool {
        memberSignalsCache[situationID] != nil
    }
```

At the end of `load()`'s success branch (after `errorMessage = nil`) add reconciliation; in the failure branch, after `openCount = 0`, add `selectedSituationID = nil`:

```swift
            reconcileSelection()
```

```swift
    /// Keeps the selection valid across reloads: an id still in the feed is
    /// kept; a vanished or absent selection falls back to the first situation.
    private func reconcileSelection() {
        if let id = selectedSituationID, situations.contains(where: { $0.id == id }) { return }
        select(situations.first?.id)
    }
```

Add the successor computation and call it at the top of `done(_:)`, `dismiss(_:)`, `snooze(_:until:)`, and `markConverted(situationID:targetID:trackID:)` (for `markConverted`, look the situation up by id first: `guard let situation = situations.first(where: { $0.id == situationID }) else …` — fall through to the plain write if it's not in the feed):

```swift
    /// Pre-computes which situation should be selected after `removed` leaves
    /// the open feed: the next row in list order, the previous when the last
    /// row was acted on, nil when the feed empties. Only applies when the
    /// removed situation IS the selected one — acting on an unselected row
    /// (context menu) leaves selection alone.
    private func advanceSelection(from removed: Situation) {
        guard selectedSituationID == removed.id else { return }
        guard let idx = situations.firstIndex(where: { $0.id == removed.id }) else { return }
        let remaining = situations.filter { $0.id != removed.id }
        guard !remaining.isEmpty else {
            selectedSituationID = nil
            return
        }
        select(remaining[min(idx, remaining.count - 1)].id)
    }
```

Example for `done` (same one-line insertion in the other three):

```swift
    func done(_ situation: Situation) {
        advanceSelection(from: situation)
        do {
            try dbManager.dbPool.write { db in try SituationQueries.done(db, id: situation.id) }
            load()
        } catch {
            errorMessage = "Failed to mark done: \(error.localizedDescription)"
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd WatchtowerDesktop && swift test --filter DashboardViewModelTests > /tmp/swift-t3b.log 2>&1; echo "exit=$?"; tail -20 /tmp/swift-t3b.log`
Expected: exit=0, all existing + new tests PASS (existing DASH-03 guards untouched).

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/ViewModels/DashboardViewModel.swift WatchtowerDesktop/Tests/DashboardViewModelTests.swift
git commit -m "feat(desktop): dashboard selection state with post-action successor in VM"
```

---

### Task 4: Swift VM — comment feedback routed through the CLI

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/DashboardViewModel.swift` (`submitFeedback`)
- Test: `WatchtowerDesktop/Tests/DashboardViewModelTests.swift`

**Interfaces:**
- Consumes: Task 2's CLI arg shape `["inbox", "feedback", "<id>", "--rating", "up"|"down", "--comment", "<text>"]`; `CLIRunnerProtocol.run(args:) async throws -> Data`; `FakeCLIRunner` test double (`Tests/Helpers/FakeCLIRunner.swift`, records `invocations: [[String]]`).
- Produces: `func submitFeedback(_ situation: Situation, rating: Int, comment: String = "") async` — Task 5's review pane calls this. **Breaking change:** the method becomes `async`; the one existing call site (`SituationCardView`, deleted in Task 5) and the existing feedback test must be updated in this task.

- [ ] **Step 1: Write the failing tests**

Append to `DashboardViewModelTests.swift`; also make the existing `testSubmitFeedbackNegativeOneCreatesLearnedRuleAndReloads` compile against the new `async` signature (add `async` to its declaration and `await` on the call — assertions unchanged):

```swift
    // MARK: - submitFeedback comment routing

    func testSubmitFeedbackWithoutCommentDoesNotInvokeCLI() async throws {
        let runner = FakeCLIRunner(stdout: Data())
        try await dbManager.dbPool.write { db in _ = try TestDatabase.insertSituation(db) }
        let vm = DashboardViewModel(dbManager: dbManager, cliRunner: runner)
        vm.load()

        await vm.submitFeedback(vm.situations[0], rating: -1, comment: "   ")

        XCTAssertTrue(runner.invocations.isEmpty, "rating-only feedback must stay on the direct-write fast path")
        XCTAssertNil(vm.errorMessage)
    }

    func testSubmitFeedbackWithCommentInvokesCLIWithExpectedArgs() async throws {
        let runner = FakeCLIRunner(stdout: Data())
        try await dbManager.dbPool.write { db in _ = try TestDatabase.insertSituation(db) }
        let vm = DashboardViewModel(dbManager: dbManager, cliRunner: runner)
        vm.load()
        let id = vm.situations[0].id

        await vm.submitFeedback(vm.situations[0], rating: 1, comment: "always show me Jane")

        XCTAssertEqual(runner.invocations, [[
            "inbox", "feedback", String(id), "--rating", "up", "--comment", "always show me Jane",
        ]])
        XCTAssertNil(vm.errorMessage)
    }

    func testSubmitFeedbackWithCommentSurfacesCLIFailure() async throws {
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "boom"))
        try await dbManager.dbPool.write { db in _ = try TestDatabase.insertSituation(db) }
        let vm = DashboardViewModel(dbManager: dbManager, cliRunner: runner)
        vm.load()

        await vm.submitFeedback(vm.situations[0], rating: -1, comment: "noise")

        XCTAssertNotNil(vm.errorMessage)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd WatchtowerDesktop && swift test --filter DashboardViewModelTests > /tmp/swift-t4.log 2>&1; echo "exit=$?"; tail -30 /tmp/swift-t4.log`
Expected: build FAILURE (`submitFeedback` has no `comment` parameter / is not async). Note: `SituationCardView` still calls the old sync signature — it is updated (deleted) in Task 5; for THIS task make the old call site compile by wrapping it: `onFeedback: { rating in Task { await vm.submitFeedback(situation, rating: rating) } }` in `DashboardView.situationRow`.

- [ ] **Step 3: Replace `submitFeedback` implementation**

```swift
    /// Records thumbs-up/down feedback for a situation. Comment-less feedback
    /// stays on the direct-write fast path (rating -1 derives channel mute
    /// rules; +1 is a no-op — see `SituationQueries.recordFeedback`). A
    /// non-empty comment routes through `watchtower inbox feedback`, whose
    /// learning interpreter turns it into targeted user rules (same pattern
    /// as `CatchUpViewModel.submitFeedback`).
    func submitFeedback(_ situation: Situation, rating: Int, comment: String = "") async {
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            do {
                try dbManager.dbPool.write { db in
                    try SituationQueries.recordFeedback(db, situationID: situation.id, rating: rating)
                }
                load()
            } catch {
                errorMessage = "Failed to submit feedback: \(error.localizedDescription)"
            }
            return
        }
        guard let runner = cliRunner ?? ProcessCLIRunner.makeDefault() else {
            errorMessage = "watchtower CLI not found in PATH"
            return
        }
        do {
            _ = try await runner.run(args: [
                "inbox", "feedback", String(situation.id),
                "--rating", rating >= 0 ? "up" : "down",
                "--comment", trimmed,
            ])
        } catch {
            errorMessage = "Failed to submit feedback: \(error.localizedDescription)"
        }
    }
```

Update the existing call site in `DashboardView.situationRow` as described in Step 2.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd WatchtowerDesktop && swift test --filter DashboardViewModelTests > /tmp/swift-t4b.log 2>&1; echo "exit=$?"; tail -20 /tmp/swift-t4b.log`
Expected: exit=0.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/ViewModels/DashboardViewModel.swift WatchtowerDesktop/Sources/Views/Dashboard/DashboardView.swift WatchtowerDesktop/Tests/DashboardViewModelTests.swift
git commit -m "feat(desktop): comment feedback routes through the inbox feedback CLI"
```

---

### Task 5: Swift views — master-detail split (SituationRow + SituationReviewPane)

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Dashboard/SituationRow.swift`
- Create: `WatchtowerDesktop/Sources/Views/Dashboard/SituationReviewPane.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Dashboard/DashboardView.swift` (full rewrite of `content`)
- Delete: `WatchtowerDesktop/Sources/Views/Dashboard/SituationCardView.swift`
- Modify: `WatchtowerDesktop/Sources/Services/SnoozeDates.swift` (doc comment only — it names `SituationCardView`)

**Interfaces:**
- Consumes: Task 3's `vm.selectedSituationID`/`select(_:)`/`selectedSituation`/`memberSignals(for:)`/`memberSignalsLoaded(_:)`; Task 4's `submitFeedback(_:rating:comment:) async`; existing `vm.senderName(for:)`, `vm.channelName(for:)`, `vm.slackURL(for:)`, `SnoozeOption`/`SnoozeDates`, `appState.navigateToTarget(_:)`/`navigateToTrack(_:)`; `CatchUpReviewPane`/`CatchUpThemeRow` as visual reference only (no code sharing).
- Produces: final UI. No new public API.

Views are not unit-tested in this project (VMs and queries are); the gate is a clean build plus the full VM suite staying green.

- [ ] **Step 1: Create `SituationRow.swift`**

```swift
import SwiftUI

// MARK: - SituationRow
//
// One row in the Dashboard's master list (left of the split). Mirrors the
// visual language of CatchUpThemeRow: priority dot + title + kind badge, with
// a trailing relative timestamp.
struct SituationRow: View {
    let situation: Situation

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(priorityColor)
                .frame(width: 8, height: 8)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 3) {
                Text(situation.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                kindBadge
            }

            Spacer(minLength: 4)

            if let date = situation.lastSignalDate {
                Text(date, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var kindBadge: some View {
        let info = kindBadgeInfo
        return Text(info.label)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(info.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(info.color.opacity(0.12), in: Capsule())
    }

    private var kindBadgeInfo: (label: String, color: Color) {
        switch situation.kind {
        case .external:      return ("Signal", .secondary)
        case .targetUpdate:  return ("Target", .blue)
        case .trackUpdate:   return ("Track", .purple)
        case .mixed:         return ("Mixed", .orange)
        }
    }

    private var priorityColor: Color {
        switch situation.priority {
        case "high": return .red
        case "medium": return .orange
        default: return .blue
        }
    }
}
```

- [ ] **Step 2: Create `SituationReviewPane.swift`**

The rich right-hand pane, modeled on `CatchUpReviewPane`. All content comes from the situation + VM lookups; all mutations go through callbacks so the sheets stay in `DashboardView`.

```swift
import SwiftUI
import AppKit

// MARK: - SituationReviewPane
//
// The rich single-situation review screen on the right of the Dashboard's
// master-detail split (modeled on CatchUpReviewPane). Shows kind/priority
// badges, the title, a Sources block (Target/Track navigation + newest-signal
// Slack link), the secretary card (why-it-matters callout, summary,
// chronology), the member-signal originals with per-bubble Slack links, and a
// bottom action bar (👍/👎 + teaching comment, Snooze, Target, Track, Dismiss,
// Done). All mutating actions are delegated to the owning DashboardView.
struct SituationReviewPane: View {
    let situation: Situation
    let memberSignals: [InboxItem]
    let memberSignalsLoaded: Bool
    var senderName: (InboxItem) -> String = { _ in "" }
    var channelName: (InboxItem) -> String = { _ in "" }
    /// Builds a Slack deep link for a member signal; nil hides the affordance.
    var slackURL: (InboxItem) -> URL? = { _ in nil }
    let onDone: () -> Void
    let onDismiss: () -> Void
    let onSnooze: (SnoozeOption) -> Void
    let onFeedback: (Int, String) -> Void
    /// Disables the Target button while its async prefill is being built.
    var isCreatingTarget: Bool = false
    let onCreateTarget: () -> Void
    let onCreateTrack: () -> Void
    let onOpenTarget: (Int) -> Void
    let onOpenTrack: (Int) -> Void

    @State private var comment: String = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    sourcesSection
                    secretaryCardOrPlaceholder
                    memberSignalsSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            actionBar
        }
        // Reset the comment field when switching to a different situation.
        .id(situation.id)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                kindBadge
                priorityBadge
                Spacer()
                if let date = situation.lastSignalDate {
                    Text(date, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Text(situation.title)
                .font(.largeTitle.bold())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var kindBadge: some View {
        let info = kindBadgeInfo
        return Text(info.label)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(info.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(info.color.opacity(0.12), in: Capsule())
    }

    private var kindBadgeInfo: (label: String, color: Color) {
        switch situation.kind {
        case .external:      return ("Signal", .secondary)
        case .targetUpdate:  return ("Target", .blue)
        case .trackUpdate:   return ("Track", .purple)
        case .mixed:         return ("Mixed", .orange)
        }
    }

    private var priorityBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(priorityColor)
                .frame(width: 8, height: 8)
            Text(situation.priority.capitalized)
                .font(.caption)
                .foregroundStyle(priorityColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(priorityColor.opacity(0.1), in: Capsule())
    }

    private var priorityColor: Color {
        switch situation.priority {
        case "high": return .red
        case "medium": return .orange
        default: return .blue
        }
    }

    // MARK: - Sources (primary sources: Target/Track navigation + newest Slack link)

    @ViewBuilder
    private var sourcesSection: some View {
        let hasAny = situation.targetID != nil || situation.trackID != nil || newestMemberSignalURL != nil
        if hasAny {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sources")
                    .font(.headline)

                if let targetID = situation.targetID {
                    sourceRow(symbol: "checkmark.circle", color: .blue,
                              title: "Target #\(targetID)", subtitle: "Target") {
                        onOpenTarget(targetID)
                    }
                }
                if let trackID = situation.trackID {
                    sourceRow(symbol: "point.topleft.down.curvedto.point.bottomright.up", color: .purple,
                              title: "Track #\(trackID)", subtitle: "Track") {
                        onOpenTrack(trackID)
                    }
                }
                if let url = newestMemberSignalURL {
                    sourceRow(symbol: "arrow.up.right.square", color: .green,
                              title: "Newest message in Slack", subtitle: "Slack") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private func sourceRow(symbol: String, color: Color, title: String, subtitle: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(color)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    /// Member signals arrive oldest-first (SituationQueries.memberSignals), so
    /// the last element is the newest — same rule the old card header used.
    private var newestMemberSignalURL: URL? {
        guard memberSignalsLoaded, let newest = memberSignals.last else { return nil }
        return slackURL(newest)
    }

    // MARK: - Secretary card

    @ViewBuilder
    private var secretaryCardOrPlaceholder: some View {
        if situation.hasCard {
            cardSection
        } else if situation.cardStatus == .failed {
            Text("Context unavailable — will retry")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Preparing context…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var cardSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !situation.whyMatters.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.yellow)
                        .font(.callout)
                    Text(situation.whyMatters)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if !situation.summary.isEmpty {
                cardParagraph(title: "Summary", text: situation.summary)
            }
            if !situation.chronology.isEmpty {
                cardParagraph(title: "Chronology", text: situation.chronology)
            }
        }
    }

    private func cardParagraph(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(text)
                .font(.body)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Member signals (same bubble shape the old card used)

    @ViewBuilder
    private var memberSignalsSection: some View {
        Divider()
        if !memberSignalsLoaded {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading signals…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if memberSignals.isEmpty {
            Text("No member signals recorded.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(memberSignals) { item in
                    memberSignalBubble(item)
                }
            }
        }
    }

    private func memberSignalBubble(_ item: InboxItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("\(senderName(item)) · \(channelName(item))")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Text(item.messageDate, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                if let url = slackURL(item) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Open in Slack")
                }
            }
            .padding(.top, 6)
            Text(item.snippet)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Action bar

    private var actionBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    onFeedback(1, comment)
                    comment = ""
                } label: {
                    Image(systemName: "hand.thumbsup")
                }
                .buttonStyle(.bordered)
                .help("Helpful")

                Button {
                    onFeedback(-1, comment)
                    comment = ""
                } label: {
                    Image(systemName: "hand.thumbsdown")
                }
                .buttonStyle(.bordered)
                .help("Not helpful")

                TextField("Comment to teach the secretary…", text: $comment)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 8) {
                Menu {
                    Button("1 hour") { onSnooze(.oneHour) }
                    Button("Till tomorrow") { onSnooze(.tillTomorrow) }
                    Button("Till Monday") { onSnooze(.tillMonday) }
                } label: {
                    Label("Snooze", systemImage: "moon.zzz")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button(action: onCreateTarget) {
                    Label("Target", systemImage: "checkmark.circle")
                }
                .buttonStyle(.bordered)
                .disabled(isCreatingTarget)

                Button(action: onCreateTrack) {
                    Label("Track", systemImage: "binoculars")
                }
                .buttonStyle(.bordered)

                Button("Dismiss", role: .destructive, action: onDismiss)
                    .buttonStyle(.bordered)

                Spacer()

                Button {
                    onDone()
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(12)
    }
}
```

- [ ] **Step 3: Rewrite `DashboardView.content` as the split, delete `SituationCardView.swift`**

Keep everything in `DashboardView` about sheets/conversion (`showCreateTarget`, `targetPrefill`, `pendingSituationID`, `isBuildingPrefill`, `conversionError`, `showCreateTrack`, `trackSituationID`, `openCreateTarget`, `openCreateTrack`, `resolveCreatedTrack`) — only the presentation changes. Remove the now-dead `@State expandedSituationID` / `@State memberSignalsCache` / `situationRow` / `toggleExpansion`. New `content` + subviews:

```swift
    private var content: some View {
        Group {
            if vm.situations.isEmpty {
                emptyState
            } else {
                HSplitView {
                    situationList
                        .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                    reviewPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    // MARK: - Left: situation list

    private var situationList: some View {
        List(selection: Binding(
            get: { vm.selectedSituationID },
            set: { vm.select($0) }
        )) {
            ForEach(vm.situations) { situation in
                SituationRow(situation: situation)
                    .tag(situation.id)
                    .contextMenu { contextMenu(for: situation) }
            }

            Button("Load more") { vm.loadMore() }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func contextMenu(for situation: Situation) -> some View {
        Button {
            vm.done(situation)
        } label: {
            Label("Done", systemImage: "checkmark.circle")
        }
        Menu {
            Button("1 hour") { vm.snooze(situation, until: SnoozeDates.until(.oneHour)) }
            Button("Till tomorrow") { vm.snooze(situation, until: SnoozeDates.until(.tillTomorrow)) }
            Button("Till Monday") { vm.snooze(situation, until: SnoozeDates.until(.tillMonday)) }
        } label: {
            Label("Snooze", systemImage: "moon.zzz")
        }
        Divider()
        Button(role: .destructive) {
            vm.dismiss(situation)
        } label: {
            Label("Dismiss", systemImage: "archivebox")
        }
    }

    // MARK: - Right: review pane

    @ViewBuilder
    private var reviewPane: some View {
        if let situation = vm.selectedSituation {
            SituationReviewPane(
                situation: situation,
                memberSignals: vm.memberSignals(for: situation.id),
                memberSignalsLoaded: vm.memberSignalsLoaded(situation.id),
                senderName: { vm.senderName(for: $0) },
                channelName: { vm.channelName(for: $0) },
                slackURL: { vm.slackURL(for: $0) },
                onDone: { vm.done(situation) },
                onDismiss: { vm.dismiss(situation) },
                onSnooze: { option in vm.snooze(situation, until: SnoozeDates.until(option)) },
                onFeedback: { rating, comment in
                    Task { await vm.submitFeedback(situation, rating: rating, comment: comment) }
                },
                isCreatingTarget: isBuildingPrefill,
                onCreateTarget: { openCreateTarget(for: situation) },
                onCreateTrack: { openCreateTrack(for: situation) },
                onOpenTarget: { appState.navigateToTarget($0) },
                onOpenTrack: { appState.navigateToTrack($0) }
            )
        } else {
            VStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("Select a situation")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
```

Then:

```bash
git rm WatchtowerDesktop/Sources/Views/Dashboard/SituationCardView.swift
grep -rn "SituationCardView" WatchtowerDesktop/ && echo "STILL REFERENCED — fix before continuing" || echo "clean"
```

In `SnoozeDates.swift`, update the two doc comments that name `SituationCardView` to name `SituationReviewPane`/`DashboardView` instead (comment-only edit).

- [ ] **Step 4: Build, run the full Swift suite, lint**

```bash
cd WatchtowerDesktop && swift build > /tmp/swift-t5.log 2>&1; echo "build=$?"
swift test > /tmp/swift-t5b.log 2>&1; echo "test=$?"
swiftlint --strict > /tmp/swift-t5c.log 2>&1; echo "lint=$?"
```
Expected: all three exit 0 (inspect the log files on any nonzero — never trust truncated output).

- [ ] **Step 5: Manual smoke (dev build)**

Run: `make app-dev` and verify by eye: split renders; selecting rows swaps the pane; Enter marks Done and selection advances; Sources rows navigate to Target/Track tabs; Slack links open; comment + 👎 fires the CLI (check `errorMessage` stays nil); Generate on the empty state still works. No macOS TCC prompt may appear at any point (P0 if it does).

- [ ] **Step 6: Commit**

```bash
git add -A WatchtowerDesktop/Sources/Views/Dashboard/ WatchtowerDesktop/Sources/Services/SnoozeDates.swift
git commit -m "feat(desktop): dashboard master-detail with catch-up-style review pane"
```

---

### Task 6: Docs — inventory contract, app guide, CLAUDE.md

**Files:**
- Modify: `docs/inventory/dashboard.md` (add DASH-04)
- Modify: `docs/app-guide.md` (Inbox/Dashboard section — describe the master-detail UX, comment feedback, source links)
- Modify: `CLAUDE.md` (the Desktop bullet in the Inbox Secretary feature notes)

**Interfaces:**
- Consumes: guard test names from Tasks 1 and 4 (`TestDash04_CommentlessFeedbackNeverInvokesInterpreter`, `testSubmitFeedbackWithoutCommentDoesNotInvokeCLI`).

- [ ] **Step 1: Add DASH-04 to `docs/inventory/dashboard.md`** (append after DASH-03, same format):

```markdown
## DASH-04 — Comment-less feedback never invokes the AI interpreter

**Status:** Enforced

**Observable:** 👍/👎 on a situation without a comment stays local: the Desktop writes rules directly (👎 → `source_mute` user_rule per member-signal channel; 👍 → no-op) and the `watchtower inbox feedback` CLI mirrors the same derivation — neither path makes an AI call. Only a non-empty comment runs the `inbox.situation_learn` learning interpreter, and every rule it derives lands as `source='user_rule'` (protected from implicit overwrite, INBOX-05).

**Why locked:** A bare thumb is a one-bit signal; silently spending an AI call (and potentially minutes of CLI latency) on it would make the cheapest feedback gesture slow and expensive, and rules invented from a bare thumb would be guesses. The interpreter runs only when the user actually said something interpretable.

**Test guards:**
- `internal/inbox/situation_feedback_test.go::TestDash04_CommentlessFeedbackNeverInvokesInterpreter`
- `WatchtowerDesktop/Tests/DashboardViewModelTests.swift::testSubmitFeedbackWithoutCommentDoesNotInvokeCLI`

**Locked since:** 2026-07-07
```

- [ ] **Step 2: Update `docs/app-guide.md`** — rewrite the Inbox tab's Feed description: master-detail split (compact ranked list left; review pane right with kind/priority badges, Sources block linking to Target/Track/Slack, why-it-matters/summary/chronology, member-signal originals with per-message Slack links); bottom action bar (👍/👎 + "Comment to teach the secretary", Snooze, Target, Track, Dismiss, Done with Enter); selection advances to the next situation after Done/Dismiss; comment feedback teaches the secretary via learned rules. Match the file's existing tone/structure (read it first).

- [ ] **Step 3: Update `CLAUDE.md`** — in the Inbox Secretary feature notes, replace the Desktop sentence describing "kind badges … inline context packet" with the master-detail description, e.g.: `Desktop: InboxFeedView hosts the Dashboard tab — a Catch-Up-style master-detail screen (SituationRow list left, SituationReviewPane right: sources block with Target/Track/Slack links, secretary card, member signals, action bar with comment feedback), replacing the in-feed card expansion` and mention the `watchtower inbox feedback` CLI + DASH-04 alongside the existing feedback-path bullet.

- [ ] **Step 4: Full verification sweep**

```bash
go test ./... > /tmp/final-go.log 2>&1; echo "go=$?"
go vet ./... && go build ./... ; echo "vet-build=$?"
cd WatchtowerDesktop && swift build > /tmp/final-swift-build.log 2>&1; echo "swift-build=$?"
swift test > /tmp/final-swift-test.log 2>&1; echo "swift-test=$?"
```
Expected: every echo prints 0; inspect logs on any failure.

- [ ] **Step 5: Commit**

```bash
git add docs/inventory/dashboard.md docs/app-guide.md CLAUDE.md
git commit -m "docs: DASH-04 contract, app guide and CLAUDE.md for dashboard master-detail"
```

---

## After all tasks

Run the `local-review` skill (per-item panel review + local CI mirror) before opening/updating any PR. Push via the `vadimtrunov` gh account (remote over Tailscale).
