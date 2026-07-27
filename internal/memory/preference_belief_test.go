package memory

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// preferenceStaged builds a stagedChat carrying one owner-action referencing the
// given situation act row, subject-mapped to subjectID — the shape the
// interaction ingest produces for the belief pass.
func preferenceStaged(actRef string, ts int64, bullet, subjectID string) *stagedChat {
	return &stagedChat{
		refs:     map[string]bool{fmt.Sprintf("%s %d", actRef, ts): true},
		subjects: map[string]bool{subjectID: true},
		actions:  []stagedAction{{ref: actRef, tsUnix: ts, text: bullet, subjects: []string{subjectID}}},
	}
}

// TestBuildReviseBeliefsPromptRendersOwnerActions: with semantic.preferences on
// and staged actions present, the belief-pass user message carries the OWNER
// ACTIONS block with the staged act: refs and the subject's engagement counts.
func TestBuildReviseBeliefsPromptRendersOwnerActions(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	subjectID := "ent_00000000000000000000000001"
	epID := "ep_00000000000000000000000001"
	tsRef := fmt.Sprintf("%d.000100", beliefNow.AddDate(0, 0, -5).Unix())
	writeAndIndex(t, v, d, rewriteEpisodeNode(epID, "C1CHAN", tsRef))
	writeAndIndex(t, v, d, beliefSubjectEntity(subjectID, epID))
	require.NoError(t, d.BumpEngagements([]db.EngagementBump{
		{NodeID: subjectID, Engaged: true, At: "2026-03-10T00:00:00Z"},
		{NodeID: subjectID, Engaged: false, At: "2026-03-11T00:00:00Z"},
		{NodeID: subjectID, Engaged: false, At: "2026-03-12T00:00:00Z"},
	}))

	gen := &fakeGen{reply: func(string) (string, error) { return "{}", nil }}
	cfg := pipelineTestConfig()
	cfg.Semantic.Preferences = true
	p := NewPipeline(d, v, gen, cfg, t.Logf)

	staged := preferenceStaged("act:situations:5", 1720000000, "owner dismissed", subjectID)
	_, _, _, _, err := p.ReviseBeliefs(context.Background(), []string{subjectID}, staged, 20, beliefNow)
	require.NoError(t, err)

	require.Len(t, gen.calls, 1)
	user := gen.calls[0]
	assert.Contains(t, user, "OWNER ACTIONS")
	assert.Contains(t, user, "act:situations:5 1720000000: owner dismissed (re "+subjectID+")")
	assert.Contains(t, user, subjectID+": engaged 1, dismissed 2")
}

// TestPreferenceBeliefBornFromOwnerAction: a scripted propose-new preference op
// citing a staged act: ref lands as a belief with exactly ONE owner-action
// evidence line and a birth confidence capped at 0.6.
func TestPreferenceBeliefBornFromOwnerAction(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	subjectID := "ent_00000000000000000000000001"
	epID := "ep_00000000000000000000000001"
	tsRef := fmt.Sprintf("%d.000100", beliefNow.AddDate(0, 0, -5).Unix())
	writeAndIndex(t, v, d, rewriteEpisodeNode(epID, "C1CHAN", tsRef))
	writeAndIndex(t, v, d, beliefSubjectEntity(subjectID, epID))

	sitID, err := d.CreateSituation(db.DashboardSituation{Title: "s", Summary: "s", Chronology: "c"})
	require.NoError(t, err)
	actRef := fmt.Sprintf("act:situations:%d", sitID)

	gen := &fakeGen{reply: func(string) (string, error) {
		return opsJSON(t, beliefOpJSON{Op: "propose-new", Statement: "the owner does not care about C1 alerts",
			Subject: subjectID, Evidence: []episodeRef{{ChannelID: actRef, TS: "1720000000"}},
			Rationale: "dismissed repeatedly"}), nil
	}}
	cfg := pipelineTestConfig()
	cfg.Semantic.Preferences = true
	p := NewPipeline(d, v, gen, cfg, t.Logf)

	staged := preferenceStaged(actRef, 1720000000, "owner dismissed", subjectID)
	touched, _, _, _, err := p.ReviseBeliefs(context.Background(), []string{subjectID}, staged, 20, beliefNow)
	require.NoError(t, err)
	require.Equal(t, 1, touched, "the preference belief was born")

	rows, err := d.ListMemoryNodes()
	require.NoError(t, err)
	var belID string
	for _, r := range rows {
		if r.Type == "belief" {
			belID = r.ID
		}
	}
	require.NotEmpty(t, belID)
	bel, err := v.ReadNode(belID)
	require.NoError(t, err)
	assert.Equal(t, subjectID, bel.Subject)
	assert.LessOrEqual(t, bel.Confidence, 0.6, "birth confidence capped at 0.6")
	assert.Contains(t, bel.Body, "- owner-action for "+actRef+" 1720000000")
	assert.Equal(t, 1, countLines(bel.Body, "owner-action for"), "exactly one owner-action evidence line")
}

// TestPreferenceBeliefGhostActRefDropped: a propose-new preference op citing an
// act: ref to a non-existent interaction row is dropped (MEM-15), so no belief
// is minted.
func TestPreferenceBeliefGhostActRefDropped(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	subjectID := "ent_00000000000000000000000001"
	epID := "ep_00000000000000000000000001"
	tsRef := fmt.Sprintf("%d.000100", beliefNow.AddDate(0, 0, -5).Unix())
	writeAndIndex(t, v, d, rewriteEpisodeNode(epID, "C1CHAN", tsRef))
	writeAndIndex(t, v, d, beliefSubjectEntity(subjectID, epID))

	ghostRef := "act:situations:999999" // no such row
	gen := &fakeGen{reply: func(string) (string, error) {
		return opsJSON(t, beliefOpJSON{Op: "propose-new", Statement: "forged preference",
			Subject: subjectID, Evidence: []episodeRef{{ChannelID: ghostRef, TS: "1720000000"}},
			Rationale: "forged"}), nil
	}}
	cfg := pipelineTestConfig()
	cfg.Semantic.Preferences = true
	p := NewPipeline(d, v, gen, cfg, t.Logf)

	staged := preferenceStaged(ghostRef, 1720000000, "owner dismissed", subjectID)
	touched, _, _, _, err := p.ReviseBeliefs(context.Background(), []string{subjectID}, staged, 20, beliefNow)
	require.NoError(t, err)
	assert.Zero(t, touched, "a ghost act: ref is dropped; the evidence-less propose-new is a no-op")

	rows, err := d.ListMemoryNodes()
	require.NoError(t, err)
	for _, r := range rows {
		assert.NotEqual(t, "belief", r.Type, "no belief minted from a ghost interaction row")
	}
}

// (TestApplyOpOwnerActionDoesNotProtectRetire already lives in
// belief_math_test.go — owner-action support confers no MEM-06 protection —
// and stays byte-green: this slice does not touch that guard.)

// TestReviseBeliefsPromptByteIdenticalWhenPreferencesOff: with the gate off,
// staged owner actions never leak into the belief-pass user message — the block
// is absent, so the prompt is byte-identical to the no-actions case for
// identical inputs.
func TestReviseBeliefsPromptByteIdenticalWhenPreferencesOff(t *testing.T) {
	build := func(withActions bool) string {
		v, d := newTestVault(t), newTestDB(t)
		subjectID := "ent_00000000000000000000000001"
		epID := "ep_00000000000000000000000001"
		tsRef := fmt.Sprintf("%d.000100", beliefNow.AddDate(0, 0, -5).Unix())
		writeAndIndex(t, v, d, rewriteEpisodeNode(epID, "C1CHAN", tsRef))
		writeAndIndex(t, v, d, beliefSubjectEntity(subjectID, epID))

		staged := &stagedChat{
			refs:     map[string]bool{"act:situations:5 1720000000": true},
			subjects: map[string]bool{subjectID: true},
		}
		if withActions {
			staged.actions = []stagedAction{{ref: "act:situations:5", tsUnix: 1720000000, text: "owner dismissed", subjects: []string{subjectID}}}
		}
		gen := &fakeGen{reply: func(string) (string, error) { return "{}", nil }}
		cfg := pipelineTestConfig() // Semantic.Preferences stays false
		p := NewPipeline(d, v, gen, cfg, t.Logf)
		_, _, _, _, err := p.ReviseBeliefs(context.Background(), []string{subjectID}, staged, 20, beliefNow)
		require.NoError(t, err)
		require.Len(t, gen.calls, 1)
		return gen.calls[0]
	}
	assert.Equal(t, build(false), build(true), "gate off: staged actions never reach the prompt")
}

// countLines counts the body lines containing needle.
func countLines(body, needle string) int {
	n := 0
	for _, line := range strings.Split(body, "\n") {
		if strings.Contains(line, needle) {
			n++
		}
	}
	return n
}
