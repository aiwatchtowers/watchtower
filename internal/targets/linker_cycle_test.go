package targets

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
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
	got, err := forbiddenParentIDs(1, snapshot, func(id int64) (int64, bool, error) {
		p, ok := parents[id]
		return p, ok, nil
	})
	require.NoError(t, err)
	assert.Equal(t, map[int64]bool{1: true, 3: true}, got)
}

// A pre-existing cycle that does not reach the target must terminate cleanly.
func TestForbiddenParentIDs_TerminatesOnExistingCycle(t *testing.T) {
	snapshot := []db.Target{
		{ID: 5, ParentID: sql.NullInt64{Int64: 6, Valid: true}},
		{ID: 6, ParentID: sql.NullInt64{Int64: 5, Valid: true}},
	}
	got, err := forbiddenParentIDs(1, snapshot, noParent)
	require.NoError(t, err)
	assert.Equal(t, map[int64]bool{1: true}, got)
}

func TestForbiddenParentIDs_EmptySnapshot(t *testing.T) {
	got, err := forbiddenParentIDs(7, nil, noParent)
	require.NoError(t, err)
	assert.Equal(t, map[int64]bool{7: true}, got)
}

// An ancestor that cannot be read, or a chain deeper than the walk cap, leaves
// the check unproven: it fails closed with an error.
func TestForbiddenParentIDs_FailsClosed(t *testing.T) {
	errRead := errors.New("disk I/O error")
	snapshot := []db.Target{{ID: 3, ParentID: sql.NullInt64{Int64: 2, Valid: true}}}
	_, err := forbiddenParentIDs(1, snapshot, func(int64) (int64, bool, error) { return 0, false, errRead })
	assert.ErrorIs(t, err, errRead)

	// 3 → 100 → 101 → … never ends within the cap.
	_, err = forbiddenParentIDs(1, snapshot, func(id int64) (int64, bool, error) {
		if id == 2 {
			return 100, true, nil
		}
		return id + 1, true, nil
	})
	assert.ErrorIs(t, err, errParentWalkTooDeep)
}

// When the ancestor walk fails, LinkExisting proposes no parent at all — even
// one that looks legitimate — but still returns the secondary links. A
// snapshot limit of 1 keeps Root out of the snapshot (Mid sorts first as the
// only quarter-level target), so Mid's chain must look Root up.
func TestLinkExisting_UnreadableAncestorDropsProposedParent(t *testing.T) {
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	defer d.Close()

	root := createLinkTarget(t, d, "Root", 0)
	target := createLinkTarget(t, d, "Target", 0)
	midID, err := d.CreateTarget(db.Target{
		Text: "Mid", Level: "quarter", PeriodStart: "2026-04-01", PeriodEnd: "2026-06-30",
		Status: "todo", Priority: "medium", Ownership: "mine", SourceType: "manual",
		ParentID: sql.NullInt64{Int64: root, Valid: true},
	})
	require.NoError(t, err)

	resp := fmt.Sprintf(`{"parent_id": %d, "secondary_links": [{"target_id": %d, "relation": "related"}]}`, midID, midID)
	cfg := &config.TargetsConfig{Resolver: config.TargetsResolverConfig{ActiveSnapshotLimit: 1}}
	for name, tc := range map[string]struct {
		lookup     parentLookup
		wantParent bool
	}{
		"lookup error fails closed": {func(int64) (int64, bool, error) { return 0, false, errors.New("injected read failure") }, false},
		"clean walk keeps parent":   {nil, true}, // the real DB lookup: Root has no parent
	} {
		t.Run(name, func(t *testing.T) {
			p := New(d, cfg, &mockGenerator{responses: []string{resp}}, nil, "", nil)
			p.ancestorParent = tc.lookup
			res, err := p.LinkExisting(context.Background(), target)
			require.NoError(t, err)
			assert.Equal(t, tc.wantParent, res.ParentID.Valid)
			assert.Len(t, res.SecondaryLinks, 1)
		})
	}
}

func noParent(int64) (int64, bool, error) { return 0, false, nil }
