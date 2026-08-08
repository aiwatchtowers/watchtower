package ideas

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// --- IDEA-01: an affirmative "ops" key is required -------------------------

// TestIdeas01_ReplyWithoutOpsKey_NothingWritten covers the affirmative-field
// rule: a syntactically-valid reply that simply omits "ops" answered nothing.
// Treating it as "no changes" would consume the run's material on the
// strength of a model failure, so it must behave exactly like malformed JSON.
func TestIdeas01_ReplyWithoutOpsKey_NothingWritten(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)
	seedDigestTopicIdeas(t, d, "C1", "general",
		[]digest.IdeaCandidate{{Text: "try X", By: "Ann", MessageTS: "1.1"}}, nil)

	gen := &fakeGen{reply: func(string) (string, error) { return `{}`, nil }}
	p := New(d, testCfg(), gen, testLogger())
	proposed, err := p.runConsolidate(context.Background())
	require.Error(t, err)
	assert.Zero(t, proposed)

	ideas, err := d.ListIdeas(db.IdeaFilter{})
	require.NoError(t, err)
	assert.Empty(t, ideas)

	dFloor, sFloor, tFloor, err := d.GetIdeasFloors()
	require.NoError(t, err)
	assert.Zero(t, dFloor)
	assert.Zero(t, sFloor)
	assert.Zero(t, tFloor)
}

// TestIdeas01_EmptyOpsArray_FloorsAdvance is the other half: an EXPLICIT empty
// ops array is the model's ordinary "nothing to record this run" answer, and
// must consume the material like any successful run.
func TestIdeas01_EmptyOpsArray_FloorsAdvance(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)
	topicID := seedDigestTopicIdeas(t, d, "C1", "general",
		[]digest.IdeaCandidate{{Text: "try X", By: "Ann", MessageTS: "1.1"}}, nil)

	gen := &fakeGen{reply: func(string) (string, error) { return `{"ops":[]}`, nil }}
	p := New(d, testCfg(), gen, testLogger())
	proposed, err := p.runConsolidate(context.Background())
	require.NoError(t, err)
	assert.Zero(t, proposed)

	dFloor, _, _, err := d.GetIdeasFloors()
	require.NoError(t, err)
	assert.Equal(t, topicID, dFloor)
}

// --- IDEA-01: the floors need somewhere to land ---------------------------

// TestIdeas01_NoWorkspaceRow_ErrorsAndRollsBack covers the silent-zero-rows
// case: with no workspace row the floor UPDATE matches nothing. Committing
// anyway would persist ideas whose material is still "new" next run — an
// infinite duplicate machine — so the whole transaction must fail.
func TestIdeas01_NoWorkspaceRow_ErrorsAndRollsBack(t *testing.T) {
	d := newTestDB(t) // deliberately NO seedWorkspace
	seedDigestTopicIdeas(t, d, "C1", "general",
		[]digest.IdeaCandidate{{Text: "try X", By: "Ann", MessageTS: "1.1"}}, nil)

	gen := &fakeGen{reply: func(string) (string, error) {
		return `{"ops":[{"op":"new_idea","title":"Try X","essence":"e",
			"mentions":[{"source":"slack","ref":"C1|1.1","quote":"try X","author":"Ann","said_at":"2026-08-01T00:00:00Z"}]}]}`, nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	proposed, err := p.runConsolidate(context.Background())
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no workspace row")
	assert.Zero(t, proposed)

	ideas, err := d.ListIdeas(db.IdeaFilter{})
	require.NoError(t, err)
	assert.Empty(t, ideas, "the failed floor write must roll back the ideas created alongside it")
}

// --- IDEA-01: degenerate runs still have to persist their floors ----------

// TestIdeas01_InertStreamDigestRows_FloorAdvancesWithoutAICall covers the
// degenerate clean-exit branch: stream_digests rows whose stage-1 candidates
// were all stripped render to nothing, so there is no AI call — but they WERE
// consumed, and their floor has to land or every future run re-reads them.
func TestIdeas01_InertStreamDigestRows_FloorAdvancesWithoutAICall(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)
	seedStreamDigestIdeas(t, d, "gmail", 1, []streamTopic{})
	lastID := seedStreamDigestIdeas(t, d, "jira", 1, []streamTopic{})

	gen := &fakeGen{reply: func(string) (string, error) {
		t.Fatal("generator must not be called when nothing rendered")
		return "", nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	proposed, err := p.runConsolidate(context.Background())
	require.NoError(t, err)
	assert.Zero(t, proposed)
	assert.Zero(t, gen.calls)

	_, sFloor, _, err := d.GetIdeasFloors()
	require.NoError(t, err)
	assert.Equal(t, lastID, sFloor, "consumed-but-inert rows must still advance the floor")

	// Second run: the same rows must not come back.
	remaining, err := d.ListStreamDigestsAfter(sFloor)
	require.NoError(t, err)
	assert.Empty(t, remaining, "the inert rows must not be re-read next run")
}

// TestIdeas01_StaleRecaplessTranscripts_FloorAdvancesWithoutAICall is the
// transcript half of the same branch: transcripts old enough that their recap
// is never coming are skipped-and-counted, with no AI call at all when they
// are the only material.
func TestIdeas01_StaleRecaplessTranscripts_FloorAdvancesWithoutAICall(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)
	seedTranscriptForIdeas(t, d, "Stale one", "", time.Now().Add(-96*time.Hour))
	lastID := seedTranscriptForIdeas(t, d, "Stale two", "", time.Now().Add(-72*time.Hour))

	gen := &fakeGen{reply: func(string) (string, error) {
		t.Fatal("generator must not be called when nothing rendered")
		return "", nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	_, err := p.runConsolidate(context.Background())
	require.NoError(t, err)
	assert.Zero(t, gen.calls)

	_, _, tFloor, err := d.GetIdeasFloors()
	require.NoError(t, err)
	assert.Equal(t, lastID, tFloor, "stale recap-less transcripts must not be rechecked forever")
}

// TestIdeas01_OversizedUnit_SkippedAndFloorAdvances covers the unit that can
// never fit: one bigger than the WHOLE budget would stop consumption on every
// run forever, permanently starving every source behind it. It is skipped and
// consumed instead.
func TestIdeas01_OversizedUnit_SkippedAndFloorAdvances(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)
	huge := strings.Repeat("x", 5000)
	oversizedID := seedDigestTopicIdeas(t, d, "C1", "general",
		[]digest.IdeaCandidate{{Text: huge, By: "Ann", MessageTS: "1.1"}}, nil)
	nextID := seedDigestTopicIdeas(t, d, "C2", "general",
		[]digest.IdeaCandidate{{Text: "small idea", By: "Bob", MessageTS: "2.2"}}, nil)

	var captured string
	gen := &fakeGen{reply: func(user string) (string, error) {
		captured = user
		return `{"ops":[]}`, nil
	}}
	cfg := testCfg()
	cfg.Ideas.MaxPromptChars = 500
	p := New(d, cfg, gen, testLogger())
	_, err := p.runConsolidate(context.Background())
	require.NoError(t, err)

	assert.NotContains(t, captured, huge, "the oversized unit is never rendered")
	assert.Contains(t, captured, "small idea", "the units behind it are not starved")

	dFloor, _, _, err := d.GetIdeasFloors()
	require.NoError(t, err)
	assert.Equal(t, nextID, dFloor, "the floor moves past the oversized unit, not up to it")
	assert.Greater(t, nextID, oversizedID)
}

// --- IDEA-02: the source is derived, never copied from the model ----------

// TestIdeas02_TranscriptRef_MentionSourceIsMeeting exercises the transcript
// path end to end: "transcript:<id>" material yields a mention stored with
// source 'meeting' — the name idea_mentions' CHECK actually accepts, which is
// NOT the token that appears in the ref.
func TestIdeas02_TranscriptRef_MentionSourceIsMeeting(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)
	transcriptID := seedTranscriptForIdeas(t, d, "Planning sync",
		`{"ideas":["spin up a design review ritual"],"key_decisions":[]}`, time.Now().Add(-72*time.Hour))

	gen := &fakeGen{reply: func(string) (string, error) {
		return fmt.Sprintf(`{"ops":[{"op":"new_idea","title":"Design review ritual","essence":"e",
			"mentions":[{"source":"meeting","ref":"transcript:%d","quote":"spin up a design review ritual","author":"Ann","said_at":"2026-08-01T00:00:00Z"}]}]}`, transcriptID), nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	proposed, err := p.runConsolidate(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, proposed)

	ideas, err := d.ListIdeas(db.IdeaFilter{})
	require.NoError(t, err)
	require.Len(t, ideas, 1)
	mentions, err := d.ListIdeaMentions(ideas[0].ID)
	require.NoError(t, err)
	require.Len(t, mentions, 1)
	assert.Equal(t, "meeting", mentions[0].Source)
	assert.Equal(t, fmt.Sprintf("transcript:%d", transcriptID), mentions[0].Ref)
}

// TestIdeas02_ModelSourceToken_Ignored pins "model proposes, Go disposes" for
// the source field. The model emits a source that is both wrong AND outside
// idea_mentions' CHECK; the mention still lands, under the source this run's
// own material recorded for that ref. Trusting the token instead would either
// drop a legitimate sighting or abort the entire transaction on the CHECK.
func TestIdeas02_ModelSourceToken_Ignored(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)
	transcriptID := seedTranscriptForIdeas(t, d, "Planning sync",
		`{"ideas":["adopt a design review"],"key_decisions":[]}`, time.Now().Add(-72*time.Hour))
	existingID := seedIdeaRow(t, d, db.Idea{Kind: "idea", Title: "Existing", Essence: "e", Status: "active"})

	gen := &fakeGen{reply: func(string) (string, error) {
		return fmt.Sprintf(`{"ops":[{"op":"attach_mention","idea_id":%d,
			"mention":{"source":"transcript","ref":"transcript:%d","quote":"q","author":"Ann","said_at":"2026-08-01T00:00:00Z"}}]}`,
			existingID, transcriptID), nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	_, err := p.runConsolidate(context.Background())
	require.NoError(t, err)

	mentions, err := d.ListIdeaMentions(existingID)
	require.NoError(t, err)
	require.Len(t, mentions, 1, "a valid ref must not be dropped over the model's source token")
	assert.Equal(t, "meeting", mentions[0].Source)
}

// --- IDEA-01: one op's failure rolls back its predecessors ---------------

// TestIdeas01_MidApplyFailure_RollsBackEarlierOps covers the mid-apply error
// path: the first op writes an idea, the second one blows up on a foreign key
// (its target idea is in the prompt registry but no longer in the DB). Nothing
// from the whole pass may survive, floors included.
func TestIdeas01_MidApplyFailure_RollsBackEarlierOps(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)
	topicID := seedDigestTopicIdeas(t, d, "C1", "general",
		[]digest.IdeaCandidate{{Text: "try X", By: "Ann", MessageTS: "1.1"}}, nil)

	// A registry entry the prompt saw, deleted out from under the apply pass
	// (the owner pruning it mid-run) — attaching to it now violates
	// idea_mentions' FK on ideas(id).
	ghostID := seedIdeaRow(t, d, db.Idea{Kind: "idea", Title: "Ghost", Essence: "e", Status: "active"})

	gen := &fakeGen{reply: func(string) (string, error) {
		_, derr := d.Exec(`DELETE FROM ideas WHERE id = ?`, ghostID)
		require.NoError(t, derr)
		return fmt.Sprintf(`{"ops":[
			{"op":"new_idea","title":"Survivor?","essence":"e","mentions":[{"source":"slack","ref":"C1|1.1","quote":"try X","author":"Ann","said_at":"2026-08-01T00:00:00Z"}]},
			{"op":"attach_mention","idea_id":%d,"mention":{"source":"slack","ref":"C1|1.1","quote":"q","author":"Ann","said_at":"2026-08-01T00:00:00Z"}}
		]}`, ghostID), nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	_, err := p.runConsolidate(context.Background())
	require.Error(t, err)

	ideas, err := d.ListIdeas(db.IdeaFilter{})
	require.NoError(t, err)
	assert.Empty(t, ideas, "the earlier op's idea must roll back with the failing one")

	dFloor, _, _, err := d.GetIdeasFloors()
	require.NoError(t, err)
	assert.Zero(t, dFloor, "a rolled-back pass leaves its material unconsumed")
	assert.NotZero(t, topicID)
}
