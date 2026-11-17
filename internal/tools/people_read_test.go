package tools

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func peopleRegistry(t *testing.T, d *db.DB) *Registry {
	t.Helper()
	reg := New(d)
	for _, tool := range []*Tool{NewListPeople(), NewGetPerson(), NewListTracks(), NewGetTrack(), NewListUpcomingEvents()} {
		require.NoError(t, reg.Register(tool))
	}
	return reg
}

func seedPersonCard(t *testing.T, d *db.DB, id, name, realName, summary string) {
	t.Helper()
	require.NoError(t, d.UpsertUser(db.User{ID: id, Name: name, RealName: realName}))
	_, err := d.UpsertPeopleCard(db.PeopleCard{UserID: id, Summary: summary, Status: "active", PeriodFrom: 1, PeriodTo: 2})
	require.NoError(t, err)
}

func TestGetPerson_NotFound(t *testing.T) {
	_, err := peopleRegistry(t, openDB(t)).CallRead(context.Background(), "get_person", json.RawMessage(`{"query":"U_NOBODY"}`), Binding{})
	require.Error(t, err)
}

// An LLM client rarely knows Slack ids — get_person resolves by partial name.
func TestGetPerson_ByName(t *testing.T) {
	d := openDB(t)
	seedPersonCard(t, d, "1:U100", "alice", "Alice Smith", "drives launches")

	got := callReadString(t, peopleRegistry(t, d), "get_person", `{"query":"Alice"}`)
	assert.Contains(t, got, "drives launches")
}

// Several name matches → an ambiguity error listing the candidate ids.
func TestGetPerson_AmbiguousName(t *testing.T) {
	d := openDB(t)
	seedPersonCard(t, d, "1:U101", "alice.a", "Alice Anderson", "card U101")
	seedPersonCard(t, d, "1:U102", "alice.b", "Alice Brown", "card U102")

	_, err := peopleRegistry(t, d).CallRead(context.Background(), "get_person", json.RawMessage(`{"query":"alice"}`), Binding{})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "U101")
	assert.Contains(t, err.Error(), "U102")
}

func TestListTracks_FiltersAndRejectsBadEnum(t *testing.T) {
	d := openDB(t)
	_, err := d.UpsertTrack(db.Track{Text: "Launch readiness", Category: "discussion", Priority: "high", Ownership: "mine"})
	require.NoError(t, err)

	got := callReadString(t, peopleRegistry(t, d), "list_tracks", `{"priority":"high"}`)
	assert.Contains(t, got, "Launch readiness")

	_, err = peopleRegistry(t, d).CallRead(context.Background(), "list_tracks", json.RawMessage(`{"priority":"urgent"}`), Binding{})
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.Contains(t, verr.Msg, "high|medium|low")
}

func TestGetTrack_NotFound(t *testing.T) {
	_, err := peopleRegistry(t, openDB(t)).CallRead(context.Background(), "get_track", json.RawMessage(`{"id":999}`), Binding{})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no track with id 999")
	assert.NotContains(t, err.Error(), "sql: no rows")
}

func TestListPeople_ReturnsCards(t *testing.T) {
	d := openDB(t)
	require.NoError(t, d.UpsertUser(db.User{ID: "1:U1", Name: "alice", RealName: "Alice Smith"}))
	_, err := d.UpsertPeopleCard(db.PeopleCard{UserID: "1:U1", Summary: "works on launch", Status: "active", PeriodFrom: 1, PeriodTo: 2})
	require.NoError(t, err)

	got := callReadString(t, peopleRegistry(t, d), "list_people", `{}`)
	assert.Contains(t, got, "works on launch")
}

func TestListPeople_EmptyIsArray(t *testing.T) {
	got := callReadString(t, peopleRegistry(t, openDB(t)), "list_people", `{}`)
	assert.Equal(t, "[]", got)
}

// list_people threads the limit through: limit=1 returns exactly one row.
func TestListPeople_Limit(t *testing.T) {
	d := openDB(t)
	seedPersonCard(t, d, "1:U1", "alice", "Alice", "one")
	seedPersonCard(t, d, "1:U2", "bob", "Bob", "two")

	var rows []map[string]any
	require.NoError(t, json.Unmarshal([]byte(callReadString(t, peopleRegistry(t, d), "list_people", `{"limit":1}`)), &rows))
	assert.Len(t, rows, 1)
}

// An empty calendar is a JSON array, not an error.
func TestListUpcomingEvents_EmptyIsArray(t *testing.T) {
	got := callReadString(t, peopleRegistry(t, openDB(t)), "list_upcoming_events", `{}`)
	assert.Equal(t, "[]", got)
}

// list_upcoming_events threads the limit through: two events in-window, limit=1
// returns one row.
func TestListUpcomingEvents_Limit(t *testing.T) {
	d := openDB(t)
	require.NoError(t, d.UpsertCalendar(0, db.CalendarCalendar{ID: "cal1", Name: "Primary"}))
	now := time.Now().UTC()
	require.NoError(t, d.UpsertCalendarEvent(db.CalendarEvent{ID: "e1", CalendarID: "cal1", Title: "One", StartTime: now.Add(time.Hour).Format(time.RFC3339), EndTime: now.Add(2 * time.Hour).Format(time.RFC3339)}))
	require.NoError(t, d.UpsertCalendarEvent(db.CalendarEvent{ID: "e2", CalendarID: "cal1", Title: "Two", StartTime: now.Add(3 * time.Hour).Format(time.RFC3339), EndTime: now.Add(4 * time.Hour).Format(time.RFC3339)}))

	var rows []map[string]any
	require.NoError(t, json.Unmarshal([]byte(callReadString(t, peopleRegistry(t, d), "list_upcoming_events", `{"limit":1}`)), &rows))
	assert.Len(t, rows, 1)
}

// The 48h window includes an event 1h out and excludes one 100h out.
func TestListUpcomingEvents_Window(t *testing.T) {
	d := openDB(t)
	require.NoError(t, d.UpsertCalendar(0, db.CalendarCalendar{ID: "cal1", Name: "Primary"}))
	now := time.Now().UTC()
	require.NoError(t, d.UpsertCalendarEvent(db.CalendarEvent{
		ID: "ev-in", CalendarID: "cal1", Title: "Standup soon",
		StartTime: now.Add(time.Hour).Format(time.RFC3339), EndTime: now.Add(2 * time.Hour).Format(time.RFC3339),
	}))
	require.NoError(t, d.UpsertCalendarEvent(db.CalendarEvent{
		ID: "ev-out", CalendarID: "cal1", Title: "Far future offsite",
		StartTime: now.Add(100 * time.Hour).Format(time.RFC3339), EndTime: now.Add(101 * time.Hour).Format(time.RFC3339),
	}))

	got := callReadString(t, peopleRegistry(t, d), "list_upcoming_events", `{"hours":48}`)
	assert.Contains(t, got, "Standup soon")
	assert.NotContains(t, got, "Far future offsite", "48h window must exclude the +100h event")
}

// droppedPeopleKeys are the people-card fields #1769 removed from every
// reader (A12, A24), in today's db.PeopleCard order.
var droppedPeopleKeys = []string{"AvgMessageLength", "ActiveHoursJSON", "VolumeChangePct", "RedFlags"}

// fullPeopleCard is a card with every field set, the dropped ones included
// (a row written before the clearing migration).
func fullPeopleCard() db.PeopleCard {
	return db.PeopleCard{
		UserID: "1:U100", PeriodFrom: 1, PeriodTo: 2, MessageCount: 42, ChannelsActive: 5, ThreadsInitiated: 3,
		ThreadsReplied: 4, AvgMessageLength: 80, ActiveHoursJSON: `{"9":3}`, VolumeChangePct: -40,
		Summary: "Works on auth", CommunicationStyle: "driver", DecisionRole: "decision-maker",
		RedFlags: `["Seems burned out"]`, Highlights: `["Led auth"]`, Accomplishments: `["Shipped SSO"]`,
		CommunicationGuide: "Be direct", DecisionStyle: "Quick", Tactics: `["If blocked, ask in thread"]`,
		RelationshipContext: "peer", Status: "active", Model: "m", InputTokens: 10, OutputTokens: 5, CostUSD: 0.5,
		PromptVersion: 2,
	}
}

// jsonKeys returns the keys of a JSON object in document order and their raw
// values.
func jsonKeys(t *testing.T, raw []byte) ([]string, map[string]json.RawMessage) {
	t.Helper()
	var vals map[string]json.RawMessage
	require.NoError(t, json.Unmarshal(raw, &vals))
	dec := json.NewDecoder(bytes.NewReader(raw))
	tok, err := dec.Token()
	require.NoError(t, err)
	require.Equal(t, json.Delim('{'), tok)
	var keys []string
	for dec.More() {
		k, err := dec.Token()
		require.NoError(t, err)
		keys = append(keys, k.(string))
		var skip json.RawMessage
		require.NoError(t, dec.Decode(&skip))
	}
	return keys, vals
}

// assertTodaysMinusDropped checks got against today's output of card: the
// same keys in the same order minus exactly the dropped ones, every shared
// value byte for byte equal.
func assertTodaysMinusDropped(t *testing.T, card db.PeopleCard, got []byte) {
	t.Helper()
	today, err := json.Marshal(card)
	require.NoError(t, err)
	todayKeys, todayVals := jsonKeys(t, today)
	gotKeys, gotVals := jsonKeys(t, got)
	want := slices.DeleteFunc(slices.Clone(todayKeys), func(k string) bool { return slices.Contains(droppedPeopleKeys, k) })
	require.Len(t, want, len(todayKeys)-len(droppedPeopleKeys), "every dropped key is in today's output")
	assert.Equal(t, want, gotKeys)
	for _, k := range gotKeys {
		assert.Equal(t, string(todayVals[k]), string(gotVals[k]), k)
	}
}

// TestGetPerson_KeysAreTodaysMinusDropped pins personOutput (#1769, A24):
// get_person and list_people return today's card record minus exactly the
// four dropped fields, in today's order, every other value unchanged.
func TestGetPerson_KeysAreTodaysMinusDropped(t *testing.T) {
	d := openDB(t)
	require.NoError(t, d.UpsertUser(db.User{ID: "1:U100", Name: "alice"}))
	_, err := d.UpsertPeopleCard(fullPeopleCard())
	require.NoError(t, err)
	stored, err := d.GetLatestPeopleCard("1:U100")
	require.NoError(t, err)
	require.NotNil(t, stored)
	reg := peopleRegistry(t, d)

	assertTodaysMinusDropped(t, *stored, []byte(callReadString(t, reg, "get_person", `{"query":"1:U100"}`)))

	var list []json.RawMessage
	require.NoError(t, json.Unmarshal([]byte(callReadString(t, reg, "list_people", `{}`)), &list))
	require.Len(t, list, 1)
	assertTodaysMinusDropped(t, *stored, list[0])
}

// An excluded person answers get_person's not-found error naming the stop,
// by id and by name; no new key.
func TestGetPerson_ExcludedSaysTheOwnerStoppedIt(t *testing.T) {
	d := openDB(t)
	seedPersonCard(t, d, "1:U0EXCL01", "carol", "Carol Example", "card")
	require.NoError(t, d.ExcludePerson("1:U0EXCL01"))
	reg := peopleRegistry(t, d)
	for _, q := range []string{`{"query":"1:U0EXCL01"}`, `{"query":"carol"}`} {
		_, err := reg.CallRead(context.Background(), "get_person", json.RawMessage(q), Binding{})
		require.Error(t, err, q)
		assert.Equal(t, "no card for 1:U0EXCL01: the owner stopped it", err.Error(), q)
	}
	_, err := reg.CallRead(context.Background(), "get_person", json.RawMessage(`{"query":"nobody"}`), Binding{})
	require.Error(t, err)
	assert.NotContains(t, err.Error(), "stopped")
}

// TestNoReaderReturnsDroppedPeopleFields (#1769, A12/A24): no tool output
// and no gallery template carries a dropped people field or a judgment
// word, even from a card written before the clearing migration. The CLI's
// own output is pinned in cmd (TestPeopleCLI_NoDroppedPeopleFields).
func TestNoReaderReturnsDroppedPeopleFields(t *testing.T) {
	d := openDB(t)
	require.NoError(t, d.UpsertChannel(db.Channel{ID: "1:C1", Name: "auth", Type: "public"}))
	require.NoError(t, d.UpsertUser(db.User{ID: "1:U100", Name: "alice", Email: "alice@example.com"}))
	require.NoError(t, d.UpsertMessage(db.Message{ChannelID: "1:C1", TS: "1700000001.000001", UserID: "1:U100",
		Text: "auth token refresh is fixed", Permalink: "https://slack.example.com/archives/C1/p1700000001000001"}))
	_, err := d.UpsertPeopleCard(fullPeopleCard())
	require.NoError(t, err)
	reg := peopleRegistry(t, d)
	require.NoError(t, reg.Register(NewFindExperts()))

	outputs := map[string]string{
		"get_person":   callReadString(t, reg, "get_person", `{"query":"1:U100"}`),
		"list_people":  callReadString(t, reg, "list_people", `{}`),
		"find_experts": callReadString(t, reg, "find_experts", `{"topic":"auth"}`),
	}
	require.Contains(t, outputs["find_experts"], "decision-maker", "find_experts still enriches from the card")
	files, err := filepath.Glob("../automations/templates/*")
	require.NoError(t, err)
	require.NotEmpty(t, files)
	for _, f := range files {
		b, err := os.ReadFile(f)
		require.NoError(t, err)
		outputs[filepath.Base(f)] = string(b)
	}
	for name, out := range outputs {
		for _, word := range []string{"RedFlags", "red_flags", "ActiveHours", "active_hours", "VolumeChangePct",
			"Volume change", "volume:", "Red flags", "overloaded", "performance"} {
			assert.NotContains(t, out, word, name)
		}
	}
}

// A name query reports a stopped card only for the person it resolves to:
// "carol" with Carol (no card, not excluded) and the excluded Carolyn is
// Carol's plain not-found, never Carolyn's stop; a partial name matching
// both asks for a user id.
func TestGetPerson_StoppedOnlyForTheResolvedPerson(t *testing.T) {
	d := openDB(t)
	require.NoError(t, d.UpsertUser(db.User{ID: "1:U0CAROL1", Name: "carol", RealName: "Carol Example"}))
	seedPersonCard(t, d, "1:U0CAROL2", "carolyn", "Carolyn Example", "card")
	require.NoError(t, d.ExcludePerson("1:U0CAROL2"))
	reg := peopleRegistry(t, d)

	_, err := reg.CallRead(context.Background(), "get_person", json.RawMessage(`{"query":"carol"}`), Binding{})
	require.Error(t, err)
	assert.Equal(t, `no people card for "carol"`, err.Error())

	_, err = reg.CallRead(context.Background(), "get_person", json.RawMessage(`{"query":"carolyn"}`), Binding{})
	require.Error(t, err)
	assert.Equal(t, "no card for 1:U0CAROL2: the owner stopped it", err.Error())

	_, err = reg.CallRead(context.Background(), "get_person", json.RawMessage(`{"query":"caro"}`), Binding{})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "pass a user id")
	assert.NotContains(t, err.Error(), "stopped")
}
