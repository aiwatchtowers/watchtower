package mcp

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

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
			Undated  bool   `json:"undated"`
		} `json:"evidence"`
	} `json:"candidates"`
	Weights   map[string]float64 `json:"weights"`
	Unmatched []string           `json:"unmatched_emails,omitempty"`
	Notes     []string           `json:"notes,omitempty"`
}

// isUsableRef reports whether ref is something a caller could actually
// follow up on: a real permalink, or the explicit "no permalink available"
// statement evidenceRef falls back to — never the old bare channelID|ts
// composite, which resolveChannel cannot resolve once channelID is
// namespaced (DEV-03 requires a resolvable ref, not merely a non-empty one).
func isUsableRef(ref string) bool {
	return strings.HasPrefix(ref, "https://") || strings.Contains(ref, "no permalink available")
}

// seedExpertsFixture inserts a payments channel, two users (petya: heavy
// contributor, anya: light contributor) and four messages mentioning
// "payments" — three from petya, one from anya — via the real writers so the
// messages_fts triggers fire. Each carries a real permalink so
// TestFindExpertsRanksByEvidenceAndAlwaysCitesIt can assert on a genuinely
// usable ref, not just a non-empty one.
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
		{ChannelID: "1:C1", TS: "1700000001.000001", UserID: "1:U1", Text: "payments retry logic is flaky again", RawJSON: "{}",
			Permalink: "https://slack.example.com/archives/C1/p1700000001000001"},
		{ChannelID: "1:C1", TS: "1700000002.000001", UserID: "1:U1", Text: "fixed the payments webhook signature check", RawJSON: "{}",
			Permalink: "https://slack.example.com/archives/C1/p1700000002000001"},
		{ChannelID: "1:C1", TS: "1700000003.000001", UserID: "1:U1", Text: "payments reconciliation job passed", RawJSON: "{}",
			Permalink: "https://slack.example.com/archives/C1/p1700000003000001"},
		{ChannelID: "1:C1", TS: "1700000004.000001", UserID: "1:U2", Text: "asking about the payments dashboard", RawJSON: "{}",
			Permalink: "https://slack.example.com/archives/C1/p1700000004000001"},
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
	// DEV-03: every candidate carries evidence with a resolvable ref — a real
	// permalink here (the fixture seeds one on every message), not merely a
	// non-empty string. A bare namespaced channelID|ts pair would pass a
	// non-empty check but resolves nowhere (resolveChannel rejects it) — this
	// assertion is what catches that class of regression.
	for _, c := range env.Candidates {
		if len(c.Evidence) == 0 {
			t.Fatalf("candidate %s has no evidence", c.Name)
		}
		for _, e := range c.Evidence {
			if e.Ref == "" {
				t.Fatalf("candidate %s has evidence with no ref: %+v", c.Name, e)
			}
			if !isUsableRef(e.Ref) {
				t.Fatalf("candidate %s has an unusable ref (not a permalink, not an explicit unavailability note): %+v", c.Name, e)
			}
		}
	}
	// DEV-03: the weights that produced the order ship with the answer.
	if len(env.Weights) == 0 {
		t.Fatalf("ranking weights must ship with the response")
	}
}

// TestFindExpertsAppliesDecayToJiraEvidenceAndFlagsUndatedCode pins the fix
// for a bug where find_experts advertised a recency half-life
// unconditionally, but Jira assignee/reporter/comment evidence (and code
// evidence) always passed tsUnix=0 — so a three-year-old assignee scored the
// same as a currently-active one, with no LastSeen to even reveal the gap. A
// genuinely dated Jira fact must now decay and carry LastSeen; a genuinely
// undated one (a supplied email — there is no "when" for code authorship)
// must be marked Undated rather than silently exempted.
func TestFindExpertsAppliesDecayToJiraEvidenceAndFlagsUndatedCode(t *testing.T) {
	database := seedDB(t)
	accountID := db.SeedTestJiraAccount(t, database)
	if err := database.UpsertUser(db.User{ID: "1:U9", Name: "dana", Email: "dana@example.com"}); err != nil {
		t.Fatalf("seeding user dana: %v", err)
	}
	updatedAt := db.FormatJiraTime(time.Now().Add(-2 * time.Hour))
	if err := database.UpsertJiraIssue(db.JiraIssue{
		AccountID:       accountID,
		Key:             "PROJ-9",
		ID:              "90001",
		ProjectKey:      "PROJ",
		Summary:         "Decay check",
		Status:          "In Progress",
		StatusCategory:  "In Progress",
		AssigneeSlackID: "1:U9",
		CreatedAt:       updatedAt,
		UpdatedAt:       updatedAt,
		SyncedAt:        updatedAt,
	}); err != nil {
		t.Fatalf("seeding jira issue: %v", err)
	}
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name: "find_experts",
		Arguments: map[string]any{
			"issue_key": "PROJ-9",
			"emails":    []string{"dana@example.com"},
		},
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
	if len(env.Candidates) != 1 {
		t.Fatalf("expected exactly 1 candidate (dana, matched two ways), got %+v", env.Candidates)
	}

	var sawJira, sawCode bool
	for _, e := range env.Candidates[0].Evidence {
		switch e.Kind {
		case "jira":
			sawJira = true
			if e.LastSeen == "" {
				t.Fatalf("dated jira evidence must carry LastSeen: %+v", e)
			}
			if e.Undated {
				t.Fatalf("dated jira evidence must not be marked Undated: %+v", e)
			}
		case "code":
			sawCode = true
			if !e.Undated {
				t.Fatalf("code evidence (a supplied email has no timestamp) must be marked Undated: %+v", e)
			}
		}
	}
	if !sawJira {
		t.Fatalf("expected jira evidence, got %+v", env.Candidates[0].Evidence)
	}
	if !sawCode {
		t.Fatalf("expected code evidence, got %+v", env.Candidates[0].Evidence)
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

// TestFindExpertsDistinguishesLookupFailureFromUnmatched forces a genuine DB
// failure on the email->user lookup (dropping the table the lookup depends
// on, before the session flips the connection read-only) and asserts it is
// reported as a note, never folded into unmatched_emails — the DEV-03
// contract the watchtower-who-to-ask skill relies on: an address the tool
// simply failed to check must not be reported as "not a Watchtower person".
func TestFindExpertsDistinguishesLookupFailureFromUnmatched(t *testing.T) {
	database := seedDB(t)
	if _, err := database.Exec(`DROP TABLE users`); err != nil {
		t.Fatalf("dropping users table: %v", err)
	}
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "find_experts",
		Arguments: map[string]any{"emails": []string{"ghost@nowhere.invalid"}},
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
	if len(env.Unmatched) != 0 {
		t.Fatalf("a lookup failure must not be reported as unmatched, got %+v", env.Unmatched)
	}
	if len(env.Notes) == 0 {
		t.Fatalf("a lookup failure must surface as a note")
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
