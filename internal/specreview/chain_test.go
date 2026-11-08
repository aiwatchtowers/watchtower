package specreview

import (
	"database/sql"
	"encoding/json"
	"strconv"
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

// Owner ruling (Discuss branch review): dismissing an As agreed card says
// nothing about a later differs/missing finding on the same passage. The
// closed list keeps the agreement's status in its kind, so the reworded
// repeat check never matches it; a dismissed differs agreement still does.
func TestClosedList_AsAgreedNeverClosesALaterDiffersOnThePassage(t *testing.T) {
	f := newFixture(t)
	first := f.ask(t, "spec", testDoc)
	result := `{"summary":"s","agreements":[
	  {"key":"ag:asagreed0000","text":"Mute for a day","status":"as_agreed","where":{"heading":"Detail","quote":"` + changedQuote + `"}},
	  {"key":"ag:differs00000","text":"Lives locally","status":"differs","where":{"heading":"Decisions","quote":"Mute state lives in the local database"}}],
	  "decided_alone":[],"blind_spots":[],"checks":[],"resolved":[],"chapters":[],"notes":[],"code_read":false,"dropped":0}`
	finishRow(t, f.d, first.ID, "owner", result, nil, nil)
	mark(t, f.d, first.ID, "ag:asagreed0000", db.SpecReviewMarkNotUseful)
	mark(t, f.d, first.ID, "ag:differs00000", "ok")
	second := f.reround(t, first.ID)

	closed, err := ClosedList(f.d, second.ID)
	require.NoError(t, err)
	assert.ElementsMatch(t, []ClosedItem{
		{Key: "ag:asagreed0000", Kind: closedKindAsAgreed, WhereQuote: changedQuote},
		{Key: "ag:differs00000", Kind: KindAgreement, WhereQuote: "Mute state lives in the local database"},
	}, closed)

	src := loopSources(1)
	src.PrevDoc = ""
	src.Closed = closed
	agreement := func(text, status, heading, quote string) string {
		b, _ := json.Marshal(map[string]any{
			"text": text, "status": status, "note": "n", "severity": "major",
			"source": map[string]string{"kind": "decisions", "ref": "", "quote": "Mute state lives in the local database"},
			"where":  map[string]string{"heading": heading, "quote": quote},
		})
		return string(b)
	}
	raw := `{"summary":"s","agreements":[` +
		agreement("The button moved", "differs", "Detail", changedQuote) + "," +
		agreement("Lives on the server now", "missing", "Decisions", "Mute state lives in the local database") + `]}`
	r := parseOne(t, raw, src)
	require.Len(t, r.Agreements, 1)
	assert.Equal(t, "The button moved", r.Agreements[0].Text, "a dismissed As agreed card closes no later differs finding")
	assert.Equal(t, map[string]int{DropDecided: 1}, r.DroppedBy, "a dismissed differs agreement still closes its passage")
}

// A Fix (comment mark) on a key closed earlier in the chain reopens it: it
// leaves the closed list until something closes it again.
func TestClosedList_CommentReopensAClosedKey(t *testing.T) {
	f := newFixture(t)
	r1 := f.ask(t, "spec", "# Spec\n\n## Goals\n\nMute a channel.\n")
	fixed := func(key string) LedgerEntry {
		return entry(key, KindBlindSpot, "Mute a channel.", VerdictResolved, &Reply{Key: key, Reply: ReplyFixed})
	}
	finishRow(t, f.d, r1.ID, "owner", `{}`, nil, []LedgerEntry{fixed("bs:reopened000"), fixed("bs:stays000000"), fixed("bs:again000000")})
	mark(t, f.d, r1.ID, "bs:reopened000", "comment")
	r2 := f.reround(t, r1.ID)
	mark(t, f.d, r2.ID, "bs:again000000", "comment")
	r3 := f.reround(t, r2.ID)
	mark(t, f.d, r3.ID, "bs:again000000", "ok")
	r4 := f.reround(t, r3.ID)

	got, err := ClosedList(f.d, r3.ID)
	require.NoError(t, err)
	assert.Equal(t, []string{"bs:stays000000"}, texts(got, func(c ClosedItem) string { return c.Key }))

	got, err = ClosedList(f.d, r4.ID)
	require.NoError(t, err)
	assert.Equal(t, []string{"bs:stays000000", "bs:again000000"}, texts(got, func(c ClosedItem) string { return c.Key }),
		"closed again later: back on the list, in the order it was last closed")
}

// A thread finding the owner added and then dismissed closes its passage:
// its kind and where-quote come from spec_review_thread_findings, which the
// reviewer never emits.
func TestClosedList_LearnsThreadFindings(t *testing.T) {
	f := newFixture(t)
	r1 := f.ask(t, "spec", testDoc)
	finishRow(t, f.d, r1.ID, "owner", `{}`, nil, nil)
	js := `{"key":"tf:0123456789ab","kind":"decided_alone","severity":"major","title":"t","text":"x","chapter":"ch:1",` +
		`"quote":{"source":"document","text":"` + changedQuote + `"},"speaker":"agent","where":{"heading":"Detail","quote":"` + changedQuote + `"},"thread":"1:1:da:x"}`
	require.NoError(t, f.d.InsertSpecReviewThreadFinding(db.SpecReviewThreadFinding{
		AskID: r1.ID, ItemKey: "tf:0123456789ab", Thread: "1:1:da:x", Finding: js, CreatedAt: "2026-11-08T10:00:00Z"}))
	require.NoError(t, f.d.InsertSpecReviewThreadFinding(db.SpecReviewThreadFinding{
		AskID: r1.ID, ItemKey: "tf:broken00000", Thread: "1:1:da:x", Finding: "{", CreatedAt: "2026-11-08T10:00:00Z"}))
	mark(t, f.d, r1.ID, "tf:0123456789ab", db.SpecReviewMarkNotUseful)
	r2 := f.reround(t, r1.ID)

	st, notes, err := readChain(f.d, r2.ID)
	require.NoError(t, err)
	assert.Equal(t, []ClosedItem{{Key: "tf:0123456789ab", Kind: KindDecidedAlone, WhereQuote: changedQuote}}, st.closed)
	require.Len(t, notes, 1)
	assert.Contains(t, notes[0], "thread finding tf:broken00000 of ask #"+strconv.FormatInt(r1.ID, 10))
}
