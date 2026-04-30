package db

import (
	"database/sql"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// helpers

func makeTarget(text, status, priority string) Target {
	return Target{
		Text:       text,
		Status:     status,
		Priority:   priority,
		Ownership:  "mine",
		SourceType: "manual",
		Level:      "day",
	}
}

// ── CreateTarget / GetTargetByID ────────────────────────────────────────────

func TestCreateTarget_RoundTrip(t *testing.T) {
	db := openTestDB(t)

	id, err := db.CreateTarget(Target{
		Text:        "Review PR #42",
		Intent:      "Check the API changes",
		Status:      "todo",
		Priority:    "high",
		Ownership:   "mine",
		Level:       "week",
		PeriodStart: "2026-04-21",
		PeriodEnd:   "2026-04-27",
		BallOn:      "alice",
		DueDate:     "2026-04-25",
		Tags:        `["review","api"]`,
		SubItems:    `[{"text":"Check tests","done":false}]`,
		SourceType:  "manual",
	})
	require.NoError(t, err)
	assert.Greater(t, id, int64(0))

	tgt, err := db.GetTargetByID(int(id))
	require.NoError(t, err)
	assert.Equal(t, "Review PR #42", tgt.Text)
	assert.Equal(t, "Check the API changes", tgt.Intent)
	assert.Equal(t, "todo", tgt.Status)
	assert.Equal(t, "high", tgt.Priority)
	assert.Equal(t, "mine", tgt.Ownership)
	assert.Equal(t, "week", tgt.Level)
	assert.Equal(t, "2026-04-21", tgt.PeriodStart)
	assert.Equal(t, "2026-04-27", tgt.PeriodEnd)
	assert.Equal(t, "alice", tgt.BallOn)
	assert.Equal(t, "2026-04-25", tgt.DueDate)
	assert.Equal(t, `["review","api"]`, tgt.Tags)
	assert.NotEmpty(t, tgt.CreatedAt)
	assert.NotEmpty(t, tgt.UpdatedAt)
}

func TestCreateTarget_Defaults(t *testing.T) {
	db := openTestDB(t)

	id, err := db.CreateTarget(makeTarget("Simple target", "todo", "medium"))
	require.NoError(t, err)

	tgt, err := db.GetTargetByID(int(id))
	require.NoError(t, err)
	assert.Equal(t, "", tgt.Intent)
	assert.Equal(t, "day", tgt.Level)
	assert.Equal(t, "[]", tgt.Tags)
	assert.Equal(t, "[]", tgt.SubItems)
	assert.Equal(t, "[]", tgt.Notes)
	assert.False(t, tgt.ParentID.Valid)
	assert.False(t, tgt.AILevelConfidence.Valid)
}

// ── GetTargets filters ───────────────────────────────────────────────────────

func TestGetTargets_FilterByStatus(t *testing.T) {
	db := openTestDB(t)

	_, err := db.CreateTarget(makeTarget("Todo", "todo", "medium"))
	require.NoError(t, err)
	_, err = db.CreateTarget(makeTarget("InProgress", "in_progress", "medium"))
	require.NoError(t, err)
	_, err = db.CreateTarget(makeTarget("Done", "done", "medium"))
	require.NoError(t, err)

	targets, err := db.GetTargets(TargetFilter{Status: "todo"})
	require.NoError(t, err)
	assert.Len(t, targets, 1)
	assert.Equal(t, "Todo", targets[0].Text)
}

func TestGetTargets_DefaultExcludesDone(t *testing.T) {
	db := openTestDB(t)

	_, err := db.CreateTarget(makeTarget("Active", "todo", "medium"))
	require.NoError(t, err)
	_, err = db.CreateTarget(makeTarget("Done", "done", "medium"))
	require.NoError(t, err)
	_, err = db.CreateTarget(makeTarget("Dismissed", "dismissed", "medium"))
	require.NoError(t, err)

	targets, err := db.GetTargets(TargetFilter{})
	require.NoError(t, err)
	assert.Len(t, targets, 1)
	assert.Equal(t, "Active", targets[0].Text)

	all, err := db.GetTargets(TargetFilter{IncludeDone: true})
	require.NoError(t, err)
	assert.Len(t, all, 3)
}

func TestGetTargets_FilterByLevel(t *testing.T) {
	db := openTestDB(t)

	t1 := makeTarget("Quarter goal", "todo", "high")
	t1.Level = "quarter"
	t1.PeriodStart = "2026-04-01"
	t1.PeriodEnd = "2026-06-30"
	_, err := db.CreateTarget(t1)
	require.NoError(t, err)

	t2 := makeTarget("Day task", "todo", "medium")
	t2.Level = "day"
	_, err = db.CreateTarget(t2)
	require.NoError(t, err)

	targets, err := db.GetTargets(TargetFilter{Level: "quarter"})
	require.NoError(t, err)
	assert.Len(t, targets, 1)
	assert.Equal(t, "Quarter goal", targets[0].Text)
}

func TestGetTargets_Limit(t *testing.T) {
	db := openTestDB(t)

	for i := 0; i < 5; i++ {
		_, err := db.CreateTarget(makeTarget(fmt.Sprintf("T%d", i), "todo", "medium"))
		require.NoError(t, err)
	}

	targets, err := db.GetTargets(TargetFilter{Limit: 3})
	require.NoError(t, err)
	assert.Len(t, targets, 3)
}

// ── UpdateTargetStatus ───────────────────────────────────────────────────────

func TestUpdateTargetStatus(t *testing.T) {
	db := openTestDB(t)

	id, err := db.CreateTarget(makeTarget("Status test", "todo", "medium"))
	require.NoError(t, err)

	err = db.UpdateTargetStatus(int(id), "in_progress")
	require.NoError(t, err)

	tgt, err := db.GetTargetByID(int(id))
	require.NoError(t, err)
	assert.Equal(t, "in_progress", tgt.Status)

	err = db.UpdateTargetStatus(int(id), "done")
	require.NoError(t, err)

	tgt, err = db.GetTargetByID(int(id))
	require.NoError(t, err)
	assert.Equal(t, "done", tgt.Status)
}

// ── DeleteTarget / ON DELETE SET NULL on parent_id ───────────────────────────

func TestDeleteTarget_Basic(t *testing.T) {
	db := openTestDB(t)

	id, err := db.CreateTarget(makeTarget("To delete", "todo", "medium"))
	require.NoError(t, err)

	err = db.DeleteTarget(int(id))
	require.NoError(t, err)

	_, err = db.GetTargetByID(int(id))
	assert.Error(t, err)
}

func TestDeleteTarget_ParentIDSetNull(t *testing.T) {
	db := openTestDB(t)

	parentID, err := db.CreateTarget(makeTarget("Parent", "todo", "high"))
	require.NoError(t, err)

	child := makeTarget("Child", "todo", "medium")
	child.ParentID = sql.NullInt64{Int64: parentID, Valid: true}
	childID, err := db.CreateTarget(child)
	require.NoError(t, err)

	// Delete the parent — child.parent_id should become NULL.
	err = db.DeleteTarget(int(parentID))
	require.NoError(t, err)

	got, err := db.GetTargetByID(int(childID))
	require.NoError(t, err)
	assert.False(t, got.ParentID.Valid, "parent_id should be NULL after parent deletion")
}

// ── target_links UNIQUE constraint ──────────────────────────────────────────

func TestTargetLinks_UniqueConstraint(t *testing.T) {
	db := openTestDB(t)

	srcID, err := db.CreateTarget(makeTarget("Source", "todo", "medium"))
	require.NoError(t, err)
	dstID, err := db.CreateTarget(makeTarget("Dest", "todo", "medium"))
	require.NoError(t, err)

	link := TargetLink{
		SourceTargetID: int(srcID),
		TargetTargetID: sql.NullInt64{Int64: dstID, Valid: true},
		Relation:       "contributes_to",
		CreatedBy:      "user",
	}
	_, err = db.CreateTargetLink(link)
	require.NoError(t, err)

	// Duplicate should fail.
	_, err = db.CreateTargetLink(link)
	assert.Error(t, err, "duplicate link should violate UNIQUE constraint")
}

// ── target_links CHECK constraint ───────────────────────────────────────────

func TestTargetLinks_CheckConstraint(t *testing.T) {
	db := openTestDB(t)

	srcID, err := db.CreateTarget(makeTarget("Source", "todo", "medium"))
	require.NoError(t, err)

	// Both target_target_id NULL and external_ref '' — should fail CHECK.
	_, err = db.CreateTargetLink(TargetLink{
		SourceTargetID: int(srcID),
		TargetTargetID: sql.NullInt64{Valid: false},
		ExternalRef:    "",
		Relation:       "related",
		CreatedBy:      "user",
	})
	assert.Error(t, err, "CHECK(target_target_id IS NOT NULL OR external_ref != '') should fail")

	// external_ref non-empty with NULL target_target_id — should succeed.
	_, err = db.CreateTargetLink(TargetLink{
		SourceTargetID: int(srcID),
		TargetTargetID: sql.NullInt64{Valid: false},
		ExternalRef:    "jira:PROJ-123",
		Relation:       "related",
		CreatedBy:      "user",
	})
	require.NoError(t, err)
}

// ── target_links ON DELETE CASCADE ──────────────────────────────────────────

func TestTargetLinks_CascadeOnSourceDelete(t *testing.T) {
	db := openTestDB(t)

	srcID, err := db.CreateTarget(makeTarget("Source", "todo", "medium"))
	require.NoError(t, err)
	dstID, err := db.CreateTarget(makeTarget("Dest", "todo", "medium"))
	require.NoError(t, err)

	_, err = db.CreateTargetLink(TargetLink{
		SourceTargetID: int(srcID),
		TargetTargetID: sql.NullInt64{Int64: dstID, Valid: true},
		Relation:       "blocks",
		CreatedBy:      "user",
	})
	require.NoError(t, err)

	// Delete the source — link should cascade-delete.
	err = db.DeleteTarget(int(srcID))
	require.NoError(t, err)

	links, err := db.GetLinksForTarget(dstID, "both")
	require.NoError(t, err)
	assert.Len(t, links, 0, "links should be cascade-deleted when source target is deleted")
}

func TestTargetLinks_CascadeOnTargetDelete(t *testing.T) {
	db := openTestDB(t)

	srcID, err := db.CreateTarget(makeTarget("Source", "todo", "medium"))
	require.NoError(t, err)
	dstID, err := db.CreateTarget(makeTarget("Dest", "todo", "medium"))
	require.NoError(t, err)

	_, err = db.CreateTargetLink(TargetLink{
		SourceTargetID: int(srcID),
		TargetTargetID: sql.NullInt64{Int64: dstID, Valid: true},
		Relation:       "related",
		CreatedBy:      "ai",
	})
	require.NoError(t, err)

	// Delete the target endpoint — link should cascade-delete.
	err = db.DeleteTarget(int(dstID))
	require.NoError(t, err)

	links, err := db.GetLinksForTarget(srcID, "outbound")
	require.NoError(t, err)
	assert.Len(t, links, 0, "links should be cascade-deleted when target endpoint is deleted")
}

// ── RecomputeParentProgress ──────────────────────────────────────────────────

func TestRecomputeParentProgress_TwoLevel(t *testing.T) {
	db := openTestDB(t)

	// Create parent.
	parentID, err := db.CreateTarget(makeTarget("Parent", "todo", "high"))
	require.NoError(t, err)

	// Create 3 children: done(1.0), in_progress(0.5), todo(0.0).
	for _, spec := range []struct {
		text   string
		status string
	}{
		{"Child done", "done"},
		{"Child in_progress", "in_progress"},
		{"Child todo", "todo"},
	} {
		child := makeTarget(spec.text, spec.status, "medium")
		child.ParentID = sql.NullInt64{Int64: parentID, Valid: true}
		_, err := db.CreateTarget(child)
		require.NoError(t, err)
	}

	// Manually trigger recompute (CreateTarget already calls it per child, but verify final state).
	err = db.RecomputeParentProgress(parentID)
	require.NoError(t, err)

	parent, err := db.GetTargetByID(int(parentID))
	require.NoError(t, err)
	// AVG(1.0, 0.5, 0.0) = 0.5
	assert.InDelta(t, 0.5, parent.Progress, 0.001, "parent progress should be AVG of children")
}

func TestRecomputeParentProgress_AllDismissedChildren(t *testing.T) {
	db := openTestDB(t)

	parentID, err := db.CreateTarget(makeTarget("Parent", "in_progress", "high"))
	require.NoError(t, err)

	child := makeTarget("Dismissed child", "dismissed", "low")
	child.ParentID = sql.NullInt64{Int64: parentID, Valid: true}
	_, err = db.CreateTarget(child)
	require.NoError(t, err)

	err = db.RecomputeParentProgress(parentID)
	require.NoError(t, err)

	parent, err := db.GetTargetByID(int(parentID))
	require.NoError(t, err)
	// No non-dismissed children → fallback to own status (in_progress = 0.5).
	assert.InDelta(t, 0.5, parent.Progress, 0.001)
}

// ── Three-level hierarchy progress rollup (fix #11) ─────────────────────────

func TestRecomputeParentProgress_ThreeLevel(t *testing.T) {
	db := openTestDB(t)

	// quarter → week → day (leaf)
	quarterID, err := db.CreateTarget(makeTarget("Quarter", "todo", "high"))
	require.NoError(t, err)

	week := makeTarget("Week", "todo", "medium")
	week.Level = "week"
	week.ParentID = sql.NullInt64{Int64: quarterID, Valid: true}
	weekID, err := db.CreateTarget(week)
	require.NoError(t, err)

	day := makeTarget("Day leaf", "todo", "medium")
	day.Level = "day"
	day.ParentID = sql.NullInt64{Int64: weekID, Valid: true}
	dayID, err := db.CreateTarget(day)
	require.NoError(t, err)

	// Mark the leaf as done; RecomputeParentProgress should walk all the way up.
	require.NoError(t, db.UpdateTargetStatus(int(dayID), "done"))

	week2, err := db.GetTargetByID(int(weekID))
	require.NoError(t, err)
	assert.InDelta(t, 1.0, week2.Progress, 0.001, "week should be 100% when only child is done")

	quarter2, err := db.GetTargetByID(int(quarterID))
	require.NoError(t, err)
	assert.InDelta(t, 1.0, quarter2.Progress, 0.001, "quarter should be 100% when week is 100%")
}

func TestRecomputeParentProgress_DismissedMidLevel(t *testing.T) {
	db := openTestDB(t)

	// quarter → week (dismissed) → day (done)
	quarterID, err := db.CreateTarget(makeTarget("Quarter", "todo", "high"))
	require.NoError(t, err)

	week := makeTarget("Week", "in_progress", "medium")
	week.Level = "week"
	week.ParentID = sql.NullInt64{Int64: quarterID, Valid: true}
	weekID, err := db.CreateTarget(week)
	require.NoError(t, err)

	day := makeTarget("Day leaf", "done", "medium")
	day.Level = "day"
	day.ParentID = sql.NullInt64{Int64: weekID, Valid: true}
	_, err = db.CreateTarget(day)
	require.NoError(t, err)

	// Dismiss the week; quarter should no longer count it in its average.
	require.NoError(t, db.UpdateTargetStatus(int(weekID), "dismissed"))

	quarter2, err := db.GetTargetByID(int(quarterID))
	require.NoError(t, err)
	// No non-dismissed children of quarter → fallback to quarter's own status (todo=0.0).
	assert.InDelta(t, 0.0, quarter2.Progress, 0.001,
		"quarter progress should fall back to its own status when only child is dismissed")
}

// ── Cycle / depth guard in RecomputeParentProgress (fix #12) ────────────────

func TestRecomputeParentProgress_CycleGuard(t *testing.T) {
	db := openTestDB(t)

	// Create two targets normally.
	aID, err := db.CreateTarget(makeTarget("A", "todo", "medium"))
	require.NoError(t, err)
	bID, err := db.CreateTarget(makeTarget("B", "todo", "medium"))
	require.NoError(t, err)

	// Manufacture a cycle by directly setting parent_id bypassing FK (FK is ON in tests,
	// but the self-referential structure is: A→B and B→A).
	// We set B.parent_id = A first (valid), then corrupt A.parent_id = B via raw Exec
	// while FK is off so we can test the cycle detection path.
	_, err = db.Exec("PRAGMA foreign_keys = OFF")
	require.NoError(t, err)
	_, err = db.Exec("UPDATE targets SET parent_id = ? WHERE id = ?", bID, aID)
	require.NoError(t, err)
	_, err = db.Exec("UPDATE targets SET parent_id = ? WHERE id = ?", aID, bID)
	require.NoError(t, err)
	_, err = db.Exec("PRAGMA foreign_keys = ON")
	require.NoError(t, err)

	// RecomputeParentProgress must return without panicking or looping infinitely.
	err = db.RecomputeParentProgress(aID)
	// No error required — the function logs and returns nil on cycle detection.
	// The important thing is it terminates.
	_ = err
}

// ── UpdateTarget / progress recompute ───────────────────────────────────────

func TestUpdateTarget_RecomputesParentProgress(t *testing.T) {
	db := openTestDB(t)

	// Create parent and two children attached to it.
	parentID, err := db.CreateTarget(makeTarget("Parent", "todo", "high"))
	require.NoError(t, err)

	child1 := makeTarget("Child done", "done", "medium")
	child1.ParentID = sql.NullInt64{Int64: parentID, Valid: true}
	child1ID, err := db.CreateTarget(child1)
	require.NoError(t, err)

	child2 := makeTarget("Child todo", "todo", "medium")
	child2.ParentID = sql.NullInt64{Int64: parentID, Valid: true}
	_, err = db.CreateTarget(child2)
	require.NoError(t, err)

	// Progress after two children: AVG(1.0, 0.0) = 0.5.
	parent, err := db.GetTargetByID(int(parentID))
	require.NoError(t, err)
	assert.InDelta(t, 0.5, parent.Progress, 0.001, "initial parent progress")

	// Update child1 from done→todo via UpdateTarget.
	got1, err := db.GetTargetByID(int(child1ID))
	require.NoError(t, err)
	got1.Status = "todo"
	require.NoError(t, db.UpdateTarget(*got1))

	// Parent progress must now be AVG(0.0, 0.0) = 0.0.
	parent, err = db.GetTargetByID(int(parentID))
	require.NoError(t, err)
	assert.InDelta(t, 0.0, parent.Progress, 0.001, "parent progress after child reverted to todo")

	// Now create a second parent and move child1 to it.
	parent2ID, err := db.CreateTarget(makeTarget("Parent2", "todo", "medium"))
	require.NoError(t, err)
	got1, err = db.GetTargetByID(int(child1ID))
	require.NoError(t, err)
	got1.ParentID = sql.NullInt64{Int64: parent2ID, Valid: true}
	got1.Status = "done"
	require.NoError(t, db.UpdateTarget(*got1))

	// Old parent (parent1) should now only have child2 (todo=0.0).
	parent, err = db.GetTargetByID(int(parentID))
	require.NoError(t, err)
	assert.InDelta(t, 0.0, parent.Progress, 0.001, "old parent progress after child moved away")

	// New parent (parent2) should have AVG(done=1.0) = 1.0.
	parent2, err := db.GetTargetByID(int(parent2ID))
	require.NoError(t, err)
	assert.InDelta(t, 1.0, parent2.Progress, 0.001, "new parent progress after child moved in as done")
}

// ── GetTargetCounts ──────────────────────────────────────────────────────────

func TestGetTargetCounts(t *testing.T) {
	db := openTestDB(t)

	_, err := db.CreateTarget(makeTarget("Active 1", "todo", "medium"))
	require.NoError(t, err)
	_, err = db.CreateTarget(makeTarget("Active 2", "in_progress", "medium"))
	require.NoError(t, err)
	_, err = db.CreateTarget(makeTarget("Done", "done", "medium"))
	require.NoError(t, err)

	overdueTarget := makeTarget("Overdue", "todo", "high")
	overdueTarget.DueDate = "2020-01-01"
	_, err = db.CreateTarget(overdueTarget)
	require.NoError(t, err)

	active, overdue, err := db.GetTargetCounts()
	require.NoError(t, err)
	assert.Equal(t, 3, active)
	assert.Equal(t, 1, overdue)
}

// ── UnsnoozeExpiredTargets ───────────────────────────────────────────────────

func TestUnsnoozeExpiredTargets(t *testing.T) {
	db := openTestDB(t)

	expired := makeTarget("Expired snooze", "snoozed", "medium")
	expired.SnoozeUntil = "2020-01-01"
	_, err := db.CreateTarget(expired)
	require.NoError(t, err)

	future := makeTarget("Future snooze", "snoozed", "medium")
	future.SnoozeUntil = "2099-12-31"
	_, err = db.CreateTarget(future)
	require.NoError(t, err)

	n, err := db.UnsnoozeExpiredTargets()
	require.NoError(t, err)
	assert.GreaterOrEqual(t, n, 1)

	all, err := db.GetTargets(TargetFilter{IncludeDone: true})
	require.NoError(t, err)
	statusByText := make(map[string]string)
	for _, tgt := range all {
		statusByText[tgt.Text] = tgt.Status
	}
	assert.Equal(t, "todo", statusByText["Expired snooze"])
	assert.Equal(t, "snoozed", statusByText["Future snooze"])
}

// ── GetTargetsForBriefing ────────────────────────────────────────────────────

func TestGetTargetsForBriefing(t *testing.T) {
	db := openTestDB(t)

	_, err := db.CreateTarget(makeTarget("Todo", "todo", "high"))
	require.NoError(t, err)
	_, err = db.CreateTarget(makeTarget("InProgress", "in_progress", "medium"))
	require.NoError(t, err)
	_, err = db.CreateTarget(makeTarget("Blocked", "blocked", "low"))
	require.NoError(t, err)
	_, err = db.CreateTarget(makeTarget("Done", "done", "high"))
	require.NoError(t, err)
	_, err = db.CreateTarget(makeTarget("Snoozed", "snoozed", "high"))
	require.NoError(t, err)

	targets, err := db.GetTargetsForBriefing()
	require.NoError(t, err)
	assert.Len(t, targets, 3)
	// Should be ordered by level (all day) then priority.
	assert.Equal(t, "Todo", targets[0].Text)
	assert.Equal(t, "InProgress", targets[1].Text)
	assert.Equal(t, "Blocked", targets[2].Text)
}

// ── Migration v67: v65→v67 on a fixture DB ───────────────────────────────────

