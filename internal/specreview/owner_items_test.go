package specreview

import (
	"database/sql"
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/asks"
	"watchtower/internal/db"
)

// The owner's items of a loop after Request changes (spec
// 2026-11-08-spec-review-discuss-design §1, D8).

const (
	seedQuote   = "Muting lasts twenty-four hours"
	marginQuote = "and then expires by itself."
)

// seedKey is the key the reviewer gives the blind spot the owner commented on.
var seedKey = itemKey("bs:", "Muted threads", seedQuote)

// seedResult is the visible review the owner answered: a blind spot the owner
// asks to fix and a decision the owner skipped.
var seedResult = `{"summary":"s","agreements":[],"checks":[],"resolved":[],
  "decided_alone":[{"key":"da:skipped0000","text":"State is local","note":"n","where":{"heading":"Behaviour","quote":"and then expires"}}],
  "blind_spots":[{"key":"` + seedKey + `","text":"Muted threads","why":"threads mute too","severity":"minor",
    "where":{"heading":"Behaviour","quote":"` + seedQuote + `"}}]}`

// seedAnswer is the owner's Request changes: a Fix comment on the blind
// spot, a margin comment, and a comment on a key the owner also skipped.
func seedAnswer(verdict string) string {
	a := asks.Answer{Verdict: verdict, Comments: []asks.Comment{
		{Body: "Name the threads", Heading: "Behaviour", ItemKey: seedKey, Quote: seedQuote},
		{Body: "Say what expires", Heading: "Behaviour", Quote: marginQuote},
		{Body: "Keep it", Heading: "Behaviour", ItemKey: "da:skipped0000", Quote: "and then expires"},
	}}
	js, err := json.Marshal(a)
	if err != nil {
		panic(err)
	}
	return string(js)
}

// threadFinding stores a finding the owner added from a thread on askID.
func threadFinding(t *testing.T, d *db.DB, askID int64, key, finding string) {
	t.Helper()
	require.NoError(t, d.InsertSpecReviewThreadFinding(db.SpecReviewThreadFinding{
		AskID: askID, ItemKey: key, Thread: "1:" + key, Finding: finding, CreatedAt: "2026-10-25T09:00:00Z",
	}))
}

// seededChain files a review the owner had (loop ended) and answered with
// verdict, then the author's next version as round 1 of a new hidden loop.
// doc is the next version's snapshot.
func seededChain(t *testing.T, f *fixture, verdict, doc string, round int) (first, second int64) {
	t.Helper()
	first = f.ask(t, "spec", runDoc).ID
	finishRow(t, f.d, first, "owner", seedResult, nil, nil)
	_, err := f.d.Exec(`UPDATE spec_reviews SET loop_end = 'settled', round = 1 WHERE ask_id = ?`, first)
	require.NoError(t, err)
	_, err = f.d.Exec(`UPDATE owner_asks SET status = 'answered', answer = ?, answered_at = '2026-10-25T09:30:00Z' WHERE id = ?`,
		seedAnswer(verdict), first)
	require.NoError(t, err)
	mark(t, f.d, first, "da:skipped0000", "ok")
	threadFinding(t, f.d, first, "tf:thread00000",
		`{"key":"tf:thread00000","kind":"blind_spot","severity":"major","title":"Restart","text":"Expiry after a restart",`+
			`"quote":{"source":"thread","text":"what about a restart"},"speaker":"owner","where":null,"thread":"1:tf:thread00000"}`)
	threadFinding(t, f.d, first, "tf:skipped0000",
		`{"key":"tf:skipped0000","kind":"missing","severity":"minor","title":"Phone","text":"Mutes on the phone",`+
			`"quote":{"source":"thread","text":"and on the phone"},"speaker":"owner","where":null}`)
	mark(t, f.d, first, "tf:skipped0000", "ok")
	require.NoError(t, f.d.WithTx(func(tx *sql.Tx) error {
		second, _, err = f.d.InsertOwnerAsk(tx, db.OwnerAsk{
			WorkbenchID: f.wb, SessionID: sql.NullInt64{Int64: f.session, Valid: true},
			TargetID: sql.NullInt64{Int64: f.tgt, Valid: true}, Kind: "review", Title: "Round after changes",
			DocPath: "docs/specs/x-design.md", DocSnapshot: doc, DocType: "spec",
			PreviousAskID: sql.NullInt64{Int64: first, Valid: true},
		})
		if err != nil {
			return err
		}
		return f.d.QueueSpecReview(tx, second, runNow, &db.SpecLoopStart{Round: round, LoopRules: LoopRulesOpen})
	}))
	return first, second
}

func seedOf(t *testing.T, d *db.DB, askID int64) []AuthorItem {
	t.Helper()
	ask, err := d.GetOwnerAskByID(askID)
	require.NoError(t, err)
	seed, _, err := SeedOf(d, ask)
	require.NoError(t, err)
	return seed
}

var marginKey = itemKey("oc:", "Say what expires", marginQuote)

func TestSeedOf_ChangesAnswerSeedsOwnerItems(t *testing.T) {
	f := newFixture(t)
	_, second := seededChain(t, f, asks.VerdictChanges, runDoc, 1)

	seed := seedOf(t, f.d, second)
	require.Len(t, seed, 3, "the Fix comment, the margin comment and the thread finding; the skipped keys stay out")

	assert.Equal(t, AuthorItem{
		Key: seedKey, Kind: KindBlindSpot, Text: "Muted threads", Note: "Name the threads",
		Where: &Anchor{Heading: "Behaviour", Quote: seedQuote}, Round: 1, Severity: SeverityMinor, Owner: true,
	}, seed[0])
	assert.Equal(t, AuthorItem{
		Key: marginKey, Kind: KindOwnerComment, Text: "Say what expires",
		Where: &Anchor{Heading: "Behaviour", Quote: marginQuote}, Round: 1, Owner: true,
	}, seed[1])
	assert.Equal(t, AuthorItem{
		Key: "tf:thread00000", Kind: KindBlindSpot, Text: "Expiry after a restart", Round: 1, Severity: SeverityMajor, Owner: true,
	}, seed[2])
}

func TestSeedOf_ApprovedSeedsNothing(t *testing.T) {
	f := newFixture(t)
	_, second := seededChain(t, f, asks.VerdictApproved, runDoc, 1)
	assert.Nil(t, seedOf(t, f.d, second))
}

func TestSeedOf_NotRound1SeedsNothing(t *testing.T) {
	f := newFixture(t)
	_, second := seededChain(t, f, asks.VerdictChanges, runDoc, 2)
	assert.Nil(t, seedOf(t, f.d, second))

	// Nor a visible review (no loop) after the same answer.
	f2 := newFixture(t)
	_, plain := seededChain(t, f2, asks.VerdictChanges, runDoc, 1)
	_, err := f2.d.Exec(`UPDATE spec_reviews SET loop = '', round = 0 WHERE ask_id = ?`, plain)
	require.NoError(t, err)
	assert.Nil(t, seedOf(t, f2.d, plain))
}

// The owner answered changes but left no comment and no thread finding: the
// new loop has an empty seed, not the previous loop's items.
func TestSeedOf_ChangesWithoutItemsIsEmpty(t *testing.T) {
	f := newFixture(t)
	first, second := seededChain(t, f, asks.VerdictChanges, runDoc, 1)
	_, err := f.d.Exec(`UPDATE owner_asks SET answer = '{"verdict":"changes","note":"redo it"}' WHERE id = ?`, first)
	require.NoError(t, err)
	_, err = f.d.Exec(`DELETE FROM spec_review_thread_findings WHERE ask_id = ?`, first)
	require.NoError(t, err)
	seed := seedOf(t, f.d, second)
	assert.NotNil(t, seed)
	assert.Empty(t, seed)
}

// Stored JSON that does not decode never blocks the seed: the comments keep
// the owner's words, a broken thread finding is left out.
func TestSeedOf_UndecodableRowsGiveWhatTheyCan(t *testing.T) {
	f := newFixture(t)
	first, second := seededChain(t, f, asks.VerdictChanges, runDoc, 1)
	_, err := f.d.Exec(`UPDATE spec_reviews SET result = '{broken', ledger = '[broken' WHERE ask_id = ?`, first)
	require.NoError(t, err)
	_, err = f.d.Exec(`UPDATE spec_review_thread_findings SET finding = '{broken' WHERE ask_id = ?`, first)
	require.NoError(t, err)

	ask, err := f.d.GetOwnerAskByID(second)
	require.NoError(t, err)
	seed, notes, err := SeedOf(f.d, ask)
	require.NoError(t, err)
	require.Len(t, seed, 2)
	assert.Len(t, notes, 4, "the findings, the ledger and each thread finding are named: %v", notes)
	for _, n := range notes {
		assert.Contains(t, n, "left out of the owner's items")
	}
	assert.Equal(t, [2]string{seedKey, KindOwnerComment}, [2]string{seed[0].Key, seed[0].Kind})
	assert.Equal(t, "Name the threads", seed[0].Text)
	assert.Equal(t, marginKey, seed[1].Key)
}

// A plain Fix (no comment text, no quote) on a finding seeds the finding as
// it stands: its text and its own anchor. A comment with no words and no
// finding behind it has nothing to check and is left out.
func TestSeedOf_PlainFixKeepsTheFinding(t *testing.T) {
	f := newFixture(t)
	first, second := seededChain(t, f, asks.VerdictChanges, runDoc, 1)
	js, err := json.Marshal(asks.Answer{Verdict: asks.VerdictChanges, Comments: []asks.Comment{
		{ItemKey: seedKey},
		{ItemKey: "ag:gone00000000"},
		{Heading: "Behaviour"},
	}})
	require.NoError(t, err)
	_, err = f.d.Exec(`UPDATE owner_asks SET answer = ? WHERE id = ?`, string(js), first)
	require.NoError(t, err)
	_, err = f.d.Exec(`DELETE FROM spec_review_thread_findings WHERE ask_id = ?`, first)
	require.NoError(t, err)

	seed := seedOf(t, f.d, second)
	require.Len(t, seed, 1)
	assert.Equal(t, AuthorItem{
		Key: seedKey, Kind: KindBlindSpot, Text: "Muted threads",
		Where: &Anchor{Heading: "Behaviour", Quote: seedQuote}, Round: 1, Severity: SeverityMinor, Owner: true,
	}, seed[0])
}

// An answer that does not decode is not Request changes: no seed, and the
// round's notes say why instead of dropping it silently.
func TestSeedOf_UndecodableAnswerIsANote(t *testing.T) {
	f := newFixture(t)
	first, second := seededChain(t, f, asks.VerdictChanges, runDoc, 1)
	_, err := f.d.Exec(`UPDATE owner_asks SET answer = '{broken' WHERE id = ?`, first)
	require.NoError(t, err)
	ask, err := f.d.GetOwnerAskByID(second)
	require.NoError(t, err)
	seed, notes, err := SeedOf(f.d, ask)
	require.NoError(t, err)
	assert.Nil(t, seed)
	require.Len(t, notes, 1)
	assert.Contains(t, notes[0], "the answer on ask #")

	prev, err := f.d.GetOwnerAskByID(first)
	require.NoError(t, err)
	changes, err := AnsweredChanges(prev)
	assert.False(t, changes)
	assert.Error(t, err)
}
