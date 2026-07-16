package memory

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

var beliefNow = time.Date(2026, 3, 15, 12, 0, 0, 0, time.UTC)

// beliefSubjectEntity is an entity page linking one episode (the new-evidence
// source for the belief pass).
func beliefSubjectEntity(id, epID string) Node {
	body := "# Subject\n\n## What\nx\n\n## Current\n\n## Facts\n\n## Links\n- [[" + epID + "]]\n\n## Open loops\n"
	return Node{ID: id, Type: "entity", Tier: "long", Status: "active", Title: "Subject", Aliases: []string{id + "-alias"}, Body: body}
}

// beliefTestNode builds a belief page with an ## Evidence block.
func beliefTestNode(id, statement, subject string, conf float64, stab int, status string, ev ...beliefEvidence) Node {
	body := "# " + statement + "\n\n## Evidence\n"
	for _, e := range ev {
		body += e.render()
	}
	body += "\n## History\n- 2026-01-01: seeded\n"
	return Node{ID: id, Type: "belief", Tier: "long", Status: status, Confidence: conf, Stability: stab, Subject: subject, Title: statement, Body: body}
}

func opsJSON(t *testing.T, ops ...beliefOpJSON) string {
	t.Helper()
	b, err := json.Marshal(beliefOpsReply{Ops: ops})
	require.NoError(t, err)
	return string(b)
}

func TestReviseBeliefsProposeNew(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	subjectID := "ent_00000000000000000000000001"
	epID := "ep_00000000000000000000000001"
	tsRef := fmt.Sprintf("%d.000100", beliefNow.AddDate(0, 0, -5).Unix())
	writeAndIndex(t, v, d, rewriteEpisodeNode(epID, "C1CHAN", tsRef))
	writeAndIndex(t, v, d, beliefSubjectEntity(subjectID, epID))

	gen := &fakeGen{reply: func(string) (string, error) {
		return opsJSON(t, beliefOpJSON{Op: "propose-new", Statement: "Alice ships fast", Subject: subjectID,
			Evidence: []episodeRef{{ChannelID: "C1CHAN", TS: tsRef}}, Rationale: "shipped twice this week"}), nil
	}}
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	touched, _, err := p.ReviseBeliefs(context.Background(), []string{subjectID}, 20, beliefNow)
	require.NoError(t, err)
	require.Equal(t, 1, touched)

	// Find the new belief in the index.
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
	assert.LessOrEqual(t, bel.Confidence, 0.6, "birth confidence capped")
	assert.Equal(t, subjectID, bel.Subject)
	assert.Equal(t, "active", bel.Status)
	assert.Contains(t, bel.Body, "## Evidence\n- observed for C1CHAN "+tsRef)
	assert.Contains(t, bel.Body, "## History")
	assert.Contains(t, bel.Body, "created")
}

func TestReviseBeliefsFreshOwnerRetireDowngraded(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	subjectID := "ent_00000000000000000000000001"
	epID := "ep_00000000000000000000000001"
	tsAgainst := fmt.Sprintf("%d.000100", beliefNow.AddDate(0, 0, -5).Unix())
	writeAndIndex(t, v, d, rewriteEpisodeNode(epID, "C1CHAN", tsAgainst))
	writeAndIndex(t, v, d, beliefSubjectEntity(subjectID, epID))

	freshOwnerTS := fmt.Sprintf("%d", beliefNow.AddDate(0, 0, -10).Unix())
	bel := beliefTestNode("bel_00000000000000000000000001", "Alice is reliable", subjectID, 0.6, 1, "active",
		beliefEvidence{Rank: rankOwner, Support: true, ChannelID: "C1CHAN", TS: freshOwnerTS})
	writeAndIndex(t, v, d, bel)

	gen := &fakeGen{reply: func(string) (string, error) {
		return opsJSON(t, beliefOpJSON{BeliefID: bel.ID, Op: "retire",
			Evidence: []episodeRef{{ChannelID: "C1CHAN", TS: tsAgainst}}, Rationale: "one miss"}), nil
	}}
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	touched, _, err := p.ReviseBeliefs(context.Background(), []string{subjectID}, 20, beliefNow)
	require.NoError(t, err)
	require.Equal(t, 1, touched)

	got, err := v.ReadNode(bel.ID)
	require.NoError(t, err)
	assert.Equal(t, "shaken", got.Status, "MEM-06: fresh owner-rank support blocks a retire — downgraded to shaken")
	assert.NotEqual(t, "retired", got.Status)

	row, err := d.GetMemoryNode(bel.ID)
	require.NoError(t, err)
	assert.Equal(t, "shaken", row.Status, "status lands in the index")
}

func TestReviseBeliefsRetireAppliedWhenOwnerDecayed(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	subjectID := "ent_00000000000000000000000001"
	epID := "ep_00000000000000000000000001"
	tsAgainst := fmt.Sprintf("%d.000100", beliefNow.AddDate(0, 0, -5).Unix())
	writeAndIndex(t, v, d, rewriteEpisodeNode(epID, "C1CHAN", tsAgainst))
	writeAndIndex(t, v, d, beliefSubjectEntity(subjectID, epID))

	decayedOwnerTS := fmt.Sprintf("%d", beliefNow.AddDate(0, 0, -200).Unix())
	bel := beliefTestNode("bel_00000000000000000000000001", "Alice is reliable", subjectID, 0.5, 0, "active",
		beliefEvidence{Rank: rankOwner, Support: true, ChannelID: "C1CHAN", TS: decayedOwnerTS})
	writeAndIndex(t, v, d, bel)

	gen := &fakeGen{reply: func(string) (string, error) {
		return opsJSON(t, beliefOpJSON{BeliefID: bel.ID, Op: "retire",
			Evidence: []episodeRef{{ChannelID: "C1CHAN", TS: tsAgainst}}, Rationale: "consistently missing now"}), nil
	}}
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	touched, _, err := p.ReviseBeliefs(context.Background(), []string{subjectID}, 20, beliefNow)
	require.NoError(t, err)
	require.Equal(t, 1, touched)

	got, err := v.ReadNode(bel.ID)
	require.NoError(t, err)
	assert.Equal(t, "retired", got.Status, "decayed owner support no longer protects — retire applies")
}

func TestReviseBeliefsInventedEvidenceRejected(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	subjectID := "ent_00000000000000000000000001"
	epID := "ep_00000000000000000000000001"
	tsRef := fmt.Sprintf("%d.000100", beliefNow.AddDate(0, 0, -5).Unix())
	writeAndIndex(t, v, d, rewriteEpisodeNode(epID, "C1CHAN", tsRef))
	writeAndIndex(t, v, d, beliefSubjectEntity(subjectID, epID))
	bel := beliefTestNode("bel_00000000000000000000000001", "Alice is reliable", subjectID, 0.5, 0, "active")
	writeAndIndex(t, v, d, bel)

	gen := &fakeGen{reply: func(string) (string, error) {
		return opsJSON(t, beliefOpJSON{BeliefID: bel.ID, Op: "confirm",
			Evidence: []episodeRef{{ChannelID: "CFAKE", TS: "9999.000000"}}, Rationale: "made up"}), nil
	}}
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	touched, _, err := p.ReviseBeliefs(context.Background(), []string{subjectID}, 20, beliefNow)
	require.NoError(t, err)
	assert.Zero(t, touched, "an op citing only invented refs is a no-op")

	got, err := v.ReadNode(bel.ID)
	require.NoError(t, err)
	assert.Equal(t, 0.5, got.Confidence, "belief left untouched")
}

func TestReviseBeliefsProposeNewUnknownSubjectRejected(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	subjectID := "ent_00000000000000000000000001"
	epID := "ep_00000000000000000000000001"
	tsRef := fmt.Sprintf("%d.000100", beliefNow.AddDate(0, 0, -5).Unix())
	writeAndIndex(t, v, d, rewriteEpisodeNode(epID, "C1CHAN", tsRef))
	writeAndIndex(t, v, d, beliefSubjectEntity(subjectID, epID))

	gen := &fakeGen{reply: func(string) (string, error) {
		return opsJSON(t, beliefOpJSON{Op: "propose-new", Statement: "x", Subject: "ent_DOESNOTEXIST",
			Evidence: []episodeRef{{ChannelID: "C1CHAN", TS: tsRef}}, Rationale: "n/a"}), nil
	}}
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	touched, _, err := p.ReviseBeliefs(context.Background(), []string{subjectID}, 20, beliefNow)
	require.NoError(t, err)
	assert.Zero(t, touched)

	rows, err := d.ListMemoryNodes()
	require.NoError(t, err)
	for _, r := range rows {
		assert.NotEqual(t, "belief", r.Type, "no belief minted on an unknown subject")
	}
}

func TestReviseBeliefsShakeAppendsHistory(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	subjectID := "ent_00000000000000000000000001"
	epID := "ep_00000000000000000000000001"
	tsAgainst := fmt.Sprintf("%d.000100", beliefNow.AddDate(0, 0, -5).Unix())
	writeAndIndex(t, v, d, rewriteEpisodeNode(epID, "C1CHAN", tsAgainst))
	writeAndIndex(t, v, d, beliefSubjectEntity(subjectID, epID))
	bel := beliefTestNode("bel_00000000000000000000000001", "Alice is reliable", subjectID, 0.5, 0, "active")
	writeAndIndex(t, v, d, bel)

	gen := &fakeGen{reply: func(string) (string, error) {
		return opsJSON(t, beliefOpJSON{BeliefID: bel.ID, Op: "shake",
			Evidence: []episodeRef{{ChannelID: "C1CHAN", TS: tsAgainst}}, Rationale: "contradicted by the incident"}), nil
	}}
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	touched, _, err := p.ReviseBeliefs(context.Background(), []string{subjectID}, 20, beliefNow)
	require.NoError(t, err)
	require.Equal(t, 1, touched)

	got, err := v.ReadNode(bel.ID)
	require.NoError(t, err)
	assert.Equal(t, "shaken", got.Status)
	assert.Contains(t, got.Body, "shake")
	assert.Contains(t, got.Body, "contradicted by the incident")
}

func TestReviseBeliefsCapRespected(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	subjectID := "ent_00000000000000000000000001"
	epID := "ep_00000000000000000000000001"
	tsRef := fmt.Sprintf("%d.000100", beliefNow.AddDate(0, 0, -5).Unix())
	writeAndIndex(t, v, d, rewriteEpisodeNode(epID, "C1CHAN", tsRef))
	writeAndIndex(t, v, d, beliefSubjectEntity(subjectID, epID))
	b1 := beliefTestNode("bel_00000000000000000000000001", "Belief one", subjectID, 0.5, 0, "active")
	b2 := beliefTestNode("bel_00000000000000000000000002", "Belief two", subjectID, 0.5, 0, "active")
	writeAndIndex(t, v, d, b1)
	writeAndIndex(t, v, d, b2)

	gen := &fakeGen{reply: func(string) (string, error) {
		return opsJSON(t,
			beliefOpJSON{BeliefID: b1.ID, Op: "confirm", Evidence: []episodeRef{{ChannelID: "C1CHAN", TS: tsRef}}},
			beliefOpJSON{BeliefID: b2.ID, Op: "confirm", Evidence: []episodeRef{{ChannelID: "C1CHAN", TS: tsRef}}},
		), nil
	}}
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	touched, _, err := p.ReviseBeliefs(context.Background(), []string{subjectID}, 1, beliefNow)
	require.NoError(t, err)
	assert.Equal(t, 1, touched, "cap respected")
}
