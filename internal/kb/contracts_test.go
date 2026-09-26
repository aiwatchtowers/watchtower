package kb

import (
	"context"
	"fmt"
	"go/parser"
	"go/token"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// dumpRows renders every row of query as one line each (column values via
// fmt.Sprint), after scanning them all (single-connection rule).
func dumpRows(t *testing.T, d *db.DB, query string) string {
	t.Helper()
	rows, err := d.Query(query)
	require.NoError(t, err, query)
	defer rows.Close()
	cols, err := rows.Columns()
	require.NoError(t, err)
	var b strings.Builder
	for rows.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		require.NoError(t, rows.Scan(ptrs...))
		for i, v := range vals {
			if raw, ok := v.([]byte); ok {
				vals[i] = string(raw)
			}
		}
		b.WriteString(fmt.Sprint(vals...))
		b.WriteByte('\n')
	}
	require.NoError(t, rows.Err())
	return b.String()
}

// dumpKB renders the index content, excluding indexed_at (a write clock) and
// kb_chunks.id (a rowid that depends on write order, not content).
func dumpKB(t *testing.T, d *db.DB) string {
	t.Helper()
	return dumpRows(t, d, `SELECT id, source, title, doc_time, link, anchor_json, meta, content_hash, chunk_count FROM kb_documents ORDER BY id`) +
		"--\n" +
		dumpRows(t, d, `SELECT doc_id, idx, title, body, meta, anchor FROM kb_chunks ORDER BY doc_id, idx`)
}

// kbSourceTables are the tables the indexer reads; it must never write them.
var kbSourceTables = []string{
	"messages", "gmail_messages", "imap_messages", "jira_issues", "jira_comments", "calendar_events",
	"meeting_transcripts", "meeting_recaps", "digests", "digest_topics", "stream_digests", "ideas", "idea_mentions",
}

func dumpSourceTables(t *testing.T, d *db.DB) string {
	t.Helper()
	var b strings.Builder
	for _, table := range kbSourceTables {
		b.WriteString("== " + table + "\n")
		b.WriteString(dumpRows(t, d, `SELECT * FROM `+table+` ORDER BY 1, 2`))
	}
	return b.String()
}

// TestKB01_IncrementalEqualsRebuild — KB-01: the index is derived. Two
// incremental passes over changing data end in exactly the state a
// from-scratch rebuild produces, and indexing never writes a source table.
func TestKB01_IncrementalEqualsRebuild(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedAll(t, d) // pass 1 at testNow()

	// Changes before pass 2: a new thread reply, two recent DM messages (inside
	// the 48h tail of the later passes), a Gmail thread update, a new idea mention.
	recent := testNow().Add(-time.Hour).Unix()
	msg(t, d, "1:C1", "1758000700.000700", "1:U1", "и ещё договорились про стейдж", "1758000000.000100", "")
	msg(t, d, "1:D1", fmt.Sprintf("%d.000100", recent), "1:U1", "свежий вопрос про бюджет", "", "")
	msg(t, d, "1:D1", fmt.Sprintf("%d.000200", recent), "1:U2", "ответ, который потом удалят", "", "")
	exec(t, d, `UPDATE gmail_messages SET body_text = 'Урезать на треть', updated_at = '2026-09-26T12:30:00Z' WHERE id = 'm1'`)
	exec(t, d, `INSERT INTO idea_mentions (id, idea_id, source, quote, author, said_at, created_at)
		VALUES (2, 9, 'jira', 'кэш на уровне CDN', 'Bob', '2026-09-26T12:00:00Z', '2026-09-26T12:30:00Z')`)
	_, err := Run(ctx, d, Options{Now: testNow().Add(time.Hour)}) // pass 2, same UTC day
	require.NoError(t, err)
	var recentDocs int
	require.NoError(t, d.QueryRow(`SELECT count(*) FROM kb_chunks WHERE body LIKE '%ответ, который потом удалят%'`).Scan(&recentDocs))
	require.Equal(t, 1, recentDocs, "pass 2 indexed the recent DM message")

	// Changes before pass 3: an in-place Slack delete (moves no rowid), a
	// Jira hard delete (moves no marker; the reconcile drops it), and a thread
	// promotion — a top-level DM message older than the 48h tail gains its
	// first reply: Slack sets the root's thread_ts in place (no new rowid)
	// and only the reply is a new row, yet the root must leave its day doc.
	exec(t, d, `UPDATE messages SET is_deleted = 1 WHERE ts = ?`, fmt.Sprintf("%d.000200", recent))
	exec(t, d, `UPDATE messages SET thread_ts = ts WHERE channel_id = '1:D1' AND ts = '1758000400.000500'`)
	msg(t, d, "1:D1", "1758000450.000550", "1:U1", "ответ в тред", "1758000400.000500", "")
	exec(t, d, `DELETE FROM jira_comments`)
	exec(t, d, `DELETE FROM jira_issues`)
	sourceBefore := dumpSourceTables(t, d)

	day2 := testNow().Add(24 * time.Hour)
	_, err = Run(ctx, d, Options{Now: day2}) // pass 3, next UTC day: reconcile runs
	require.NoError(t, err)
	incremental := dumpKB(t, d)
	assert.NotContains(t, incremental, "ответ, который потом удалят")
	assert.NotContains(t, incremental, "jira:1:PROJ-123")
	assert.Contains(t, incremental, "Урезать на треть")
	assert.Contains(t, incremental, "кэш на уровне CDN")
	assert.Contains(t, incremental, "и еще договорились про стейдж")
	assert.Contains(t, incremental, "ответ в тред")

	_, err = Reindex(ctx, d, nil, day2)
	require.NoError(t, err)
	assert.Equal(t, incremental, dumpKB(t, d), "incremental indexing equals a from-scratch rebuild")
	assert.Equal(t, sourceBefore, dumpSourceTables(t, d), "indexing never writes a source table")
}

// TestKB02_NoGeneratorImports — KB-02: internal/kb makes no model calls, so it
// imports none of the generator packages.
func TestKB02_NoGeneratorImports(t *testing.T) {
	entries, err := os.ReadDir(".")
	require.NoError(t, err)
	forbidden := []string{"watchtower/internal/digest", "watchtower/internal/ai", "watchtower/internal/codex", "watchtower/internal/ollama", "watchtower/internal/providers"}
	fset := token.NewFileSet()
	files := 0
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		f, err := parser.ParseFile(fset, name, nil, parser.ImportsOnly)
		require.NoError(t, err, name)
		files++
		for _, imp := range f.Imports {
			path := strings.Trim(imp.Path.Value, `"`)
			for _, bad := range forbidden {
				assert.False(t, path == bad || strings.HasPrefix(path, bad+"/"), "%s imports %s", name, path)
			}
		}
	}
	assert.GreaterOrEqual(t, files, 10, "scan floor: the kb package files must actually be walked")
}

// TestKB03_EveryHitOpensAndAnchors — KB-03: every hit, from every source,
// opens via GetDocument and carries a non-empty source-native anchor.
func TestKB03_EveryHitOpensAndAnchors(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedAll(t, d)
	// Per source, queries that together reach every one of its fixture documents.
	perSource := map[string][]string{
		"slack":         {"пятница", "привет"},
		"gmail":         {"бюджет", "solo"},
		"imap":          {"инвойс"},
		"jira":          {"стейдж"},
		"calendar":      {"стейдж", "квартальное"},
		"transcript":    {"миграция"},
		"recap":         {"ретроспективу", "созвон"},
		"digest":        {"выкатку", "итоги"},
		"stream_digest": {"стейдж", "untitled"},
		"idea":          {"кэш*"},
	}
	require.Len(t, perSource, len(SourceNames()), "the fixture covers every source")
	var all []Hit
	for _, src := range SourceNames() {
		queries, ok := perSource[src]
		require.True(t, ok, "no query for source %s", src)
		res, err := Search(ctx, d, Request{Queries: queries, Sources: []string{src}, Limit: MaxLimit, Now: testNow()})
		require.NoError(t, err, src)
		n := countDocs(t, d, src)
		require.Positive(t, n, "seedAll indexed no %s document", src)
		assert.Len(t, res.Hits, n, "every %s document is reachable", src)
		all = append(all, res.Hits...)
	}
	broad, err := Search(ctx, d, Request{Queries: []string{"стейдж привет бюджет инвойс", "миграция OR кэш*"}, Limit: MaxLimit, Now: testNow()})
	require.NoError(t, err)
	assert.GreaterOrEqual(t, len(hitSources(broad)), 5, "the broad OR query spans sources")
	all = append(all, broad.Hits...)

	seen := map[string]bool{}
	for _, h := range all {
		seen[h.Source] = true
		doc, err := GetDocument(ctx, d, h.Ref, DocOptions{})
		require.NoError(t, err, h.Ref)
		assert.NotEmpty(t, strings.TrimSpace(doc.Text), h.Ref)
		assert.Equal(t, h.Ref, doc.Ref)
		assert.NotEmpty(t, h.Anchor, "%s has no anchor", h.Ref)
		for k, v := range h.Anchor {
			assert.NotEmpty(t, v, "%s anchor %q is empty", h.Ref, k)
		}
		assert.Equal(t, h.Anchor, doc.Anchor, h.Ref)
		// The hit's best-matching chunk opens too (from_chunk = hit.Chunk).
		at, err := GetDocument(ctx, d, h.Ref, DocOptions{FromChunk: h.Chunk})
		require.NoError(t, err, "%s from chunk %d", h.Ref, h.Chunk)
		assert.NotEmpty(t, strings.TrimSpace(at.Text), h.Ref)
	}
	for _, src := range SourceNames() {
		assert.True(t, seen[src], "no hit from source %s", src)
	}
}
