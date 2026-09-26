package ideas

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// fakeGen is a stub digest.Generator whose reply func drives success/error
// and records how many times Generate was called (the internal/memory
// pipeline_test.go fakeGen precedent).
type fakeGen struct {
	reply func(user string) (string, error)
	calls int
}

func (g *fakeGen) Generate(_ context.Context, _, user, _ string) (string, *digest.Usage, string, error) {
	g.calls++
	out, err := g.reply(user)
	if err != nil {
		return "", nil, "", err
	}
	return out, &digest.Usage{InputTokens: 10, OutputTokens: 5, TotalAPITokens: 15}, "sess", nil
}

func testCfg() *config.Config {
	return &config.Config{Digest: config.DigestConfig{Language: "English"}}
}

// testCfgWithBudget is testCfg with an explicit stage-1 prompt budget, so a
// test can force the renderers' truncation branch without seeding 60 KB of
// fixture text.
func testCfgWithBudget(maxPromptChars int) *config.Config {
	cfg := testCfg()
	cfg.Ideas.MaxPromptChars = maxPromptChars
	return cfg
}

// assertNoStreamDigestCites fails if ref appears anywhere in stream_digests —
// the direct reading of IDEA-02 at stage 1: an invented reference never
// reaches the database, whatever shape the row around it would have had.
func assertNoStreamDigestCites(t *testing.T, d *db.DB, ref string) {
	t.Helper()
	digests, err := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, err)
	for _, sd := range digests {
		assert.NotContains(t, sd.TopicsJSON, ref, "stream_digests row %d cites an invented ref", sd.ID)
	}
}

func testLogger() *log.Logger {
	return log.New(io.Discard, "", 0)
}

// seedGoogleAccount inserts a Gmail-enabled google_accounts row with the
// given Gmail sync watermark (unix seconds) and returns its id. Each call
// gets a unique email so multiple accounts can be seeded in one test.
func seedGoogleAccount(t *testing.T, d *db.DB, syncWatermark float64) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO google_accounts (email, label, gmail_enabled, gmail_last_internal_date)
		VALUES (?, 'Test', 1, ?)`, fmt.Sprintf("acct%d@example.com", time.Now().UnixNano()), syncWatermark)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

// setIdeasEmailFloorRaw seeds an account's ideas_email_floor directly,
// bypassing the pipeline's own floor==0 init-and-skip pass, so a test can
// start from an "already initialized" account.
func setIdeasEmailFloorRaw(t *testing.T, d *db.DB, accountID int64, floor float64) {
	t.Helper()
	_, err := d.Exec(`UPDATE google_accounts SET ideas_email_floor = ? WHERE id = ?`, floor, accountID)
	require.NoError(t, err)
}

func seedGmailMessageIdeas(t *testing.T, d *db.DB, accountID int64, id, threadID, fromEmail, fromName, subject, body, internalDateISO string) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO gmail_messages
		(account_id, id, thread_id, from_email, from_name, subject, body_text, internal_date)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		accountID, id, threadID, fromEmail, fromName, subject, body, internalDateISO)
	require.NoError(t, err)
}

// seedGmailThreadsInOneSecond inserts n single-message threads all carrying
// the same internal_date, in one transaction — the boundary-drain ceiling only
// engages past maxTieDrainUnits units, so its guard needs a bulk fixture.
func seedGmailThreadsInOneSecond(t *testing.T, d *db.DB, accountID int64, n int, internalDateISO string) {
	t.Helper()
	tx, err := d.Begin()
	require.NoError(t, err)
	defer func() { _ = tx.Rollback() }()
	stmt, err := tx.Prepare(`INSERT INTO gmail_messages
		(account_id, id, thread_id, from_email, from_name, subject, body_text, internal_date)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`)
	require.NoError(t, err)
	defer stmt.Close()
	for i := 0; i < n; i++ {
		_, err = stmt.Exec(accountID, fmt.Sprintf("m%05d", i), fmt.Sprintf("thr-%05d", i),
			"a@example.com", "Ann", "Subj", "body", internalDateISO)
		require.NoError(t, err)
	}
	require.NoError(t, tx.Commit())
}

func TestRunEmailDigests_InsertsRowAndAdvancesFloor(t *testing.T) {
	d := newTestDB(t)
	base := time.Now().Add(-time.Hour).Unix()
	acctID := seedGoogleAccount(t, d, float64(base))
	setIdeasEmailFloorRaw(t, d, acctID, float64(base-10))

	iso1 := time.Unix(base+10, 0).UTC().Format(time.RFC3339)
	iso2 := time.Unix(base+20, 0).UTC().Format(time.RFC3339)
	seedGmailMessageIdeas(t, d, acctID, "m1", "thr-1", "a@example.com", "Ann", "Budget review", "We should try a new vendor.", iso1)
	seedGmailMessageIdeas(t, d, acctID, "m2", "thr-2", "b@example.com", "Bob", "Launch plan", "We decided to launch Friday.", iso2)

	tag1 := fmt.Sprintf("gmail:%d:thr-1", acctID)
	tag2 := fmt.Sprintf("gmail:%d:thr-2", acctID)
	gen := &fakeGen{reply: func(string) (string, error) {
		return fmt.Sprintf(`{"topics":[
			{"title":"Vendor idea","summary":"s","ideas":[{"text":"try a new vendor","author":"Ann","ref":%q}],"decisions":[]},
			{"title":"Launch","summary":"s2","ideas":[],"decisions":[{"text":"launch Friday","author":"Bob","ref":%q}]}
		]}`, tag1, tag2), nil
	}}

	p := New(d, testCfg(), gen, testLogger())
	err := p.runEmailDigests(context.Background(), time.Time{})
	require.NoError(t, err)
	assert.Equal(t, 1, gen.calls)

	digests, err := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, err)
	require.Len(t, digests, 1)
	sd := digests[0]
	assert.Equal(t, "gmail", sd.Source)
	assert.Equal(t, acctID, sd.AccountID)
	assert.Contains(t, sd.TopicsJSON, tag1)
	assert.Contains(t, sd.TopicsJSON, tag2)

	newFloor, err := d.IdeasEmailFloor(acctID)
	require.NoError(t, err)
	assert.Equal(t, float64(base+20), newFloor)
}

func TestIdeas01_EmailGeneratorErrorNoRowFloorUnchanged(t *testing.T) {
	d := newTestDB(t)
	base := time.Now().Add(-time.Hour).Unix()
	acctID := seedGoogleAccount(t, d, float64(base))
	setIdeasEmailFloorRaw(t, d, acctID, float64(base-10))

	iso1 := time.Unix(base+10, 0).UTC().Format(time.RFC3339)
	seedGmailMessageIdeas(t, d, acctID, "m1", "thr-1", "a@example.com", "Ann", "Subj", "body", iso1)

	gen := &fakeGen{reply: func(string) (string, error) { return "", fmt.Errorf("boom") }}
	p := New(d, testCfg(), gen, testLogger())
	err := p.runEmailDigests(context.Background(), time.Time{})
	require.Error(t, err)

	digests, err := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, err)
	assert.Empty(t, digests)

	floor, err := d.IdeasEmailFloor(acctID)
	require.NoError(t, err)
	assert.Equal(t, float64(base-10), floor)
}

// TestIdeas01_EmailNoNewMessagesCleanNoOp covers the degenerate
// zero-new-material branch: an already-initialized account with nothing new
// above its floor must not call the generator, insert a row, or touch the
// floor (see feedback_test_degenerate_clean_exit).
func TestIdeas01_EmailNoNewMessagesCleanNoOp(t *testing.T) {
	d := newTestDB(t)
	base := time.Now().Add(-time.Hour).Unix()
	acctID := seedGoogleAccount(t, d, float64(base))
	setIdeasEmailFloorRaw(t, d, acctID, float64(base))

	gen := &fakeGen{reply: func(string) (string, error) {
		t.Fatal("generator must not be called with no new material")
		return "", nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	err := p.runEmailDigests(context.Background(), time.Time{})
	require.NoError(t, err)
	assert.Zero(t, gen.calls)

	digests, err := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, err)
	assert.Empty(t, digests)

	floor, err := d.IdeasEmailFloor(acctID)
	require.NoError(t, err)
	assert.Equal(t, float64(base), floor)
}

// TestRunEmailDigests_FloorZero_InitializesAndSkips covers the no-backfill
// first-run path: a never-initialized account skips extraction entirely and
// just sets its floor to the current Gmail sync watermark.
func TestRunEmailDigests_FloorZero_InitializesAndSkips(t *testing.T) {
	d := newTestDB(t)
	base := time.Now().Add(-time.Hour).Unix()
	acctID := seedGoogleAccount(t, d, float64(base)) // ideas_email_floor defaults to 0
	iso1 := time.Unix(base-100, 0).UTC().Format(time.RFC3339)
	seedGmailMessageIdeas(t, d, acctID, "m1", "thr-1", "a@example.com", "Ann", "Subj", "body", iso1)

	gen := &fakeGen{reply: func(string) (string, error) {
		t.Fatal("generator must not be called on the init pass")
		return "", nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	err := p.runEmailDigests(context.Background(), time.Time{})
	require.NoError(t, err)
	assert.Zero(t, gen.calls)

	floor, err := d.IdeasEmailFloor(acctID)
	require.NoError(t, err)
	assert.Equal(t, float64(base), floor)

	digests, err := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, err)
	assert.Empty(t, digests)
}

// TestIdeas02_EmailHallucinatedRefDropped covers ref validation: a candidate
// whose ref does not match a rendered thread tag never reaches the database at
// all, while the pass still completes normally (the AI call itself succeeded,
// so the mined window's floor advances — only the untrustworthy candidate is
// discarded).
//
// Re-expressed 2026-09-13 (audit fix wave 2): the invented ref used to leave
// behind a stream_digests row carrying "[]". This now asserts zero rows, which
// is strictly stronger — the earlier assertion accepted a row as long as its
// topics were empty, this one accepts no row at all.
func TestIdeas02_EmailHallucinatedRefDropped(t *testing.T) {
	d := newTestDB(t)
	base := time.Now().Add(-time.Hour).Unix()
	acctID := seedGoogleAccount(t, d, float64(base))
	setIdeasEmailFloorRaw(t, d, acctID, float64(base-10))

	iso1 := time.Unix(base+10, 0).UTC().Format(time.RFC3339)
	seedGmailMessageIdeas(t, d, acctID, "m1", "thr-1", "a@example.com", "Ann", "Subj", "body", iso1)

	gen := &fakeGen{reply: func(string) (string, error) {
		return `{"topics":[{"title":"t","summary":"s","ideas":[{"text":"invented","author":"Ann","ref":"gmail:999:fake-thread"}],"decisions":[]}]}`, nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	err := p.runEmailDigests(context.Background(), time.Time{})
	require.NoError(t, err)

	assertNoStreamDigestCites(t, d, "gmail:999:fake-thread")
	digests, err := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, err)
	assert.Empty(t, digests,
		"an invented ref must not reach stream_digests at all — not even as an empty row")

	floor, err := d.IdeasEmailFloor(acctID)
	require.NoError(t, err)
	assert.Equal(t, float64(base+10), floor, "the window was mined, so its floor still advances")
}

// TestIdeas01_EmailEmptyTopics_NoRowFloorAdvances is the other route to the
// same no-empty-row rule: the model answered with an affirmative but empty
// "topics" array. No row is written (an empty digest is an unread badge for
// nothing), yet the window was genuinely mined, so the floor advances.
func TestIdeas01_EmailEmptyTopics_NoRowFloorAdvances(t *testing.T) {
	d := newTestDB(t)
	base := time.Now().Add(-time.Hour).Unix()
	acctID := seedGoogleAccount(t, d, float64(base))
	setIdeasEmailFloorRaw(t, d, acctID, float64(base-10))
	seedGmailMessageIdeas(t, d, acctID, "m1", "thr-1", "a@example.com", "Ann", "Subj", "body",
		time.Unix(base+10, 0).UTC().Format(time.RFC3339))

	gen := &fakeGen{reply: func(string) (string, error) { return `{"topics":[]}`, nil }}
	p := New(d, testCfg(), gen, testLogger())
	require.NoError(t, p.runEmailDigests(context.Background(), time.Time{}))
	require.Equal(t, 1, gen.calls)

	digests, err := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, err)
	assert.Empty(t, digests, "a window with no topics must write no stream_digests row")

	floor, err := d.IdeasEmailFloor(acctID)
	require.NoError(t, err)
	assert.Equal(t, float64(base+10), floor)
}

// TestIdeas01_EmailFloorStopsAtBudgetDroppedThread pins the floor to what the
// renderer actually put in front of the model: with a budget that fits only
// the first thread, the floor must stop at that thread's newest message, so
// the dropped thread is still above the floor and gets mined next run.
func TestIdeas01_EmailFloorStopsAtBudgetDroppedThread(t *testing.T) {
	d := newTestDB(t)
	base := time.Now().Add(-time.Hour).Unix()
	acctID := seedGoogleAccount(t, d, float64(base))
	setIdeasEmailFloorRaw(t, d, acctID, float64(base-10))

	seedGmailMessageIdeas(t, d, acctID, "m1", "thr-1", "a@example.com", "Ann", "First", "short",
		time.Unix(base+10, 0).UTC().Format(time.RFC3339))
	seedGmailMessageIdeas(t, d, acctID, "m2", "thr-2", "b@example.com", "Bob", "Second",
		strings.Repeat("y ", 400),
		time.Unix(base+20, 0).UTC().Format(time.RFC3339))

	// Budget the first thread's line exactly, so the second thread is dropped.
	window, err := d.ListGmailThreadsForExtract(acctID, float64(base-10), 0, 500)
	require.NoError(t, err)
	full, _ := renderEmailBlock(acctID, groupThreads(window), 1000000, 0)
	budget := strings.Index(full, "\n") + 1

	var seenBlock string
	gen := &fakeGen{reply: func(user string) (string, error) {
		seenBlock = user
		return fmt.Sprintf(`{"topics":[{"title":"t","summary":"s","ideas":[{"text":"i","author":"Ann","ref":%q}],"decisions":[]}]}`,
			fmt.Sprintf("gmail:%d:thr-1", acctID)), nil
	}}
	p := New(d, testCfgWithBudget(budget), gen, testLogger())
	require.NoError(t, p.runEmailDigests(context.Background(), time.Time{}))
	require.Equal(t, 1, gen.calls)
	require.NotContains(t, seenBlock, "thr-2", "the second thread must not have been rendered")

	floor, ferr := d.IdeasEmailFloor(acctID)
	require.NoError(t, ferr)
	assert.Equal(t, float64(base+10), floor,
		"the floor may only advance over threads the model was actually shown")

	// The dropped thread is still visible to the next run.
	msgs, merr := d.ListGmailThreadsForExtract(acctID, floor, 0, 500)
	require.NoError(t, merr)
	require.Len(t, msgs, 1)
	assert.Equal(t, "thr-2", msgs[0].ThreadID)

	digests, derr := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, derr)
	require.Len(t, digests, 1)
	assert.Equal(t, time.Unix(base+10, 0).UTC().Format(time.RFC3339), digests[0].PeriodTo,
		"period_to must describe what the row summarizes, not what was loaded")
}

// TestIdeas01_EmailTieAtBudgetCut_DrainedNotBuried pins the boundary-tie rule.
// internal_date is second-granular, so two threads whose oldest message shares
// a second are ordinary. When the budget cut lands inside that second, a floor
// set to the last rendered message would sit exactly ON it — and the reload is
// strictly greater-than, so the dropped thread would never be read again. The
// whole tie group must be rendered instead.
func TestIdeas01_EmailTieAtBudgetCut_DrainedNotBuried(t *testing.T) {
	d := newTestDB(t)
	base := time.Now().Add(-time.Hour).Unix()
	acctID := seedGoogleAccount(t, d, float64(base))
	setIdeasEmailFloorRaw(t, d, acctID, float64(base-10))

	// Both threads' only message sits in the same second.
	same := time.Unix(base+10, 0).UTC().Format(time.RFC3339)
	seedGmailMessageIdeas(t, d, acctID, "m1", "thr-1", "a@example.com", "Ann", "First", "short", same)
	seedGmailMessageIdeas(t, d, acctID, "m2", "thr-2", "b@example.com", "Bob", "Second",
		strings.Repeat("y ", 400), same)

	// A budget that fits the first thread's line only.
	window, err := d.ListGmailThreadsForExtract(acctID, float64(base-10), 0, 500)
	require.NoError(t, err)
	full, _ := renderEmailBlock(acctID, groupThreads(window), 1000000, 0)
	budget := strings.Index(full, "\n") + 1

	var seenBlock string
	gen := &fakeGen{reply: func(user string) (string, error) {
		seenBlock = user
		return fmt.Sprintf(`{"topics":[{"title":"t","summary":"s","ideas":[{"text":"i","author":"Ann","ref":%q}],"decisions":[]}]}`,
			fmt.Sprintf("gmail:%d:thr-1", acctID)), nil
	}}
	p := New(d, testCfgWithBudget(budget), gen, testLogger())
	require.NoError(t, p.runEmailDigests(context.Background(), time.Time{}))
	require.Equal(t, 1, gen.calls)

	assert.Contains(t, seenBlock, "thr-2",
		"the tie-mate must be drained into the same prompt, not dropped below the floor")

	floor, ferr := d.IdeasEmailFloor(acctID)
	require.NoError(t, ferr)
	assert.Equal(t, float64(base+10), floor)

	// Nothing is left behind: the floor passed the second only because the
	// whole second was rendered.
	left, lerr := d.ListGmailThreadsForExtract(acctID, floor, 0, 500)
	require.NoError(t, lerr)
	assert.Empty(t, left, "no message may sit at-or-below the floor unmined")
}

// TestIdeas01_EmailTieGroupBeyondCeiling_BoundedAndFloorAdvances covers the
// one branch that still loses material: a tie group larger than
// maxTieDrainUnits is drained only to the ceiling, and the floor passes the
// second anyway — deliberately, because the alternative is a pass that can
// never move (a second-granular group is all-or-nothing). The drain must stop
// somewhere, or one second could pull an unbounded load into a single prompt;
// and when it does stop short, the pass must report a FAULT naming the source,
// the timestamp and how many units went unrendered, not a quiet statistic.
//
// The numbers here are LITERAL on purpose. The ceiling's value is the whole
// point of the branch — at 50 a routine bulk edit silently lost its tail — so
// the guard defends the chosen magnitude rather than re-deriving it from the
// constant and passing at any value.
func TestIdeas01_EmailTieGroupBeyondCeiling_BoundedAndFloorAdvances(t *testing.T) {
	require.Equal(t, 1000, maxTieDrainUnits,
		"the drain ceiling must stay out of reach of ordinary bulk activity: a tie group is "+
			"all-or-nothing, so whatever the ceiling trims goes under the floor unmined. "+
			"If this constant is deliberately changed, re-derive the counts below with it.")

	d := newTestDB(t)
	base := time.Now().Add(-time.Hour).Unix()
	acctID := seedGoogleAccount(t, d, float64(base))
	setIdeasEmailFloorRaw(t, d, acctID, float64(base-10))

	// 1005 threads in one second: past the ceiling by 5, and past the loader's
	// own 500-message cap — so this also exercises the loader's unbounded
	// boundary drain handing the renderer more than one pass normally holds.
	const seeded, wantRendered, wantUnrendered = 1005, 1000, 5
	same := time.Unix(base+10, 0).UTC().Format(time.RFC3339)
	seedGmailThreadsInOneSecond(t, d, acctID, seeded, same)

	var seenBlock string
	var logged bytes.Buffer
	gen := &fakeGen{reply: func(user string) (string, error) {
		seenBlock = user
		return `{"topics":[]}`, nil
	}}
	p := New(d, testCfgWithBudget(1), gen, log.New(&logged, "", 0))
	require.NoError(t, p.runEmailDigests(context.Background(), time.Time{}))
	require.Equal(t, 1, gen.calls)

	assert.Equal(t, wantRendered, strings.Count(seenBlock, "gmail:"),
		"the drain must take the group up to the ceiling and stop exactly there")
	// Numbering stays contiguous across the drain's skipped threads, matching
	// renderProject's twin.
	assert.Contains(t, seenBlock, fmt.Sprintf("[%d] ", wantRendered))
	assert.NotContains(t, seenBlock, fmt.Sprintf("[%d] ", wantRendered+1))

	floor, err := d.IdeasEmailFloor(acctID)
	require.NoError(t, err)
	assert.Equal(t, float64(base+10), floor,
		"above the ceiling the floor still passes the second — a bounded residual, not a stall")

	// The loss must surface as a fault, with enough detail to act on: which
	// source, which timestamp, and exactly how many units went unmined.
	out := logged.String()
	assert.Contains(t, out, "ERROR", "hitting the ceiling is a fault, not a note")
	assert.Contains(t, out, fmt.Sprintf(
		"ERROR: gmail account %d: %d thread(s) sharing second %d were NOT rendered — the boundary drain stopped at its ceilings (%d units / %d chars,",
		acctID, wantUnrendered, base+10, maxTieDrainUnits, tieDrainCharCeiling),
		"the fault must name the source, the count, the timestamp and both ceilings")
	// The UNIT ceiling is what stopped this drain, so the block must sit far
	// below the byte ceiling — otherwise this test is silently exercising the
	// other bound.
	assert.Less(t, len(seenBlock), tieDrainCharCeiling/2,
		"this fixture must exercise the unit ceiling, not the byte ceiling")
}

// TestIdeas01_EmailTieDrainStopsAtByteCeiling covers the drain's SECOND
// ceiling, in the dimension the unit ceiling cannot see. A thousand fat units
// build a prompt no model accepts, and an over-context call is the worst
// outcome available here: the generator errors, the floor correctly does not
// advance, and the next cycle rebuilds the same oversized drain — losing the
// tie group AND everything above it, permanently. Stopping on bytes loses only
// the undrained tie-mates and says so, which is why the byte bound inherits
// the unit ceiling's disposition exactly: advance anyway, counted fault, never
// a retreat.
//
// Fixture arithmetic, pinned literally: 8 threads share a second, each
// rendering one ~100 KB line, against a 600 000-char ceiling — so 5 fit
// (5 x 100 060 = 500 300; a 6th would be 600 360) and 3 do not. Well under the
// 1000-unit ceiling, so bytes are provably what stopped it.
func TestIdeas01_EmailTieDrainStopsAtByteCeiling(t *testing.T) {
	require.Equal(t, 10, tieDrainBudgetFactor,
		"the byte ceiling protects against an over-context drain; changing the factor means "+
			"re-deriving the counts below with it")

	d := newTestDB(t)
	base := time.Now().Add(-time.Hour).Unix()
	acctID := seedGoogleAccount(t, d, float64(base))
	setIdeasEmailFloorRaw(t, d, acctID, float64(base-10))

	const seeded, wantRendered, wantUnrendered = 8, 5, 3
	const fatSubject = 100000 // subjects are not excerpt-capped, so this sets the line size
	same := time.Unix(base+10, 0).UTC().Format(time.RFC3339)
	for i := 0; i < seeded; i++ {
		seedGmailMessageIdeas(t, d, acctID, fmt.Sprintf("m%03d", i), fmt.Sprintf("thr-%03d", i),
			"a@example.com", "Ann", strings.Repeat("s", fatSubject), "body", same)
	}

	var seenBlock string
	var logged bytes.Buffer
	gen := &fakeGen{reply: func(user string) (string, error) {
		seenBlock = user
		return `{"topics":[]}`, nil
	}}
	// Budget 1: every thread overshoots, so the drain — not the ordinary
	// budget loop — decides everything after the first.
	p := New(d, testCfgWithBudget(1), gen, log.New(&logged, "", 0))
	require.NoError(t, p.runEmailDigests(context.Background(), time.Time{}))
	require.Equal(t, 1, gen.calls)

	const ceiling = tieDrainCharCeiling
	assert.Equal(t, wantRendered, strings.Count(seenBlock, "gmail:"),
		"the drain must stop on bytes, having taken as many tie-mates as the ceiling allows")
	assert.LessOrEqual(t, len(seenBlock), ceiling, "the block must never exceed the byte ceiling")
	assert.Less(t, wantRendered, maxTieDrainUnits,
		"bytes, not units, must be what stopped this drain")

	floor, err := d.IdeasEmailFloor(acctID)
	require.NoError(t, err)
	assert.Equal(t, float64(base+10), floor,
		"the byte ceiling inherits the unit ceiling's disposition: advance anyway, never retreat")

	assert.Contains(t, logged.String(), fmt.Sprintf(
		"ERROR: gmail account %d: %d thread(s) sharing second %d were NOT rendered — the boundary drain stopped at its ceilings (%d units / %d chars,",
		acctID, wantUnrendered, base+10, maxTieDrainUnits, ceiling),
		"a byte-ceiling breach must report the same counted fault as a unit-ceiling breach")
}

// TestIdeas01_RaisedPromptBudgetDoesNotRaiseTheDrainCeiling pins the dangerous
// direction of the byte ceiling's clamp (final-review A5): it is tied to the
// DEFAULT prompt budget, not the configured one, so raising
// ideas.max_prompt_chars cannot raise the protection out from under itself. A
// budget-relative ceiling at 120 000 — a value this codebase already uses for
// catchup.max_prompt_chars — would reach 1.2 MB, past a 200k-token context,
// restoring the over-context stall the bound exists to prevent.
//
// Same fixture as the byte-ceiling guard, with the budget raised 120 000x: the
// drain must still stop at exactly the same place.
func TestIdeas01_RaisedPromptBudgetDoesNotRaiseTheDrainCeiling(t *testing.T) {
	d := newTestDB(t)
	base := time.Now().Add(-time.Hour).Unix()
	acctID := seedGoogleAccount(t, d, float64(base))
	setIdeasEmailFloorRaw(t, d, acctID, float64(base-10))

	const seeded, wantRendered = 8, 5
	const fatSubject = 100000
	same := time.Unix(base+10, 0).UTC().Format(time.RFC3339)
	for i := 0; i < seeded; i++ {
		seedGmailMessageIdeas(t, d, acctID, fmt.Sprintf("m%03d", i), fmt.Sprintf("thr-%03d", i),
			"a@example.com", "Ann", strings.Repeat("s", fatSubject), "body", same)
	}

	var seenBlock string
	gen := &fakeGen{reply: func(user string) (string, error) {
		seenBlock = user
		return `{"topics":[]}`, nil
	}}
	p := New(d, testCfgWithBudget(120000), gen, testLogger())
	require.NoError(t, p.runEmailDigests(context.Background(), time.Time{}))
	require.Equal(t, 1, gen.calls)

	assert.LessOrEqual(t, len(seenBlock), tieDrainCharCeiling,
		"a raised ideas.max_prompt_chars must not raise the drain's byte ceiling")
	assert.Equal(t, wantRendered, strings.Count(seenBlock, "gmail:"),
		"the drain must stop at the same place whatever the configured budget is")

	floor, err := d.IdeasEmailFloor(acctID)
	require.NoError(t, err)
	assert.Equal(t, float64(base+10), floor, "and still advance past the boundary, never retreat")
}

// TestIdeas01_EmailCappedThreadTail_StaysAboveTheFloor covers the
// maxMessagesPerThread cap: a thread longer than the cap is rendered only up
// to it, so the floor must stop at the last message actually rendered, not at
// the thread's newest. The cap keeps the OLDEST messages precisely so the
// remainder can stay above the floor and be mined next run.
//
// There is deliberately NO Jira twin of this test, and nobody forgot to write
// one: it would fail. Gmail's floor is message-granular (renderedEmailWindow
// walks message ids), so a thread's excluded tail is itself an unrendered unit
// and holds the floor below it. Jira's floor is issue-granular
// (renderedJiraFloor matches whole issue keys), so an issue's comments past
// maxCommentsPerIssue cannot hold the floor below the issue and are not
// re-listed — a stated limitation, not an oversight. See
// maxCommentsPerIssue's comment and the "Known limitation" paragraph in
// docs/inventory/ideas.md's IDEA-01.
func TestIdeas01_EmailCappedThreadTail_StaysAboveTheFloor(t *testing.T) {
	d := newTestDB(t)
	base := time.Now().Add(-time.Hour).Unix()
	acctID := seedGoogleAccount(t, d, float64(base))
	setIdeasEmailFloorRaw(t, d, acctID, float64(base-10))

	const extra = 10
	for i := 1; i <= maxMessagesPerThread+extra; i++ {
		seedGmailMessageIdeas(t, d, acctID, fmt.Sprintf("m%03d", i), "thr-1", "a@example.com", "Ann",
			"Long thread", fmt.Sprintf("message %d", i),
			time.Unix(base+int64(i), 0).UTC().Format(time.RFC3339))
	}

	gen := &fakeGen{reply: func(string) (string, error) { return `{"topics":[]}`, nil }}
	p := New(d, testCfg(), gen, testLogger())
	require.NoError(t, p.runEmailDigests(context.Background(), time.Time{}))
	require.Equal(t, 1, gen.calls)

	floor, err := d.IdeasEmailFloor(acctID)
	require.NoError(t, err)
	assert.Equal(t, float64(base+maxMessagesPerThread), floor,
		"the floor stops at the newest message the cap actually rendered")

	left, lerr := d.ListGmailThreadsForExtract(acctID, floor, 0, 500)
	require.NoError(t, lerr)
	assert.Len(t, left, extra, "the messages the cap left out must still be minable")
}

// TestIdeas01_EmailOversizedThread_RenderedAnywayFloorAdvances covers the
// degenerate branch the old code got most wrong (see
// feedback_test_degenerate_clean_exit), in the shape the controller ruled on
// 2026-09-13: a prompt budget too small for even the oldest thread must still
// render that one thread, overshooting the cap, so the pass mines the window
// and its floor moves. Rendering nothing would be honest about the floor and
// still wrong — the account would re-read the same thread forever, mining
// nothing, which loses the window exactly like a dishonest floor does.
func TestIdeas01_EmailOversizedThread_RenderedAnywayFloorAdvances(t *testing.T) {
	d := newTestDB(t)
	base := time.Now().Add(-time.Hour).Unix()
	acctID := seedGoogleAccount(t, d, float64(base))
	setIdeasEmailFloorRaw(t, d, acctID, float64(base-10))
	seedGmailMessageIdeas(t, d, acctID, "m1", "thr-1", "a@example.com", "Ann", "Subj", "body",
		time.Unix(base+10, 0).UTC().Format(time.RFC3339))
	tag := fmt.Sprintf("gmail:%d:thr-1", acctID)

	var logged bytes.Buffer
	var seenBlock string
	gen := &fakeGen{reply: func(user string) (string, error) {
		seenBlock = user
		return fmt.Sprintf(`{"topics":[{"title":"t","summary":"s","ideas":[{"text":"i","author":"Ann","ref":%q}],"decisions":[]}]}`, tag), nil
	}}
	const budget = 1
	p := New(d, testCfgWithBudget(budget), gen, log.New(&logged, "", 0))
	require.NoError(t, p.runEmailDigests(context.Background(), time.Time{}))

	require.Equal(t, 1, gen.calls, "the oversized thread must still be mined")
	assert.Contains(t, seenBlock, "thr-1", "the one oversized thread must be rendered")
	assert.Greater(t, len(seenBlock), budget, "the overshoot is what makes progress possible")

	digests, err := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, err)
	require.Len(t, digests, 1)

	floor, err := d.IdeasEmailFloor(acctID)
	require.NoError(t, err)
	assert.Equal(t, float64(base+10), floor, "the rendered thread's floor must advance, or the pass stalls forever")

	// The operator must be able to see why the prompt outgrew their cap.
	assert.Contains(t, logged.String(), tag, "the overshoot log must name the thread")
	assert.Contains(t, logged.String(), "ideas.max_prompt_chars", "the overshoot log must name the cap")
}

// TestRunEmailDigests_DisabledAccount_Skipped covers the GmailEnabled gate:
// an account with Gmail disabled never triggers a Generate call even with
// new messages seeded under it.
func TestRunEmailDigests_DisabledAccount_Skipped(t *testing.T) {
	d := newTestDB(t)
	base := time.Now().Add(-time.Hour).Unix()
	res, err := d.Exec(`INSERT INTO google_accounts (email, label, gmail_enabled, gmail_last_internal_date)
		VALUES ('disabled@example.com', 'Test', 0, ?)`, float64(base))
	require.NoError(t, err)
	acctID, err := res.LastInsertId()
	require.NoError(t, err)
	setIdeasEmailFloorRaw(t, d, acctID, float64(base-10))
	iso1 := time.Unix(base+10, 0).UTC().Format(time.RFC3339)
	seedGmailMessageIdeas(t, d, acctID, "m1", "thr-1", "a@example.com", "Ann", "Subj", "body", iso1)

	gen := &fakeGen{reply: func(string) (string, error) {
		t.Fatal("generator must not be called for a Gmail-disabled account")
		return "", nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	err = p.runEmailDigests(context.Background(), time.Time{})
	require.NoError(t, err)
	assert.Zero(t, gen.calls)
}
