package memory

import (
	"fmt"
	"os"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// TestMain installs the db schema template cache before running tests.
// Without it, every db.Open(":memory:") call runs the full goose migration
// suite which under -race exceeds Go's 10-minute test timeout on CI.
func TestMain(m *testing.M) {
	if err := db.InitTestTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}

// newTestDB opens an isolated pre-migrated in-memory database.
func newTestDB(t *testing.T) *db.DB {
	t.Helper()
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	return d
}

// newTestVault opens a fresh vault in a temp dir.
func newTestVault(t *testing.T) *Vault {
	t.Helper()
	v, err := OpenVault(t.TempDir())
	require.NoError(t, err)
	return v
}

// indexNode upserts a node into the SQLite index the way reconcile would.
func indexNode(t *testing.T, d *db.DB, n Node) {
	t.Helper()
	rel, err := nodeRelPath(n.ID)
	require.NoError(t, err)
	require.NoError(t, d.UpsertMemoryNode(db.MemoryNodeRow{
		ID:          n.ID,
		Type:        n.Type,
		Tier:        n.Tier,
		Status:      n.Status,
		RedirectTo:  n.RedirectTo,
		Title:       n.Title,
		Path:        rel,
		ContentHash: "test-hash",
		IndexedAt:   "2026-07-15T00:00:00Z",
	}, n.Body, n.Aliases))
}

// writeAndIndex commits a node to the vault and mirrors it into the index.
func writeAndIndex(t *testing.T, v *Vault, d *db.DB, n Node) {
	t.Helper()
	_, err := v.WriteNodes([]Node{n}, CommitMsg{Op: "seed", Summary: "test node", Cause: "seed", NodeIDs: []string{n.ID}})
	require.NoError(t, err)
	indexNode(t, d, n)
}

// tombstoneNode builds a tombstone stub redirecting to target.
func tombstoneNode(id, target string) Node {
	return Node{
		ID:         id,
		Type:       "entity",
		Tier:       "long",
		Status:     "tombstone",
		RedirectTo: target,
		Body:       "Merged into [[" + target + "]].\n",
	}
}

func TestResolveByCanonicalID(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	n := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5RS1", "entity", "Billing")
	writeAndIndex(t, v, d, n)

	got, err := Resolve(v, d, n.ID)
	require.NoError(t, err)
	assert.Equal(t, n, got)
}

func TestResolveByAliasCaseInsensitive(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	n := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5RS2", "entity", "Deploys Channel")
	n.Aliases = []string{"C0123ABC", "situation:42"}
	writeAndIndex(t, v, d, n)

	for _, ref := range []string{"C0123ABC", "c0123abc", "situation:42", "SITUATION:42"} {
		got, err := Resolve(v, d, ref)
		require.NoError(t, err, "ref %q", ref)
		assert.Equal(t, n.ID, got.ID, "ref %q", ref)
	}
}

func TestResolveTombstoneChaseTwoHops(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	final := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5RS5", "entity", "Winner")
	mid := tombstoneNode("ent_01ARZ3NDEKTSV4RRFFQ69G5RS4", final.ID)
	first := tombstoneNode("ent_01ARZ3NDEKTSV4RRFFQ69G5RS3", mid.ID)
	for _, n := range []Node{final, mid, first} {
		writeAndIndex(t, v, d, n)
	}

	got, err := Resolve(v, d, first.ID)
	require.NoError(t, err)
	assert.Equal(t, final.ID, got.ID, "resolved node carries the FINAL canonical ID")
	assert.Equal(t, final, got)
}

func TestResolveRedirectCycleErrors(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	a := tombstoneNode("ent_01ARZ3NDEKTSV4RRFFQ69G5RS6", "ent_01ARZ3NDEKTSV4RRFFQ69G5RS7")
	b := tombstoneNode("ent_01ARZ3NDEKTSV4RRFFQ69G5RS7", a.ID)
	writeAndIndex(t, v, d, a)
	writeAndIndex(t, v, d, b)

	_, err := Resolve(v, d, a.ID)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "cycle")
}

func TestResolveUnknownRefReturnsErrNotFound(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)

	_, err := Resolve(v, d, "no-such-alias")
	require.ErrorIs(t, err, ErrNotFound)

	_, err = Resolve(v, d, "ent_01ARZ3NDEKTSV4RRFFQ69G5RS8")
	require.ErrorIs(t, err, ErrNotFound)
}
