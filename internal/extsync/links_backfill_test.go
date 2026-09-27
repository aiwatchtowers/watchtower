package extsync

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// seedStoredDocs writes n pages "s00".."s<n-1>" straight into ext_documents,
// as a version synced before links existed would have left them: page i
// mentions KEY-i, and page 0 also has a comment mentioning CMT-1.
func seedStoredDocs(t *testing.T, d *db.DB, sourceID int64, n int) {
	t.Helper()
	for i := range n {
		_, err := d.Exec(`INSERT INTO ext_documents (source_id, ext_id, kind, title, sections_json)
			VALUES (?, ?, 'page', ?, ?)`, sourceID, fmt.Sprintf("s%02d", i), fmt.Sprintf("Page %d", i),
			fmt.Sprintf(`[{"heading":"","anchor":"","text":"covers KEY-%d"}]`, i))
		require.NoError(t, err)
	}
	_, err := d.Exec(`INSERT INTO ext_comments (source_id, ext_id, page_ext_id, kind, body_text) VALUES (?, 'c1', 's00', 'footer', 'see CMT-1')`, sourceID)
	require.NoError(t, err)
}

func relinkState(t *testing.T, d *db.DB) string {
	t.Helper()
	var s string
	err := d.QueryRow(`SELECT cursor FROM ext_link_state WHERE from_kind = 'ext_relink'`).Scan(&s)
	if err != nil {
		return ""
	}
	return s
}

// countingRelink counts calls and forwards to the production linker.
type countingRelink struct {
	mu    sync.Mutex
	calls int
}

func (c *countingRelink) relink(ctx context.Context, q Queryer, ref string, texts ...string) error {
	c.mu.Lock()
	c.calls++
	c.mu.Unlock()
	return linkConfluence(ctx, q, ref, texts...)
}

// Documents stored before the engine had a linker get their links once,
// including their comments'; afterwards the backfill is a single read.
func TestLinks_BackfillRelinksStoredDocumentsOnce(t *testing.T) {
	ctx := context.Background()
	d, src := newSourceDB(t)
	seedStoredDocs(t, d, src.ID, 3)
	c := &countingRelink{}
	e := New(d, Options{Relink: c.relink})

	_, err := e.Run(ctx)
	require.NoError(t, err)
	assert.Equal(t, []string{"CMT-1", "KEY-0"}, jiraLinks(t, d, src.ID, "s00"))
	assert.Equal(t, []string{"KEY-2"}, jiraLinks(t, d, src.ID, "s02"))
	assert.Equal(t, relinkDone, relinkState(t, d))
	require.Equal(t, 3, c.calls)

	_, err = e.Run(ctx)
	require.NoError(t, err)
	assert.Equal(t, 3, c.calls, "a finished backfill never relinks again")
}

// A budget-cut backfill resumes where it stopped: one batch per Run here.
func TestLinks_BackfillResumesAcrossRuns(t *testing.T) {
	old := relinkBatchSize
	relinkBatchSize = 2
	t.Cleanup(func() { relinkBatchSize = old })
	ctx := context.Background()
	d, src := newSourceDB(t)
	seedStoredDocs(t, d, src.ID, 5)
	c := &countingRelink{}
	// Every clock read advances 1s against a 2s budget: exactly one batch
	// starts before the budget reads as spent.
	e := New(d, Options{Relink: c.relink, Budget: 2 * time.Second, Now: (&stepClock{t: t0, step: time.Second}).Now})

	_, err := e.Run(ctx)
	require.NoError(t, err)
	assert.Equal(t, 2, c.calls)
	assert.Equal(t, fmt.Sprintf("%d|s01", src.ID), relinkState(t, d))

	for range 5 {
		if relinkState(t, d) == relinkDone {
			break
		}
		_, err = e.Run(ctx)
		require.NoError(t, err)
	}
	assert.Equal(t, relinkDone, relinkState(t, d))
	assert.Equal(t, 5, c.calls, "each stored document relinked exactly once")
	assert.Equal(t, []string{"KEY-4"}, jiraLinks(t, d, src.ID, "s04"))
}

// Without a linker nothing is relinked and no state is written.
func TestLinks_NoRelinkNoBackfill(t *testing.T) {
	d, src := newSourceDB(t)
	seedStoredDocs(t, d, src.ID, 2)
	e := New(d, Options{})
	_, err := e.Run(context.Background())
	require.NoError(t, err)
	assert.Empty(t, relinkState(t, d))
	assert.Empty(t, jiraLinks(t, d, src.ID, "s00"))
}

// The backfill walk seeks the ext_documents primary key.
func TestLinks_BackfillQueryPlan(t *testing.T) {
	d, _ := newSourceDB(t)
	rows, err := d.Query(`EXPLAIN QUERY PLAN `+relinkWalkQuery, 0, "", 200)
	require.NoError(t, err)
	defer rows.Close()
	var plan []string
	for rows.Next() {
		var id, parent, notused int
		var detail string
		require.NoError(t, rows.Scan(&id, &parent, &notused, &detail))
		plan = append(plan, detail)
	}
	require.NoError(t, rows.Err())
	joined := strings.Join(plan, "\n")
	assert.Contains(t, joined, "INDEX sqlite_autoindex_ext_documents_1 ((source_id,ext_id)>(?,?))")
	assert.NotContains(t, joined, "TEMP B-TREE")
}

// TestEXT04_EngineImportsNoLinkOrAIPackages — the generic sync engine stays
// free of Atlassian-, link- and AI-specific packages: the linker is
// injected (Options.Relink), never imported. Checked on the real build graph.
func TestEXT04_EngineImportsNoLinkOrAIPackages(t *testing.T) {
	out, err := exec.Command("go", "list", "-deps", "watchtower/internal/extsync").Output()
	require.NoError(t, err)
	deps := strings.Fields(string(out))
	require.Contains(t, deps, "watchtower/internal/db", "scan floor: the dependency list must actually be read")
	for _, bad := range []string{
		"watchtower/internal/jira", "watchtower/internal/ai", "watchtower/internal/kb",
		"watchtower/internal/confluence", "watchtower/internal/doclinks", "watchtower/internal/digest",
	} {
		for _, dep := range deps {
			assert.False(t, dep == bad || strings.HasPrefix(dep, bad+"/"), "internal/extsync depends on %s", dep)
		}
	}
}
