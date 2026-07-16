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

	touched, _, _, err := p.ReviseBeliefs(context.Background(), []string{subjectID}, 20, beliefNow)
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

	touched, _, _, err := p.ReviseBeliefs(context.Background(), []string{subjectID}, 20, beliefNow)
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

	touched, _, _, err := p.ReviseBeliefs(context.Background(), []string{subjectID}, 20, beliefNow)
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

	touched, _, _, err := p.ReviseBeliefs(context.Background(), []string{subjectID}, 20, beliefNow)
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

	touched, _, _, err := p.ReviseBeliefs(context.Background(), []string{subjectID}, 20, beliefNow)
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

	touched, _, _, err := p.ReviseBeliefs(context.Background(), []string{subjectID}, 20, beliefNow)
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

	touched, _, _, err := p.ReviseBeliefs(context.Background(), []string{subjectID}, 1, beliefNow)
	require.NoError(t, err)
	assert.Equal(t, 1, touched, "cap respected")
}

// TestApplyBeliefOpMathRejectedCounts: an op the rank math refuses (a shake
// against an already-retired belief) is reported as mathRejected so ReviseBeliefs
// can count it into RunStats.BeliefOpsRejected (fix 3). Driven at applyBeliefOp
// because ReviseBeliefs excludes retired beliefs from its candidate scan.
func TestApplyBeliefOpMathRejectedCounts(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	gen := &fakeGen{reply: func(string) (string, error) { return "{}", nil }}
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	retired := beliefTestNode("bel_00000000000000000000000009", "Retired belief", "ent_x", 0.2, 0, statusRetired)
	candidates := map[string]Node{retired.ID: retired}
	inputSet := map[string]bool{"C1CHAN 100.000100": true}
	op := beliefOpJSON{BeliefID: retired.ID, Op: "shake",
		Evidence: []episodeRef{{ChannelID: "C1CHAN", TS: "100.000100"}}}

	_, applied, mathRejected := p.applyBeliefOp(op, candidates, inputSet, beliefNow)
	assert.False(t, applied, "a shake on a retired belief is not applied")
	assert.True(t, mathRejected, "the refusal is reported so it can be counted")
}

// TestParseBeliefEvidenceLogsUnparseable: a prose evidence bullet and a bad-rank
// bullet are skipped but LOGGED (not silently dropped), while canonical 4-field
// lines parse normally (fix 8 — owner-rank protection depends on canonical lines).
func TestParseBeliefEvidenceLogsUnparseable(t *testing.T) {
	body := "# B\n\n## Evidence\n" +
		"- owner for C1CHAN 100\n" + // canonical
		"- billing is behind, owner said so\n" + // prose (wrong field count)
		"- bogus for C2CHAN 200\n" // unknown rank

	var logs []string
	logf := func(format string, args ...any) { logs = append(logs, fmt.Sprintf(format, args...)) }

	ev := parseBeliefEvidence(body, logf)
	require.Len(t, ev, 1, "only the canonical line parses")
	assert.Equal(t, rankOwner, ev[0].Rank)
	assert.Len(t, logs, 2, "both unparseable lines are logged, not silently dropped")
}

// TestMemory06_OwnerRankBeliefNeverAutoFlipped is the MEM-06 formal guard: a
// belief carrying non-decayed owner-rank evidence, fed contradicting
// observations through the full belief pass, is at most shaken — never retired
// or flipped. Owner rank protects until it decays (180d); no amount of observed
// contradiction auto-flips a fresh owner belief. This drives the full
// ReviseBeliefs → applyOp seam, not the pure math directly.
func TestMemory06_OwnerRankBeliefNeverAutoFlipped(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	subjectID := "ent_00000000000000000000000001"
	epID := "ep_00000000000000000000000001"
	tsAgainst := fmt.Sprintf("%d.000100", beliefNow.AddDate(0, 0, -5).Unix())
	writeAndIndex(t, v, d, rewriteEpisodeNode(epID, "C1CHAN", tsAgainst))
	writeAndIndex(t, v, d, beliefSubjectEntity(subjectID, epID))

	freshOwnerTS := fmt.Sprintf("%d", beliefNow.AddDate(0, 0, -10).Unix()) // well within the 180d owner window
	bel := beliefTestNode("bel_00000000000000000000000001", "Alice is reliable", subjectID, 0.6, 3, "active",
		beliefEvidence{Rank: rankOwner, Support: true, ChannelID: "C1CHAN", TS: freshOwnerTS})
	writeAndIndex(t, v, d, bel)

	// The model asks to retire the belief on one contradicting observation. The
	// rank math (belief_math_test.go proves the volume-invariance exhaustively)
	// downgrades any retire/flip against non-decayed owner support to shaken.
	gen := &fakeGen{reply: func(string) (string, error) {
		return opsJSON(t, beliefOpJSON{BeliefID: bel.ID, Op: "retire",
			Evidence: []episodeRef{{ChannelID: "C1CHAN", TS: tsAgainst}}, Rationale: "one contradicting incident"}), nil
	}}
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	_, _, _, err := p.ReviseBeliefs(context.Background(), []string{subjectID}, 20, beliefNow)
	require.NoError(t, err)

	got, err := v.ReadNode(bel.ID)
	require.NoError(t, err)
	assert.Equal(t, "shaken", got.Status, "MEM-06: owner-rank belief is shaken at most, never retired")
	assert.NotEqual(t, "retired", got.Status)

	row, err := d.GetMemoryNode(bel.ID)
	require.NoError(t, err)
	assert.Equal(t, "shaken", row.Status, "index agrees the belief was never retired")
}

// TestMemory08_BeliefOpsGatedByRankMath is the MEM-08 formal guard: model output
// reaches the vault only through code-side validation. A model op the rank/
// threshold math disallows is not applied; self-declared confidence/status never
// bypass applyOp; invented evidence is rejected; and a rewrite marker absent from
// the input set is dropped.
func TestMemory08_BeliefOpsGatedByRankMath(t *testing.T) {
	t.Run("model self-declared confidence never reaches the belief", func(t *testing.T) {
		v, d := newTestVault(t), newTestDB(t)
		subjectID := "ent_00000000000000000000000001"
		epID := "ep_00000000000000000000000001"
		tsRef := fmt.Sprintf("%d.000100", beliefNow.AddDate(0, 0, -5).Unix())
		writeAndIndex(t, v, d, rewriteEpisodeNode(epID, "C1CHAN", tsRef))
		writeAndIndex(t, v, d, beliefSubjectEntity(subjectID, epID))

		// The model tries to self-declare a high confidence, an active status, and
		// a stability — all extra JSON keys the op schema does not carry, so they
		// are ignored; birth confidence comes from the rank math (capped at 0.6).
		raw := fmt.Sprintf(`{"ops":[{"op":"propose-new","statement":"Alice ships fast","subject":%q,`+
			`"confidence":0.99,"status":"active","stability":9,`+
			`"evidence":[{"channel_id":"C1CHAN","ts":%q}],"rationale":"x"}]}`, subjectID, tsRef)
		gen := &fakeGen{reply: func(string) (string, error) { return raw, nil }}
		p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

		touched, _, _, err := p.ReviseBeliefs(context.Background(), []string{subjectID}, 20, beliefNow)
		require.NoError(t, err)
		require.Equal(t, 1, touched)

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
		assert.LessOrEqual(t, bel.Confidence, 0.6, "confidence from the rank math, not the model's 0.99")
	})

	t.Run("invented-only evidence op is a no-op", func(t *testing.T) {
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

		touched, _, _, err := p.ReviseBeliefs(context.Background(), []string{subjectID}, 20, beliefNow)
		require.NoError(t, err)
		assert.Zero(t, touched, "an op citing only invented refs never reaches applyOp")

		got, err := v.ReadNode(bel.ID)
		require.NoError(t, err)
		assert.Equal(t, 0.5, got.Confidence, "belief left untouched")
	})

	t.Run("rewrite marker not in the input set is dropped", func(t *testing.T) {
		v, d := newTestVault(t), newTestDB(t)
		entID := dueEntityIDs(rewriteNow, 1)[0]
		epID := "ep_00000000000000000000000001"
		writeAndIndex(t, v, d, rewriteEpisodeNode(epID, "C1CHAN", "1710000000.000100"))
		writeAndIndex(t, v, d, rewriteEntityNode(entID, "Acme", epID))

		gen := &fakeGen{reply: func(string) (string, error) {
			return rewriteReplyJSON(t, "w", "c", []string{"f"}, []episodeRef{
				{ChannelID: "C1CHAN", TS: "1710000000.000100"}, // valid
				{ChannelID: "CFAKE", TS: "9999.000000"},        // invented
			}), nil
		}}
		p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

		rewritten, _, _, err := p.RewriteEntityPages(context.Background(), 10, rewriteNow)
		require.NoError(t, err)
		require.Len(t, rewritten, 1)

		page, err := v.ReadNode(entID)
		require.NoError(t, err)
		assert.Contains(t, page.Body, "C1CHAN 1710000000.000100")
		assert.NotContains(t, page.Body, "CFAKE", "invented marker never reaches the vault (MEM-08)")
	})
}
