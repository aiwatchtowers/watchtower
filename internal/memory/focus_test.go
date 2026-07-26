package memory

import (
	"context"
	"os"
	"path/filepath"
	"sort"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// ── parseFocus ───────────────────────────────────────────────────────────

func TestParseFocus(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want focusDirectives
	}{
		{
			name: "both sections",
			raw:  "## Now\n- CEX\n- Hashbank Integration\n\n## Cooled\n- old project\n",
			want: focusDirectives{Now: []string{"CEX", "Hashbank Integration"}, Cooled: []string{"old project"}},
		},
		{
			name: "missing section",
			raw:  "## Now\n- CEX\n",
			want: focusDirectives{Now: []string{"CEX"}},
		},
		{
			name: "cooled only",
			raw:  "## Cooled\n- CEX\n",
			want: focusDirectives{Cooled: []string{"CEX"}},
		},
		{
			name: "bullets trimmed",
			raw:  "## Now\n-   CEX with spaces   \n",
			want: focusDirectives{Now: []string{"CEX with spaces"}},
		},
		{
			name: "heading case-insensitive",
			raw:  "## NOW\n- CEX\n## cOoLeD\n- old\n",
			want: focusDirectives{Now: []string{"CEX"}, Cooled: []string{"old"}},
		},
		{
			name: "prose between sections ignored",
			raw:  "## Now\n- CEX\nSome unrelated prose line.\nAnother note.\n## Cooled\n- old\nMore prose.\n",
			want: focusDirectives{Now: []string{"CEX"}, Cooled: []string{"old"}},
		},
		{
			name: "unknown heading ends section",
			raw:  "## Now\n- CEX\n## Something Else\n- ignored bullet\n## Cooled\n- old\n",
			want: focusDirectives{Now: []string{"CEX"}, Cooled: []string{"old"}},
		},
		{
			name: "empty raw is zero value",
			raw:  "",
			want: focusDirectives{},
		},
		{
			name: "no headings at all",
			raw:  "just some prose\n- not a bullet inside a section\n",
			want: focusDirectives{},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := parseFocus(tt.raw)
			assert.Equal(t, tt.want, got)
		})
	}
}

// ── matchFingerprint ─────────────────────────────────────────────────────
//
// matchFingerprint replaced focusDirectives.fingerprint() (final-review Fix
// 2): the fingerprint now hashes the RESOLVED match set (node ids), not the
// raw directive text, so it is exercised with ids rather than free-text
// bullets — the case/space-normalization behavior of the old text fingerprint
// no longer applies (ids are already canonical).

func TestMatchFingerprint(t *testing.T) {
	t.Run("empty is stable non-special value", func(t *testing.T) {
		fp1 := matchFingerprint(nil, nil)
		fp2 := matchFingerprint(nil, nil)
		assert.NotEmpty(t, fp1)
		assert.Equal(t, fp1, fp2)
	})

	t.Run("id reorder within a section is invariant", func(t *testing.T) {
		a := matchFingerprint([]string{"ent_a", "ent_b"}, []string{"ent_c"})
		b := matchFingerprint([]string{"ent_b", "ent_a"}, []string{"ent_c"})
		assert.Equal(t, a, b)
	})

	t.Run("moving an id between sections changes it", func(t *testing.T) {
		a := matchFingerprint([]string{"ent_a"}, []string{"ent_b"})
		b := matchFingerprint([]string{"ent_b"}, []string{"ent_a"})
		assert.NotEqual(t, a, b)
	})

	t.Run("different content differs", func(t *testing.T) {
		a := matchFingerprint([]string{"ent_a"}, nil)
		b := matchFingerprint([]string{"ent_b"}, nil)
		assert.NotEqual(t, a, b)
	})
}

// ── readFocusFile ────────────────────────────────────────────────────────

func TestReadFocusFile(t *testing.T) {
	t.Run("present", func(t *testing.T) {
		v, d := newTestVault(t), newTestDB(t)
		p := NewPipeline(d, v, nil, pipelineTestConfig(), t.Logf)
		require.NoError(t, os.WriteFile(filepath.Join(v.path, "focus.md"), []byte("## Now\n- CEX\n"), 0o644))

		raw, present, err := p.readFocusFile()
		require.NoError(t, err)
		assert.True(t, present)
		assert.Equal(t, "## Now\n- CEX\n", raw)
	})

	t.Run("absent", func(t *testing.T) {
		v, d := newTestVault(t), newTestDB(t)
		p := NewPipeline(d, v, nil, pipelineTestConfig(), t.Logf)

		raw, present, err := p.readFocusFile()
		require.NoError(t, err)
		assert.False(t, present)
		assert.Equal(t, "", raw)
	})
}

// ── matchFocus ───────────────────────────────────────────────────────────

// seedFocusFixture seeds two nodes for the matcher tests: one entity aliased
// "CEX" (alias hit) and one entity titled "Hashbank Integration" (title hit).
// Returns their ids.
func seedFocusFixture(t *testing.T, d *db.DB) (cexID, hashbankID string) {
	t.Helper()
	cexID = "ent_00000000000000000000000cex"
	hashbankID = "ent_00000000000000000000hash"
	indexNode(t, d, Node{ID: cexID, Type: "entity", Tier: "long", Status: "active", Title: "CEX Exchange", Aliases: []string{"CEX"}})
	indexNode(t, d, Node{ID: hashbankID, Type: "entity", Tier: "long", Status: "active", Title: "Hashbank Integration"})
	return cexID, hashbankID
}

func TestMatchFocus_AliasHit(t *testing.T) {
	d := newTestDB(t)
	cexID, _ := seedFocusFixture(t, d)
	p := NewPipeline(d, newTestVault(t), nil, pipelineTestConfig(), t.Logf)

	now, cooled, err := p.matchFocus(focusDirectives{Now: []string{"CEX"}})
	require.NoError(t, err)
	assert.Equal(t, []string{cexID}, now)
	assert.Empty(t, cooled)
}

func TestMatchFocus_TitleHitCaseInsensitive(t *testing.T) {
	d := newTestDB(t)
	_, hashbankID := seedFocusFixture(t, d)
	p := NewPipeline(d, newTestVault(t), nil, pipelineTestConfig(), t.Logf)

	now, cooled, err := p.matchFocus(focusDirectives{Now: []string{"hashbank integration"}})
	require.NoError(t, err)
	assert.Equal(t, []string{hashbankID}, now)
	assert.Empty(t, cooled)
}

func TestMatchFocus_CommaFragmentHit(t *testing.T) {
	d := newTestDB(t)
	cexID, hashbankID := seedFocusFixture(t, d)
	p := NewPipeline(d, newTestVault(t), nil, pipelineTestConfig(), t.Logf)

	now, cooled, err := p.matchFocus(focusDirectives{Now: []string{"CEX, Hashbank Integration"}})
	require.NoError(t, err)
	got := append([]string{}, now...)
	sort.Strings(got)
	want := []string{cexID, hashbankID}
	sort.Strings(want)
	assert.Equal(t, want, got)
	assert.Empty(t, cooled)
}

func TestMatchFocus_BothSectionsResolvesToNowOnly(t *testing.T) {
	d := newTestDB(t)
	cexID, _ := seedFocusFixture(t, d)
	p := NewPipeline(d, newTestVault(t), nil, pipelineTestConfig(), t.Logf)

	now, cooled, err := p.matchFocus(focusDirectives{Now: []string{"CEX"}, Cooled: []string{"CEX"}})
	require.NoError(t, err)
	assert.Equal(t, []string{cexID}, now)
	assert.Empty(t, cooled, "a node matched by both sections lands in now only")
}

func TestMatchFocus_NoMatchBulletContributesNothing(t *testing.T) {
	d := newTestDB(t)
	seedFocusFixture(t, d)
	p := NewPipeline(d, newTestVault(t), nil, pipelineTestConfig(), t.Logf)

	now, cooled, err := p.matchFocus(focusDirectives{Now: []string{"totally unknown thing"}})
	require.NoError(t, err)
	assert.Empty(t, now)
	assert.Empty(t, cooled)
}

func TestMatchFocus_EmptyDirectivesNoError(t *testing.T) {
	d := newTestDB(t)
	p := NewPipeline(d, newTestVault(t), nil, pipelineTestConfig(), t.Logf)

	now, cooled, err := p.matchFocus(focusDirectives{})
	require.NoError(t, err)
	assert.Empty(t, now)
	assert.Empty(t, cooled)
}

func TestMatchFocus_ResultsAreSortedAndDeduped(t *testing.T) {
	d := newTestDB(t)
	cexID, hashbankID := seedFocusFixture(t, d)
	p := NewPipeline(d, newTestVault(t), nil, pipelineTestConfig(), t.Logf)

	// Two bullets both matching CEX (alias + comma fragment) must dedupe;
	// output must come back sorted for determinism.
	now, _, err := p.matchFocus(focusDirectives{Now: []string{"CEX", "CEX, Hashbank Integration"}})
	require.NoError(t, err)
	want := []string{cexID, hashbankID}
	sort.Strings(want)
	assert.Equal(t, want, now)
}

// ── runFocus ─────────────────────────────────────────────────────────────

// TestRunFocusSweepOnFingerprintChange: a focus.md matching a seeded entity
// causes (a) the entity to land in memory_focus_matches as "now", (b) its
// persisted importance_score to double (the "now" multiplier applied on top
// of its organic base — here 1.0 from the situation-origin bonus), (c) an
// UNRELATED node's stale persisted score to be recomputed too (the sweep is
// whole-vault, not just the matched set), and (d) the fingerprint column to
// advance to the new directive set's hash.
func TestRunFocusSweepOnFingerprintChange(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)

	// Matched entity: base importance 1.0 (situation-origin bonus alone), so
	// the "now" ×2 multiplier landing on exactly 2.0 is unambiguous.
	entID := "ent_00000000000000000000000cex"
	writeAndIndex(t, v, d, Node{
		ID: entID, Type: "entity", Tier: "long", Status: "active",
		Title: "CEX Exchange", Aliases: []string{"CEX", "situation:1"},
		Body: "# CEX Exchange\n",
	})
	require.NoError(t, d.UpdateMemoryNodeImportanceScore(entID, 1.0))

	// Unrelated node with a stale sentinel score the sweep must overwrite.
	otherID := "ent_00000000000000000000other1"
	writeAndIndex(t, v, d, Node{
		ID: otherID, Type: "entity", Tier: "long", Status: "active",
		Title: "Unrelated Thing", Body: "# Unrelated Thing\n",
	})
	require.NoError(t, d.UpdateMemoryNodeImportanceScore(otherID, 999))

	require.NoError(t, os.WriteFile(filepath.Join(v.path, focusFileName), []byte("## Now\n- CEX\n"), 0o644))

	p := NewPipeline(d, v, nil, pipelineTestConfig(), t.Logf)
	var stats RunStats
	n, err := p.runFocus(1, 0, &stats)
	require.NoError(t, err)
	assert.Equal(t, 1, n)
	assert.Equal(t, 1, stats.FocusMatched)
	assert.Equal(t, 2, stats.FocusSwept)
	assert.Zero(t, stats.FocusFailed)

	state, err := d.FocusState(entID)
	require.NoError(t, err)
	assert.Equal(t, "now", state, "matched entity lands in memory_focus_matches")

	got, err := d.GetMemoryNode(entID)
	require.NoError(t, err)
	assert.Equal(t, 2.0, got.ImportanceScore, "matched entity's importance doubled by the now multiplier")

	otherRow, err := d.GetMemoryNode(otherID)
	require.NoError(t, err)
	assert.Equal(t, 0.0, otherRow.ImportanceScore, "unrelated node's stale sentinel was recomputed by the whole-vault sweep")

	fp, err := d.FocusFingerprint()
	require.NoError(t, err)
	assert.Equal(t, matchFingerprint([]string{entID}, nil), fp, "fingerprint column advances to the resolved match set")
}

// TestRunFocusUnchangedFingerprintNoSweep: a second runFocus call against the
// same focus.md content AND the same index is a no-op — no rewrite, no
// sweep, 0 steps — proven by a hand-tweaked sentinel importance_score
// surviving untouched. Post Fix 2, matchFocus re-resolves on every call, but
// since neither the file nor the index changed between calls, the RESOLVED
// SET is identical and the fingerprint comparison still short-circuits (see
// TestRunFocusMatchesNodeCreatedLater below for the case where the index
// changes and the no-op breaks, as intended).
func TestRunFocusUnchangedFingerprintNoSweep(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)

	entID := "ent_00000000000000000000000cex"
	writeAndIndex(t, v, d, Node{
		ID: entID, Type: "entity", Tier: "long", Status: "active",
		Title: "CEX Exchange", Aliases: []string{"CEX"}, Body: "# CEX Exchange\n",
	})
	require.NoError(t, os.WriteFile(filepath.Join(v.path, focusFileName), []byte("## Now\n- CEX\n"), 0o644))

	p := NewPipeline(d, v, nil, pipelineTestConfig(), t.Logf)
	var stats RunStats
	n, err := p.runFocus(1, 0, &stats)
	require.NoError(t, err)
	require.Equal(t, 1, n, "first call with a changed fingerprint does the work")

	require.NoError(t, d.UpdateMemoryNodeImportanceScore(entID, 12345))

	n2, err := p.runFocus(1, 0, &stats)
	require.NoError(t, err)
	assert.Equal(t, 0, n2, "unchanged fingerprint → no sweep, 0 steps")

	got, err := d.GetMemoryNode(entID)
	require.NoError(t, err)
	assert.Equal(t, 12345.0, got.ImportanceScore, "an unchanged-fingerprint run must not overwrite the sentinel")
}

// TestRunFocusMatchesNodeCreatedLater (Fix 2, final-review wave): the
// fingerprint hashes the RESOLVED match set, not focus.md's raw text, so a
// bullet naming a node that doesn't exist yet is not permanently inert — the
// very next gated run re-resolves it (matchFocus always runs) and, once the
// node shows up, matches and boosts it with NO focus.md edit at all.
func TestRunFocusMatchesNodeCreatedLater(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	require.NoError(t, os.WriteFile(filepath.Join(v.path, focusFileName), []byte("## Now\n- CEX\n"), 0o644))

	p := NewPipeline(d, v, nil, pipelineTestConfig(), t.Logf)
	var stats RunStats
	n, err := p.runFocus(1, 0, &stats)
	require.NoError(t, err)
	require.Equal(t, 1, n, "first run applies the (empty) resolved set — no node named CEX exists yet")
	assert.Zero(t, stats.FocusMatched)

	// The focused entity shows up later, seeded in a subsequent run — no
	// focus.md edit at all. It carries a situation:1 alias so its organic
	// base importance is exactly 1.0 (the situation-origin bonus alone), the
	// same unambiguous-doubling setup as TestRunFocusSweepOnFingerprintChange.
	entID := "ent_00000000000000000000000cex"
	writeAndIndex(t, v, d, Node{
		ID: entID, Type: "entity", Tier: "long", Status: "active",
		Title: "CEX Exchange", Aliases: []string{"CEX", "situation:1"}, Body: "# CEX Exchange\n",
	})

	n2, err := p.runFocus(1, 0, &stats)
	require.NoError(t, err)
	assert.Equal(t, 1, n2, "resolved set changed (∅ → {entID}) even though focus.md itself did not")

	state, err := d.FocusState(entID)
	require.NoError(t, err)
	assert.Equal(t, "now", state)

	got, err := d.GetMemoryNode(entID)
	require.NoError(t, err)
	assert.Equal(t, 2.0, got.ImportanceScore, "newly-matched node is boosted with no file edit")
}

// TestRunFocusSweepErrorFreezesFingerprint: a failure reading the sweep's
// node list (memory_nodes dropped — the jira freeze test's DROP-TABLE
// mechanism, TestRunJiraIngestWatermarkFreezeOnError, mirrored against the
// sweep's own read path) must leave the applied fingerprint exactly where it
// was, so the next run retries the same work.
func TestRunFocusSweepErrorFreezesFingerprint(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	require.NoError(t, d.SetFocusFingerprint("sentinel-old-fp"))

	// No focus.md: parseFocus("")'s fingerprint still differs from the
	// sentinel above, so the empty directive set's fingerprint participates
	// and the step still attempts the sweep (no bullets means matchFocus
	// itself never touches memory_nodes, isolating the failure to the sweep).
	_, err := d.Exec(`DROP TABLE memory_nodes`)
	require.NoError(t, err)

	p := NewPipeline(d, v, nil, pipelineTestConfig(), t.Logf)
	var stats RunStats
	n, err := p.runFocus(1, 0, &stats)
	require.Error(t, err)
	assert.Equal(t, 1, n)

	fp, ferr := d.FocusFingerprint()
	require.NoError(t, ferr)
	assert.Equal(t, "sentinel-old-fp", fp, "a failed sweep must freeze the fingerprint")
}

// TestRunFocusGateOffByteIdentical: with memory.focus.enabled off, adding
// focus.md between two full Run calls changes nothing in memory_nodes — the
// gate is checked before any parse, so the file is never even read.
func TestRunFocusGateOffByteIdentical(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	entID := "ent_00000000000000000000000cex"
	writeAndIndex(t, v, d, Node{
		ID: entID, Type: "entity", Tier: "long", Status: "active",
		Title: "CEX Exchange", Aliases: []string{"CEX"}, Body: "# CEX Exchange\n",
	})

	cfg := pipelineTestConfig() // Focus.Enabled defaults false
	p := NewPipeline(d, v, noCallGen(t), cfg, t.Logf)

	_, err := p.Run(context.Background())
	require.NoError(t, err)
	before := dumpTable(t, d, "memory_nodes")

	require.NoError(t, os.WriteFile(filepath.Join(v.path, focusFileName), []byte("## Now\n- CEX\n"), 0o644))

	_, err = p.Run(context.Background())
	require.NoError(t, err)
	after := dumpTable(t, d, "memory_nodes")

	assert.Equal(t, before, after, "gate off: adding focus.md must not change memory_nodes")

	fp, ferr := d.FocusFingerprint()
	require.NoError(t, ferr)
	assert.Empty(t, fp, "gate off: focus.md is never parsed, fingerprint stays unset")
}

// TestRunFocusDisableNeutralizesResidual (Fix 1, final-review wave): a
// workspace that HAD focus enabled and accumulated a matched/boosted node
// must have that residual state cleared once the gate flips back off — a
// stale ×2/×0.5 skew must not survive forever. An enable-run matches and
// doubles a node's score; flipping the gate off and running again empties
// memory_focus_matches, sweeps the score back to its un-boosted value, and
// clears the fingerprint; a THIRD disabled run takes the fast path
// (fingerprint already empty) and records no focus-disable step at all.
func TestRunFocusDisableNeutralizesResidual(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)

	entID := "ent_00000000000000000000000cex"
	writeAndIndex(t, v, d, Node{
		ID: entID, Type: "entity", Tier: "long", Status: "active",
		Title: "CEX Exchange", Aliases: []string{"CEX", "situation:1"},
		Body: "# CEX Exchange\n",
	})
	require.NoError(t, d.UpdateMemoryNodeImportanceScore(entID, 1.0))
	require.NoError(t, os.WriteFile(filepath.Join(v.path, focusFileName), []byte("## Now\n- CEX\n"), 0o644))

	enabledCfg := pipelineTestConfig()
	enabledCfg.Focus.Enabled = true
	pEnabled := NewPipeline(d, v, noCallGen(t), enabledCfg, t.Logf)
	_, err := pEnabled.Run(context.Background())
	require.NoError(t, err)

	got, err := d.GetMemoryNode(entID)
	require.NoError(t, err)
	require.Equal(t, 2.0, got.ImportanceScore, "enable-run doubled the matched node's score")
	fp, err := d.FocusFingerprint()
	require.NoError(t, err)
	require.NotEmpty(t, fp, "enable-run applied a fingerprint")

	// Flip the gate off: the second Run must neutralize the residual state.
	pDisabled := NewPipeline(d, v, noCallGen(t), pipelineTestConfig(), t.Logf)
	_, err = pDisabled.Run(context.Background())
	require.NoError(t, err)

	state, err := d.FocusState(entID)
	require.NoError(t, err)
	assert.Empty(t, state, "matches table emptied")
	fp, err = d.FocusFingerprint()
	require.NoError(t, err)
	assert.Empty(t, fp, "fingerprint cleared")
	got, err = d.GetMemoryNode(entID)
	require.NoError(t, err)
	assert.Equal(t, 1.0, got.ImportanceScore, "score restored to its un-boosted value")

	// A third disabled run takes the fast path: fingerprint already empty,
	// so no focus-disable step is even recorded.
	_, err = pDisabled.Run(context.Background())
	require.NoError(t, err)

	var runID int64
	require.NoError(t, d.QueryRow(`SELECT id FROM pipeline_runs WHERE pipeline = 'memory' ORDER BY id DESC LIMIT 1`).Scan(&runID))
	steps, err := d.GetPipelineSteps(runID)
	require.NoError(t, err)
	for _, s := range steps {
		assert.NotEqual(t, "focus-disable", s.ChannelName, "fast path records no step")
	}
}
