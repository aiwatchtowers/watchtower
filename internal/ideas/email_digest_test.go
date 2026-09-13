package ideas

import (
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
	full, _ := renderEmailBlock(acctID, groupThreads(window), 1000000)
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

// TestIdeas01_EmailNothingRendered_NoCallNoRowFloorUnchanged covers the
// degenerate branch the old code got most wrong (see
// feedback_test_degenerate_clean_exit): a prompt budget too small for even the
// oldest thread renders nothing, so there is nothing to ask the model about
// and nothing this run may claim — no AI call, no row, floor frozen.
func TestIdeas01_EmailNothingRendered_NoCallNoRowFloorUnchanged(t *testing.T) {
	d := newTestDB(t)
	base := time.Now().Add(-time.Hour).Unix()
	acctID := seedGoogleAccount(t, d, float64(base))
	setIdeasEmailFloorRaw(t, d, acctID, float64(base-10))
	seedGmailMessageIdeas(t, d, acctID, "m1", "thr-1", "a@example.com", "Ann", "Subj", "body",
		time.Unix(base+10, 0).UTC().Format(time.RFC3339))

	gen := &fakeGen{reply: func(string) (string, error) {
		t.Fatal("generator must not be called when the budget fits no thread")
		return "", nil
	}}
	p := New(d, testCfgWithBudget(1), gen, testLogger())
	require.NoError(t, p.runEmailDigests(context.Background(), time.Time{}))
	assert.Zero(t, gen.calls)

	digests, err := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, err)
	assert.Empty(t, digests)

	floor, err := d.IdeasEmailFloor(acctID)
	require.NoError(t, err)
	assert.Equal(t, float64(base-10), floor, "nothing was rendered, so the floor must not move at all")
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
