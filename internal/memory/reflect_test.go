package memory

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/digest"
)

// reflectConfig enables the reflection surface on top of the semantic tier.
func reflectConfig() config.MemoryConfig {
	cfg := semanticTestConfig()
	cfg.Surfaces.Reflection = true
	return cfg
}

// reflectDueDay returns a UTC-noon time, within the next stagger window, on
// which reflection is due for the given workspace key — so a test-created churn
// commit (at real time.Now()) falls inside the pass's 7-day lookback.
func reflectDueDay(key string) time.Time {
	base := time.Now().UTC().Truncate(24 * time.Hour).Add(12 * time.Hour)
	for i := 0; i < reflectStaggerDays; i++ {
		d := base.AddDate(0, 0, i)
		if dueForReflect(key, d) {
			return d
		}
	}
	return base
}

// reflectNotDueDay returns a day on which reflection is NOT due for key.
func reflectNotDueDay(key string) time.Time {
	base := time.Now().UTC().Truncate(24 * time.Hour).Add(12 * time.Hour)
	for i := 0; i < reflectStaggerDays; i++ {
		d := base.AddDate(0, 0, i)
		if !dueForReflect(key, d) {
			return d
		}
	}
	return base
}

// churnNode commits n (op) revisions of a node so LogMemoryCommits sees it as
// flapping. Each revision appends a dated ## History bullet so the belief also
// accrues history churn (and the git tree changes commit to commit).
func churnNode(t *testing.T, v *Vault, n Node, op string, times int, day time.Time) {
	t.Helper()
	rev := n
	for i := 0; i < times; i++ {
		rev.Body = appendHistory(rev.Body, fmt.Sprintf("- %s: %s rev %d\n", day.Format("2006-01-02"), op, i))
		_, err := v.WriteNodes([]Node{rev}, CommitMsg{Op: op, Summary: "revised", Cause: op, NodeIDs: []string{n.ID}})
		require.NoError(t, err)
	}
}

func reflectObsJSON(obs ...string) string {
	return `{"observations":[` + strings.Join(obs, ",") + `]}`
}

// TestReflectFlapsBeliefToDispute: a belief that churned >= threshold in the
// window is flagged dispute_pending (MEM-11 — its confidence/status/stability
// are byte-unchanged; only the side-table flag is set).
func TestReflectFlapsBeliefToDispute(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	key := "T1"
	day := reflectDueDay(key)

	belID := "bel_00000000000000000000000001"
	bel := beliefTestNode(belID, "Alice ships fast", "ent_00000000000000000000000001", 0.5, 1, "active",
		beliefEvidence{Rank: rankObserved, Support: true, ChannelID: "C1", TS: "1710000000"})
	writeAndIndex(t, v, d, bel)
	churnNode(t, v, bel, "beliefs", reflectChurnThreshold, day)

	before, err := v.ReadNode(belID)
	require.NoError(t, err)

	gen := &fakeGen{reply: func(string) (string, error) {
		return reflectObsJSON(fmt.Sprintf(`{"kind":"dispute","node_id":%q,"rationale":"keeps flipping"}`, belID)), nil
	}}
	p := NewPipeline(d, v, gen, reflectConfig(), t.Logf)

	n, flagged, _, err := p.Reflect(context.Background(), day)
	require.NoError(t, err)
	assert.Equal(t, 1, n)
	assert.Equal(t, 1, flagged)
	require.Len(t, gen.calls, 1)

	row, err := d.GetMemoryNode(belID)
	require.NoError(t, err)
	assert.True(t, row.DisputePending, "the flapping belief is flagged for the inbox detector")

	// MEM-11: reflection never touched the belief's confidence/status/stability.
	after, err := v.ReadNode(belID)
	require.NoError(t, err)
	assert.Equal(t, before.Confidence, after.Confidence)
	assert.Equal(t, before.Status, after.Status)
	assert.Equal(t, before.Stability, after.Stability)
	assert.Equal(t, before.Body, after.Body, "no belief vault write from a dispute observation")
}

// TestReflectEntityNoteAppendsCurrent: an entity observation appends a dated
// ## Current bullet via a memory(reflect) commit, touching no belief.
func TestReflectEntityNoteAppendsCurrent(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	key := "T1"
	day := reflectDueDay(key)

	entID := "ent_00000000000000000000000001"
	ent := rewriteEntityNode(entID, "Acme", "ep_00000000000000000000000001")
	writeAndIndex(t, v, d, ent)
	churnNode(t, v, ent, "rewrite", reflectChurnThreshold, day)

	// A belief present but not observed as flapping — must stay untouched.
	belID := "bel_00000000000000000000000009"
	bel := beliefTestNode(belID, "stable belief", entID, 0.7, 2, "active")
	writeAndIndex(t, v, d, bel)
	belBefore, err := v.ReadNode(belID)
	require.NoError(t, err)

	gen := &fakeGen{reply: func(string) (string, error) {
		return reflectObsJSON(fmt.Sprintf(`{"kind":"note","node_id":%q,"note":"page keeps churning","rationale":"unstable"}`, entID)), nil
	}}
	p := NewPipeline(d, v, gen, reflectConfig(), t.Logf)

	n, flagged, _, err := p.Reflect(context.Background(), day)
	require.NoError(t, err)
	assert.Equal(t, 1, n)
	assert.Zero(t, flagged, "an entity note is not a dispute")

	page, err := v.ReadNode(entID)
	require.NoError(t, err)
	assert.Contains(t, page.Body, day.Format("2006-01-02")+": page keeps churning", "dated ## Current bullet appended")
	assert.Contains(t, sectionText(page.Body, "## Current"), "page keeps churning", "note lands in ## Current, not elsewhere")

	// No belief was disputed or written.
	row, err := d.GetMemoryNode(belID)
	require.NoError(t, err)
	assert.False(t, row.DisputePending)
	belAfter, err := v.ReadNode(belID)
	require.NoError(t, err)
	assert.Equal(t, belBefore.Body, belAfter.Body, "reflection note touched no belief")
}

// TestReflectStaggerSkipsNonDueDay: on a day outside the workspace's weekly
// slot, Reflect is a no-op with no AI call.
func TestReflectStaggerSkipsNonDueDay(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	notDue := reflectNotDueDay("T1")

	belID := "bel_00000000000000000000000001"
	bel := beliefTestNode(belID, "Alice ships fast", "ent_x", 0.5, 1, "active")
	writeAndIndex(t, v, d, bel)
	churnNode(t, v, bel, "beliefs", reflectChurnThreshold, notDue)

	gen := &fakeGen{reply: func(string) (string, error) { return reflectObsJSON(), nil }}
	p := NewPipeline(d, v, gen, reflectConfig(), t.Logf)

	n, flagged, _, err := p.Reflect(context.Background(), notDue)
	require.NoError(t, err)
	assert.Zero(t, n)
	assert.Zero(t, flagged)
	assert.Empty(t, gen.calls, "a non-due day never calls the model")
}

// TestReflectModelFailureIsolated: a generate failure leaves every belief and
// entity untouched and returns an error (the pipeline logs it and continues).
func TestReflectModelFailureIsolated(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	day := reflectDueDay("T1")

	belID := "bel_00000000000000000000000001"
	bel := beliefTestNode(belID, "Alice ships fast", "ent_x", 0.5, 1, "active")
	writeAndIndex(t, v, d, bel)
	churnNode(t, v, bel, "beliefs", reflectChurnThreshold, day)
	before, err := v.ReadNode(belID)
	require.NoError(t, err)

	gen := &fakeGen{reply: func(string) (string, error) { return "", fmt.Errorf("model down") }}
	p := NewPipeline(d, v, gen, reflectConfig(), t.Logf)

	n, flagged, _, err := p.Reflect(context.Background(), day)
	require.Error(t, err)
	assert.Zero(t, n)
	assert.Zero(t, flagged)

	row, err := d.GetMemoryNode(belID)
	require.NoError(t, err)
	assert.False(t, row.DisputePending, "a failed reflection flags nothing")
	after, err := v.ReadNode(belID)
	require.NoError(t, err)
	assert.Equal(t, before.Body, after.Body)
}

// TestReflectDropsInventedAndCalmObservations: an observation whose node_id is
// not in the churn set (invented), or a belief below the flapping threshold, is
// dropped by the code-side guard — copy-don't-invent for reflection.
func TestReflectDropsInventedAndCalmObservations(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	day := reflectDueDay("T1")

	// A calm belief: committed once (below threshold), so it must not be disputed.
	calmID := "bel_00000000000000000000000002"
	calm := beliefTestNode(calmID, "calm belief", "ent_x", 0.5, 1, "active")
	writeAndIndex(t, v, d, calm)
	churnNode(t, v, calm, "beliefs", reflectChurnThreshold-1, day)

	// A flapping belief so there is a non-empty churn set (an AI call happens).
	flapID := "bel_00000000000000000000000001"
	flap := beliefTestNode(flapID, "flapping belief", "ent_x", 0.5, 1, "active")
	writeAndIndex(t, v, d, flap)
	churnNode(t, v, flap, "beliefs", reflectChurnThreshold, day)

	gen := &fakeGen{reply: func(string) (string, error) {
		return reflectObsJSON(
			`{"kind":"dispute","node_id":"bel_09999999999999999999999999","rationale":"invented"}`,
			fmt.Sprintf(`{"kind":"dispute","node_id":%q,"rationale":"calm — below threshold"}`, calmID),
		), nil
	}}
	p := NewPipeline(d, v, gen, reflectConfig(), t.Logf)

	n, flagged, _, err := p.Reflect(context.Background(), day)
	require.NoError(t, err)
	assert.Zero(t, n, "invented id and sub-threshold belief both dropped")
	assert.Zero(t, flagged)

	row, err := d.GetMemoryNode(calmID)
	require.NoError(t, err)
	assert.False(t, row.DisputePending, "a calm (sub-threshold) belief is never disputed")
}

// TestReflectCapsObservations: at most reflectMaxObservations are applied even
// when the model returns more.
func TestReflectCapsObservations(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	day := reflectDueDay("T1")

	var obs []string
	for i := 0; i < reflectMaxObservations+2; i++ {
		id := fmt.Sprintf("bel_0000000000000000000000000%d", i+1)
		bel := beliefTestNode(id, fmt.Sprintf("belief %d", i), "ent_x", 0.5, 1, "active")
		writeAndIndex(t, v, d, bel)
		churnNode(t, v, bel, "beliefs", reflectChurnThreshold, day)
		obs = append(obs, fmt.Sprintf(`{"kind":"dispute","node_id":%q,"rationale":"flap"}`, id))
	}

	gen := &fakeGen{reply: func(string) (string, error) { return reflectObsJSON(obs...), nil }}
	p := NewPipeline(d, v, gen, reflectConfig(), t.Logf)

	n, _, _, err := p.Reflect(context.Background(), day)
	require.NoError(t, err)
	assert.Equal(t, reflectMaxObservations, n, "observations capped per run")
}

// TestReflectBudgetSkipsInPipeline: at pipeline level, once the output budget is
// spent the reflect step records a 'skipped' row and never calls the model for
// reflection.
func TestReflectBudgetSkipsInPipeline(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	pipelineFixture(t, d)

	cfg := reflectConfig()
	cfg.Semantic.OutputBudget = 5 // tiny — blown by the extraction calls
	gen := &fakeGen{
		usage: digest.Usage{InputTokens: 10, OutputTokens: 500, TotalAPITokens: 20},
		reply: semanticReply,
	}
	p := NewPipeline(d, v, gen, cfg, t.Logf)

	_, err := p.Run(context.Background())
	require.NoError(t, err)

	runID, _, _, _, _, _, _, _, _ := memoryPipelineRunRow(t, d)
	steps, err := d.GetPipelineSteps(runID)
	require.NoError(t, err)
	byName := map[string]string{}
	for _, s := range steps {
		byName[s.ChannelName] = s.Status
	}
	assert.Equal(t, "skipped", byName["reflect"], "over budget, reflection records a skipped row")
	for _, c := range gen.calls {
		assert.NotContains(t, c, "Memory activity over the last seven days", "no reflection AI call over budget")
	}
}

// TestReflectGateOffNoStep: with the reflection gate off there is no reflect
// pipeline step at all (independent blast radius).
func TestReflectGateOffNoStep(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	pipelineFixture(t, d)

	gen := &fakeGen{reply: semanticReply}
	p := NewPipeline(d, v, gen, semanticTestConfig(), t.Logf) // Surfaces.Reflection == false
	_, err := p.Run(context.Background())
	require.NoError(t, err)

	runID, _, _, _, _, _, _, _, _ := memoryPipelineRunRow(t, d)
	steps, err := d.GetPipelineSteps(runID)
	require.NoError(t, err)
	for _, s := range steps {
		assert.NotEqual(t, "reflect", s.ChannelName, "no reflect step when the gate is off")
	}
}

// TestMemory10_DisputeFlagsNeverTouchInboxFromMemory guards MEM-10 (MEM-05
// restated for Phase 4): even with a dispute flag set and every surface gate
// on, a full memory consolidation run writes nothing to inbox_items /
// situations / situation_signals and never moves inbox_last_processed_ts. The
// dispute flag is memory-owned side-table state; only the inbox watchtower
// detector (internal/inbox) mints the item — the memory package never does.
func TestMemory10_DisputeFlagsNeverTouchInboxFromMemory(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	pipelineFixture(t, d) // workspace + channels + messages

	// Pre-existing inbox/situation state the memory run must not disturb.
	entID := "ent_0000000000000000000000000A"
	writeAndIndex(t, v, d, bareEntity(entID, "C1GEN"))
	seedSituationForChannel(t, d, "C1GEN", "U2BOB") // inbox_item + situation + signal

	// A belief already flagged disputed by consolidation.
	belID := "bel_00000000000000000000000001"
	writeAndIndex(t, v, d, beliefTestNode(belID, "Alice is reliable", entID, 0.5, 1, "active"))
	require.NoError(t, d.SetDisputePending(belID, "evidence conflicts"))

	inboxBefore := dumpTable(t, d, "inbox_items")
	sitBefore := dumpTable(t, d, "situations")
	sigBefore := dumpTable(t, d, "situation_signals")
	var wmBefore float64
	require.NoError(t, d.QueryRow(`SELECT COALESCE(inbox_last_processed_ts, 0) FROM workspace`).Scan(&wmBefore))

	cfg := reflectConfig()
	cfg.Surfaces.Disputes = true // "even with disputes enabled" — memory never reads this
	cfg.Surfaces.Chat = true
	cfg.Surfaces.Briefing = true
	p := NewPipeline(d, v, &fakeGen{reply: semanticReply}, cfg, t.Logf)

	_, err := p.Run(context.Background())
	require.NoError(t, err)

	assert.Equal(t, inboxBefore, dumpTable(t, d, "inbox_items"), "memory writes no inbox_items even with a dispute flag set")
	assert.Equal(t, sitBefore, dumpTable(t, d, "situations"), "situations byte-identical")
	assert.Equal(t, sigBefore, dumpTable(t, d, "situation_signals"), "situation_signals byte-identical")

	var wmAfter float64
	require.NoError(t, d.QueryRow(`SELECT COALESCE(inbox_last_processed_ts, 0) FROM workspace`).Scan(&wmAfter))
	assert.Equal(t, wmBefore, wmAfter, "inbox watermark untouched by the memory run")

	// The flag is still pending: memory sets it, only the inbox detector consumes it.
	row, err := d.GetMemoryNode(belID)
	require.NoError(t, err)
	assert.True(t, row.DisputePending, "the dispute flag is memory-owned side-table state, unconsumed by memory")

	var memItems int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM inbox_items WHERE channel_id='memory'`).Scan(&memItems))
	assert.Zero(t, memItems, "the memory package never mints a dispute inbox item")
}

// TestMemory11_SurfacesDontMutateBeliefs guards MEM-11: the Phase-4 surfaces are
// read-only over belief history. A reflection pass that flags a dispute and
// appends an entity note leaves EVERY belief's confidence/status/stability (and
// body) byte-unchanged — the only belief-side effect is the side-table dispute
// flag, never a confidence/status mutation (those flow solely through
// applyBeliefOp). The briefing revision journal read is likewise read-only
// (gatherMemoryRevisions only ListMemoryNodes + ReadNode).
func TestMemory11_SurfacesDontMutateBeliefs(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	day := reflectDueDay("T1")

	entID := "ent_00000000000000000000000001"
	ent := rewriteEntityNode(entID, "Acme", "ep_00000000000000000000000001")
	writeAndIndex(t, v, d, ent)
	churnNode(t, v, ent, "rewrite", reflectChurnThreshold, day)

	// A flapping belief (will be disputed) and a stable belief (untouched).
	flapID := "bel_00000000000000000000000001"
	flap := beliefTestNode(flapID, "flapping belief", entID, 0.5, 1, "active",
		beliefEvidence{Rank: rankObserved, Support: true, ChannelID: "C1", TS: "1710000000"})
	writeAndIndex(t, v, d, flap)
	churnNode(t, v, flap, "beliefs", reflectChurnThreshold, day)

	stableID := "bel_00000000000000000000000002"
	stable := beliefTestNode(stableID, "stable belief", entID, 0.7, 2, "shaken")
	writeAndIndex(t, v, d, stable)

	type belState struct {
		conf   float64
		stab   int
		status string
		body   string
	}
	snap := func(id string) belState {
		n, err := v.ReadNode(id)
		require.NoError(t, err)
		return belState{n.Confidence, n.Stability, n.Status, n.Body}
	}
	flapBefore, stableBefore := snap(flapID), snap(stableID)

	gen := &fakeGen{reply: func(string) (string, error) {
		return reflectObsJSON(
			fmt.Sprintf(`{"kind":"dispute","node_id":%q,"rationale":"keeps flipping"}`, flapID),
			fmt.Sprintf(`{"kind":"note","node_id":%q,"note":"page churning","rationale":"unstable"}`, entID),
		), nil
	}}
	p := NewPipeline(d, v, gen, reflectConfig(), t.Logf)

	n, flagged, _, err := p.Reflect(context.Background(), day)
	require.NoError(t, err)
	assert.Equal(t, 2, n)
	assert.Equal(t, 1, flagged)

	// Every belief's confidence/status/stability/body is byte-unchanged.
	assert.Equal(t, flapBefore, snap(flapID), "reflection never mutated the disputed belief's math")
	assert.Equal(t, stableBefore, snap(stableID), "reflection never touched an unrelated belief")

	// The only belief-side effect is the side-table dispute flag.
	row, err := d.GetMemoryNode(flapID)
	require.NoError(t, err)
	assert.True(t, row.DisputePending)
	stableRow, err := d.GetMemoryNode(stableID)
	require.NoError(t, err)
	assert.False(t, stableRow.DisputePending)
}

// sectionText returns the raw text of a "## X" section (up to the next "## "
// heading), for asserting a note landed in the right section.
func sectionText(body, heading string) string {
	lines := strings.Split(body, "\n")
	in := false
	var out []string
	for _, l := range lines {
		if strings.HasPrefix(l, "## ") {
			in = strings.TrimSpace(l) == heading
			continue
		}
		if in {
			out = append(out, l)
		}
	}
	return strings.Join(out, "\n")
}
