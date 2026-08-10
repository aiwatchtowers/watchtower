package ideas

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// seedWorkspace seeds the singleton workspace row the ideas floors live on
// (internal/db/ideas_test.go's mustSeedWorkspace precedent) — without it,
// SetIdeasFloorsTx silently updates zero rows.
func seedWorkspace(t *testing.T, d *db.DB) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO workspace (id, name) VALUES ('T1', 'Test')`)
	require.NoError(t, err)
}

// seedMessage inserts one Slack message row — the real, non-deleted message a
// digest topic's candidate message_ts has to resolve to before its ref can be
// rendered or cited (IDEA-02).
func seedMessage(t *testing.T, d *db.DB, channelID, ts string, deleted bool) {
	t.Helper()
	require.NoError(t, d.UpsertMessage(db.Message{
		ChannelID: channelID, TS: ts, UserID: "U1", Text: "message text", IsDeleted: deleted, RawJSON: "{}",
	}))
}

// seedCandidateMessages inserts the real message every candidate's message_ts
// points at, so a seeded topic's refs survive renderTopicUnit's IDEA-02
// validation. A test that wants an UNVERIFIABLE candidate (the hallucinated-ts
// shape) seeds its topic with seedDigestTopicIdeasUnverified instead.
func seedCandidateMessages(t *testing.T, d *db.DB, channelID string, ideas []digest.IdeaCandidate, decisions []digest.Decision) {
	t.Helper()
	for _, c := range ideas {
		seedMessage(t, d, channelID, c.MessageTS, false)
	}
	for _, c := range decisions {
		seedMessage(t, d, channelID, c.MessageTS, false)
	}
}

// seedDigestTopicIdeas inserts a channel-type digest plus one digest_topics
// row carrying the given idea/decision candidates — each backed by a real
// message row, the ordinary case — and returns the topic id.
func seedDigestTopicIdeas(t *testing.T, d *db.DB, channelID, title string, ideas []digest.IdeaCandidate, decisions []digest.Decision) int64 {
	t.Helper()
	seedCandidateMessages(t, d, channelID, ideas, decisions)
	return seedDigestTopicIdeasUnverified(t, d, channelID, title, ideas, decisions)
}

// seedDigestTopicIdeasUnverified is seedDigestTopicIdeas without the backing
// messages rows: the shape a hallucinating digest model produces, where
// digest_topics cites a message_ts no message in that channel actually
// carries. A test that wants only SOME of its candidates verifiable seeds the
// real ones with seedMessage afterwards.
func seedDigestTopicIdeasUnverified(t *testing.T, d *db.DB, channelID, title string, ideas []digest.IdeaCandidate, decisions []digest.Decision) int64 {
	t.Helper()
	if ideas == nil {
		ideas = []digest.IdeaCandidate{}
	}
	if decisions == nil {
		decisions = []digest.Decision{}
	}
	ideasJSON, err := json.Marshal(ideas)
	require.NoError(t, err)
	decisionsJSON, err := json.Marshal(decisions)
	require.NoError(t, err)

	from := float64(time.Now().UnixNano())
	digestID, err := d.UpsertDigest(db.Digest{
		ChannelID: channelID, Type: "channel", PeriodFrom: from, PeriodTo: from + 60,
		Summary: "s", Topics: "[]", Decisions: "[]", ActionItems: "[]", PeopleSignals: "[]", Situations: "[]",
	})
	require.NoError(t, err)

	require.NoError(t, d.InsertDigestTopics(digestID, []db.DigestTopic{{
		Idx: 0, Title: title, Summary: "s", Decisions: string(decisionsJSON), ActionItems: "[]",
		Situations: "[]", KeyMessages: "[]", Ideas: string(ideasJSON),
	}}))

	var topicID int64
	require.NoError(t, d.QueryRow(`SELECT id FROM digest_topics WHERE digest_id = ?`, digestID).Scan(&topicID))
	return topicID
}

// seedStreamDigestIdeas inserts a stream_digests row (Gmail or Jira) with the
// given topics, already in the stage-1-validated shape the consolidator
// reads, and returns its id.
func seedStreamDigestIdeas(t *testing.T, d *db.DB, source string, accountID int64, topics []streamTopic) int64 {
	t.Helper()
	topicsJSON, err := json.Marshal(topics)
	require.NoError(t, err)
	id, err := d.InsertStreamDigest(db.StreamDigest{
		Source: source, AccountID: accountID, PeriodFrom: "p1", PeriodTo: "p2", TopicsJSON: string(topicsJSON),
	})
	require.NoError(t, err)
	return id
}

// seedTranscriptForIdeas inserts a meeting_transcripts row with the given
// resolved recap JSON (as summary_json — no event/recap join needed for an
// ad-hoc transcript) and created_at, and returns its id.
func seedTranscriptForIdeas(t *testing.T, d *db.DB, title, summaryJSON string, createdAt time.Time) int64 {
	t.Helper()
	ts := createdAt.UTC().Format(time.RFC3339)
	res, err := d.Exec(`INSERT INTO meeting_transcripts (title, transcript_text, summary_json, created_at, updated_at)
		VALUES (?, 'full transcript text', ?, ?, ?)`, title, summaryJSON, ts, ts)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

// seedIdeaRow inserts a registry idea directly (bypassing the consolidator)
// and returns its id.
func seedIdeaRow(t *testing.T, d *db.DB, idea db.Idea) int64 {
	t.Helper()
	tx, err := d.Begin()
	require.NoError(t, err)
	id, err := d.CreateIdeaTx(tx, idea)
	require.NoError(t, err)
	require.NoError(t, tx.Commit())
	return id
}

// seedIdeaMention records a mention directly (bypassing the consolidator) —
// used by the IDEA-05 tests to put a ref already "mined" into idea_mentions
// before the consolidator ever sees it.
func seedIdeaMention(t *testing.T, d *db.DB, ideaID int64, source, ref string) {
	t.Helper()
	tx, err := d.Begin()
	require.NoError(t, err)
	require.NoError(t, d.InsertIdeaMentionTx(tx, db.IdeaMention{
		IdeaID: ideaID, Source: source, Ref: ref, Quote: "q", Author: "Ann", SaidAt: "2026-08-01T00:00:00Z",
	}))
	require.NoError(t, tx.Commit())
}

// TestConsolidate_NewIdea_ValidRef covers case 1: a new_idea op citing a ref
// that really is in this run's stage-1 material creates a proposed idea plus
// its mention, and the digest floor advances to the consumed topic.
func TestConsolidate_NewIdea_ValidRef(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)
	topicID := seedDigestTopicIdeas(t, d, "C1", "general",
		[]digest.IdeaCandidate{{Text: "we should try X", By: "Ann", MessageTS: "123.45"}}, nil)

	gen := &fakeGen{reply: func(string) (string, error) {
		return `{"ops":[{"op":"new_idea","title":"Try X","essence":"a new vendor idea",
			"mentions":[{"source":"slack","ref":"C1|123.45","quote":"we should try X","author":"Ann","said_at":"2026-08-01T00:00:00Z"}]}]}`, nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	proposed, _, err := p.runConsolidate(context.Background(), time.Time{}, time.Time{})
	require.NoError(t, err)
	assert.Equal(t, 1, proposed)
	assert.Equal(t, 1, gen.calls)

	ideas, err := d.ListIdeas(db.IdeaFilter{})
	require.NoError(t, err)
	require.Len(t, ideas, 1)
	assert.Equal(t, "idea", ideas[0].Kind)
	assert.Equal(t, "proposed", ideas[0].Status)
	assert.Equal(t, "Try X", ideas[0].Title)

	mentions, err := d.ListIdeaMentions(ideas[0].ID)
	require.NoError(t, err)
	require.Len(t, mentions, 1)
	assert.Equal(t, "slack", mentions[0].Source)
	assert.Equal(t, "C1|123.45", mentions[0].Ref)

	dFloor, sFloor, tFloor, err := d.GetIdeasFloors()
	require.NoError(t, err)
	assert.Equal(t, topicID, dFloor)
	assert.Zero(t, sFloor)
	assert.Zero(t, tFloor)
}

// TestIdeas02_InventedRefPartiallyDropped covers case 2 (partial): a
// new_idea op with two mentions, one real and one invented, keeps only the
// real one — the idea is still created.
func TestIdeas02_InventedRefPartiallyDropped(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)
	seedDigestTopicIdeas(t, d, "C1", "general",
		[]digest.IdeaCandidate{{Text: "try X", By: "Ann", MessageTS: "1.1"}}, nil)

	gen := &fakeGen{reply: func(string) (string, error) {
		return `{"ops":[{"op":"new_idea","title":"Try X","essence":"e","mentions":[
			{"source":"slack","ref":"C1|1.1","quote":"try X","author":"Ann","said_at":"2026-08-01T00:00:00Z"},
			{"source":"slack","ref":"C1|9.9","quote":"invented","author":"Ann","said_at":"2026-08-01T00:00:00Z"}
		]}]}`, nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	proposed, _, err := p.runConsolidate(context.Background(), time.Time{}, time.Time{})
	require.NoError(t, err)
	assert.Equal(t, 1, proposed)

	ideas, err := d.ListIdeas(db.IdeaFilter{})
	require.NoError(t, err)
	require.Len(t, ideas, 1)
	mentions, err := d.ListIdeaMentions(ideas[0].ID)
	require.NoError(t, err)
	require.Len(t, mentions, 1, "only the valid mention should survive")
	assert.Equal(t, "C1|1.1", mentions[0].Ref)
}

// TestIdeas02_InventedRefAllDroppedOpDiscarded covers case 2 (full):
// an op whose every mention is invented is dropped entirely — nothing is
// written for it (IDEA-02) — while the run itself still succeeds and the
// floor still advances past the topic that was genuinely processed.
func TestIdeas02_InventedRefAllDroppedOpDiscarded(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)
	topicID := seedDigestTopicIdeas(t, d, "C1", "general",
		[]digest.IdeaCandidate{{Text: "try X", By: "Ann", MessageTS: "1.1"}}, nil)

	gen := &fakeGen{reply: func(string) (string, error) {
		return `{"ops":[{"op":"new_idea","title":"Ghost","essence":"e",
			"mentions":[{"source":"slack","ref":"C1|999.9","quote":"invented","author":"Ann","said_at":"2026-08-01T00:00:00Z"}]}]}`, nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	proposed, _, err := p.runConsolidate(context.Background(), time.Time{}, time.Time{})
	require.NoError(t, err)
	assert.Zero(t, proposed)

	ideas, err := d.ListIdeas(db.IdeaFilter{})
	require.NoError(t, err)
	assert.Empty(t, ideas, "an op with only invented refs must write nothing")

	dFloor, _, _, err := d.GetIdeasFloors()
	require.NoError(t, err)
	assert.Equal(t, topicID, dFloor, "the run still succeeded — the floor still advances past the processed topic")
}

// --- IDEA-02: a digest topic's Slack ts must resolve to a real message -----

// TestIdeas02_SlackRefMissingFromMessages_NotRenderedNotCitable pins the
// stage-1 half of IDEA-02 for Slack. A digest topic's `message_ts` is emitted
// by the digest model, so it can be hallucinated — the real incident that
// motivated this validation (2026-08-10) had a topic citing ts
// 1754131080.000000 in a channel where the genuine message was
// 1785746329.642879, the model having shifted the year. A candidate whose ts
// resolves to no message is not rendered, is not citable, and an op that cites
// it anyway is discarded whole.
func TestIdeas02_SlackRefMissingFromMessages_NotRenderedNotCitable(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)
	topicID := seedDigestTopicIdeasUnverified(t, d, "C1", "general", []digest.IdeaCandidate{
		{Text: "real idea", By: "Ann", MessageTS: "1785746329.642879"},
		{Text: "hallucinated idea", By: "Ann", MessageTS: "1754131080.000000"},
	}, nil)
	seedMessage(t, d, "C1", "1785746329.642879", false) // only the first candidate has a message

	var logBuf bytes.Buffer
	var capturedUser string
	gen := &fakeGen{reply: func(user string) (string, error) {
		capturedUser = user
		return `{"ops":[{"op":"new_idea","title":"Ghost","essence":"e",
			"mentions":[{"source":"slack","ref":"C1|1754131080.000000","quote":"hallucinated idea","author":"Ann","said_at":"2026-08-01T00:00:00Z"}]}]}`, nil
	}}
	p := New(d, testCfg(), gen, log.New(&logBuf, "", 0))

	// The valid-ref set itself, before any op is applied: only the real
	// message's ref is offered.
	in, err := p.gatherConsolidateInput(p.maxPromptChars(), time.Time{}, time.Time{})
	require.NoError(t, err)
	assert.Equal(t, map[string]string{"C1|1785746329.642879": "slack"}, in.validRefs)

	proposed, _, err := p.runConsolidate(context.Background(), time.Time{}, time.Time{})
	require.NoError(t, err)
	assert.Zero(t, proposed)

	assert.Contains(t, capturedUser, "real idea", "the verifiable candidate is still rendered")
	assert.NotContains(t, capturedUser, "hallucinated idea", "an unverifiable candidate must never reach the model")
	assert.NotContains(t, capturedUser, "1754131080.000000", "nor may its ref be offered as citable")

	ideas, err := d.ListIdeas(db.IdeaFilter{})
	require.NoError(t, err)
	assert.Empty(t, ideas, "an op whose only ref was never rendered must write nothing")

	assert.Contains(t, logBuf.String(), "dropped 1 unverifiable slack ref")
	assert.Contains(t, logBuf.String(), "dropped 1 invented ref", "the op's citation of the dropped ref counts as refs_rejected")

	dFloor, _, _, err := d.GetIdeasFloors()
	require.NoError(t, err)
	assert.Equal(t, topicID, dFloor, "the run still succeeded — the floor advances past the processed topic")
}

// TestIdeas02_SlackRefDeletedMessage_Dropped covers the other way a ts fails
// to resolve: the message existed when the digest was written and has since
// been deleted. A tombstoned row is treated as absent (db.MessageExists'
// is_deleted = 0 precedent), so its ref is no more citable than an invented
// one — the evidence a reader would follow the ref to is gone.
func TestIdeas02_SlackRefDeletedMessage_Dropped(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)
	topicID := seedDigestTopicIdeasUnverified(t, d, "C1", "general", []digest.IdeaCandidate{
		{Text: "live idea", By: "Ann", MessageTS: "1.1"},
	}, []digest.Decision{
		{Text: "deleted decision", By: "Bob", MessageTS: "2.2", Importance: "high"},
	})
	seedMessage(t, d, "C1", "1.1", false)
	seedMessage(t, d, "C1", "2.2", true) // deleted after the digest cited it

	var logBuf bytes.Buffer
	var capturedUser string
	gen := &fakeGen{reply: func(user string) (string, error) {
		capturedUser = user
		return `{"ops":[{"op":"new_decision","title":"Ghost decision","essence":"e",
			"mentions":[{"source":"slack","ref":"C1|2.2","quote":"deleted decision","author":"Bob","said_at":"2026-08-01T00:00:00Z"}]}]}`, nil
	}}
	p := New(d, testCfg(), gen, log.New(&logBuf, "", 0))
	proposed, _, err := p.runConsolidate(context.Background(), time.Time{}, time.Time{})
	require.NoError(t, err)
	assert.Zero(t, proposed)

	assert.Contains(t, capturedUser, "live idea")
	assert.NotContains(t, capturedUser, "deleted decision", "a deleted message's candidate must not be rendered")

	ideas, err := d.ListIdeas(db.IdeaFilter{})
	require.NoError(t, err)
	assert.Empty(t, ideas)

	assert.Contains(t, logBuf.String(), "dropped 1 unverifiable slack ref",
		"a tombstoned message's drop must be as visible in the log as a missing one's")
	slackDropped, refsRejected := p.AccumulatedDrops()
	assert.Equal(t, 1, slackDropped)
	assert.Equal(t, 1, refsRejected, "the op citing the dropped ref counts as an invented ref")

	dFloor, _, _, err := d.GetIdeasFloors()
	require.NoError(t, err)
	assert.Equal(t, topicID, dFloor)
}

// TestIdeas02_SlackRefRealMessage_SurvivesValidation is the happy-path pin for
// the same validation: a candidate whose ts really is in the channel is
// rendered, citable, and its mention persists — the validation must not cost
// the ordinary case anything.
func TestIdeas02_SlackRefRealMessage_SurvivesValidation(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)
	seedDigestTopicIdeas(t, d, "C1", "general",
		[]digest.IdeaCandidate{{Text: "we should try X", By: "Ann", MessageTS: "1785746329.642879"}}, nil)

	gen := &fakeGen{reply: func(string) (string, error) {
		return `{"ops":[{"op":"new_idea","title":"Try X","essence":"e",
			"mentions":[{"source":"slack","ref":"C1|1785746329.642879","quote":"we should try X","author":"Ann","said_at":"2026-08-01T00:00:00Z"}]}]}`, nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	proposed, _, err := p.runConsolidate(context.Background(), time.Time{}, time.Time{})
	require.NoError(t, err)
	assert.Equal(t, 1, proposed)

	ideas, err := d.ListIdeas(db.IdeaFilter{})
	require.NoError(t, err)
	require.Len(t, ideas, 1)
	mentions, err := d.ListIdeaMentions(ideas[0].ID)
	require.NoError(t, err)
	require.Len(t, mentions, 1)
	assert.Equal(t, "slack", mentions[0].Source)
	assert.Equal(t, "C1|1785746329.642879", mentions[0].Ref)
}

// TestIdeas02_AllSlackRefsUnverifiable_NoMaterialFloorAdvances is the
// valid-but-degenerate input for the same path (see the "test the degenerate
// clean-exit branch" house rule): a topic whose EVERY candidate is
// unverifiable renders to nothing, so it behaves exactly like a candidate-less
// topic — no AI call at all, yet the floor still advances so the same dead
// topic is not re-read forever (IDEA-01).
func TestIdeas02_AllSlackRefsUnverifiable_NoMaterialFloorAdvances(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)
	topicID := seedDigestTopicIdeasUnverified(t, d, "C1", "general", []digest.IdeaCandidate{
		{Text: "ghost one", By: "Ann", MessageTS: "1754131080.000000"},
		{Text: "ghost two", By: "Ann", MessageTS: "1754131081.000000"},
	}, nil)

	gen := &fakeGen{reply: func(string) (string, error) {
		t.Fatal("generator must not be called when every candidate was dropped")
		return "", nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	proposed, _, err := p.runConsolidate(context.Background(), time.Time{}, time.Time{})
	require.NoError(t, err)
	assert.Zero(t, proposed)
	assert.Zero(t, gen.calls)

	dFloor, _, _, err := d.GetIdeasFloors()
	require.NoError(t, err)
	assert.Equal(t, topicID, dFloor, "a fully-dropped topic is consumed like an empty one, not left blocking")
}

// TestIdeas02_MessageLookupError_FailsRunFloorsUntouched pins the other half
// of the same validation: an unreadable messages table is an INFRASTRUCTURE
// failure, not a verdict that every candidate was invented. Swallowing it
// would render every topic as candidate-less and quietly advance the floors
// over real material (IDEA-01) — so the run fails instead, with nothing
// consumed and no AI call made.
func TestIdeas02_MessageLookupError_FailsRunFloorsUntouched(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)
	seedDigestTopicIdeas(t, d, "C1", "general",
		[]digest.IdeaCandidate{{Text: "try X", By: "Ann", MessageTS: "1.1"}}, nil)
	_, err := d.Exec(`DROP TABLE messages`)
	require.NoError(t, err)

	gen := &fakeGen{reply: func(string) (string, error) {
		t.Fatal("generator must not be called when the material could not be verified")
		return "", nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	_, _, err = p.runConsolidate(context.Background(), time.Time{}, time.Time{})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "verifying slack refs")
	assert.Zero(t, gen.calls)

	dFloor, _, _, err := d.GetIdeasFloors()
	require.NoError(t, err)
	assert.Zero(t, dFloor, "an unverifiable run consumes nothing")
}

// sqliteMaxVariables is modernc.org/sqlite's SQLITE_MAX_VARIABLE_NUMBER. A
// statement carrying MORE bound parameters than this fails to prepare with
// "too many SQL variables" — which is how the test below forces the SECOND of
// two topics to fail its messages lookup while the first one renders cleanly,
// something no in-memory DB error injection can express (both topics share one
// real *db.DB). Should a future driver raise the limit, the test fails loudly
// on its require.Error rather than passing silently, and this constant is what
// needs bumping.
const sqliteMaxVariables = 32766

// TestIdeas01_SecondTopicLookupFails_WholeInputDiscardedNoPartialFloor is the
// IDEA-01 crux for the Slack-ref validation's error path: topic 1 renders
// successfully and topic 2's messages lookup then fails, and the run must
// discard the WHOLE gathered input — no AI call on topic 1 alone, and above
// all no floor advanced past topic 1. Advancing it would consume topic 1's
// material without ever applying it, which is exactly the loss IDEA-01 exists
// to prevent; the pre-run stream/transcript floors must survive untouched too,
// since a partial write is what we are ruling out, not merely a wrong value.
func TestIdeas01_SecondTopicLookupFails_WholeInputDiscardedNoPartialFloor(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)
	// Non-zero starting floors on the two sources this run never reaches, so
	// "unchanged" is a real assertion rather than "still the zero value".
	require.NoError(t, d.SetIdeasFloors(0, 42, 7))

	topic1 := seedDigestTopicIdeas(t, d, "C1", "general",
		[]digest.IdeaCandidate{{Text: "verifiable idea", By: "Ann", MessageTS: "1.1"}}, nil)

	// Topic 2 carries one more candidate than the driver can bind in a single
	// IN (...) lookup (its channel_id argument takes the last slot), so
	// renderTopicUnit's verification query cannot even be prepared.
	oversized := make([]digest.IdeaCandidate, sqliteMaxVariables)
	for i := range oversized {
		oversized[i] = digest.IdeaCandidate{Text: "c", By: "Ann", MessageTS: fmt.Sprintf("%d.1", i)}
	}
	topic2 := seedDigestTopicIdeasUnverified(t, d, "C1", "general", oversized, nil)
	require.Greater(t, topic2, topic1, "the failing topic must be listed second")

	gen := &fakeGen{reply: func(string) (string, error) {
		t.Fatal("generator must not be called when part of the material could not be verified")
		return "", nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	_, _, err := p.runConsolidate(context.Background(), time.Time{}, time.Time{})
	require.Error(t, err)
	assert.Contains(t, err.Error(), fmt.Sprintf("verifying slack refs for digest topic %d", topic2))
	assert.Zero(t, gen.calls)

	dFloor, sFloor, tFloor, err := d.GetIdeasFloors()
	require.NoError(t, err)
	assert.Zero(t, dFloor, "the successfully rendered topic must NOT be consumed by a failed run")
	assert.EqualValues(t, 42, sFloor)
	assert.EqualValues(t, 7, tFloor)
}

// TestConsolidate_AttachMention_ActiveIdea covers case 3: attaching to an
// active idea records the mention, bumps last_mention_at, and leaves status
// and needs_review untouched.
func TestConsolidate_AttachMention_ActiveIdea(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)
	ideaID := seedIdeaRow(t, d, db.Idea{Kind: "idea", Title: "Existing", Essence: "e", Status: "active"})
	seedStreamDigestIdeas(t, d, "jira", 1, []streamTopic{{
		Title: "t", Summary: "s",
		Ideas: []streamCandidate{{Text: "existing idea again", Author: "Bob", Ref: "WT-9"}},
	}})

	gen := &fakeGen{reply: func(string) (string, error) {
		return fmt.Sprintf(`{"ops":[{"op":"attach_mention","idea_id":%d,"mention":{"source":"jira","ref":"WT-9","quote":"q","author":"Bob","said_at":"2026-08-01T00:00:00Z"}}]}`, ideaID), nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	proposed, _, err := p.runConsolidate(context.Background(), time.Time{}, time.Time{})
	require.NoError(t, err)
	assert.Zero(t, proposed)

	mentions, err := d.ListIdeaMentions(ideaID)
	require.NoError(t, err)
	require.Len(t, mentions, 1)

	idea, err := d.GetIdea(ideaID)
	require.NoError(t, err)
	assert.Equal(t, "active", idea.Status)
	assert.False(t, idea.NeedsReview)
	assert.Equal(t, "2026-08-01T00:00:00Z", idea.LastMentionAt)
}

// TestIdeas04_AttachMentionRejectedIdeaNeedsReview covers case 4
// (IDEA-04): attaching a fresh sighting to a rejected idea flags it for
// owner review with a reason, but never overturns the rejected verdict.
func TestIdeas04_AttachMentionRejectedIdeaNeedsReview(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)
	ideaID := seedIdeaRow(t, d, db.Idea{Kind: "idea", Title: "Old idea", Essence: "e", Status: "rejected"})
	seedStreamDigestIdeas(t, d, "jira", 1, []streamTopic{{
		Title: "t", Summary: "s",
		Ideas: []streamCandidate{{Text: "brought up again", Author: "Bob", Ref: "WT-1"}},
	}})

	gen := &fakeGen{reply: func(string) (string, error) {
		return fmt.Sprintf(`{"ops":[{"op":"attach_mention","idea_id":%d,"mention":{"source":"jira","ref":"WT-1","quote":"q","author":"Bob","said_at":"2026-08-02T00:00:00Z"}}]}`, ideaID), nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	_, _, err := p.runConsolidate(context.Background(), time.Time{}, time.Time{})
	require.NoError(t, err)

	idea, err := d.GetIdea(ideaID)
	require.NoError(t, err)
	assert.Equal(t, "rejected", idea.Status, "IDEA-04: a resurfacing must not overturn the owner's verdict")
	assert.True(t, idea.NeedsReview)
	assert.Contains(t, idea.ReviewReason, "brought up again")
	assert.Contains(t, idea.ReviewReason, "WT-1")
}

// TestIdeas03_AttachMentionMergedIdeaLandsOnTarget covers case 5: a
// mention cited against an idea that has since been merged away lands on its
// merged_into_id target instead — the merged idea itself gets nothing.
func TestIdeas03_AttachMentionMergedIdeaLandsOnTarget(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)
	targetID := seedIdeaRow(t, d, db.Idea{Kind: "idea", Title: "Target", Essence: "e", Status: "active"})
	mergedID := seedIdeaRow(t, d, db.Idea{
		Kind: "idea", Title: "Merged away", Essence: "e", Status: "merged",
		MergedIntoID: sql.NullInt64{Int64: targetID, Valid: true},
	})
	seedStreamDigestIdeas(t, d, "gmail", 1, []streamTopic{{
		Title: "t", Summary: "s",
		Ideas: []streamCandidate{{Text: "same idea again", Author: "Ann", Ref: "gmail:1:thr-1"}},
	}})

	gen := &fakeGen{reply: func(string) (string, error) {
		return fmt.Sprintf(`{"ops":[{"op":"attach_mention","idea_id":%d,"mention":{"source":"gmail","ref":"gmail:1:thr-1","quote":"q","author":"Ann","said_at":"2026-08-01T00:00:00Z"}}]}`, mergedID), nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	_, _, err := p.runConsolidate(context.Background(), time.Time{}, time.Time{})
	require.NoError(t, err)

	targetMentions, err := d.ListIdeaMentions(targetID)
	require.NoError(t, err)
	assert.Len(t, targetMentions, 1)

	mergedMentions, err := d.ListIdeaMentions(mergedID)
	require.NoError(t, err)
	assert.Empty(t, mergedMentions)
}

// TestIdeas01_GeneratorErrorNothingWritten covers case 6 (IDEA-01): a
// failed AI call writes no rows and leaves every floor untouched.
func TestIdeas01_GeneratorErrorNothingWritten(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)
	seedDigestTopicIdeas(t, d, "C1", "general",
		[]digest.IdeaCandidate{{Text: "try X", By: "Ann", MessageTS: "1.1"}}, nil)

	gen := &fakeGen{reply: func(string) (string, error) { return "", fmt.Errorf("boom") }}
	p := New(d, testCfg(), gen, testLogger())
	proposed, _, err := p.runConsolidate(context.Background(), time.Time{}, time.Time{})
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

// TestIdeas01_MalformedJSONNothingWritten covers case 7: same as a
// generator error — a reply with no parseable JSON object writes nothing and
// leaves the floors untouched.
func TestIdeas01_MalformedJSONNothingWritten(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)
	seedDigestTopicIdeas(t, d, "C1", "general",
		[]digest.IdeaCandidate{{Text: "try X", By: "Ann", MessageTS: "1.1"}}, nil)

	gen := &fakeGen{reply: func(string) (string, error) { return "not json at all", nil }}
	p := New(d, testCfg(), gen, testLogger())
	proposed, _, err := p.runConsolidate(context.Background(), time.Time{}, time.Time{})
	require.Error(t, err)
	assert.Zero(t, proposed)

	ideas, err := d.ListIdeas(db.IdeaFilter{})
	require.NoError(t, err)
	assert.Empty(t, ideas)

	dFloor, _, _, err := d.GetIdeasFloors()
	require.NoError(t, err)
	assert.Zero(t, dFloor)
}

// TestIdeas01_NoNewMaterialCleanNoOp covers case 8 (the degenerate
// clean-exit branch, see feedback_test_degenerate_clean_exit): with nothing
// new above any floor — including a workspace row that doesn't exist yet —
// the generator must never be called.
func TestIdeas01_NoNewMaterialCleanNoOp(t *testing.T) {
	d := newTestDB(t) // no workspace row seeded — exercises the fresh-workspace floor fallback too

	gen := &fakeGen{reply: func(string) (string, error) {
		t.Fatal("generator must not be called with no new material")
		return "", nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	proposed, _, err := p.runConsolidate(context.Background(), time.Time{}, time.Time{})
	require.NoError(t, err)
	assert.Zero(t, proposed)
	assert.Zero(t, gen.calls)
}

// TestIdeas01_MaxPromptCharsTruncatesToWholeUnits covers case 9: with a
// budget that exactly fits the first of two digest topics, only the first is
// included in the material sent to the model, and the digest floor advances
// only past it — the second topic is left for a future run.
func TestIdeas01_MaxPromptCharsTruncatesToWholeUnits(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)

	topic1Ideas := []digest.IdeaCandidate{{Text: "idea one", By: "Ann", MessageTS: "1.1"}}
	ideasJSON, err := json.Marshal(topic1Ideas)
	require.NoError(t, err)

	// Seeded before the unit is rendered: renderTopicUnit now resolves every
	// candidate ts against a real message, so a unit measured against an
	// unseeded channel would come back empty (IDEA-02).
	id1 := seedDigestTopicIdeas(t, d, "C1", "general", topic1Ideas, nil)
	unit1, _, err := New(d, testCfg(), nil, testLogger()).
		renderTopicUnit(db.DigestTopicForIdeas{ChannelID: "C1", Ideas: string(ideasJSON), Decisions: "[]"})
	require.NoError(t, err)
	require.NotEmpty(t, unit1)

	seedDigestTopicIdeas(t, d, "C1", "general",
		[]digest.IdeaCandidate{{Text: "idea two", By: "Ann", MessageTS: "2.2"}}, nil)

	var capturedUser string
	gen := &fakeGen{reply: func(user string) (string, error) {
		capturedUser = user
		return `{"ops":[]}`, nil
	}}
	cfg := testCfg()
	cfg.Ideas.MaxPromptChars = len(unit1)
	p := New(d, cfg, gen, testLogger())
	proposed, _, err := p.runConsolidate(context.Background(), time.Time{}, time.Time{})
	require.NoError(t, err)
	assert.Zero(t, proposed)
	assert.Equal(t, 1, gen.calls)

	assert.Contains(t, capturedUser, "idea one")
	assert.NotContains(t, capturedUser, "idea two")

	dFloor, _, _, err := d.GetIdeasFloors()
	require.NoError(t, err)
	assert.Equal(t, id1, dFloor, "the floor must advance only past the included topic")
}

// TestConsolidate_TranscriptRecapWait_StopsAtRecentRecaplessTranscript
// covers the spec §7 transcript nuance: a just-created transcript with no
// recap yet stops transcript consumption at the row before it (the recap may
// still arrive), even though it and any later transcript are otherwise
// eligible.
func TestConsolidate_TranscriptRecapWait_StopsAtRecentRecaplessTranscript(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)

	oldID := seedTranscriptForIdeas(t, d, "Old meeting",
		`{"ideas":["explore new tool"],"key_decisions":[]}`, time.Now().Add(-time.Hour))
	seedTranscriptForIdeas(t, d, "Fresh meeting", "", time.Now()) // no recap yet, brand new

	gen := &fakeGen{reply: func(string) (string, error) {
		return `{"ops":[]}`, nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	_, _, err := p.runConsolidate(context.Background(), time.Time{}, time.Time{})
	require.NoError(t, err)
	assert.Equal(t, 1, gen.calls)

	_, _, tFloor, err := d.GetIdeasFloors()
	require.NoError(t, err)
	assert.Equal(t, oldID, tFloor, "consumption must stop before the recent recap-less transcript")
}

// TestConsolidate_TranscriptRecapWait_SkipsStaleRecaplessTranscript covers
// the other half of spec §7: an OLD transcript that never got a recap is
// skipped (not rendered) but still counted — the floor moves past it so it
// isn't rechecked forever.
func TestConsolidate_TranscriptRecapWait_SkipsStaleRecaplessTranscript(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)

	staleID := seedTranscriptForIdeas(t, d, "Stale meeting", "", time.Now().Add(-72*time.Hour))
	freshID := seedTranscriptForIdeas(t, d, "Recapped meeting",
		`{"ideas":["ship the thing"],"key_decisions":[]}`, time.Now().Add(-time.Hour))

	gen := &fakeGen{reply: func(string) (string, error) {
		return `{"ops":[]}`, nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	_, _, err := p.runConsolidate(context.Background(), time.Time{}, time.Time{})
	require.NoError(t, err)
	assert.Equal(t, 1, gen.calls)

	_, _, tFloor, err := d.GetIdeasFloors()
	require.NoError(t, err)
	assert.Equal(t, freshID, tFloor, "the stale recap-less transcript is skipped-and-counted, not left blocking")
	assert.Greater(t, freshID, staleID)
}

// TestRun_CallsConsolidate_ReturnsProposedCount is a Run()-level smoke test:
// once both stage-1 passes complete cleanly, Run must invoke the
// consolidator and surface its proposed count.
func TestRun_CallsConsolidate_ReturnsProposedCount(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)
	seedDigestTopicIdeas(t, d, "C1", "general",
		[]digest.IdeaCandidate{{Text: "try X", By: "Ann", MessageTS: "1.1"}}, nil)

	gen := &fakeGen{reply: func(string) (string, error) {
		return `{"ops":[{"op":"new_idea","title":"Try X","essence":"e",
			"mentions":[{"source":"slack","ref":"C1|1.1","quote":"try X","author":"Ann","said_at":"2026-08-01T00:00:00Z"}]}]}`, nil
	}}
	cfg := testCfg()
	cfg.Ideas.Enabled = true
	p := New(d, cfg, gen, testLogger())

	proposed, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, proposed)
}

// --- IDEA-05: re-mining idempotency (ref-level dedup) ----------------------

// TestIdeas05_RerunSameWindow_NoDuplicates re-mines the SAME material twice —
// the backfill scenario, simulated here by rewinding the digest floor back to
// zero after the first run so gatherConsolidateInput re-reads the same topic.
// The second run must create nothing new: the op's only mention cites a ref
// already recorded on the idea the first run minted, so the whole op is
// dropped (IDEA-02's "nothing survived" path, now also reachable via
// IDEA-05) and the dedup count is surfaced on the run's log line.
func TestIdeas05_RerunSameWindow_NoDuplicates(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)
	topicID := seedDigestTopicIdeas(t, d, "C1", "general",
		[]digest.IdeaCandidate{{Text: "we should try X", By: "Ann", MessageTS: "1.1"}}, nil)

	gen := &fakeGen{reply: func(string) (string, error) {
		return `{"ops":[{"op":"new_idea","title":"Try X","essence":"e",
			"mentions":[{"source":"slack","ref":"C1|1.1","quote":"we should try X","author":"Ann","said_at":"2026-08-01T00:00:00Z"}]}]}`, nil
	}}
	var logBuf bytes.Buffer
	p := New(d, testCfg(), gen, log.New(&logBuf, "", 0))

	proposed, _, err := p.runConsolidate(context.Background(), time.Time{}, time.Time{})
	require.NoError(t, err)
	assert.Equal(t, 1, proposed)

	ideas, err := d.ListIdeas(db.IdeaFilter{})
	require.NoError(t, err)
	require.Len(t, ideas, 1)
	mentions, err := d.ListIdeaMentions(ideas[0].ID)
	require.NoError(t, err)
	require.Len(t, mentions, 1)

	// Rewind the floor — the backfill precedent — so the same topic is
	// re-read on the next run.
	tx, err := d.Begin()
	require.NoError(t, err)
	require.NoError(t, d.SetIdeasFloorsTx(tx, 0, 0, 0))
	require.NoError(t, tx.Commit())

	logBuf.Reset()
	proposed, _, err = p.runConsolidate(context.Background(), time.Time{}, time.Time{})
	require.NoError(t, err)
	assert.Zero(t, proposed, "the ref was already mined — no new idea")
	assert.Equal(t, 2, gen.calls)

	ideas, err = d.ListIdeas(db.IdeaFilter{})
	require.NoError(t, err)
	assert.Len(t, ideas, 1, "no duplicate idea")
	mentions, err = d.ListIdeaMentions(ideas[0].ID)
	require.NoError(t, err)
	assert.Len(t, mentions, 1, "no duplicate mention")

	dFloor, _, _, err := d.GetIdeasFloors()
	require.NoError(t, err)
	assert.Equal(t, topicID, dFloor, "the floor still advances — the rerun still fully consumed the topic")

	assert.Contains(t, logBuf.String(), "deduped 1 already-mined mention", "mentionsDeduped must be surfaced on the run's log line")
}

// TestIdeas05_AttachKnownRef_InsertsNothing covers layer 1's attach_mention
// half of the contract: attaching a ref that's already recorded on the
// target idea inserts nothing. It also pins the IDEA-05 x IDEA-04
// intersection from the design doc: since the dedup drop is not-new-evidence,
// it must NOT resurface a rejected/dropped/not_now verdict via needs_review.
func TestIdeas05_AttachKnownRef_InsertsNothing(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)
	ideaID := seedIdeaRow(t, d, db.Idea{Kind: "idea", Title: "Old idea", Essence: "e", Status: "rejected"})
	seedIdeaMention(t, d, ideaID, "jira", "WT-9") // already mined by an earlier cycle
	seedStreamDigestIdeas(t, d, "jira", 1, []streamTopic{{
		Title: "t", Summary: "s",
		Ideas: []streamCandidate{{Text: "existing idea again", Author: "Bob", Ref: "WT-9"}},
	}})

	gen := &fakeGen{reply: func(string) (string, error) {
		return fmt.Sprintf(`{"ops":[{"op":"attach_mention","idea_id":%d,"mention":{"source":"jira","ref":"WT-9","quote":"q","author":"Bob","said_at":"2026-08-02T00:00:00Z"}}]}`, ideaID), nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	proposed, _, err := p.runConsolidate(context.Background(), time.Time{}, time.Time{})
	require.NoError(t, err)
	assert.Zero(t, proposed)

	mentions, err := d.ListIdeaMentions(ideaID)
	require.NoError(t, err)
	require.Len(t, mentions, 1, "the already-known ref must not be inserted a second time")

	idea, err := d.GetIdea(ideaID)
	require.NoError(t, err)
	assert.Equal(t, "rejected", idea.Status)
	assert.False(t, idea.NeedsReview, "a deduped attach carries no new evidence, so it must not resurface the verdict (IDEA-05 x IDEA-04)")
	assert.Empty(t, idea.ReviewReason)
}

// TestIdeas05_PartiallyKnownNewIdea_KeepsUnknownRefsOnly covers layer 1's
// new_idea/new_decision half: an op citing two mentions, one already mined
// (against a DIFFERENT idea, simulating a stale AI clustering decision) and
// one genuinely new, still creates the idea but keeps only the unknown ref —
// the known one is dropped, not duplicated.
func TestIdeas05_PartiallyKnownNewIdea_KeepsUnknownRefsOnly(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)
	otherID := seedIdeaRow(t, d, db.Idea{Kind: "idea", Title: "Other", Essence: "e", Status: "active"})
	seedIdeaMention(t, d, otherID, "slack", "C1|1.1") // already mined, elsewhere in the registry

	seedDigestTopicIdeas(t, d, "C1", "general", []digest.IdeaCandidate{
		{Text: "we should try X", By: "Ann", MessageTS: "1.1"},
		{Text: "we should try Y", By: "Ann", MessageTS: "2.2"},
	}, nil)

	gen := &fakeGen{reply: func(string) (string, error) {
		return `{"ops":[{"op":"new_idea","title":"Try X and Y","essence":"e","mentions":[
			{"source":"slack","ref":"C1|1.1","quote":"we should try X","author":"Ann","said_at":"2026-08-01T00:00:00Z"},
			{"source":"slack","ref":"C1|2.2","quote":"we should try Y","author":"Ann","said_at":"2026-08-01T00:00:00Z"}
		]}]}`, nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	proposed, _, err := p.runConsolidate(context.Background(), time.Time{}, time.Time{})
	require.NoError(t, err)
	assert.Equal(t, 1, proposed, "the op still creates an idea — it wasn't ALL known")

	ideas, err := d.ListIdeas(db.IdeaFilter{Status: "proposed"})
	require.NoError(t, err)
	require.Len(t, ideas, 1)
	mentions, err := d.ListIdeaMentions(ideas[0].ID)
	require.NoError(t, err)
	require.Len(t, mentions, 1, "only the unknown ref survives")
	assert.Equal(t, "C1|2.2", mentions[0].Ref)

	// The known ref was not duplicated onto the new idea either.
	otherMentions, err := d.ListIdeaMentions(otherID)
	require.NoError(t, err)
	assert.Len(t, otherMentions, 1)
}

// TestGB6_TwoNewIdeasShareSameRefInOnePass_BothSurvive pins the 2026-08-08
// [OWNER] ruling on IDEA-05 clause 2: a ref minted by an EARLIER new_idea/
// new_decision op in the SAME apply pass must not make a LATER op's
// identical ref look "already known" — a single message can genuinely
// evidence two distinct new ideas, and both must survive. Without the
// same-tx exclusion, op 2's only mention would be seen as a duplicate of
// what op 1 just inserted moments earlier in this same transaction, and op
// 2 would be silently discarded entirely.
func TestGB6_TwoNewIdeasShareSameRefInOnePass_BothSurvive(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)

	seedDigestTopicIdeas(t, d, "C1", "general", []digest.IdeaCandidate{
		{Text: "we should try X and also Y", By: "Ann", MessageTS: "1.1"},
	}, nil)

	gen := &fakeGen{reply: func(string) (string, error) {
		return `{"ops":[
			{"op":"new_idea","title":"Try X","essence":"e","mentions":[{"source":"slack","ref":"C1|1.1","quote":"try X","author":"Ann","said_at":"2026-08-01T00:00:00Z"}]},
			{"op":"new_idea","title":"Try Y","essence":"e","mentions":[{"source":"slack","ref":"C1|1.1","quote":"try Y","author":"Ann","said_at":"2026-08-01T00:00:00Z"}]}
		]}`, nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	proposed, mentionsDeduped, err := p.runConsolidate(context.Background(), time.Time{}, time.Time{})
	require.NoError(t, err)
	assert.Equal(t, 2, proposed, "two distinct ideas citing the same ref within one pass must both survive")
	assert.Zero(t, mentionsDeduped, "the second op's ref must not be treated as already-mined just because the first op minted it earlier in this same pass")

	ideas, err := d.ListIdeas(db.IdeaFilter{Status: "proposed"})
	require.NoError(t, err)
	require.Len(t, ideas, 2)
	for _, idea := range ideas {
		mentions, err := d.ListIdeaMentions(idea.ID)
		require.NoError(t, err)
		require.Len(t, mentions, 1)
		assert.Equal(t, "C1|1.1", mentions[0].Ref)
	}
}

// TestGB5_AttachMention_RefKnownOnDifferentIdea_StillInsertsOnTarget pins
// GB5 (attach dedup stays TARGET-SCOPED, [OWNER] confirmed): a ref already
// recorded on a DIFFERENT idea must not block attaching it to the target —
// the two ideas are separately, legitimately evidenced by the same message.
// The mirror image of TestIdeas05_AttachKnownRef_InsertsNothing, which pins
// the opposite case (ref known on the TARGET itself). A genuinely new
// mention on a rejected target must still flag it for review (IDEA-04).
func TestGB5_AttachMention_RefKnownOnDifferentIdea_StillInsertsOnTarget(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)
	otherID := seedIdeaRow(t, d, db.Idea{Kind: "idea", Title: "Other", Essence: "e", Status: "active"})
	seedIdeaMention(t, d, otherID, "jira", "WT-9") // same ref, but on a DIFFERENT idea

	targetID := seedIdeaRow(t, d, db.Idea{Kind: "idea", Title: "Target", Essence: "e", Status: "rejected"})
	seedStreamDigestIdeas(t, d, "jira", 1, []streamTopic{{
		Title: "t", Summary: "s",
		Ideas: []streamCandidate{{Text: "existing idea again", Author: "Bob", Ref: "WT-9"}},
	}})

	gen := &fakeGen{reply: func(string) (string, error) {
		return fmt.Sprintf(`{"ops":[{"op":"attach_mention","idea_id":%d,"mention":{"source":"jira","ref":"WT-9","quote":"q","author":"Bob","said_at":"2026-08-02T00:00:00Z"}}]}`, targetID), nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	_, mentionsDeduped, err := p.runConsolidate(context.Background(), time.Time{}, time.Time{})
	require.NoError(t, err)
	assert.Zero(t, mentionsDeduped, "a ref known on a DIFFERENT idea is not a dedup hit for the target")

	mentions, err := d.ListIdeaMentions(targetID)
	require.NoError(t, err)
	require.Len(t, mentions, 1, "a ref known on a DIFFERENT idea must not block attaching it to the target")
	assert.Equal(t, "WT-9", mentions[0].Ref)

	idea, err := d.GetIdea(targetID)
	require.NoError(t, err)
	assert.True(t, idea.NeedsReview, "a genuinely new mention on a rejected target must still flag it for review (IDEA-04)")
	assert.Contains(t, idea.ReviewReason, "WT-9")

	// The other idea's own mention must be untouched.
	otherMentions, err := d.ListIdeaMentions(otherID)
	require.NoError(t, err)
	require.Len(t, otherMentions, 1)
}
