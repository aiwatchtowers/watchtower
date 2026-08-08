package ideas

import (
	"context"
	"fmt"
	"io"
	"log"
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
	err := p.runEmailDigests(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, gen.calls)

	digests, err := d.ListStreamDigestsAfter(0)
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
	err := p.runEmailDigests(context.Background())
	require.Error(t, err)

	digests, err := d.ListStreamDigestsAfter(0)
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
	err := p.runEmailDigests(context.Background())
	require.NoError(t, err)
	assert.Zero(t, gen.calls)

	digests, err := d.ListStreamDigestsAfter(0)
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
	err := p.runEmailDigests(context.Background())
	require.NoError(t, err)
	assert.Zero(t, gen.calls)

	floor, err := d.IdeasEmailFloor(acctID)
	require.NoError(t, err)
	assert.Equal(t, float64(base), floor)

	digests, err := d.ListStreamDigestsAfter(0)
	require.NoError(t, err)
	assert.Empty(t, digests)
}

// TestIdeas02_EmailHallucinatedRefDropped covers ref validation: a
// candidate whose ref does not match a rendered thread tag is dropped, but
// the pass still completes normally (row inserted, floor advanced) since the
// AI call itself succeeded — only the untrustworthy candidate is discarded.
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
	err := p.runEmailDigests(context.Background())
	require.NoError(t, err)

	digests, err := d.ListStreamDigestsAfter(0)
	require.NoError(t, err)
	require.Len(t, digests, 1)
	assert.Equal(t, "[]", digests[0].TopicsJSON)

	floor, err := d.IdeasEmailFloor(acctID)
	require.NoError(t, err)
	assert.Equal(t, float64(base+10), floor)
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
	err = p.runEmailDigests(context.Background())
	require.NoError(t, err)
	assert.Zero(t, gen.calls)
}
