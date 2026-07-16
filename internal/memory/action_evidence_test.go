package memory

import (
	"context"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// TestNewEvidenceLinesMintsOwnerActionForActRef: newEvidenceLines mints the
// owner-action rank for an act: ref (as it mints owner for a chat: ref), and
// leaves an ordinary episode ref at observed rank — the rank is derived from the
// ref's scheme by CODE, never named by the model.
func TestNewEvidenceLinesMintsOwnerActionForActRef(t *testing.T) {
	lines := newEvidenceLines([]episodeRef{
		{ChannelID: "act:inbox_feedback:7", TS: "1720000000"},
		{ChannelID: "C1CHAN", TS: "100.0"},
		{ChannelID: "mail:m1", TS: "1720000001"},
		{ChannelID: "chat:9", TS: "1720000002"},
	}, opConfirm)

	require.Len(t, lines, 4)
	assert.Equal(t, rankOwnerAction, lines[0].Rank, "act: ref → owner-action")
	assert.Equal(t, rankObserved, lines[1].Rank, "bare channel ref → observed")
	assert.Equal(t, rankObserved, lines[2].Rank, "mail: ref → observed")
	assert.Equal(t, rankOwner, lines[3].Rank, "chat: ref → owner")
}

// TestMemory15_ActionRankOnlyFromInteractionRows is the MEM-15 formal guard:
// owner-action evidence is minted only by code for an act: ref that a registered
// resolver confirmed points at a real whitelisted interaction row. A model op
// that forges a "rank" key never yields owner-action (the op schema carries no
// rank field — the rank is derived from the ref scheme); an act: ref to a
// non-existent row is dropped exactly like an invented ref.
func TestMemory15_ActionRankOnlyFromInteractionRows(t *testing.T) {
	t.Run("validated act: ref mints an owner-action evidence line", func(t *testing.T) {
		v, d := newTestVault(t), newTestDB(t)
		subjectID := "ent_00000000000000000000000001"
		epID := "ep_00000000000000000000000001"
		tsRef := fmt.Sprintf("%d.000100", beliefNow.AddDate(0, 0, -5).Unix())
		writeAndIndex(t, v, d, rewriteEpisodeNode(epID, "C1CHAN", tsRef))
		writeAndIndex(t, v, d, beliefSubjectEntity(subjectID, epID))
		bel := beliefTestNode("bel_00000000000000000000000001", "Alice is reliable", subjectID, 0.5, 0, "active")
		writeAndIndex(t, v, d, bel)

		sitID, err := d.CreateSituation(db.DashboardSituation{Title: "s", Summary: "s", Chronology: "c"})
		require.NoError(t, err)
		actRef := fmt.Sprintf("act:situations:%d", sitID)

		gen := &fakeGen{reply: func(string) (string, error) {
			return opsJSON(t, beliefOpJSON{BeliefID: bel.ID, Op: "confirm",
				Evidence: []episodeRef{{ChannelID: actRef, TS: "1720000000"}}, Rationale: "owner acted on it"}), nil
		}}
		p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)
		// Stage the act: ref into the input set exactly as the interaction ingest
		// (Task 7) will — so it passes validateMarkers and reaches the act resolver.
		staged := &stagedChat{
			refs:     map[string]bool{actRef + " 1720000000": true},
			subjects: map[string]bool{subjectID: true},
		}

		touched, _, _, _, err := p.ReviseBeliefs(context.Background(), nil, staged, 20, beliefNow)
		require.NoError(t, err)
		require.Equal(t, 1, touched, "the act-backed confirm applied")

		got, err := v.ReadNode(bel.ID)
		require.NoError(t, err)
		assert.Contains(t, got.Body, "- owner-action for "+actRef+" 1720000000",
			"a validated act: ref mints an owner-action evidence line")
	})

	t.Run("act: ref to a non-existent row is dropped like an invented ref", func(t *testing.T) {
		v, d := newTestVault(t), newTestDB(t)
		subjectID := "ent_00000000000000000000000001"
		epID := "ep_00000000000000000000000001"
		tsRef := fmt.Sprintf("%d.000100", beliefNow.AddDate(0, 0, -5).Unix())
		writeAndIndex(t, v, d, rewriteEpisodeNode(epID, "C1CHAN", tsRef))
		writeAndIndex(t, v, d, beliefSubjectEntity(subjectID, epID))
		bel := beliefTestNode("bel_00000000000000000000000001", "Alice is reliable", subjectID, 0.5, 0, "active")
		writeAndIndex(t, v, d, bel)

		ghostRef := "act:situations:999999" // no such row
		gen := &fakeGen{reply: func(string) (string, error) {
			return opsJSON(t, beliefOpJSON{BeliefID: bel.ID, Op: "confirm",
				Evidence: []episodeRef{{ChannelID: ghostRef, TS: "1720000000"}}, Rationale: "forged"}), nil
		}}
		p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)
		staged := &stagedChat{
			refs:     map[string]bool{ghostRef + " 1720000000": true}, // even staged, the resolver drops it
			subjects: map[string]bool{subjectID: true},
		}

		touched, _, _, _, err := p.ReviseBeliefs(context.Background(), nil, staged, 20, beliefNow)
		require.NoError(t, err)
		assert.Zero(t, touched, "an act: ref to a non-existent row is dropped; the evidence-less op is a no-op")

		got, err := v.ReadNode(bel.ID)
		require.NoError(t, err)
		assert.NotContains(t, got.Body, "owner-action", "no owner-action line minted for a ghost interaction row")
	})

	t.Run("a model-forged rank key never mints owner-action", func(t *testing.T) {
		// The op JSON schema carries no rank field, so a "rank" key is ignored; the
		// rank is derived from the ref scheme. An ordinary episode ref stays observed
		// no matter what rank the model names.
		raw := `{"ops":[{"belief_id":"b","op":"confirm","rank":"owner-action",` +
			`"evidence":[{"channel_id":"C1CHAN","ts":"100.0"}],"rationale":"x"}]}`
		ops, err := parseBeliefOps(raw)
		require.NoError(t, err)
		require.Len(t, ops.Ops, 1)

		lines := newEvidenceLines(ops.Ops[0].Evidence, beliefOp(ops.Ops[0].Op))
		require.Len(t, lines, 1)
		assert.Equal(t, rankObserved, lines[0].Rank,
			"a model-named rank is ignored; a bare episode ref stays observed (MEM-15)")
	})
}
