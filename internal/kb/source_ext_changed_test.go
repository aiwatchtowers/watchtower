package kb

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"

	"watchtower/internal/db"
)

// TestConfluence_ChangedDocsQueryPlan guards extDocsChangedQuery (the docs
// arm of extSource.Changed): the s.id = d.source_id join must resolve
// through an index over ext_documents, never a full scan — this is the
// query a daemon cycle runs on every install with a selected space, so an
// unindexed join here costs one table scan per cycle regardless of how much
// changed.
func TestConfluence_ChangedDocsQueryPlan(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedConfluence(t, d)
	plan := explainPlanDetail(ctx, t, d, extDocsChangedQuery, "confluence", "confluence", "", "2099-01-01T00:00:00Z")
	assert.NotContains(t, plan, "SCAN d", "the join must not fall back to a full ext_documents scan")
	assert.NotContains(t, plan, "SCAN ext_documents")
}
