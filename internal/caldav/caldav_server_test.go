package caldav

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"

	"github.com/emersion/go-ical"
	webcaldav "github.com/emersion/go-webdav/caldav"
)

const (
	testCalDAVUser     = "me@example.com"
	testCalDAVPassword = "app-password"
)

// testCalDAVBackend is a minimal in-memory caldav.Backend — the CalDAV
// analog of the imapmemserver used by internal/imap's tests. It serves one
// calendar home with the given calendars/objects; QueryCalendarObjects
// applies the client's time-range filter via the library's own Filter
// helper, like a real server would.
type testCalDAVBackend struct {
	calendars []webcaldav.Calendar
	objects   map[string][]webcaldav.CalendarObject // calendar path -> objects
}

func (b *testCalDAVBackend) CurrentUserPrincipal(_ context.Context) (string, error) {
	return "/user/", nil
}

func (b *testCalDAVBackend) CalendarHomeSetPath(_ context.Context) (string, error) {
	return "/user/calendars/", nil
}

func (b *testCalDAVBackend) CreateCalendar(_ context.Context, _ *webcaldav.Calendar) error {
	return fmt.Errorf("read-only test backend")
}

func (b *testCalDAVBackend) ListCalendars(_ context.Context) ([]webcaldav.Calendar, error) {
	return b.calendars, nil
}

func (b *testCalDAVBackend) GetCalendar(_ context.Context, path string) (*webcaldav.Calendar, error) {
	for _, cal := range b.calendars {
		if cal.Path == path {
			return &cal, nil
		}
	}
	return nil, fmt.Errorf("calendar %s not found", path)
}

func (b *testCalDAVBackend) GetCalendarObject(_ context.Context, path string, _ *webcaldav.CalendarCompRequest) (*webcaldav.CalendarObject, error) {
	for _, objs := range b.objects {
		for _, obj := range objs {
			if obj.Path == path {
				return &obj, nil
			}
		}
	}
	return nil, fmt.Errorf("calendar object %s not found", path)
}

func (b *testCalDAVBackend) ListCalendarObjects(_ context.Context, path string, _ *webcaldav.CalendarCompRequest) ([]webcaldav.CalendarObject, error) {
	return b.objects[path], nil
}

func (b *testCalDAVBackend) QueryCalendarObjects(_ context.Context, path string, query *webcaldav.CalendarQuery) ([]webcaldav.CalendarObject, error) {
	return webcaldav.Filter(query, b.objects[path])
}

func (b *testCalDAVBackend) PutCalendarObject(_ context.Context, _ string, _ *ical.Calendar, _ *webcaldav.PutCalendarObjectOptions) (*webcaldav.CalendarObject, error) {
	return nil, fmt.Errorf("read-only test backend")
}

func (b *testCalDAVBackend) DeleteCalendarObject(_ context.Context, _ string) error {
	return fmt.Errorf("read-only test backend")
}

// startCalDAVServer serves a caldav.Handler over httptest behind HTTP basic
// auth, with one VEVENT (tomorrow, one hour) in /user/calendars/personal.
func startCalDAVServer(t *testing.T, now time.Time) *httptest.Server {
	t.Helper()
	tomorrow := now.Add(24 * time.Hour)
	obj := calendarObject(t, "/user/calendars/personal/planning.ics", fmt.Sprintf(`BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Watchtower Test//EN
BEGIN:VEVENT
UID:planning-uid
DTSTAMP:20260101T000000Z
DTSTART:%s
DTEND:%s
SUMMARY:Planning
END:VEVENT
END:VCALENDAR
`, tomorrow.Format(instanceTimeFormat), tomorrow.Add(time.Hour).Format(instanceTimeFormat)))

	backend := &testCalDAVBackend{
		calendars: []webcaldav.Calendar{{
			Path:                  "/user/calendars/personal",
			Name:                  "Personal",
			SupportedComponentSet: []string{ical.CompEvent},
		}},
		objects: map[string][]webcaldav.CalendarObject{
			"/user/calendars/personal": {obj},
		},
	}
	handler := &webcaldav.Handler{Backend: backend}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user, pass, ok := r.BasicAuth()
		if !ok || user != testCalDAVUser || pass != testCalDAVPassword {
			w.Header().Set("WWW-Authenticate", `Basic realm="test"`)
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		handler.ServeHTTP(w, r)
	}))
	t.Cleanup(srv.Close)
	return srv
}

func calendarObject(t *testing.T, path, ics string) webcaldav.CalendarObject {
	t.Helper()
	cal, err := ical.NewDecoder(strings.NewReader(crlf(ics))).Decode()
	if err != nil {
		t.Fatalf("parsing test object: %v", err)
	}
	return webcaldav.CalendarObject{Path: path, ModTime: time.Now(), Data: cal}
}

func newCalDAVSyncer(t *testing.T, database *db.DB, serverURL, password string) (*Syncer, db.CalendarAccount) {
	t.Helper()
	id, err := database.CreateCalendarAccount(db.CalendarAccount{
		Provider: "caldav", Username: testCalDAVUser, URL: serverURL,
	})
	if err != nil {
		t.Fatalf("create calendar account: %v", err)
	}
	acct, err := database.GetCalendarAccount(id)
	if err != nil {
		t.Fatalf("get calendar account: %v", err)
	}
	cfg := &config.Config{}
	cfg.Calendar.SyncDaysAhead = 7
	return NewSyncer(acct, &Credentials{Password: password}, database, cfg, nil), acct
}

func TestCalDAVSyncStoresEventsEndToEnd(t *testing.T) {
	srv := startCalDAVServer(t, time.Now().UTC())
	database := db.OpenTestDB(t)

	syncer, acct := newCalDAVSyncer(t, database, srv.URL, testCalDAVPassword)
	n, err := syncer.Sync(context.Background())
	if err != nil {
		t.Fatalf("Sync: %v", err)
	}
	if n != 1 {
		t.Fatalf("want 1 event synced, got %d", n)
	}

	calID := fmt.Sprintf("caldav:%d", acct.ID)
	events, err := database.GetCalendarEvents(db.CalendarEventFilter{CalendarID: calID})
	if err != nil {
		t.Fatalf("query events: %v", err)
	}
	if len(events) != 1 {
		t.Fatalf("want 1 stored row, got %v", eventIDs(t, database, calID))
	}
	if events[0].ID != calID+":planning-uid" || events[0].Title != "Planning" {
		t.Errorf("row wrong: %+v", events[0])
	}

	updated, err := database.GetCalendarAccount(acct.ID)
	if err != nil {
		t.Fatalf("get account: %v", err)
	}
	if updated.Status != "ok" {
		t.Errorf("status = %q, want ok", updated.Status)
	}
}

func TestCalDAVSyncWrongPasswordRecordsAuthError(t *testing.T) {
	srv := startCalDAVServer(t, time.Now().UTC())
	database := db.OpenTestDB(t)

	syncer, acct := newCalDAVSyncer(t, database, srv.URL, "wrong")
	if _, err := syncer.Sync(context.Background()); err == nil {
		t.Fatal("want error for wrong password, got nil")
	}
	updated, err := database.GetCalendarAccount(acct.ID)
	if err != nil {
		t.Fatalf("get account: %v", err)
	}
	if updated.Status != "error" || updated.Error == "" {
		t.Errorf("want status=error with a message, got status=%q error=%q", updated.Status, updated.Error)
	}
}
