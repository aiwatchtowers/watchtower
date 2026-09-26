package dayplan

import (
	"context"
	"database/sql"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func TestDetectConflicts_FlipsFlag(t *testing.T) {
	d := gatherTestDB(t)
	planID, err := d.CreateDayPlan(&db.DayPlan{
		UserID: "U1", PlanDate: "2026-04-23",
		Status: "active", GeneratedAt: time.Now(), FeedbackHistory: "[]",
	})
	require.NoError(t, err)

	start := time.Date(2026, 4, 23, 10, 0, 0, 0, time.Local)
	end := start.Add(time.Hour)

	// Non-calendar timeblock 10:00–11:00.
	require.NoError(t, d.CreateDayPlanItems(planID, []db.DayPlanItem{
		{
			DayPlanID:  planID,
			Kind:       "timeblock",
			SourceType: "focus",
			Title:      "Focus",
			StartTime:  sql.NullTime{Time: start, Valid: true},
			EndTime:    sql.NullTime{Time: end, Valid: true},
			Status:     "pending",
			Tags:       "[]",
		},
	}))

	// Calendar parent required by FK.
	require.NoError(t, d.UpsertCalendar(0, db.CalendarCalendar{
		ID: "c1", Name: "Primary", IsPrimary: true,
	}))

	// Calendar event overlapping 10:30–11:30.
	require.NoError(t, d.UpsertCalendarEvent(db.CalendarEvent{
		ID:         "ev1",
		CalendarID: "c1",
		Title:      "Meeting",
		StartTime:  start.Add(30 * time.Minute).UTC().Format(time.RFC3339),
		EndTime:    end.Add(30 * time.Minute).UTC().Format(time.RFC3339),
		Attendees:  "[]",
	}))

	p := New(d, pipeTestCfg(), nil, nil)
	require.NoError(t, p.DetectConflicts(context.Background(), "U1", "2026-04-23"))

	plan, err := d.GetDayPlan("U1", "2026-04-23")
	require.NoError(t, err)
	assert.True(t, plan.HasConflicts)
	assert.Contains(t, plan.ConflictSummary.String, "Focus")
	assert.Contains(t, plan.ConflictSummary.String, "Meeting")
}

func TestDetectConflicts_NoOverlap_ClearsFlag(t *testing.T) {
	d := gatherTestDB(t)
	planID, err := d.CreateDayPlan(&db.DayPlan{
		UserID: "U1", PlanDate: "2026-04-23",
		Status: "active", GeneratedAt: time.Now(), FeedbackHistory: "[]",
		HasConflicts:    true,
		ConflictSummary: sql.NullString{String: "stale", Valid: true},
	})
	require.NoError(t, err)
	_ = planID

	p := New(d, pipeTestCfg(), nil, nil)
	require.NoError(t, p.DetectConflicts(context.Background(), "U1", "2026-04-23"))

	plan, err := d.GetDayPlan("U1", "2026-04-23")
	require.NoError(t, err)
	assert.False(t, plan.HasConflicts)
}

// TestDetectConflicts_AllDayEvent_NoFalseConflict guards against an all-day
// event (00:00–24:00) being treated as an ordinary busy slot: since it spans
// the whole day, it would otherwise "overlap" every user timeblock and mark
// the whole plan as conflicting.
func TestDetectConflicts_AllDayEvent_NoFalseConflict(t *testing.T) {
	d := gatherTestDB(t)
	planID, err := d.CreateDayPlan(&db.DayPlan{
		UserID: "U1", PlanDate: "2026-04-23",
		Status: "active", GeneratedAt: time.Now(), FeedbackHistory: "[]",
	})
	require.NoError(t, err)

	start := time.Date(2026, 4, 23, 10, 0, 0, 0, time.Local)
	end := start.Add(time.Hour)

	// Non-calendar timeblock 10:00–11:00.
	require.NoError(t, d.CreateDayPlanItems(planID, []db.DayPlanItem{
		{
			DayPlanID:  planID,
			Kind:       "timeblock",
			SourceType: "focus",
			Title:      "Focus",
			StartTime:  sql.NullTime{Time: start, Valid: true},
			EndTime:    sql.NullTime{Time: end, Valid: true},
			Status:     "pending",
			Tags:       "[]",
		},
	}))

	require.NoError(t, d.UpsertCalendar(0, db.CalendarCalendar{
		ID: "c1", Name: "Primary", IsPrimary: true,
	}))

	// All-day event spanning the whole day — must not count as a conflict.
	require.NoError(t, d.UpsertCalendarEvent(db.CalendarEvent{
		ID:         "holiday1",
		CalendarID: "c1",
		Title:      "Company Holiday",
		StartTime:  "2026-04-23T00:00:00Z",
		EndTime:    "2026-04-24T00:00:00Z",
		IsAllDay:   true,
		Attendees:  "[]",
	}))

	p := New(d, pipeTestCfg(), nil, nil)
	require.NoError(t, p.DetectConflicts(context.Background(), "U1", "2026-04-23"))

	plan, err := d.GetDayPlan("U1", "2026-04-23")
	require.NoError(t, err)
	assert.False(t, plan.HasConflicts, "all-day event must not trigger a false conflict")
}
