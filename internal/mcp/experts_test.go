package mcp

import (
	"context"
	"encoding/json"
	"testing"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

type expertsEnvelope struct {
	Candidates []struct {
		UserID   string  `json:"user_id"`
		Name     string  `json:"name"`
		Score    float64 `json:"score"`
		Evidence []struct {
			Kind     string `json:"kind"`
			Detail   string `json:"detail"`
			Count    int    `json:"count"`
			LastSeen string `json:"last_seen"`
			Ref      string `json:"ref"`
		} `json:"evidence"`
	} `json:"candidates"`
	Weights   map[string]float64 `json:"weights"`
	Unmatched []string           `json:"unmatched_emails,omitempty"`
}

// seedExpertsFixture inserts a payments channel, two users (petya: heavy
// contributor, anya: light contributor) and four messages mentioning
// "payments" — three from petya, one from anya — via the real writers so the
// messages_fts triggers fire.
func seedExpertsFixture(t *testing.T, database *db.DB) {
	t.Helper()
	if err := database.UpsertChannel(db.Channel{ID: "1:C1", Name: "payments", Type: "public"}); err != nil {
		t.Fatalf("seeding channel: %v", err)
	}
	if err := database.UpsertUser(db.User{ID: "1:U1", Name: "petya", Email: "petya@example.com"}); err != nil {
		t.Fatalf("seeding user petya: %v", err)
	}
	if err := database.UpsertUser(db.User{ID: "1:U2", Name: "anya", Email: "anya@example.com"}); err != nil {
		t.Fatalf("seeding user anya: %v", err)
	}
	msgs := []db.Message{
		{ChannelID: "1:C1", TS: "1700000001.000001", UserID: "1:U1", Text: "payments retry logic is flaky again", RawJSON: "{}"},
		{ChannelID: "1:C1", TS: "1700000002.000001", UserID: "1:U1", Text: "fixed the payments webhook signature check", RawJSON: "{}"},
		{ChannelID: "1:C1", TS: "1700000003.000001", UserID: "1:U1", Text: "payments reconciliation job passed", RawJSON: "{}"},
		{ChannelID: "1:C1", TS: "1700000004.000001", UserID: "1:U2", Text: "asking about the payments dashboard", RawJSON: "{}"},
	}
	for _, m := range msgs {
		if err := database.UpsertMessage(m); err != nil {
			t.Fatalf("seeding message %s: %v", m.TS, err)
		}
	}
}

func TestFindExpertsRanksByEvidenceAndAlwaysCitesIt(t *testing.T) {
	database := seedDB(t)
	seedExpertsFixture(t, database) // petya: 3 messages on "payments"; anya: 1
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "find_experts",
		Arguments: map[string]any{"topic": "payments"},
	})
	if err != nil {
		t.Fatalf("calling find_experts: %v", err)
	}
	if res.IsError {
		t.Fatalf("tool error: %s", textContent(t, res))
	}

	var env expertsEnvelope
	if err := json.Unmarshal([]byte(textContent(t, res)), &env); err != nil {
		t.Fatalf("decoding result: %v", err)
	}
	if len(env.Candidates) < 2 {
		t.Fatalf("expected both candidates, got %d", len(env.Candidates))
	}
	if env.Candidates[0].Name != "petya" {
		t.Fatalf("expected the heavier contributor first, got %s", env.Candidates[0].Name)
	}
	// DEV-03: every candidate carries evidence with a resolvable ref.
	for _, c := range env.Candidates {
		if len(c.Evidence) == 0 {
			t.Fatalf("candidate %s has no evidence", c.Name)
		}
		for _, e := range c.Evidence {
			if e.Ref == "" {
				t.Fatalf("candidate %s has evidence with no ref: %+v", c.Name, e)
			}
		}
	}
	// DEV-03: the weights that produced the order ship with the answer.
	if len(env.Weights) == 0 {
		t.Fatalf("ranking weights must ship with the response")
	}
}

func TestFindExpertsReportsUnmatchedEmails(t *testing.T) {
	database := seedDB(t)
	seedExpertsFixture(t, database)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name: "find_experts",
		Arguments: map[string]any{
			"emails": []string{"PETYA@Example.COM", "ghost@nowhere.invalid"},
		},
	})
	if err != nil {
		t.Fatalf("calling find_experts: %v", err)
	}
	var env expertsEnvelope
	if err := json.Unmarshal([]byte(textContent(t, res)), &env); err != nil {
		t.Fatalf("decoding result: %v", err)
	}
	// Case-folded match: the mixed-case address resolves to the seeded user.
	if len(env.Candidates) != 1 || env.Candidates[0].Name != "petya" {
		t.Fatalf("expected the case-folded email to match petya, got %+v", env.Candidates)
	}
	// The unmatchable address is reported, never silently dropped.
	if len(env.Unmatched) != 1 || env.Unmatched[0] != "ghost@nowhere.invalid" {
		t.Fatalf("expected the unmatched email reported, got %+v", env.Unmatched)
	}
}

func TestFindExpertsRequiresAnInput(t *testing.T) {
	database := seedDB(t)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "find_experts",
		Arguments: map[string]any{},
	})
	if err != nil {
		t.Fatalf("calling find_experts: %v", err)
	}
	if !res.IsError {
		t.Fatalf("a call with no topic/issue_key/emails must be a soft error")
	}
}
