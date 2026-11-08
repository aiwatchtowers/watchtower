package briefing

import (
	"io"
	"log"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// useLocalZone makes time.Local the named zone for the test, so the briefing's
// local-midnight arithmetic is exercised on a DST day whatever the machine TZ.
func useLocalZone(t *testing.T, name string) *time.Location {
	t.Helper()
	loc, err := time.LoadLocation(name)
	require.NoError(t, err)
	prev := time.Local
	time.Local = loc
	t.Cleanup(func() { time.Local = prev })
	return loc
}

// TestGatherDigests_DSTDays: a digest covering the previous local midnight to
// the next local midnight is inside the window on the 25-hour (autumn) and
// 23-hour (spring) days and on their neighbours. The window used to end 24 h
// after the date's midnight, which on 2026-10-25 (Europe/Berlin) cut off a
// digest running to midnight and failed the briefing tests that night.
func TestGatherDigests_DSTDays(t *testing.T) {
	loc := useLocalZone(t, "Europe/Berlin")
	for _, date := range []string{
		"2026-10-24", "2026-10-25", "2026-10-26",
		"2027-03-27", "2027-03-28", "2027-03-29",
	} {
		t.Run(date, func(t *testing.T) {
			database := testDB(t)
			day, err := time.ParseInLocation("2006-01-02", date, loc)
			require.NoError(t, err)
			_, err = database.UpsertDigest(db.Digest{
				ChannelID:    "C1",
				Type:         "channel",
				PeriodFrom:   float64(day.AddDate(0, 0, -1).Unix()),
				PeriodTo:     float64(day.AddDate(0, 0, 1).Unix()),
				Summary:      "Feature release discussion",
				Topics:       `["release"]`,
				Decisions:    `[]`,
				ActionItems:  `[]`,
				MessageCount: 15,
			})
			require.NoError(t, err)

			pipe := New(database, testConfig(), nil, log.New(io.Discard, "", 0))
			assert.NotEmpty(t, pipe.gatherDigests(date), "digest ending at the next local midnight must be in the window")
		})
	}
}
