package specreview

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/sessionfeed"
)

const (
	// changedQuote is in the paragraph the author rewrote since prevTestDoc.
	changedQuote = "The mute button sits in the channel header"
	// keptQuote is in a paragraph both rounds share.
	keptQuote = "Muting lasts twenty-four hours"
)

// prevTestDoc is testDoc before the author rewrote the mute button's
// paragraph (chapter ch:1, Behaviour); ch:2 (Decisions) is unchanged.
var prevTestDoc = strings.Replace(testDoc, "The mute button sits in the channel header.", "The mute button sits somewhere.", 1)

func loopSources(round int) Sources {
	src := testSources()
	src.LoopRound, src.PrevDoc = round, prevTestDoc
	return src
}

func decidedJSON(text, quote, severity string) string {
	b, _ := json.Marshal(map[string]any{
		"text": text, "note": "n", "severity": severity,
		"where": map[string]string{"heading": "Behaviour", "quote": quote},
	})
	return string(b)
}

func blindJSON(text, quote, severity string) string {
	m := map[string]any{"text": text, "why": "w", "severity": severity}
	if quote != "" {
		m["where"] = map[string]string{"heading": "Behaviour", "quote": quote}
	}
	b, _ := json.Marshal(m)
	return string(b)
}

func concernJSON(chapter, question, severity string) string {
	b, _ := json.Marshal(map[string]string{
		"chapter": chapter, "lens": "promises", "question": question, "answer": "concern", "note": "n", "severity": severity,
	})
	return string(b)
}

func texts[T any](list []T, text func(T) string) []string {
	out := []string{}
	for _, x := range list {
		out = append(out, text(x))
	}
	return out
}

func daTexts(r Result) []string {
	return texts(r.DecidedAlone, func(d DecidedAlone) string { return d.Text })
}
func bsTexts(r Result) []string {
	return texts(r.BlindSpots, func(b BlindSpot) string { return b.Text })
}

func TestUnchangedIn(t *testing.T) {
	prev := "# Doc\n\nThe first paragraph stays.\n\nThe second paragraph\nis here.\n"
	doc := "# Doc\n\nThe first   paragraph\nstays.\n\nThe second paragraph is edited.\n"
	in := unchangedIn(prev, doc)
	assert.True(t, in("first paragraph stays"), "a quote in a kept paragraph")
	assert.False(t, in("second paragraph is edited"), "a quote in an edited paragraph")
	assert.False(t, in("stays. The second paragraph"), "a quote across two paragraphs")
	assert.False(t, in("nowhere in the text"))
	assert.False(t, unchangedIn("", doc)("first paragraph stays"), "no previous document: everything changed")
}

func TestParse_Round2DropsNonBlockerOnUnchangedText(t *testing.T) {
	raw := `{"summary":"s","decided_alone":[` +
		decidedJSON("old text major", keptQuote, "major") + "," +
		decidedJSON("old text blocker", keptQuote, "blocker") + "," +
		decidedJSON("changed text major", changedQuote, "major") + `],"checks":[` +
		concernJSON("ch:1", "Changed chapter?", "minor") + "," +
		concernJSON("ch:2", "Unchanged chapter?", "major") + "," +
		`{"chapter":"ch:2","lens":"promises","question":"Fine?","answer":"ok","note":"n"}]}`
	r := parseOne(t, raw, loopSources(2))
	assert.Equal(t, []string{"old text blocker", "changed text major"}, daTexts(r))
	assert.Equal(t, []string{"Changed chapter?", "Fine?"}, texts(r.Checks, func(c Check) string { return c.Question }))
	assert.Equal(t, 2, r.Dropped)
	assert.Equal(t, map[string]int{DropUnchangedText: 2}, r.DroppedBy)
}

func TestParse_Round2UnanchoredNeedsNewSource(t *testing.T) {
	missing := func(text, kind, ref, quote string) string {
		return `{"text":"` + text + `","status":"missing","severity":"major","source":{"kind":"` + kind +
			`","ref":"` + ref + `","quote":"` + quote + `"},"where":null}`
	}
	src := loopSources(2)
	src.NewRefs = map[string]bool{"ask:1": true}
	raw := `{"summary":"s","agreements":[` +
		missing("old source", "conversation", "entry:1", "mute a channel for a day") + "," +
		missing("new source", "ask", "ask:1", "keep the state local") + `],"blind_spots":[` +
		blindJSON("unanchored major", "", "major") + "," + blindJSON("unanchored blocker", "", "blocker") + `]}`
	r := parseOne(t, raw, src)
	assert.Equal(t, []string{"new source"}, texts(r.Agreements, func(a Agreement) string { return a.Text }))
	assert.Equal(t, []string{"unanchored blocker"}, bsTexts(r))
	assert.Equal(t, map[string]int{DropUnchangedText: 2}, r.DroppedBy)
}

func TestParse_Round3DropsMinorAndEmptySeverity(t *testing.T) {
	src := loopSources(3)
	src.PrevOpenKeys = map[string]bool{itemKey("bs:", "carried minor", keptQuote): true}
	raw := `{"summary":"s","blind_spots":[` +
		blindJSON("new minor", changedQuote, "minor") + "," +
		blindJSON("new no severity", changedQuote, "") + "," +
		blindJSON("new major", changedQuote, "major") + "," +
		blindJSON("carried minor", keptQuote, "minor") + `]}`
	r := parseOne(t, raw, src)
	assert.Equal(t, []string{"new major", "carried minor"}, bsTexts(r))
	assert.Equal(t, map[string]int{DropMinorLate: 2}, r.DroppedBy)
	assert.Equal(t, 2, r.Dropped)

	// Round 2 has no floor yet.
	src.LoopRound = 2
	r = parseOne(t, raw, src)
	assert.Len(t, r.BlindSpots, 4)
	assert.Nil(t, r.DroppedBy)
}

func TestParse_ClosedKeyAndRewordedRepeatDropped(t *testing.T) {
	src := loopSources(2)
	closedKey := itemKey("da:", "closed finding", changedQuote)
	src.Closed = []ClosedItem{
		// The where-quote is stored as the reviewer wrote it.
		{Key: closedKey, Kind: KindDecidedAlone, WhereQuote: "The mute button\n  sits in the channel header"},
	}
	src.KnownKeys = map[string]bool{closedKey: true}
	raw := `{"summary":"s","decided_alone":[` +
		decidedJSON("closed finding", changedQuote, "blocker") + "," +
		decidedJSON("the same finding reworded", changedQuote, "major") + `],"blind_spots":[` +
		blindJSON("same place, other kind", changedQuote, "major") + `]}`
	r := parseOne(t, raw, src)
	assert.Empty(t, r.DecidedAlone)
	assert.Equal(t, []string{"same place, other kind"}, bsTexts(r))
	assert.Equal(t, map[string]int{DropDecided: 2}, r.DroppedBy)
}

// Outside a loop round nothing is guarded; round 1 of a loop with no
// previous document (the classic first round) only keeps closed items out.
func TestParse_NotALoopRoundUnchanged(t *testing.T) {
	src := loopSources(0)
	src.Closed = []ClosedItem{{Key: itemKey("bs:", "closed", keptQuote), Kind: KindBlindSpot, WhereQuote: keptQuote}}
	raw := `{"summary":"s","blind_spots":[` +
		blindJSON("closed", keptQuote, "minor") + "," +
		blindJSON("on unchanged text", "and then expires by itself", "") + "," +
		blindJSON("unanchored", "", "minor") + `]}`
	r := parseOne(t, raw, src)
	assert.Len(t, r.BlindSpots, 3)
	assert.Zero(t, r.Dropped)
	assert.Nil(t, r.DroppedBy)

	src.LoopRound, src.PrevDoc = 1, ""
	r = parseOne(t, raw, src)
	assert.Equal(t, []string{"on unchanged text", "unanchored"}, bsTexts(r))
	assert.Equal(t, map[string]int{DropDecided: 1}, r.DroppedBy)

	// Round 1 of a loop after the owner's answer has a previous document:
	// the changed-text guard runs.
	src.PrevDoc = prevTestDoc
	r = parseOne(t, raw, src)
	assert.Empty(t, r.BlindSpots)
	assert.Equal(t, map[string]int{DropDecided: 1, DropUnchangedText: 2}, r.DroppedBy)
}

// queueLoopRound files a re-round on prev with snapshot doc, queued as
// round of an author loop under LoopRulesOpen.
func (f *fixture) queueLoopRound(t *testing.T, prev int64, round int, doc string) *db.OwnerAsk {
	t.Helper()
	return f.queueLoopRoundRules(t, prev, round, doc, LoopRulesOpen)
}

func (f *fixture) queueLoopRoundRules(t *testing.T, prev int64, round int, doc string, rules int) *db.OwnerAsk {
	t.Helper()
	var id int64
	require.NoError(t, f.d.WithTx(func(tx *sql.Tx) error {
		var err error
		id, _, err = f.d.InsertOwnerAsk(tx, db.OwnerAsk{
			WorkbenchID: f.wb, SessionID: sql.NullInt64{Int64: f.session, Valid: true},
			TargetID: sql.NullInt64{Int64: f.tgt, Valid: true}, Kind: "review", Title: fmt.Sprintf("Round %d", round),
			DocPath: "docs/specs/x-design.md", DocSnapshot: doc, DocType: "spec",
			PreviousAskID: sql.NullInt64{Int64: prev, Valid: prev != 0},
		})
		if err != nil {
			return err
		}
		return f.d.QueueSpecReview(tx, id, runNow, &db.SpecLoopStart{Round: round, LoopRules: rules})
	}))
	a, err := f.d.GetOwnerAskByID(id)
	require.NoError(t, err)
	return a
}

// A key the reviewer confirmed fixed in round 2 of a loop stays closed in
// round 4 of the same loop: the earlier rounds' ledgers carry it.
func TestBuildInputs_KeyClosedEarlierInTheLoopDropped(t *testing.T) {
	f := newFixture(t)
	key := itemKey("bs:", "Threads are not covered", changedQuote)
	item := AuthorItem{Key: key, Kind: KindBlindSpot, Text: "Threads are not covered", Round: 1, Where: &Anchor{Heading: "Behaviour", Quote: changedQuote}}
	fixed := LedgerEntry{AuthorItem: item, Verdict: VerdictResolved, Settled: 2}
	fixed.Reply = &Reply{Key: key, Reply: ReplyFixed}

	r1 := f.queueLoopRound(t, 0, 1, testDoc)
	finishRow(t, f.d, r1.ID, "author", `{}`, []AuthorItem{item}, nil)
	r2 := f.queueLoopRound(t, r1.ID, 2, testDoc)
	finishRow(t, f.d, r2.ID, "author", `{}`, []AuthorItem{{Key: "bs:other000000", Kind: KindBlindSpot, Round: 2}}, []LedgerEntry{fixed})
	r3 := f.queueLoopRound(t, r2.ID, 3, testDoc)
	finishRow(t, f.d, r3.ID, "author", `{}`, []AuthorItem{{Key: "bs:other000000", Kind: KindBlindSpot, Round: 2}}, []LedgerEntry{fixed})
	r4 := f.queueLoopRound(t, r3.ID, 4, testDoc)

	src, _, _, err := BuildInputs(context.Background(), f.deps(nil), r4, f.folder)
	require.NoError(t, err)
	assert.Equal(t, 4, src.LoopRound)
	r := parseOne(t, `{"summary":"s","blind_spots":[`+blindJSON("Threads are not covered", changedQuote, "blocker")+`]}`, src)
	assert.Empty(t, r.BlindSpots)
	assert.Equal(t, map[string]int{DropDecided: 1}, r.DroppedBy)
}

// BuildInputs hands Parse the loop round, the previous round's document and
// the sources that are new since the previous ask was filed.
func TestBuildInputs_LoopRoundPrevDocNewRefs(t *testing.T) {
	f := newFixture(t)
	prevAt := runNow.Add(-time.Hour)
	tid := sql.NullInt64{Int64: f.tgt, Valid: true}
	oldC, err := f.d.AddWorkbenchComment(db.WorkbenchComment{WorkbenchID: f.wb, TargetID: tid, Author: "owner", Body: "An old comment on the mute"})
	require.NoError(t, err)
	newC, err := f.d.AddWorkbenchComment(db.WorkbenchComment{WorkbenchID: f.wb, TargetID: tid, Author: "owner", Body: "A new comment on the mute"})
	require.NoError(t, err)
	stamp := func(table string, id int64, col string, at time.Time) {
		_, err := f.d.Exec(`UPDATE `+table+` SET `+col+` = ? WHERE id = ?`, at.UTC().Format(time.RFC3339), id)
		require.NoError(t, err)
	}
	stamp("project_comments", oldC, "created_at", prevAt.Add(-time.Minute))
	stamp("project_comments", newC, "created_at", prevAt.Add(time.Minute))
	f.feed = []sessionfeed.Entry{
		{ID: "old", Kind: sessionfeed.KindOwner, Text: "An old line", At: prevAt.Add(-time.Minute)},
		{ID: "new", Kind: sessionfeed.KindOwner, Text: "A new line", At: prevAt.Add(time.Minute)},
		{ID: "notime", Kind: sessionfeed.KindOwner, Text: "A line with no time"},
	}

	r1 := f.queueLoopRound(t, 0, 1, prevTestDoc)
	stamp("owner_asks", r1.ID, "created_at", prevAt)
	_, err = f.d.Exec(`UPDATE owner_asks SET status = 'answered', answer = '{"verdict":"changes"}' WHERE id = ?`, r1.ID)
	require.NoError(t, err)
	stamp("owner_asks", r1.ID, "answered_at", prevAt.Add(30*time.Minute))
	r2 := f.queueLoopRound(t, r1.ID, 2, testDoc)

	src, _, _, err := BuildInputs(context.Background(), f.deps(nil), r2, f.folder)
	require.NoError(t, err)
	assert.Equal(t, 2, src.LoopRound)
	assert.Equal(t, prevTestDoc, src.PrevDoc)
	assert.Equal(t, map[string]bool{
		"entry:new": true, fmt.Sprintf("comment:%d", newC): true, fmt.Sprintf("ask:%d", r1.ID): true,
	}, src.NewRefs)

	// Not a loop round: the round stays 0.
	src, _, _, err = BuildInputs(context.Background(), f.deps(nil), f.ask(t, "spec", testDoc), f.folder)
	require.NoError(t, err)
	assert.Zero(t, src.LoopRound)
	assert.Empty(t, src.PrevDoc)
}

// A loop running under the legacy rules keeps the Parse it started with: in
// its round 2 a non-blocker new finding on unchanged text stays.
func TestBuildInputs_LegacyLoopHasNoDriftGuards(t *testing.T) {
	f := newFixture(t)
	r1 := f.queueLoopRoundRules(t, 0, 1, testDoc, LoopRulesLegacy)
	finishRow(t, f.d, r1.ID, "author", `{}`, nil, nil)
	r2 := f.queueLoopRoundRules(t, r1.ID, 2, testDoc, LoopRulesLegacy)

	src, _, _, err := BuildInputs(context.Background(), f.deps(nil), r2, f.folder)
	require.NoError(t, err)
	assert.Zero(t, src.LoopRound)
	assert.Equal(t, testDoc, src.PrevDoc)
	r := parseOne(t, `{"summary":"s","blind_spots":[`+blindJSON("old text minor", keptQuote, "minor")+`]}`, src)
	assert.Equal(t, []string{"old text minor"}, bsTexts(r))
	assert.Nil(t, r.DroppedBy)
}
