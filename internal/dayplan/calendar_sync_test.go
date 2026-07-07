package dayplan

import (
	"database/sql"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func TestSyncCalendarItems_AddsUpdatesRemoves(t *testing.T) {
	d := gatherTestDB(t)
	planID, err := d.CreateDayPlan(&db.DayPlan{
		UserID:          "U1",
		PlanDate:        "2026-04-23",
		Status:          "active",
		GeneratedAt:     time.Now(),
		FeedbackHistory: "[]",
	})
	require.NoError(t, err)

	// Seed: existing calendar items for ev1 (old title) and ev2 (will be orphaned).
	startLocal := time.Date(2026, 4, 23, 10, 0, 0, 0, time.Local)
	endLocal := startLocal.Add(time.Hour)
	require.NoError(t, d.CreateDayPlanItems(planID, []db.DayPlanItem{
		{
			DayPlanID:  planID,
			Kind:       "timeblock",
			SourceType: "calendar",
			SourceID:   sql.NullString{String: "ev1", Valid: true},
			Title:      "Old title",
			StartTime:  sql.NullTime{Time: startLocal, Valid: true},
			EndTime:    sql.NullTime{Time: endLocal, Valid: true},
			Status:     "pending",
			Tags:       "[]",
		},
		{
			DayPlanID:  planID,
			Kind:       "timeblock",
			SourceType: "calendar",
			SourceID:   sql.NullString{String: "ev2", Valid: true},
			Title:      "Going away",
			StartTime:  sql.NullTime{Time: startLocal, Valid: true},
			EndTime:    sql.NullTime{Time: endLocal, Valid: true},
			Status:     "pending",
			Tags:       "[]",
		},
	}))

	// Current calendar: ev1 updated, ev3 new, ev2 deleted.
	events := []db.CalendarEvent{
		{
			ID:        "ev1",
			Title:     "New title",
			StartTime: startLocal.UTC().Format(time.RFC3339),
			EndTime:   endLocal.UTC().Format(time.RFC3339),
		},
		{
			ID:        "ev3",
			Title:     "Fresh",
			StartTime: startLocal.Add(2 * time.Hour).UTC().Format(time.RFC3339),
			EndTime:   startLocal.Add(3 * time.Hour).UTC().Format(time.RFC3339),
		},
	}

	p := New(d, pipeTestCfg(), nil, nil)
	require.NoError(t, p.syncCalendarItems(planID, "2026-04-23", events))

	items, err := d.GetDayPlanItems(planID)
	require.NoError(t, err)

	titles := map[string]bool{}
	for _, it := range items {
		titles[it.Title] = true
	}

	assert.True(t, titles["New title"], "ev1 should be updated to new title")
	assert.True(t, titles["Fresh"], "ev3 should be added")
	assert.False(t, titles["Going away"], "ev2 should be removed (orphan)")
	assert.False(t, titles["Old title"], "old ev1 title should be gone after update")
}

// TestSyncCalendarItems_SkipsAllDayEvent guards against an all-day event
// (holiday, OOO) being inserted as a 1440-minute timeblock — it is
// background context, not a schedulable slot.
func TestSyncCalendarItems_SkipsAllDayEvent(t *testing.T) {
	d := gatherTestDB(t)
	planID, err := d.CreateDayPlan(&db.DayPlan{
		UserID:          "U1",
		PlanDate:        "2026-04-23",
		Status:          "active",
		GeneratedAt:     time.Now(),
		FeedbackHistory: "[]",
	})
	require.NoError(t, err)

	events := []db.CalendarEvent{
		{
			ID:        "holiday1",
			Title:     "Company Holiday",
			StartTime: "2026-04-23T00:00:00Z",
			EndTime:   "2026-04-24T00:00:00Z",
			IsAllDay:  true,
		},
	}

	p := New(d, pipeTestCfg(), nil, nil)
	require.NoError(t, p.syncCalendarItems(planID, "2026-04-23", events))

	items, err := d.GetDayPlanItems(planID)
	require.NoError(t, err)
	for _, it := range items {
		assert.NotEqual(t, "Company Holiday", it.Title, "all-day event must not become a timeblock")
	}
}

// TestSyncCalendarItems_OrphansStaleAllDayItem guards the cleanup path: a
// day_plan_item left over from before the all-day fix (inserted as a
// 1440-minute calendar timeblock) must be removed by the orphan logic once
// all-day events are excluded from the sync's event set.
func TestSyncCalendarItems_OrphansStaleAllDayItem(t *testing.T) {
	d := gatherTestDB(t)
	planID, err := d.CreateDayPlan(&db.DayPlan{
		UserID:          "U1",
		PlanDate:        "2026-04-23",
		Status:          "active",
		GeneratedAt:     time.Now(),
		FeedbackHistory: "[]",
	})
	require.NoError(t, err)

	// Pre-existing calendar item, as if inserted by a pre-fix run.
	require.NoError(t, d.CreateDayPlanItems(planID, []db.DayPlanItem{
		{
			DayPlanID:  planID,
			Kind:       "timeblock",
			SourceType: "calendar",
			SourceID:   sql.NullString{String: "holiday1", Valid: true},
			Title:      "Company Holiday",
			StartTime:  sql.NullTime{Time: time.Date(2026, 4, 23, 0, 0, 0, 0, time.UTC), Valid: true},
			EndTime:    sql.NullTime{Time: time.Date(2026, 4, 24, 0, 0, 0, 0, time.UTC), Valid: true},
			Status:     "pending",
			Tags:       "[]",
		},
	}))

	events := []db.CalendarEvent{
		{
			ID:        "holiday1",
			Title:     "Company Holiday",
			StartTime: "2026-04-23T00:00:00Z",
			EndTime:   "2026-04-24T00:00:00Z",
			IsAllDay:  true,
		},
	}

	p := New(d, pipeTestCfg(), nil, nil)
	require.NoError(t, p.syncCalendarItems(planID, "2026-04-23", events))

	items, err := d.GetDayPlanItems(planID)
	require.NoError(t, err)
	for _, it := range items {
		assert.NotEqual(t, "Company Holiday", it.Title, "stale all-day timeblock must be cleaned up as an orphan")
	}
}
