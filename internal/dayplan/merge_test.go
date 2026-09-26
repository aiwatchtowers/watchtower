package dayplan

import (
	"fmt"
	"testing"
	"time"

	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestBuildItems_ValidResponse(t *testing.T) {
	r := &GenerateResult{
		Timeblocks: []AIItem{
			{SourceType: "focus", Title: "Deep work", Description: "d", Rationale: "r",
				StartTimeLocal: "10:00", EndTimeLocal: "11:30", Priority: "high"},
		},
		Backlog: []AIItem{
			{SourceType: "task", SourceID: "42", Title: "T", Description: "d", Rationale: "r", Priority: "medium"},
		},
	}
	items, dropped := buildItems(r, "2026-04-23", nil, map[string]bool{"42": true}, nil)
	require.Len(t, items, 2)
	assert.Empty(t, dropped)
	// first item is timeblock (order preserved)
	assert.Equal(t, db.DayPlanItemKindTimeblock, items[0].Kind)
	assert.True(t, items[0].StartTime.Valid)
}

func TestBuildItems_DropsUnknownSourceID(t *testing.T) {
	r := &GenerateResult{
		Backlog: []AIItem{
			{SourceType: "task", SourceID: "999", Title: "Bogus", Priority: "low"},
		},
	}
	items, dropped := buildItems(r, "2026-04-23", nil, map[string]bool{"1": true}, nil)
	assert.Len(t, items, 0)
	assert.Len(t, dropped, 1)
	assert.Contains(t, dropped[0], "unknown task source_id")
}

func TestBuildItems_DropsTimeblockOverlappingCalendar(t *testing.T) {
	today := time.Now()
	// Use local time so it overlaps with the local-parsed timeblock 10:00–11:00.
	evStart := time.Date(today.Year(), today.Month(), today.Day(), 10, 15, 0, 0, time.Local)
	evEnd := evStart.Add(30 * time.Minute)
	events := []db.CalendarEvent{
		{
			ID:        "e1",
			StartTime: evStart.Format(time.RFC3339),
			EndTime:   evEnd.Format(time.RFC3339),
			Title:     "Meeting",
		},
	}

	r := &GenerateResult{
		Timeblocks: []AIItem{
			{SourceType: "focus", Title: "Deep", StartTimeLocal: "10:00", EndTimeLocal: "11:00", Priority: "high"},
		},
	}
	date := fmt.Sprintf("%d-%02d-%02d", today.Year(), today.Month(), today.Day())
	items, dropped := buildItems(r, date, events, nil, nil)
	assert.Len(t, items, 0)
	assert.Len(t, dropped, 1)
	assert.Contains(t, dropped[0], "overlaps calendar")
}

// TestBuildItems_KeepsTimeblocksOverlappingAllDayEvent guards against a
// single all-day event (e.g. a holiday or OOO, stored as 00:00–24:00) being
// treated as an ordinary busy slot: since it spans the whole day, every
// AI-generated timeblock would otherwise "overlap" it and get dropped. Uses
// a non-UTC time.Local (like the checklist's repro) to also confirm the
// all-day exclusion holds regardless of the reader's zone.
func TestBuildItems_KeepsTimeblocksOverlappingAllDayEvent(t *testing.T) {
	orig := time.Local
	loc, err := time.LoadLocation("America/Los_Angeles")
	require.NoError(t, err)
	time.Local = loc
	defer func() { time.Local = orig }()

	events := []db.CalendarEvent{
		{
			ID:        "holiday1",
			Title:     "Company Holiday",
			StartTime: "2026-04-23T00:00:00Z",
			EndTime:   "2026-04-24T00:00:00Z",
			IsAllDay:  true,
		},
	}

	r := &GenerateResult{
		Timeblocks: []AIItem{
			{SourceType: "focus", Title: "Deep work", StartTimeLocal: "10:00", EndTimeLocal: "11:00", Priority: "high"},
		},
	}
	items, dropped := buildItems(r, "2026-04-23", events, nil, nil)
	require.Len(t, items, 1, "all-day event must not block AI timeblocks")
	assert.Empty(t, dropped)
}

func TestBuildItems_DropsTimeblockMissingTime(t *testing.T) {
	r := &GenerateResult{
		Timeblocks: []AIItem{
			{SourceType: "focus", Title: "x", Priority: "low"}, // no start/end
		},
	}
	items, dropped := buildItems(r, "2026-04-23", nil, nil, nil)
	assert.Len(t, items, 0)
	assert.Len(t, dropped, 1)
}
