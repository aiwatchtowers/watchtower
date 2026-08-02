package memory

import (
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// recordHint records a (hint, episode) observation for promotion tests.
func recordHint(t *testing.T, d *db.DB, hint, episodeID string) {
	t.Helper()
	require.NoError(t, d.RecordEntityHints([]db.EntityHint{{Hint: hint, EpisodeID: episodeID}}))
}

// TestPromoteConceptsCreatesEntityAtThreshold: a hint recurring across 5
// distinct episodes becomes one concept entity with alias "hsm", the five
// contributing episodes back-linked into ## Links, one commit, and resolvable.
func TestPromoteConceptsCreatesEntityAtThreshold(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	var epIDs []string
	for i := 0; i < 5; i++ {
		ep := fmt.Sprintf("ep_01ARZ3NDEKTSV4RRFFQ69G5H0%d", i)
		epIDs = append(epIDs, ep)
		recordHint(t, d, "hsm", ep)
	}

	before := commitCount(t, openTestRepo(t, v.path))
	created, err := PromoteConcepts(v, d, 5, 10)
	require.NoError(t, err)
	assert.Equal(t, 1, created)
	assert.Equal(t, before+1, commitCount(t, openTestRepo(t, v.path)), "exactly one promote commit")

	got, err := Resolve(v, d, "hsm")
	require.NoError(t, err)
	assert.Equal(t, "entity", got.Type)
	assert.Equal(t, "long", got.Tier)
	assert.Equal(t, []string{"hsm"}, got.Aliases)
	for _, ep := range epIDs {
		assert.Contains(t, got.Body, "[["+ep+"]]", "episode %s back-linked", ep)
	}
}

// TestPromoteConceptsBelowThreshold: 4 distinct episodes do not reach the
// threshold of 5 → nothing promoted.
func TestPromoteConceptsBelowThreshold(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	for i := 0; i < 4; i++ {
		recordHint(t, d, "phishing", fmt.Sprintf("ep_01ARZ3NDEKTSV4RRFFQ69G5H1%d", i))
	}

	created, err := PromoteConcepts(v, d, 5, 10)
	require.NoError(t, err)
	assert.Equal(t, 0, created)

	_, err = Resolve(v, d, "phishing")
	require.ErrorIs(t, err, ErrNotFound)
}

// TestPromoteConceptsIdempotent: a second run promotes nothing (the first run
// stamped promoted_to on the hint rows).
func TestPromoteConceptsIdempotent(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	for i := 0; i < 5; i++ {
		recordHint(t, d, "hsm", fmt.Sprintf("ep_01ARZ3NDEKTSV4RRFFQ69G5H2%d", i))
	}

	created, err := PromoteConcepts(v, d, 5, 10)
	require.NoError(t, err)
	require.Equal(t, 1, created)

	created, err = PromoteConcepts(v, d, 5, 10)
	require.NoError(t, err)
	assert.Equal(t, 0, created, "already-promoted hints are not re-promoted")
}

// TestPromoteConceptsAliasCollision: when the concept alias already resolves to
// an existing node, no new node is created — the hint is just marked promoted
// to the existing node id.
func TestPromoteConceptsAliasCollision(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	existing := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5H30", "entity", "HSM appliance")
	existing.Aliases = []string{"hsm"}
	writeAndIndex(t, v, d, existing)

	for i := 0; i < 5; i++ {
		recordHint(t, d, "hsm", fmt.Sprintf("ep_01ARZ3NDEKTSV4RRFFQ69G5H3%d", i+1))
	}

	before := commitCount(t, openTestRepo(t, v.path))
	created, err := PromoteConcepts(v, d, 5, 10)
	require.NoError(t, err)
	assert.Equal(t, 0, created, "collision creates no new node")
	assert.Equal(t, before, commitCount(t, openTestRepo(t, v.path)), "no commit on a pure collision")

	// The hint is marked promoted to the existing node, so it never re-promotes.
	promotable, err := d.ListPromotableHints(5)
	require.NoError(t, err)
	assert.Empty(t, promotable, "collided hint is marked promoted")
	var promotedTo string
	require.NoError(t, d.QueryRow(`SELECT promoted_to FROM memory_entity_hints WHERE hint = 'hsm' LIMIT 1`).Scan(&promotedTo))
	assert.Equal(t, existing.ID, promotedTo)
}

// TestPromoteConceptsCapRespected: with three eligible hints and a cap of one,
// only one concept entity is created per run.
func TestPromoteConceptsCapRespected(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	for _, hint := range []string{"alpha", "bravo", "charlie"} {
		for i := 0; i < 5; i++ {
			recordHint(t, d, hint, fmt.Sprintf("ep_%s_%d", hint, i))
		}
	}

	created, err := PromoteConcepts(v, d, 5, 1)
	require.NoError(t, err)
	assert.Equal(t, 1, created, "cap of one stops after a single concept entity")
}
