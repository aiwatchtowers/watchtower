package daemon

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/caldav"
	"watchtower/internal/config"
	"watchtower/internal/db"
)

// icsAccount connects one ICS calendar account served from feedURL.
func icsAccount(t *testing.T, database *db.DB, feedURL string) *caldav.Syncer {
	t.Helper()
	id, err := database.CreateCalendarAccount(db.CalendarAccount{Provider: "ics"})
	require.NoError(t, err)
	acct, err := database.GetCalendarAccount(id)
	require.NoError(t, err)
	cfg := &config.Config{}
	cfg.Calendar.SyncDaysAhead = 7
	return caldav.NewSyncer(acct, &caldav.Credentials{FeedURL: feedURL}, database, cfg, nil)
}

// TestPhaseCalDAVSync_FailingAccountDoesNotBlockTheNext pins the fan-out rule
// the per-account sync phases document: the first account's feed errors, the
// second account still syncs its event, and the failure lands on the first
// account's status row.
func TestPhaseCalDAVSync_FailingAccountDoesNotBlockTheNext(t *testing.T) {
	broken := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	t.Cleanup(broken.Close)
	start := time.Now().UTC().Add(24 * time.Hour)
	ics := strings.ReplaceAll(fmt.Sprintf(`BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Watchtower Test//EN
BEGIN:VEVENT
UID:fanout-uid
DTSTAMP:20260101T000000Z
DTSTART:%s
DTEND:%s
SUMMARY:Planning
END:VEVENT
END:VCALENDAR
`, start.Format("20060102T150405Z"), start.Add(time.Hour).Format("20060102T150405Z")), "\n", "\r\n")
	healthy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(ics))
	}))
	t.Cleanup(healthy.Close)

	database := db.OpenTestDB(t)
	first := icsAccount(t, database, broken.URL)
	second := icsAccount(t, database, healthy.URL)

	d := newQuietDaemon(t)
	d.SetCalDAVSyncers([]*caldav.Syncer{first, second})
	d.phaseCalDAVSync(context.Background())

	events, err := database.GetCalendarEvents(db.CalendarEventFilter{CalendarID: second.CalendarID()})
	require.NoError(t, err)
	assert.Len(t, events, 1, "the healthy second account must sync despite the first one failing")

	accts, err := database.ListCalendarAccounts()
	require.NoError(t, err)
	require.Len(t, accts, 2)
	assert.Equal(t, "error", accts[0].Status, "the failing account records its error")
	assert.Equal(t, "ok", accts[1].Status)
}
