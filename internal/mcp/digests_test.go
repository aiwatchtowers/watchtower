package mcp

import (
	"context"
	"strings"
	"testing"

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
	if got := textContent(t, res); !strings.Contains(got, "discussed the launch") {
		t.Fatalf("expected seeded digest, got: %s", got)
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
