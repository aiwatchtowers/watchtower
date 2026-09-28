package targets

import (
	"context"
	"database/sql"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func createLinkTarget(t *testing.T, d *db.DB, text string, parent int64) int64 {
	t.Helper()
	tg := db.Target{
		Text: text, Level: "day", PeriodStart: "2026-04-23", PeriodEnd: "2026-04-23",
		Status: "todo", Priority: "medium", Ownership: "mine", SourceType: "manual",
	}
	if parent > 0 {
		tg.ParentID = sql.NullInt64{Int64: parent, Valid: true}
	}
	id, err := d.CreateTarget(tg)
	require.NoError(t, err)
	return id
}

// A proposed parent that is the target itself or one of its descendants
// would make the target its own ancestor; it is dropped like an unknown id,
// while a legitimate parent still passes. A secondary link to the target
// itself is dropped too.
func TestLinkExisting_RejectsSelfAndDescendantParents(t *testing.T) {
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	defer d.Close()

	root := createLinkTarget(t, d, "Root", 0)
	target := createLinkTarget(t, d, "Target", root)
	child := createLinkTarget(t, d, "Child", target)
	grandchild := createLinkTarget(t, d, "Grandchild", child)
	other := createLinkTarget(t, d, "Unrelated", 0)

	for name, tc := range map[string]struct {
		parent int64
		want   int64 // 0 = no parent proposed
	}{
		"self":       {target, 0},
		"child":      {child, 0},
		"grandchild": {grandchild, 0},
		"root":       {root, root},
		"unrelated":  {other, other},
	} {
		t.Run(name, func(t *testing.T) {
			resp := fmt.Sprintf(`{"parent_id": %d, "secondary_links": [
				{"target_id": %d, "relation": "related"},
				{"target_id": %d, "relation": "contributes_to"}
			]}`, tc.parent, target, child)
			p := New(d, nil, &mockGenerator{responses: []string{resp}}, nil, "", nil)
			res, err := p.LinkExisting(context.Background(), target)
			require.NoError(t, err)
			if tc.want == 0 {
				assert.False(t, res.ParentID.Valid, "parent %d must be rejected", tc.parent)
			} else {
				assert.Equal(t, sql.NullInt64{Int64: tc.want, Valid: true}, res.ParentID)
			}
			require.Len(t, res.SecondaryLinks, 1, "the self link is dropped, the child link kept")
			assert.Equal(t, child, res.SecondaryLinks[0].TargetID.Int64)
		})
	}
}

// An ancestor outside the snapshot is resolved through parentOf, so a
// descendant whose chain passes through it is still forbidden.
func TestForbiddenParentIDs_WalksThroughAncestorsOutsideSnapshot(t *testing.T) {
	snapshot := []db.Target{
		{ID: 3, ParentID: sql.NullInt64{Int64: 2, Valid: true}}, // 2 is not in the snapshot
		{ID: 4},
	}
	parents := map[int64]int64{2: 1}
	got := forbiddenParentIDs(1, snapshot, func(id int64) (int64, bool) {
		p, ok := parents[id]
		return p, ok
	})
	assert.Equal(t, map[int64]bool{1: true, 3: true}, got)
}

// A pre-existing cycle that does not reach the target must terminate.
func TestForbiddenParentIDs_TerminatesOnExistingCycle(t *testing.T) {
	snapshot := []db.Target{
		{ID: 5, ParentID: sql.NullInt64{Int64: 6, Valid: true}},
		{ID: 6, ParentID: sql.NullInt64{Int64: 5, Valid: true}},
	}
	got := forbiddenParentIDs(1, snapshot, func(int64) (int64, bool) { return 0, false })
	assert.Equal(t, map[int64]bool{1: true}, got)
}

func TestForbiddenParentIDs_EmptySnapshot(t *testing.T) {
	got := forbiddenParentIDs(7, nil, func(int64) (int64, bool) { return 0, false })
	assert.Equal(t, map[int64]bool{7: true}, got)
}
