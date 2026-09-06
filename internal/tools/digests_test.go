package tools

import (
	"context"
	"encoding/json"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// callReadString runs a read tool and returns its data marshalled to JSON, so a
// test can assert on the model-facing shape.
func callReadString(t *testing.T, reg *Registry, name, args string) string {
	t.Helper()
	data, err := reg.CallRead(context.Background(), name, json.RawMessage(args))
	require.NoError(t, err)
	b, err := json.Marshal(data)
	require.NoError(t, err)
	return string(b)
}

func digestsRegistry(t *testing.T, d *db.DB) *Registry {
	t.Helper()
	reg := New(d)
	for _, tool := range []*Tool{NewGetTodayBriefing(), NewListDigests(), NewGetDigest()} {
		require.NoError(t, reg.Register(tool))
	}
	return reg
}

// list_digests filters by type: a matching digest is returned, a non-matching
// one excluded (the filter excludes rather than being ignored).
func TestListDigests_FiltersByType(t *testing.T) {
	d := openDB(t)
	_, err := d.UpsertDigest(db.Digest{ChannelID: "C1", Type: "daily", Summary: "people discussed the launch", PeriodFrom: 1, PeriodTo: 2, MessageCount: 5})
	require.NoError(t, err)
	_, err = d.UpsertDigest(db.Digest{ChannelID: "C2", Type: "weekly", Summary: "weekly trends rollup", PeriodFrom: 1, PeriodTo: 2, MessageCount: 9})
	require.NoError(t, err)

	got := callReadString(t, digestsRegistry(t, d), "list_digests", `{"type":"daily"}`)
	assert.Contains(t, got, "discussed the launch")
	assert.NotContains(t, got, "weekly trends rollup", "type filter must exclude the weekly digest")
}

func TestGetDigest_ReturnsBody(t *testing.T) {
	d := openDB(t)
	id, err := d.UpsertDigest(db.Digest{ChannelID: "C1", Type: "daily", Summary: "single digest body", PeriodFrom: 1, PeriodTo: 2, MessageCount: 3})
	require.NoError(t, err)

	got := callReadString(t, digestsRegistry(t, d), "get_digest", `{"id":`+strconv.Itoa(int(id))+`}`)
	assert.Contains(t, got, "single digest body")
}

func TestGetDigest_NotFound(t *testing.T) {
	_, err := digestsRegistry(t, openDB(t)).CallRead(context.Background(), "get_digest", json.RawMessage(`{"id":4242}`))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no digest with id 4242")
}

// get_today_briefing returns TODAY's briefing, never a stale older one.
func TestGetTodayBriefing_ReturnsTodayNotStale(t *testing.T) {
	d := openDB(t)
	require.NoError(t, d.UpsertWorkspace(db.Workspace{ID: "W1", Name: "test"}))
	_, err := d.CreateSlackAccount(db.SlackAccount{CurrentUserID: "U1"})
	require.NoError(t, err)
	today := time.Now().Format("2006-01-02")
	empty := db.Briefing{WorkspaceID: "W1", UserID: "U1", Attention: "[]", YourDay: "[]", WhatHappened: "[]", TeamPulse: "[]", Coaching: "[]"}
	todayB := empty
	todayB.Date = today
	_, err = d.UpsertBriefing(todayB)
	require.NoError(t, err)
	oldB := empty
	oldB.Date = "2020-01-01"
	_, err = d.UpsertBriefing(oldB)
	require.NoError(t, err)

	got := callReadString(t, digestsRegistry(t, d), "get_today_briefing", `{}`)
	assert.Contains(t, got, today)
	assert.NotContains(t, got, "2020-01-01", "must not return a stale older briefing")
}

// A missing briefing is null, not an error.
func TestGetTodayBriefing_EmptyIsNotError(t *testing.T) {
	d := openDB(t)
	require.NoError(t, d.UpsertWorkspace(db.Workspace{ID: "W1", Name: "test"}))
	_, err := d.CreateSlackAccount(db.SlackAccount{CurrentUserID: "U1"})
	require.NoError(t, err)

	data, err := digestsRegistry(t, d).CallRead(context.Background(), "get_today_briefing", json.RawMessage(`{}`))
	require.NoError(t, err, "a missing briefing must not be an error")
	assert.Nil(t, data)
}

func TestListDigests_RejectsInvalidType(t *testing.T) {
	_, err := digestsRegistry(t, openDB(t)).CallRead(context.Background(), "list_digests", json.RawMessage(`{"type":"monthly"}`))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.Contains(t, verr.Msg, "monthly")
	assert.Contains(t, verr.Msg, "channel|daily|weekly")
}

// list_digests since: only digests whose period starts on/after the date remain.
func TestListDigests_Since(t *testing.T) {
	d := openDB(t)
	oldStart := time.Date(2026, 1, 10, 9, 0, 0, 0, time.Local)
	newStart := time.Date(2026, 6, 15, 9, 0, 0, 0, time.Local)
	_, err := d.UpsertDigest(db.Digest{ChannelID: "C1", Type: "daily", Summary: "january digest", PeriodFrom: float64(oldStart.Unix()), PeriodTo: float64(oldStart.Add(time.Hour).Unix())})
	require.NoError(t, err)
	_, err = d.UpsertDigest(db.Digest{ChannelID: "C1", Type: "daily", Summary: "june digest", PeriodFrom: float64(newStart.Unix()), PeriodTo: float64(newStart.Add(time.Hour).Unix())})
	require.NoError(t, err)

	got := callReadString(t, digestsRegistry(t, d), "list_digests", `{"since":"2026-06-01"}`)
	assert.Contains(t, got, "june digest")
	assert.NotContains(t, got, "january digest", "since must exclude the older digest")
}

func TestListDigests_RejectsInvalidSince(t *testing.T) {
	_, err := digestsRegistry(t, openDB(t)).CallRead(context.Background(), "list_digests", json.RawMessage(`{"since":"yesterday"}`))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.Contains(t, verr.Msg, "yesterday")
}
