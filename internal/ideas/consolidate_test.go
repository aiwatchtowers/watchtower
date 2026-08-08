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

// seedDigestTopicIdeas inserts a channel-type digest plus one digest_topics
// row carrying the given idea/decision candidates, and returns the topic id.
func seedDigestTopicIdeas(t *testing.T, d *db.DB, channelID, title string, ideas []digest.IdeaCandidate, decisions []digest.Decision) int64 {
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
	proposed, _, err := p.runConsolidate(context.Background(), time.Time{})
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
	proposed, _, err := p.runConsolidate(context.Background(), time.Time{})
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
	proposed, _, err := p.runConsolidate(context.Background(), time.Time{})
	require.NoError(t, err)
	assert.Zero(t, proposed)

	ideas, err := d.ListIdeas(db.IdeaFilter{})
	require.NoError(t, err)
	assert.Empty(t, ideas, "an op with only invented refs must write nothing")

	dFloor, _, _, err := d.GetIdeasFloors()
	require.NoError(t, err)
	assert.Equal(t, topicID, dFloor, "the run still succeeded — the floor still advances past the processed topic")
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
	proposed, _, err := p.runConsolidate(context.Background(), time.Time{})
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
	_, _, err := p.runConsolidate(context.Background(), time.Time{})
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
	_, _, err := p.runConsolidate(context.Background(), time.Time{})
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
	proposed, _, err := p.runConsolidate(context.Background(), time.Time{})
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
	proposed, _, err := p.runConsolidate(context.Background(), time.Time{})
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
	proposed, _, err := p.runConsolidate(context.Background(), time.Time{})
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
	unit1, _ := New(d, testCfg(), nil, testLogger()).
		renderTopicUnit(db.DigestTopicForIdeas{ChannelID: "C1", Ideas: string(ideasJSON), Decisions: "[]"})
	require.NotEmpty(t, unit1)

	id1 := seedDigestTopicIdeas(t, d, "C1", "general", topic1Ideas, nil)
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
	proposed, _, err := p.runConsolidate(context.Background(), time.Time{})
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
	_, _, err := p.runConsolidate(context.Background(), time.Time{})
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
	_, _, err := p.runConsolidate(context.Background(), time.Time{})
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

	proposed, _, err := p.runConsolidate(context.Background(), time.Time{})
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
	proposed, _, err = p.runConsolidate(context.Background(), time.Time{})
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
	proposed, _, err := p.runConsolidate(context.Background(), time.Time{})
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
	proposed, _, err := p.runConsolidate(context.Background(), time.Time{})
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
