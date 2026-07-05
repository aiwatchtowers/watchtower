package mcp

import (
	"context"
	"strings"
	"testing"
	"time"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

func TestListDigests(t *testing.T) {
	database := seedDB(t)
	if _, err := database.UpsertDigest(db.Digest{
		ChannelID:    "C1",
		Type:         "daily",
		Summary:      "people discussed the launch",
		PeriodFrom:   1.0,
		PeriodTo:     2.0,
		MessageCount: 5,
	}); err != nil {
		t.Fatalf("seeding digest: %v", err)
	}
	// A non-matching type proves the filter excludes rather than being ignored.
	if _, err := database.UpsertDigest(db.Digest{
		ChannelID:    "C2",
		Type:         "weekly",
		Summary:      "weekly trends rollup",
		PeriodFrom:   1.0,
		PeriodTo:     2.0,
		MessageCount: 9,
	}); err != nil {
		t.Fatalf("seeding non-matching digest: %v", err)
	}
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_digests",
		Arguments: map[string]any{"type": "daily"},
	})
	if err != nil {
		t.Fatalf("call list_digests: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error: %s", textContent(t, res))
	}
	got := textContent(t, res)
	if !strings.Contains(got, "discussed the launch") {
		t.Fatalf("expected matching digest, got: %s", got)
	}
	if strings.Contains(got, "weekly trends rollup") {
		t.Fatalf("type filter did not exclude the weekly digest, got: %s", got)
	}
}

func TestGetDigest(t *testing.T) {
	database := seedDB(t)
	id, err := database.UpsertDigest(db.Digest{
		ChannelID:    "C1",
		Type:         "daily",
		Summary:      "single digest body",
		PeriodFrom:   1.0,
		PeriodTo:     2.0,
		MessageCount: 3,
	})
	if err != nil {
		t.Fatalf("seeding digest: %v", err)
	}
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_digest",
		Arguments: map[string]any{"id": int(id)},
	})
	if err != nil {
		t.Fatalf("call get_digest: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error: %s", textContent(t, res))
	}
	if got := textContent(t, res); !strings.Contains(got, "single digest body") {
		t.Fatalf("expected digest summary, got: %s", got)
	}
}

func TestGetDigestNotFound(t *testing.T) {
	database := seedDB(t)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_digest",
		Arguments: map[string]any{"id": 4242},
	})
	if err != nil {
		t.Fatalf("call get_digest: %v", err)
	}
	if !res.IsError {
		t.Fatalf("expected error for unknown digest id")
	}
	if got := textContent(t, res); !strings.Contains(got, "no digest with id 4242") {
		t.Fatalf("expected friendly not-found message, got: %s", got)
	}
}

// TestGetTodayBriefingHappy guards F5: get_today_briefing returns TODAY's
// briefing (not just the most recent regardless of date).
func TestGetTodayBriefingHappy(t *testing.T) {
	database := seedDB(t)
	if err := database.UpsertWorkspace(db.Workspace{ID: "W1", Name: "test"}); err != nil {
		t.Fatalf("seeding workspace: %v", err)
	}
	if err := database.SetCurrentUserID("U1"); err != nil {
		t.Fatalf("setting current user: %v", err)
	}
	today := time.Now().Format("2006-01-02")
	if _, err := database.UpsertBriefing(db.Briefing{
		WorkspaceID: "W1", UserID: "U1", Date: today,
		Attention: "[]", YourDay: "[]", WhatHappened: "[]", TeamPulse: "[]", Coaching: "[]",
	}); err != nil {
		t.Fatalf("seeding briefing: %v", err)
	}
	// An older briefing must NOT be returned in place of today's.
	if _, err := database.UpsertBriefing(db.Briefing{
		WorkspaceID: "W1", UserID: "U1", Date: "2020-01-01",
		Attention: "[]", YourDay: "[]", WhatHappened: "[]", TeamPulse: "[]", Coaching: "[]",
	}); err != nil {
		t.Fatalf("seeding old briefing: %v", err)
	}
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_today_briefing",
		Arguments: map[string]any{},
	})
	if err != nil {
		t.Fatalf("call get_today_briefing: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error: %s", textContent(t, res))
	}
	got := textContent(t, res)
	if !strings.Contains(got, today) {
		t.Fatalf("expected today's briefing (date %s), got: %s", today, got)
	}
	if strings.Contains(got, "2020-01-01") {
		t.Fatalf("returned a stale older briefing instead of today's: %s", got)
	}
}

func TestGetTodayBriefingEmpty(t *testing.T) {
	// No briefing exists yet → empty/null result, not an error.
	database := seedDB(t)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_today_briefing",
		Arguments: map[string]any{},
	})
	if err != nil {
		t.Fatalf("call get_today_briefing: %v", err)
	}
	if res.IsError {
		t.Fatalf("missing briefing should not be an error: %s", textContent(t, res))
	}
}

func TestListDigestsInvalidType(t *testing.T) {
	database := seedDB(t)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_digests",
		Arguments: map[string]any{"type": "monthly"},
	})
	if err != nil {
		t.Fatalf("call list_digests: %v", err)
	}
	if !res.IsError {
		t.Fatalf("expected validation error for type=monthly, got: %s", textContent(t, res))
	}
	if msg := textContent(t, res); !strings.Contains(msg, "monthly") || !strings.Contains(msg, "channel|daily|weekly") {
		t.Fatalf("error should name the bad value and allowed set, got: %s", msg)
	}
}

// TestListDigestsSince: only digests whose period starts on/after the given
// date are returned; older ones are excluded.
func TestListDigestsSince(t *testing.T) {
	database := seedDB(t)
	oldStart := time.Date(2026, 1, 10, 9, 0, 0, 0, time.Local)
	newStart := time.Date(2026, 6, 15, 9, 0, 0, 0, time.Local)
	if _, err := database.UpsertDigest(db.Digest{
		ChannelID: "C1", Type: "daily", Summary: "january digest",
		PeriodFrom: float64(oldStart.Unix()), PeriodTo: float64(oldStart.Add(time.Hour).Unix()),
	}); err != nil {
		t.Fatalf("seeding old digest: %v", err)
	}
	if _, err := database.UpsertDigest(db.Digest{
		ChannelID: "C1", Type: "daily", Summary: "june digest",
		PeriodFrom: float64(newStart.Unix()), PeriodTo: float64(newStart.Add(time.Hour).Unix()),
	}); err != nil {
		t.Fatalf("seeding new digest: %v", err)
	}
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_digests",
		Arguments: map[string]any{"since": "2026-06-01"},
	})
	if err != nil {
		t.Fatalf("call list_digests: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error: %s", textContent(t, res))
	}
	got := textContent(t, res)
	if !strings.Contains(got, "june digest") {
		t.Fatalf("expected the june digest, got: %s", got)
	}
	if strings.Contains(got, "january digest") {
		t.Fatalf("since=2026-06-01 must exclude the january digest, got: %s", got)
	}
}

func TestListDigestsInvalidSince(t *testing.T) {
	database := seedDB(t)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_digests",
		Arguments: map[string]any{"since": "yesterday"},
	})
	if err != nil {
		t.Fatalf("call list_digests: %v", err)
	}
	if !res.IsError {
		t.Fatalf("expected validation error for since=yesterday, got: %s", textContent(t, res))
	}
	if msg := textContent(t, res); !strings.Contains(msg, "yesterday") {
		t.Fatalf("error should name the bad value, got: %s", msg)
	}
}
