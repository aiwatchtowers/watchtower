package kb

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// MEETPRIV-02 (docs/inventory/meetings.md): a private recording and the recap
// it owns are never indexed, and a recording turned private leaves the index
// on the next pass — through the kb_dirty trigger, since the Desktop flips the
// flag without moving any change cursor.

func seedMeetPrivKB(t *testing.T, d *db.DB) {
	t.Helper()
	exec(t, d, `INSERT INTO calendar_calendars (id, name) VALUES ('cal1','Work')`)
	exec(t, d, `INSERT INTO calendar_events (id, calendar_id, title, start_time, end_time) VALUES
		('e1','cal1','Public sync','2026-09-11T10:00:00Z','2026-09-11T11:00:00Z'),
		('e2','cal1','Private sync','2026-09-11T12:00:00Z','2026-09-11T13:00:00Z')`)
	exec(t, d, `INSERT INTO meeting_transcripts (id, event_id, title, transcript_text, private, created_at, updated_at) VALUES
		(1, 'e1', 'Public sync', 'public words', 0, '2026-09-11T10:00:00Z', '2026-09-11T10:00:00Z'),
		(2, 'e2', 'Private sync', 'secret words', 1, '2026-09-11T12:00:00Z', '2026-09-11T12:00:00Z')`)
	exec(t, d, `INSERT INTO meeting_recaps (id, event_id, transcript_id, source_text, recap_json, created_at, updated_at) VALUES
		(10, 'e1', 1, 'src', '{"summary":"public recap"}', '2026-09-11T11:00:00Z', '2026-09-11T11:00:00Z'),
		(20, 'e2', 2, 'src', '{"summary":"secret recap"}', '2026-09-11T13:00:00Z', '2026-09-11T13:00:00Z')`)
}

var meetPrivSources = []string{"transcript", "recap"}

func TestMeetPriv02_PrivateRecordingNeverIndexed(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedMeetPrivKB(t, d)

	_, err := Run(ctx, d, Options{Now: testNow(), Sources: meetPrivSources})
	require.NoError(t, err)
	assert.True(t, docExists(t, d, "transcript:1"))
	assert.True(t, docExists(t, d, "recap:10"))
	assert.False(t, docExists(t, d, "transcript:2"))
	assert.False(t, docExists(t, d, "recap:20"))

	keys, err := transcriptSource{}.Keys(ctx, d)
	require.NoError(t, err)
	assert.Equal(t, []string{"transcript:1"}, keys)
	keys, err = recapSource{}.Keys(ctx, d)
	require.NoError(t, err)
	assert.Equal(t, []string{"recap:10"}, keys)
}

func TestMeetPriv02_TurnedPrivateLeavesIndexNextPass(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedMeetPrivKB(t, d)
	_, err := Run(ctx, d, Options{Now: testNow(), Sources: meetPrivSources})
	require.NoError(t, err)
	require.True(t, docExists(t, d, "transcript:1"))

	// The Desktop path: a bare flag write, updated_at untouched.
	exec(t, d, `UPDATE meeting_transcripts SET private = 1 WHERE id = 1`)
	_, err = Run(ctx, d, Options{Now: testNow(), Sources: meetPrivSources})
	require.NoError(t, err)
	assert.False(t, docExists(t, d, "transcript:1"))
	assert.False(t, docExists(t, d, "recap:10"))
	assert.Zero(t, dirtyCount(t, d))

	// Incremental equals a rebuild (KB-01) with a private recording.
	assertReindexMatches(t, d)

	// Turning private off brings both back (MEETPRIV-04).
	exec(t, d, `UPDATE meeting_transcripts SET private = 0 WHERE id = 1`)
	_, err = Run(ctx, d, Options{Now: testNow(), Sources: meetPrivSources})
	require.NoError(t, err)
	assert.True(t, docExists(t, d, "transcript:1"))
	assert.True(t, docExists(t, d, "recap:10"))
	assertReindexMatches(t, d)
}

// assertReindexMatches compares the transcript and recap documents before and
// after a from-scratch rebuild of those two sources.
func assertReindexMatches(t *testing.T, d *db.DB) {
	t.Helper()
	ctx := context.Background()
	snapshot := func() map[string]string {
		rows, err := d.Query(`SELECT id, content_hash FROM kb_documents WHERE source IN ('transcript','recap')`)
		require.NoError(t, err)
		defer rows.Close()
		out := map[string]string{}
		for rows.Next() {
			var id, hash string
			require.NoError(t, rows.Scan(&id, &hash))
			out[id] = hash
		}
		require.NoError(t, rows.Err())
		return out
	}
	before := snapshot()
	_, err := Reindex(ctx, d, meetPrivSources, testNow())
	require.NoError(t, err)
	assert.Equal(t, before, snapshot())
}

// TestMeetPriv04_DropPrivateRecordingLeavesSearchNow pins that the flip's
// drop takes the transcript and its recap out of search and get-document
// with no indexer pass in between, touches no other recording, and that the
// next pass leaves the index as a rebuild would (KB-01).
func TestMeetPriv04_DropPrivateRecordingLeavesSearchNow(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedMeetPrivKB(t, d)
	_, err := Run(ctx, d, Options{Now: testNow(), Sources: meetPrivSources})
	require.NoError(t, err)
	res, err := Search(ctx, d, Request{Queries: []string{"public"}, Sources: meetPrivSources})
	require.NoError(t, err)
	require.NotEmpty(t, res.Hits)

	exec(t, d, `UPDATE meeting_transcripts SET private = 1 WHERE id = 1`)
	n, err := DropPrivateRecording(ctx, d, 1)
	require.NoError(t, err)
	assert.Equal(t, 2, n)
	res, err = Search(ctx, d, Request{Queries: []string{"public"}, Sources: meetPrivSources})
	require.NoError(t, err)
	assert.Empty(t, res.Hits)
	for _, ref := range []string{"transcript:1", "recap:10"} {
		_, err = GetDocument(ctx, d, ref, DocOptions{})
		assert.ErrorIs(t, err, ErrNotFound, ref)
	}

	// Nothing left to drop is not an error.
	n, err = DropPrivateRecording(ctx, d, 1)
	require.NoError(t, err)
	assert.Zero(t, n)

	_, err = Run(ctx, d, Options{Now: testNow(), Sources: meetPrivSources})
	require.NoError(t, err)
	assert.False(t, docExists(t, d, "transcript:1"))
	assertReindexMatches(t, d)
}

// TestMeetPriv02_PrivateMeetingChatArtifactsLeaveIndex pins that an artifact
// kept from the meeting chat of a recording turned private leaves the index on
// the next pass (the flip's kb_dirty mark, no cursor moves) and right away
// through DropPrivateRecording, comes back once private is off, and that a
// plain chat's artifact is untouched.
func TestMeetPriv02_PrivateMeetingChatArtifactsLeaveIndex(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedMeetPrivKB(t, d)
	exec(t, d, `INSERT INTO chat_conversations (id, title, context_type, context_id, created_at, updated_at) VALUES
		(5, 'Public sync chat', 'meeting', '1', 1, 1),
		(6, 'Plain chat', '', '', 1, 1)`)
	exec(t, d, `INSERT INTO chat_messages (id, conversation_id, role, text, created_at) VALUES (1, 5, 'assistant', 'x', 1), (2, 6, 'assistant', 'y', 1)`)
	exec(t, d, `INSERT INTO chat_artifacts (conversation_id, message_id, artifact_key, version, kind, title, content, created_at) VALUES
		(5, 1, 'plan', 1, 'document', 'Meeting plan', 'kiwi rollout from the meeting', 1),
		(6, 2, 'plan', 1, 'document', 'Plain plan', 'kiwi rollout from a plain chat', 1)`)
	exec(t, d, `INSERT INTO chat_knowledge_artifacts (conversation_id, artifact_key, version, kept_at) VALUES
		(5, 'plan', 1, '2026-10-24T09:00:00Z'), (6, 'plan', 1, '2026-10-24T10:00:00Z')`)
	// The plain artifact is kept later, so the change cursor moves past the
	// meeting one: only the flip's kb_dirty mark can bring it back.
	sources := []string{"transcript", "recap", "chat_artifact"}
	run := func() {
		t.Helper()
		_, err := Run(ctx, d, Options{Now: testNow(), Sources: sources})
		require.NoError(t, err)
	}
	run()
	require.True(t, docExists(t, d, "chat_artifact:5:plan"))

	// The Desktop path: a bare flag write, then the next pass.
	exec(t, d, `UPDATE meeting_transcripts SET private = 1 WHERE id = 1`)
	run()
	assert.False(t, docExists(t, d, "chat_artifact:5:plan"))
	assert.True(t, docExists(t, d, "chat_artifact:6:plan"))
	keys, err := chatArtifactSource{}.Keys(ctx, d)
	require.NoError(t, err)
	assert.Equal(t, []string{"chat_artifact:6:plan"}, keys)
	doc, err := chatArtifactSource{}.Build(ctx, d, "chat_artifact:5:plan")
	require.NoError(t, err)
	assert.Nil(t, doc)

	exec(t, d, `UPDATE meeting_transcripts SET private = 0 WHERE id = 1`)
	run()
	assert.True(t, docExists(t, d, "chat_artifact:5:plan"))

	// The CLI path: dropped at once, with no pass in between.
	exec(t, d, `UPDATE meeting_transcripts SET private = 1 WHERE id = 1`)
	n, err := DropPrivateRecording(ctx, d, 1)
	require.NoError(t, err)
	assert.Equal(t, 3, n, "transcript, recap and the kept artifact")
	assert.False(t, docExists(t, d, "chat_artifact:5:plan"))
	assert.True(t, docExists(t, d, "chat_artifact:6:plan"))
	run()
	assert.Zero(t, dirtyCount(t, d))
}
