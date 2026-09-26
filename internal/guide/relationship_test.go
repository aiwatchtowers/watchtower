package guide

import (
	"testing"

	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
)

// TestRelationshipContext_DirectReport pins the Reports match: the blob and
// the probe id both carry the "1:<rawID>" namespace prefix migration 00054
// backfills, so the plain substring check against the raw JSON text succeeds.
func TestRelationshipContext_DirectReport(t *testing.T) {
	p := &Pipeline{profile: &db.UserProfile{Reports: `["1:U456"]`}}
	assert.Contains(t, p.relationshipContext("1:U456"), "DIRECT REPORT")
}

// TestRelationshipContext_Peer is the same contract for the Peers blob.
func TestRelationshipContext_Peer(t *testing.T) {
	p := &Pipeline{profile: &db.UserProfile{Peers: `["1:U789"]`}}
	assert.Contains(t, p.relationshipContext("1:U789"), "YOUR PEER")
}

// TestRelationshipContext_NoMatch: an id absent from every blob yields no
// relationship, not an error.
func TestRelationshipContext_NoMatch(t *testing.T) {
	p := &Pipeline{profile: &db.UserProfile{
		Reports: `["1:U456"]`,
		Peers:   `["1:U789"]`,
	}}
	assert.Equal(t, "", p.relationshipContext("1:U000"))
}

// TestRelationshipContext_BareBlobMisses is the negative twin: a Reports blob
// that was never namespaced (still bare "U456") can never match a namespaced
// probe id, so the relationship silently disappears instead of erroring —
// the exact hazard migration 00054 fixes. This must fail if the match ever
// becomes namespace-tolerant by accident.
func TestRelationshipContext_BareBlobMisses(t *testing.T) {
	p := &Pipeline{profile: &db.UserProfile{Reports: `["U456"]`}}
	assert.Equal(t, "", p.relationshipContext("1:U456"))
}
