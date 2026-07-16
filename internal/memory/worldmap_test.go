package memory

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// indexEntity is a minimal active entity page for the index/map renders.
func indexEntity(id, title, what string, aliases ...string) Node {
	body := "# " + title + "\n\n## What\n" + what + "\n\n## Current\n" + what + " now\n\n## Facts\n\n## Links\n\n## Open loops\n"
	return Node{ID: id, Type: "entity", Tier: "long", Status: "active", Title: title, Aliases: aliases, Body: body}
}

func TestRenderIndexMechanical(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	writeAndIndex(t, v, d, indexEntity("ent_00000000000000000000000001", "#general", "the general channel", "C1GEN"))
	writeAndIndex(t, v, d, rewriteEpisodeNode("ep_00000000000000000000000001", "C1GEN", "1710000000.000100"))
	p := NewPipeline(d, v, nil, pipelineTestConfig(), t.Logf)

	require.NoError(t, p.renderIndex(1))

	content, err := os.ReadFile(filepath.Join(v.path, indexFileName))
	require.NoError(t, err)
	s := string(content)
	assert.Contains(t, s, "# Memory Index")
	assert.Contains(t, s, "- entity: 1 (short 0, long 1)")
	assert.Contains(t, s, "## Channels")
	assert.Contains(t, s, "#general")
	assert.Contains(t, s, "## Recent open episodes")

	// A byte-identical re-render adds no commit.
	repo := openTestRepo(t, v.path)
	before := commitCount(t, repo)
	require.NoError(t, p.renderIndex(2))
	assert.Equal(t, before, commitCount(t, repo), "byte-identical index re-render is a no-op")
}

func TestRenderMapStrongTruncatesTo2KB(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	writeAndIndex(t, v, d, indexEntity("ent_00000000000000000000000001", "Acme", "a project"))

	huge := strings.Repeat("- an area with a fairly long description line here\n", 400) // ~20 KB
	gen := &fakeGen{reply: func(string) (string, error) { return huge, nil }}
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	_, err := p.renderMap(context.Background(), 1, true)
	require.NoError(t, err)
	require.Len(t, gen.calls, 1)

	content, err := os.ReadFile(filepath.Join(v.path, mapFileName))
	require.NoError(t, err)
	assert.LessOrEqual(t, len(content), mapByteCap, "map.md hard-capped")
	assert.True(t, strings.HasSuffix(string(content), "\n"), "truncated at a line boundary")
	assert.Contains(t, string(content), "truncated", "truncation note appended")
}

func TestRenderMapFailureKeepsPreviousMap(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	writeAndIndex(t, v, d, indexEntity("ent_00000000000000000000000001", "Acme", "a project"))
	// Commit a known previous map.md.
	_, err := v.WriteFile(mapFileName, []byte("# Previous hot map\n\nkeep me\n"),
		CommitMsg{Op: "map", Summary: "seed", Cause: "test"})
	require.NoError(t, err)
	repo := openTestRepo(t, v.path)
	before := commitCount(t, repo)

	gen := &fakeGen{reply: func(string) (string, error) { return "", errors.New("model exploded") }}
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	_, err = p.renderMap(context.Background(), 1, true)
	require.NoError(t, err, "a failed map render never fails the run")

	content, err := os.ReadFile(filepath.Join(v.path, mapFileName))
	require.NoError(t, err)
	assert.Equal(t, "# Previous hot map\n\nkeep me\n", string(content), "previous map.md preserved on failure")
	assert.Equal(t, before, commitCount(t, repo), "no commit churn on fallback")
}

func TestRenderMapSemanticOffNeverCallsGenerator(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	writeAndIndex(t, v, d, indexEntity("ent_00000000000000000000000001", "Acme", "a project"))

	gen := &fakeGen{reply: func(string) (string, error) {
		t.Fatal("generator must not be called when the semantic tier is off")
		return "", nil
	}}
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	_, err := p.renderMap(context.Background(), 1, false)
	require.NoError(t, err)
	assert.Empty(t, gen.calls)

	// map.md still present (the init map is kept) so MCP memory_map has a target.
	_, err = os.Stat(filepath.Join(v.path, mapFileName))
	require.NoError(t, err)
}
