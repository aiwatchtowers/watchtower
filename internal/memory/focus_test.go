package memory

import (
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

// ── focusDirectives.fingerprint ─────────────────────────────────────────────

func TestFocusDirectivesFingerprint(t *testing.T) {
	t.Run("empty is stable non-special value", func(t *testing.T) {
		fp1 := focusDirectives{}.fingerprint()
		fp2 := focusDirectives{}.fingerprint()
		assert.NotEmpty(t, fp1)
		assert.Equal(t, fp1, fp2)
	})

	t.Run("bullet reorder within a section is invariant", func(t *testing.T) {
		a := focusDirectives{Now: []string{"CEX", "Hashbank"}, Cooled: []string{"old"}}
		b := focusDirectives{Now: []string{"Hashbank", "CEX"}, Cooled: []string{"old"}}
		assert.Equal(t, a.fingerprint(), b.fingerprint())
	})

	t.Run("moving a bullet between sections changes it", func(t *testing.T) {
		a := focusDirectives{Now: []string{"CEX"}, Cooled: []string{"old"}}
		b := focusDirectives{Now: []string{"old"}, Cooled: []string{"CEX"}}
		assert.NotEqual(t, a.fingerprint(), b.fingerprint())
	})

	t.Run("case and space normalization", func(t *testing.T) {
		a := focusDirectives{Now: []string{"CEX"}}
		b := focusDirectives{Now: []string{"  cex  "}}
		assert.Equal(t, a.fingerprint(), b.fingerprint())
	})

	t.Run("different content differs", func(t *testing.T) {
		a := focusDirectives{Now: []string{"CEX"}}
		b := focusDirectives{Now: []string{"Hashbank"}}
		assert.NotEqual(t, a.fingerprint(), b.fingerprint())
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
