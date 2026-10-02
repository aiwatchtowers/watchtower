package calendar

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// TestClient_FetchCalendars_PagesToEndWithHidden pins that the calendar list
// is read to its last page and asks for hidden calendars on every page, so a
// caller can treat it as the complete list.
func TestClient_FetchCalendars_PagesToEndWithHidden(t *testing.T) {
	var tokens []string
	apiSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		assert.Equal(t, "true", q.Get("showHidden"), "every page must ask for hidden calendars")
		tokens = append(tokens, q.Get("pageToken"))
		switch q.Get("pageToken") {
		case "":
			_, _ = w.Write([]byte(`{"items":[{"id":"me","primary":true}],"nextPageToken":"p2"}`))
		case "p2":
			_, _ = w.Write([]byte(`{"items":[{"id":"team"}],"nextPageToken":"p3"}`))
		case "p3":
			_, _ = w.Write([]byte(`{"items":[{"id":"holidays","hidden":true}]}`))
		default:
			w.WriteHeader(http.StatusBadRequest)
		}
	}))
	defer apiSrv.Close()
	prev := calendarAPIBase
	calendarAPIBase = apiSrv.URL
	defer func() { calendarAPIBase = prev }()

	c := &Client{hc: apiSrv.Client(), accessToken: "at"}
	cals, err := c.FetchCalendars(context.Background())
	require.NoError(t, err)
	assert.Equal(t, []string{"", "p2", "p3"}, tokens)
	require.Len(t, cals, 3)
	assert.Equal(t, []string{"me", "team", "holidays"}, []string{cals[0].ID, cals[1].ID, cals[2].ID})
	assert.False(t, cals[1].Hidden)
	assert.True(t, cals[2].Hidden)
}

// TestClient_FetchCalendars_LaterPageErrorFails pins that a failure on a
// later page fails the whole list instead of returning a partial one that
// looks complete.
func TestClient_FetchCalendars_LaterPageErrorFails(t *testing.T) {
	apiSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("pageToken") == "" {
			_, _ = w.Write([]byte(`{"items":[{"id":"me","primary":true}],"nextPageToken":"p2"}`))
			return
		}
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer apiSrv.Close()
	prev := calendarAPIBase
	calendarAPIBase = apiSrv.URL
	defer func() { calendarAPIBase = prev }()

	c := &Client{hc: apiSrv.Client(), accessToken: "at"}
	cals, err := c.FetchCalendars(context.Background())
	require.Error(t, err)
	assert.Nil(t, cals)
}

// TestSync_HiddenCalendarStartsUnselectedAndOwnerChoiceWins pins the hidden
// calendar rule: a calendar hidden in Google is listed but starts unselected;
// once the owner selects it, it stays selected; and a selected calendar the
// owner later hides in Google is not deselected by the sync.
func TestSync_HiddenCalendarStartsUnselectedAndOwnerChoiceWins(t *testing.T) {
	hidden := map[string]bool{"holidays": true}
	mux := http.NewServeMux()
	mux.HandleFunc("/users/me/calendarList", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"items":[{"id":"aliceprimary","primary":true},` +
			`{"id":"holidays","hidden":` + strconv.FormatBool(hidden["holidays"]) + `},` +
			`{"id":"team","hidden":` + strconv.FormatBool(hidden["team"]) + `}]}`))
	})
	for _, id := range []string{"aliceprimary", "holidays", "team"} {
		mux.HandleFunc("/calendars/"+id+"/events", func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(eventsFixture("", "")))
		})
	}
	srv := httptest.NewServer(mux)
	defer srv.Close()
	prevAPI := calendarAPIBase
	calendarAPIBase = srv.URL
	defer func() { calendarAPIBase = prevAPI }()

	database := db.OpenTestDB(t)
	acct, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@example.com", Label: "A"})
	require.NoError(t, err)
	syncer := NewSyncer(&Client{hc: srv.Client(), accessToken: "token-a"}, database, &config.Config{}, nil, acct)
	selected := func() []string {
		ids, err := database.GetSelectedCalendarIDs(acct)
		require.NoError(t, err)
		return ids
	}

	_, err = syncer.Sync(context.Background())
	require.NoError(t, err)
	assert.ElementsMatch(t, []string{"aliceprimary", "team"}, selected(), "a hidden calendar starts unselected")

	require.NoError(t, database.SetCalendarSelected("holidays", true))
	hidden["team"] = true // the owner hides a selected calendar in Google
	_, err = syncer.Sync(context.Background())
	require.NoError(t, err)
	assert.ElementsMatch(t, []string{"aliceprimary", "holidays", "team"}, selected(),
		"the owner's Watchtower selection wins over Google's hidden flag")
}
