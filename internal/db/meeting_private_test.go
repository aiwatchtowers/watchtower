package db

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Guards for MEETPRIV-02 (docs/inventory/meetings.md): a private recording,
// and the meeting_recaps row it owns, never reach a prompt-feeding reader.

// meetPrivFixture is one public and one private recording, each linked to
// its own event and owning that event's recap, plus a pasted recap with no
// recording. Every row is created inside [1970-01-01T00:16:40Z, 00:33:20Z]
// (unix 1000..2000) for the catch-up window.
type meetPrivFixture struct {
	publicID, privateID           int64
	publicRecapID, privateRecapID int64
	pastedRecapID                 int64
}

func seedMeetPriv(t *testing.T, d *DB) meetPrivFixture {
	t.Helper()
	var f meetPrivFixture
	_, err := d.Exec(`INSERT INTO calendar_calendars (id, name) VALUES ('cal1', 'Primary')`)
	require.NoError(t, err)
	for _, ev := range []string{"E-pub", "E-priv", "E-paste"} {
		_, err = d.Exec(`INSERT INTO calendar_events (id, calendar_id, title, start_time, end_time)
			VALUES (?, 'cal1', ?, '1970-01-01T00:20:00Z', '1970-01-01T00:21:00Z')`, ev, "title "+ev)
		require.NoError(t, err)
	}
	insert := func(eventID, title, text string, private bool) int64 {
		res, err := d.Exec(`INSERT INTO meeting_transcripts (event_id, title, transcript_text, summary_json, private, created_at)
			VALUES (?, ?, ?, '{"summary":"s"}', ?, '1970-01-01T00:20:00Z')`, eventID, title, text, private)
		require.NoError(t, err)
		id, err := res.LastInsertId()
		require.NoError(t, err)
		return id
	}
	f.publicID = insert("E-pub", "Public sync", "roadmap kiwi public words", false)
	f.privateID = insert("E-priv", "Private sync", "roadmap kiwi secret words", true)
	recap := func(eventID string, transcriptID int64) int64 {
		var tid any
		if transcriptID > 0 {
			tid = transcriptID
		}
		res, err := d.Exec(`INSERT INTO meeting_recaps (event_id, transcript_id, source_text, recap_json, created_at)
			VALUES (?, ?, 'src', '{"summary":"recap"}', '1970-01-01T00:20:00Z')`, eventID, tid)
		require.NoError(t, err)
		id, err := res.LastInsertId()
		require.NoError(t, err)
		return id
	}
	f.publicRecapID = recap("E-pub", f.publicID)
	f.privateRecapID = recap("E-priv", f.privateID)
	f.pastedRecapID = recap("E-paste", 0)
	return f
}

func TestMeetPriv02_SearchTranscriptsSkipsPrivate(t *testing.T) {
	d := openTestDB(t)
	f := seedMeetPriv(t, d)

	hits, err := d.SearchTranscripts("kiwi", 10)
	require.NoError(t, err)
	var ids []int64
	for _, h := range hits {
		ids = append(ids, h.ID)
	}
	assert.Equal(t, []int64{f.publicID}, ids)
}

func TestMeetPriv02_ListMeetingTranscriptsSkipsPrivateByDefault(t *testing.T) {
	d := openTestDB(t)
	f := seedMeetPriv(t, d)

	shared, err := d.ListMeetingTranscripts(MeetingTranscriptFilter{})
	require.NoError(t, err)
	require.Len(t, shared, 1, "the default filter must leave private recordings out")
	assert.Equal(t, f.publicID, shared[0].ID)
	assert.False(t, shared[0].Private)

	all, err := d.ListMeetingTranscripts(MeetingTranscriptFilter{IncludePrivate: true})
	require.NoError(t, err)
	assert.Len(t, all, 2, "IncludePrivate (the owner's own list) keeps every recording")
}

func TestMeetPriv02_IdeasReaderSkipsPrivate(t *testing.T) {
	d := openTestDB(t)
	f := seedMeetPriv(t, d)
	// A second, public recording of the private recording's event: it may be
	// mined, but never with the recap the private recording owns.
	res, err := d.Exec(`INSERT INTO meeting_transcripts (event_id, title, transcript_text, created_at)
		VALUES ('E-priv', 'Second take', 'other words', '1970-01-01T00:20:00Z')`)
	require.NoError(t, err)
	secondID, err := res.LastInsertId()
	require.NoError(t, err)

	rows, err := d.ListTranscriptsForIdeasAfter(0, "")
	require.NoError(t, err)
	got := map[int64]string{}
	for _, r := range rows {
		got[r.ID] = r.RecapJSON
	}
	assert.Contains(t, got, f.publicID)
	assert.Equal(t, `{"summary":"recap"}`, got[f.publicID])
	assert.NotContains(t, got, f.privateID)
	assert.Contains(t, got, secondID)
	assert.Empty(t, got[secondID], "the private recording's recap must not ride along with another recording")
}

// TestMeetPriv02_IdeasChatTurnsSkipPrivateMeetingChat pins that the ideas
// miner never reads the meeting chat of a private recording, while a public
// recording's meeting chat and a plain chat stay mined.
func TestMeetPriv02_IdeasChatTurnsSkipPrivateMeetingChat(t *testing.T) {
	d := openTestDB(t)
	f := seedMeetPriv(t, d)
	cutoff := time.Now().UTC().Add(time.Hour)

	privConv := insertChatConversation(t, d, "meeting", fmt.Sprint(f.privateID))
	pubConv := insertChatConversation(t, d, "meeting", fmt.Sprint(f.publicID))
	plain := insertChatConversation(t, d, "", "")
	insertChatMessage(t, d, privConv, "user", "secret plan", 1)
	pub := insertChatMessage(t, d, pubConv, "user", "public plan", 2)
	other := insertChatMessage(t, d, plain, "assistant", "plain chat", 3)

	got, err := d.ListChatTurnsForIdeas(0, cutoff.Format(time.RFC3339), 100)
	require.NoError(t, err)
	var ids []int64
	for _, turn := range got {
		ids = append(ids, turn.ID)
	}
	assert.Equal(t, []int64{pub, other}, ids)

	// Turning it private later stops the mining of what is left too.
	_, err = d.SetMeetingTranscriptPrivate(f.publicID, true)
	require.NoError(t, err)
	got, err = d.ListChatTurnsForIdeas(0, cutoff.Format(time.RFC3339), 100)
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.Equal(t, other, got[0].ID)
}

func TestMeetPriv02_CatchupSkipsPrivate(t *testing.T) {
	d := openTestDB(t)
	f := seedMeetPriv(t, d)
	// Ad-hoc pair (no event): only those reach the "transcripts" area.
	for _, private := range []bool{false, true} {
		_, err := d.Exec(`INSERT INTO meeting_transcripts (title, transcript_text, summary_json, private, created_at)
			VALUES (?, 't', '{"summary":"adhoc"}', ?, '1970-01-01T00:20:00Z')`, map[bool]string{false: "Adhoc public", true: "Adhoc private"}[private], private)
		require.NoError(t, err)
	}

	items, err := d.ListCatchupMeetings(1000, 2000, 10)
	require.NoError(t, err)
	recaps := map[int64]bool{}
	var titles []string
	for _, it := range items {
		if it.Area == "recaps" {
			recaps[int64(it.ID)] = true
		} else {
			titles = append(titles, it.Title)
		}
	}
	assert.True(t, recaps[f.publicRecapID])
	assert.True(t, recaps[f.pastedRecapID], "a recap with no recording is not transcript content")
	assert.False(t, recaps[f.privateRecapID])
	assert.Equal(t, []string{"Adhoc public"}, titles)
}

func TestMeetPriv02_AutomationRecapReadsSkipPrivate(t *testing.T) {
	d := openTestDB(t)
	f := seedMeetPriv(t, d)
	ctx := context.Background()

	rows, err := d.ListMeetingRecaps(ctx, "", "", 10)
	require.NoError(t, err)
	ids := map[int64]bool{}
	for _, r := range rows {
		ids[r.ID] = true
	}
	assert.Equal(t, map[int64]bool{f.publicRecapID: true, f.pastedRecapID: true}, ids)

	got, err := d.GetMeetingRecapByID(ctx, f.privateRecapID)
	require.NoError(t, err)
	assert.Nil(t, got)
	got, err = d.GetMeetingRecapByEventID(ctx, "E-priv")
	require.NoError(t, err)
	assert.Nil(t, got)
	got, err = d.GetMeetingRecapByID(ctx, f.publicRecapID)
	require.NoError(t, err)
	assert.NotNil(t, got)
}

func TestMeetPriv02_GetMeetingRecapForAISkipsPrivate(t *testing.T) {
	d := openTestDB(t)
	seedMeetPriv(t, d)

	got, err := d.GetMeetingRecapForAI("E-priv")
	require.NoError(t, err)
	assert.Nil(t, got)
	for _, ev := range []string{"E-pub", "E-paste"} {
		got, err = d.GetMeetingRecapForAI(ev)
		require.NoError(t, err)
		assert.NotNil(t, got, ev)
	}
	// The plain lookup (writers, the owner's own CLI) still sees it.
	own, err := d.GetMeetingRecap("E-priv")
	require.NoError(t, err)
	assert.NotNil(t, own)
}

// TestMeetPriv02_UpsertKeepsRecapOwnership pins that a rewrite never strips a
// PRIVATE recording's ownership (the link is what hides its recap and deletes
// it with the recording), while a public owner's row follows the writer as
// before: a pasted recap (no recording) unlinks it.
func TestMeetPriv02_UpsertKeepsRecapOwnership(t *testing.T) {
	d := openTestDB(t)
	f := seedMeetPriv(t, d)

	require.NoError(t, d.UpsertMeetingRecap("E-priv", "pasted", `{"summary":"new"}`, 0))
	got, err := d.GetMeetingRecap("E-priv")
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, f.privateRecapID, got.ID)
	assert.True(t, got.TranscriptID.Valid)
	assert.Equal(t, f.privateID, got.TranscriptID.Int64)
	ai, err := d.GetMeetingRecapForAI("E-priv")
	require.NoError(t, err)
	assert.Nil(t, ai, "the rewritten recap is still the private recording's")
	// Not even a writer naming another recording takes it over.
	require.NoError(t, d.UpsertMeetingRecap("E-priv", "src", `{"summary":"other"}`, f.publicID))
	got, err = d.GetMeetingRecap("E-priv")
	require.NoError(t, err)
	assert.Equal(t, f.privateID, got.TranscriptID.Int64)

	// A public owner's recap replaced by a pasted one is unlinked.
	require.NoError(t, d.UpsertMeetingRecap("E-pub", "pasted", `{"summary":"pasted"}`, 0))
	got, err = d.GetMeetingRecap("E-pub")
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, f.publicRecapID, got.ID)
	assert.False(t, got.TranscriptID.Valid, "a pasted recap belongs to no recording")
	own, err := d.GetMeetingRecapByTranscript(f.publicID)
	require.NoError(t, err)
	assert.Nil(t, own, "the public recording's Regenerate must not overwrite the pasted recap")

	// A writer that names a recording still sets it.
	require.NoError(t, d.UpsertMeetingRecap("E-paste", "src", `{"summary":"r"}`, f.publicID))
	got, err = d.GetMeetingRecap("E-paste")
	require.NoError(t, err)
	assert.Equal(t, f.publicID, got.TranscriptID.Int64)
}

func TestMeetPriv02_DeletingPrivateRecordingDeletesItsRecap(t *testing.T) {
	d := openTestDB(t)
	f := seedMeetPriv(t, d)
	ctx := context.Background()

	_, err := d.Exec(`DELETE FROM meeting_transcripts WHERE id = ?`, f.privateID)
	require.NoError(t, err)

	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM meeting_recaps WHERE id = ?`, f.privateRecapID).Scan(&n))
	assert.Zero(t, n, "the private recording's recap must not outlive it as a recap with no recording")
	got, err := d.GetMeetingRecap("E-priv")
	require.NoError(t, err)
	assert.Nil(t, got)
	got, err = d.GetMeetingRecapForAI("E-priv")
	require.NoError(t, err)
	assert.Nil(t, got)
	rows, err := d.ListMeetingRecaps(ctx, "", "", 10)
	require.NoError(t, err)
	ids := map[int64]bool{}
	for _, r := range rows {
		ids[r.ID] = true
	}
	assert.Equal(t, map[int64]bool{f.publicRecapID: true, f.pastedRecapID: true}, ids)
	items, err := d.ListCatchupMeetings(1000, 2000, 10)
	require.NoError(t, err)
	for _, it := range items {
		assert.False(t, it.Area == "recaps" && int64(it.ID) == f.privateRecapID)
	}

	// A public recording's recap still outlives it, unlinked (existing behaviour).
	_, err = d.Exec(`DELETE FROM meeting_transcripts WHERE id = ?`, f.publicID)
	require.NoError(t, err)
	var tid any
	require.NoError(t, d.QueryRow(`SELECT transcript_id FROM meeting_recaps WHERE id = ?`, f.publicRecapID).Scan(&tid))
	assert.Nil(t, tid)
	got, err = d.GetMeetingRecapForAI("E-pub")
	require.NoError(t, err)
	assert.NotNil(t, got)
}

func TestMeetPriv04_FlagRoundTripAndKBDirtyMarks(t *testing.T) {
	d := openTestDB(t)
	f := seedMeetPriv(t, d)

	ok, err := d.SetMeetingTranscriptPrivate(f.publicID, true)
	require.NoError(t, err)
	assert.True(t, ok)
	tr, err := d.GetMeetingTranscript(f.publicID)
	require.NoError(t, err)
	assert.True(t, tr.Private)

	marks := func() []string {
		rows, err := d.Query(`SELECT source || '|' || key FROM kb_dirty ORDER BY source, key`)
		require.NoError(t, err)
		defer rows.Close()
		var out []string
		for rows.Next() {
			var s string
			require.NoError(t, rows.Scan(&s))
			out = append(out, s)
		}
		require.NoError(t, rows.Err())
		return out
	}
	assert.ElementsMatch(t, []string{
		fmt.Sprintf("recap|recap:%d", f.publicRecapID),
		fmt.Sprintf("transcript|transcript:%d", f.publicID),
	}, marks())

	// Writing the same value again marks nothing new.
	_, err = d.Exec(`DELETE FROM kb_dirty`)
	require.NoError(t, err)
	_, err = d.SetMeetingTranscriptPrivate(f.publicID, true)
	require.NoError(t, err)
	assert.Empty(t, marks())

	ok, err = d.SetMeetingTranscriptPrivate(f.publicID, false)
	require.NoError(t, err)
	assert.True(t, ok)
	assert.Len(t, marks(), 2, "turning private off re-renders the documents too")

	ok, err = d.SetMeetingTranscriptPrivate(999999, true)
	require.NoError(t, err)
	assert.False(t, ok)
}

func TestMeetPriv01_InsertStoresPrivate(t *testing.T) {
	d := openTestDB(t)
	id, err := d.InsertMeetingTranscript(MeetingTranscript{Title: "p", TranscriptText: "x", Private: true})
	require.NoError(t, err)
	tr, err := d.GetMeetingTranscript(id)
	require.NoError(t, err)
	assert.True(t, tr.Private)
}
