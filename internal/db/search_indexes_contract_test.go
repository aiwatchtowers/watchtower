package db

import (
	"bytes"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestSearchIdx01_MigrationsKeepMessagesRowid pins SEARCHIDX-01's migration
// half: messages_fts rows are keyed by messages.rowid, so every migration
// after 00146 that rebuilds messages must copy rowid. The seed leaves rowid
// gaps, which a rebuild without rowid would close and so shift every key.
func TestSearchIdx01_MigrationsKeepMessagesRowid(t *testing.T) {
	t.Parallel()
	d := rawFileDBAt(t, 146)
	for i := range 50 {
		_, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C1', ?, 'U1', ?)`,
			fmt.Sprintf("1.%06d", i), fmt.Sprintf("indexed words %d", i))
		require.NoError(t, err)
	}
	_, err := d.Exec(`DELETE FROM messages WHERE rowid % 3 = 0`)
	require.NoError(t, err)
	require.Positive(t, queryInt(t, d, `SELECT MAX(rowid) - COUNT(*) FROM messages`), "the seed must leave rowid gaps")

	require.NoError(t, d.migrate())

	assert.Zero(t, queryInt(t, d, messagesIndexMismatches))
	assert.Equal(t,
		queryInt(t, d, `SELECT COUNT(*) FROM messages WHERE text != '' AND is_deleted = 0`),
		queryInt(t, d, `SELECT COUNT(*) FROM messages_fts`))
}

// replaceIntoMessages matches a REPLACE write to the messages table. REPLACE
// deletes the conflicting row and inserts a new one under a new rowid, which
// orphans its messages_fts row.
var replaceIntoMessages = regexp.MustCompile("(?i)(insert\\s+or\\s+replace|replace)\\s+into\\s+(main\\.)?[\"`\\[]?messages\\b")

// searchIdxScanMinFiles is the coverage floor: a scan pointed at the wrong
// root walks nothing and passes for the wrong reason.
const searchIdxScanMinFiles = 300

// TestSearchIdx01_NoReplaceIntoMessages pins SEARCHIDX-01's write half: no
// code path writes messages with INSERT OR REPLACE or REPLACE INTO (upserts
// use ON CONFLICT … DO UPDATE, which keeps the rowid). It scans the non-test
// Go and SQL files under internal/ and cmd/ and the Desktop's Swift sources.
func TestSearchIdx01_NoReplaceIntoMessages(t *testing.T) {
	root := repoRootForOwnerScan(t)
	scans := []struct {
		dir  string
		exts []string
	}{
		{"internal", []string{".go", ".sql"}},
		{"cmd", []string{".go"}},
		{filepath.Join("WatchtowerDesktop", "Sources"), []string{".swift"}},
	}

	repo, err := os.OpenRoot(root)
	require.NoError(t, err)
	t.Cleanup(func() { _ = repo.Close() })
	walked := 0
	for _, s := range scans {
		err := fs.WalkDir(repo.FS(), filepath.ToSlash(s.dir), func(path string, e fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if e.IsDir() || strings.HasSuffix(path, "_test.go") || !hasAnySuffix(path, s.exts) {
				return nil
			}
			walked++
			body, err := fs.ReadFile(repo.FS(), path)
			if err != nil {
				return err
			}
			// The whole body, so a statement split across lines still matches.
			for _, m := range replaceIntoMessages.FindAllIndex(body, -1) {
				line := 1 + bytes.Count(body[:m[0]], []byte("\n"))
				t.Errorf("%s:%d: writes messages with REPLACE — use ON CONFLICT … DO UPDATE so the rowid (the search index key) stays (SEARCHIDX-01)", path, line)
			}
			return nil
		})
		require.NoError(t, err, "walking %s", s.dir)
	}
	require.GreaterOrEqual(t, walked, searchIdxScanMinFiles, "wrong root %q?", root)
}

func hasAnySuffix(s string, suffixes []string) bool {
	for _, suf := range suffixes {
		if strings.HasSuffix(s, suf) {
			return true
		}
	}
	return false
}
