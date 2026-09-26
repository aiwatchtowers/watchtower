package memory

import (
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// TestRetrieveCompare_LegacyTablesByteIdentical is the MEM-05/14-precedent
// pure-reader guard, adapted from TestDigestCompare_LegacyTablesByteIdentical:
// all three Compare* functions read memory_nodes/memory_fts (and, for
// CompareRevisions, the vault) and write ONLY memory_retrieve_shadow — never
// mutating a memory_nodes row, never touching the vault git log. Tasks 8-10
// each add a further, surface-specific guard proving their LIVE caller's
// actual returned response/journal/context is unchanged; this test proves
// the shared infrastructure itself never mutates anything but the shadow
// table, independent of any specific caller.
func TestRetrieveCompare_LegacyTablesByteIdentical(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	target := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5TG01", "entity", "Target")
	writeNodes(t, v, target)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	before := dumpMemoryNodesTable(t, d)
	beforeHead := memGitHeadCountForTest(t, v.path)

	_, err = CompareRecall(d, d, "target", []string{target.ID}, 10)
	require.NoError(t, err)
	_, err = CompareRevisions(d, d, v, 0, nil, 5)
	require.NoError(t, err)
	_, err = CompareSubject(d, d, target.ID, nil, 3, 5)
	require.NoError(t, err)

	after := dumpMemoryNodesTable(t, d)
	assert.Equal(t, before, after, "memory_nodes must be byte-identical across all three compare calls")
	assert.Equal(t, beforeHead, memGitHeadCountForTest(t, v.path), "the vault git log must not move")

	rows, err := d.ListMemoryRetrieveShadow("recall", time.Time{})
	require.NoError(t, err)
	assert.Len(t, rows, 1, "exactly one recall shadow row written")
}

// dumpMemoryNodesTable serializes every memory_nodes row into one comparable
// string, for the byte-identical guard above (the digest_compare.go
// dumpDigestTables precedent, applied to memory_nodes instead of
// digests/digest_topics).
func dumpMemoryNodesTable(t *testing.T, d *db.DB) string {
	t.Helper()
	var b strings.Builder
	rows, err := d.Query(`SELECT id, type, tier, status, COALESCE(redirect_to, ''),
			title, path, content_hash, indexed_at, subject, confidence, importance_score
		FROM memory_nodes ORDER BY id`)
	require.NoError(t, err)
	defer rows.Close()
	for rows.Next() {
		var id, typ, tier, status, redirectTo, title, path, contentHash, indexedAt, subject string
		var confidence, importance float64
		require.NoError(t, rows.Scan(&id, &typ, &tier, &status, &redirectTo,
			&title, &path, &contentHash, &indexedAt, &subject, &confidence, &importance))
		fmt.Fprintf(&b, "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%v|%v\n",
			id, typ, tier, status, redirectTo, title, path, contentHash, indexedAt, subject, confidence, importance)
	}
	require.NoError(t, rows.Err())
	return b.String()
}

// memGitHeadCountForTest returns the vault repo's commit count at path, via
// `git rev-list --count HEAD` — the "did the vault git log move" guard,
// cheaper than diffing the full log.
func memGitHeadCountForTest(t *testing.T, path string) int {
	t.Helper()
	out, err := exec.Command("git", "-C", path, "rev-list", "--count", "HEAD").Output()
	require.NoError(t, err)
	n, err := strconv.Atoi(strings.TrimSpace(string(out)))
	require.NoError(t, err)
	return n
}
