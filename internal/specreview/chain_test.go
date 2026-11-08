package specreview

import (
	"database/sql"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// finishRow stores a done review row for askID with result, loop columns
// and the given loop state.
func finishRow(t *testing.T, d *db.DB, askID int64, loop string, result string, open []AuthorItem, ledger []LedgerEntry) {
	t.Helper()
	openJS, err := encodeList(open)
	require.NoError(t, err)
	ledgerJS, err := encodeList(ledger)
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE spec_reviews SET status = 'done', loop = ?, result = ?, open_items = ?, ledger = ?
		WHERE ask_id = ?`, loop, result, openJS, ledgerJS, askID)
	require.NoError(t, err)
}

func mark(t *testing.T, d *db.DB, askID int64, key, state string) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO spec_review_marks (ask_id, item_key, state, updated_at) VALUES (?, ?, ?, 'x')`, askID, key, state)
	require.NoError(t, err)
}

func entry(key, kind, quote, verdict string, reply *Reply) LedgerEntry {
	it := AuthorItem{Key: key, Kind: kind, Text: "t " + key, Round: 1, Reply: reply}
	if quote != "" {
		it.Where = &Anchor{Heading: "Goals", Quote: quote}
	}
	return LedgerEntry{AuthorItem: it, Verdict: verdict, Settled: 2}
}

const chainResult = `{"summary":"s","agreements":[
    {"key":"ag:okmark00000","text":"A mute lasts a day","status":"differs","where":{"heading":"Goals","quote":"Mute a channel."}},
    {"key":"ag:comment0000","text":"Commented","status":"missing"}],
  "decided_alone":[{"key":"da:notuseful00","text":"Muted threads","where":{"heading":"Goals","quote":"Threads too."}}],
  "blind_spots":[],"checks":[{"key":"ck:okcheck0000","chapter":"ch:1","lens":"l","question":"Does it expire?","answer":"concern"}],
  "resolved":[],"chapters":[],"notes":[],"code_read":false,"dropped":0}`

func TestClosedList_FixedSkippedAuthorRight(t *testing.T) {
	f := newFixture(t)
	first := f.ask(t, "spec", "# Spec\n\n## Goals\n\nMute a channel.\n")
	finishRow(t, f.d, first.ID, "owner", chainResult, nil, []LedgerEntry{
		entry("bs:fixed000000", KindBlindSpot, "Restart.", VerdictResolved, &Reply{Key: "bs:fixed000000", Reply: ReplyFixed}),
		entry("bs:noreply0000", KindBlindSpot, "Silence.", VerdictResolved, nil),
		entry("da:disagreeres", KindDecidedAlone, "Other.", VerdictResolved, &Reply{Key: "da:disagreeres", Reply: ReplyDisagree, Note: "no"}),
		entry("da:authright00", KindDecidedAlone, "Disputed text.", VerdictDisputed, &Reply{Key: "da:authright00", Reply: ReplyDisagree, Note: "asked"}),
		entry("da:disputed000", KindDecidedAlone, "Open dispute.", VerdictDisputed, &Reply{Key: "da:disputed000", Reply: ReplyDisagree, Note: "asked"}),
		entry("ck:unsettled00", KindCheck, "", VerdictUnsettled, nil),
	})
	mark(t, f.d, first.ID, "ag:okmark00000", "ok")
	mark(t, f.d, first.ID, "da:notuseful00", db.SpecReviewMarkNotUseful)
	mark(t, f.d, first.ID, "ck:okcheck0000", "ok")
	mark(t, f.d, first.ID, "da:authright00", "ok")
	mark(t, f.d, first.ID, "ag:comment0000", "comment")
	second := f.reround(t, first.ID)
	mark(t, f.d, second.ID, "da:ownmark0000", "ok") // the ask under review is not earlier

	got, err := ClosedList(f.d, second.ID)
	require.NoError(t, err)
	assert.ElementsMatch(t, []ClosedItem{
		{Key: "bs:fixed000000", Kind: KindBlindSpot, WhereQuote: "Restart."},
		{Key: "bs:noreply0000", Kind: KindBlindSpot, WhereQuote: "Silence."},
		{Key: "da:authright00", Kind: KindDecidedAlone, WhereQuote: "Disputed text."},
		{Key: "ag:okmark00000", Kind: KindAgreement, WhereQuote: "Mute a channel."},
		{Key: "da:notuseful00", Kind: KindDecidedAlone, WhereQuote: "Threads too."},
		{Key: "ck:okcheck0000", Kind: KindCheck, WhereQuote: ""},
	}, got)

	// The root of a chain has nothing earlier.
	got, err = ClosedList(f.d, first.ID)
	require.NoError(t, err)
	assert.Empty(t, got)
}

// A key closed in a loop that ended before the owner answered is on the list
// of the next loop's first round, which follows the owner's answer.
func TestClosedList_CarriesAcrossLoops(t *testing.T) {
	f := newFixture(t)
	r1 := f.ask(t, "spec", "# Spec\n\n## Goals\n\nMute a channel.\n")
	open := []AuthorItem{{Key: "bs:loopone0000", Kind: KindBlindSpot, Text: "Restart", Round: 1, Where: &Anchor{Heading: "Goals", Quote: "Mute a channel."}}}
	finishRow(t, f.d, r1.ID, "author", `{}`, open, nil)
	r2 := f.reround(t, r1.ID)
	require.NoError(t, f.d.WithTx(func(tx *sql.Tx) error {
		return f.d.QueueSpecReview(tx, r2.ID, runNow, &db.SpecLoopStart{Round: 2})
	}))
	fixed := entry("bs:loopone0000", KindBlindSpot, "Mute a channel.", VerdictResolved, &Reply{Key: "bs:loopone0000", Reply: ReplyFixed})
	finishRow(t, f.d, r2.ID, "owner", `{}`, nil, []LedgerEntry{fixed})
	_, err := f.d.Exec(`UPDATE owner_asks SET status = 'answered', answer = '{"verdict":"changes"}' WHERE id = ?`, r2.ID)
	require.NoError(t, err)
	r3 := f.reround(t, r2.ID)
	require.NoError(t, f.d.WithTx(func(tx *sql.Tx) error {
		return f.d.QueueSpecReview(tx, r3.ID, runNow, &db.SpecLoopStart{Round: 1, LoopRules: LoopRulesOpen})
	}))

	got, err := ClosedList(f.d, r3.ID)
	require.NoError(t, err)
	assert.Equal(t, []ClosedItem{{Key: "bs:loopone0000", Kind: KindBlindSpot, WhereQuote: "Mute a channel."}}, got)
}

// A key seen in several rounds keeps the latest where-quote and kind known
// for it, so a reworded repeat is compared with the text as it stands now.
func TestClosedList_LatestWhereQuote(t *testing.T) {
	f := newFixture(t)
	r1 := f.ask(t, "spec", "# Spec\n\n## Goals\n\nMute a channel.\n")
	open := []AuthorItem{{Key: "bs:moved000000", Kind: KindBlindSpot, Text: "Restart", Round: 1, Where: &Anchor{Heading: "Goals", Quote: "Mute a channel."}}}
	finishRow(t, f.d, r1.ID, "author", `{}`, open, nil)
	r2 := f.reround(t, r1.ID)
	require.NoError(t, f.d.WithTx(func(tx *sql.Tx) error {
		return f.d.QueueSpecReview(tx, r2.ID, runNow, &db.SpecLoopStart{Round: 2})
	}))
	moved := entry("bs:moved000000", KindBlindSpot, "Mute, now for a day.", VerdictResolved, nil)
	finishRow(t, f.d, r2.ID, "owner", `{}`, nil, []LedgerEntry{moved})
	r3 := f.reround(t, r2.ID)

	got, err := ClosedList(f.d, r3.ID)
	require.NoError(t, err)
	assert.Equal(t, []ClosedItem{{Key: "bs:moved000000", Kind: KindBlindSpot, WhereQuote: "Mute, now for a day."}}, got)
}
