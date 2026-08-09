package mcp

import (
	"context"
	"strings"
	"testing"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestListSituationsReturnsOpenOnesRanked(t *testing.T) {
	database := seedDB(t)
	_, err := database.Exec(`INSERT INTO situations (title, status, rank, priority, why_matters, last_signal_at)
		VALUES ('Payments migration stalled', 'open', 9, 'high', 'blocks the release', '2026-08-08T10:00:00Z'),
		       ('Onboarding flow flaky', 'open', 3, 'medium', 'new signups affected', '2026-08-07T10:00:00Z'),
		       ('Old thing', 'done', 1, 'low', '', '2026-08-01T10:00:00Z')`)
	if err != nil {
		t.Fatalf("seed: %v", err)
	}
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_situations",
		Arguments: map[string]any{"status": "open"},
	})
	if err != nil {
		t.Fatalf("calling list_situations: %v", err)
	}
	if res.IsError {
		t.Fatalf("tool error: %s", textContent(t, res))
	}
	out := textContent(t, res)
	if !contains(out, "Payments migration stalled") {
		t.Fatalf("expected the open situation in output, got: %s", out)
	}
	if contains(out, "Old thing") {
		t.Fatalf("done situation must not appear under status=open: %s", out)
	}

	// Pin the ranking: the higher-rank open situation (9) must be rendered
	// before the lower-rank one (3).
	highIdx := strings.Index(out, "Payments migration stalled")
	lowIdx := strings.Index(out, "Onboarding flow flaky")
	if highIdx == -1 || lowIdx == -1 {
		t.Fatalf("expected both open situations in output, got: %s", out)
	}
	if highIdx > lowIdx {
		t.Fatalf("expected higher-rank situation first, got order: %s", out)
	}
}

func TestListSituationsDefaultsToOpenWhenStatusOmitted(t *testing.T) {
	database := seedDB(t)
	_, err := database.Exec(`INSERT INTO situations (title, status, rank, priority, why_matters, last_signal_at)
		VALUES ('Payments migration stalled', 'open', 9, 'high', 'blocks the release', '2026-08-08T10:00:00Z'),
		       ('Old thing', 'done', 1, 'low', '', '2026-08-01T10:00:00Z')`)
	if err != nil {
		t.Fatalf("seed: %v", err)
	}
	cs := newTestSession(t, database)

	// No "status" argument at all — must default to open, not "any status".
	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name: "list_situations",
	})
	if err != nil {
		t.Fatalf("calling list_situations: %v", err)
	}
	if res.IsError {
		t.Fatalf("tool error: %s", textContent(t, res))
	}
	out := textContent(t, res)
	if !contains(out, "Payments migration stalled") {
		t.Fatalf("expected the open situation in output, got: %s", out)
	}
	if contains(out, "Old thing") {
		t.Fatalf("done situation must not appear when status is omitted (default must be open): %s", out)
	}
}

func TestGetSituationIncludesSignalsAndMissingIdIsSoftError(t *testing.T) {
	database := seedDB(t)
	if _, err := database.Exec(`INSERT INTO situations (id, title, status, why_matters, summary)
		VALUES (1, 'Release blocked', 'open', 'ship date at risk', 'the migration is stuck'),
		       (2, 'Unrelated story', 'open', 'not related', 'a different thread entirely')`); err != nil {
		t.Fatalf("seed situation: %v", err)
	}
	if _, err := database.Exec(`INSERT INTO inbox_items (id, trigger_type, channel_id, message_ts, sender_user_id, snippet, status)
		VALUES (10, 'mention', '1:C1', '111.1', '1:U2', 'we cannot ship until this lands', 'pending'),
		       (20, 'mention', '1:C2', '222.2', '1:U3', 'totally unrelated other topic', 'pending')`); err != nil {
		t.Fatalf("seed inbox item: %v", err)
	}
	if _, err := database.Exec(`INSERT INTO situation_signals (situation_id, inbox_item_id) VALUES (1, 10), (2, 20)`); err != nil {
		t.Fatalf("seed signal: %v", err)
	}
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_situation",
		Arguments: map[string]any{"id": 1},
	})
	if err != nil {
		t.Fatalf("calling get_situation: %v", err)
	}
	out := textContent(t, res)
	if !contains(out, "we cannot ship until this lands") {
		t.Fatalf("expected signal text in the situation detail, got: %s", out)
	}
	// Situation 1's detail must include only its own signal, not situation 2's
	// (pins ListSituationSignals' situation_id filter, not just "some signal
	// came back").
	if contains(out, "totally unrelated other topic") {
		t.Fatalf("situation 1's detail leaked situation 2's signal: %s", out)
	}

	missing, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_situation",
		Arguments: map[string]any{"id": 999},
	})
	if err != nil {
		t.Fatalf("calling get_situation: %v", err)
	}
	if !missing.IsError {
		t.Fatalf("a missing id must be a soft tool error, got: %s", textContent(t, missing))
	}
}

// contains is a tiny readability wrapper over strings.Contains.
func contains(haystack, needle string) bool { return strings.Contains(haystack, needle) }
