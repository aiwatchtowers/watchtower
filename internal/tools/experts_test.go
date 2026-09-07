package tools

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

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

func expertsEnv(t *testing.T, d *db.DB, args string) expertsEnvelope {
	t.Helper()
	reg := New(d)
	require.NoError(t, reg.Register(NewFindExperts()))
	var env expertsEnvelope
	require.NoError(t, json.Unmarshal([]byte(callReadString(t, reg, "find_experts", args)), &env))
	return env
}

// isUsableRef reports whether ref is something a caller could actually follow up
// on: a real permalink, or the explicit "no permalink available" fallback —
// never a bare namespaced channelID|ts composite (DEV-03).
func isUsableRef(ref string) bool {
	return strings.HasPrefix(ref, "https://") || strings.Contains(ref, "no permalink available")
}

// seedExpertsFixture inserts a payments channel and two users — petya (3
// messages on "payments") and anya (1) — each message carrying a real permalink.
func seedExpertsFixture(t *testing.T, d *db.DB) {
	t.Helper()
	require.NoError(t, d.UpsertChannel(db.Channel{ID: "1:C1", Name: "payments", Type: "public"}))
	require.NoError(t, d.UpsertUser(db.User{ID: "1:U1", Name: "petya", Email: "petya@example.com"}))
	require.NoError(t, d.UpsertUser(db.User{ID: "1:U2", Name: "anya", Email: "anya@example.com"}))
	msgs := []db.Message{
		{ChannelID: "1:C1", TS: "1700000001.000001", UserID: "1:U1", Text: "payments retry logic is flaky again", RawJSON: "{}", Permalink: "https://slack.example.com/archives/C1/p1700000001000001"},
		{ChannelID: "1:C1", TS: "1700000002.000001", UserID: "1:U1", Text: "fixed the payments webhook signature check", RawJSON: "{}", Permalink: "https://slack.example.com/archives/C1/p1700000002000001"},
		{ChannelID: "1:C1", TS: "1700000003.000001", UserID: "1:U1", Text: "payments reconciliation job passed", RawJSON: "{}", Permalink: "https://slack.example.com/archives/C1/p1700000003000001"},
		{ChannelID: "1:C1", TS: "1700000004.000001", UserID: "1:U2", Text: "asking about the payments dashboard", RawJSON: "{}", Permalink: "https://slack.example.com/archives/C1/p1700000004000001"},
	}
	for _, m := range msgs {
		require.NoError(t, d.UpsertMessage(m))
	}
}

// The heavier contributor ranks first, and every candidate carries evidence
// with a usable ref + the ranking weights (DEV-03).
func TestFindExperts_RanksByEvidenceAndCitesIt(t *testing.T) {
	d := openDB(t)
	seedExpertsFixture(t, d)
	env := expertsEnv(t, d, `{"topic":"payments"}`)

	require.GreaterOrEqual(t, len(env.Candidates), 2)
	assert.Equal(t, "petya", env.Candidates[0].Name, "the heavier contributor ranks first")
	for _, c := range env.Candidates {
		require.NotEmpty(t, c.Evidence, "candidate %s has no evidence", c.Name)
		for _, e := range c.Evidence {
			assert.True(t, isUsableRef(e.Ref), "candidate %s has an unusable ref: %+v", c.Name, e)
		}
	}
	assert.NotEmpty(t, env.Weights, "ranking weights must ship with the response")
}

// Dated Jira evidence decays and carries LastSeen; code evidence (a supplied
// email has no timestamp) is marked Undated.
func TestFindExperts_DecayAndUndatedFlags(t *testing.T) {
	d := openDB(t)
	accountID := db.SeedTestJiraAccount(t, d)
	require.NoError(t, d.UpsertUser(db.User{ID: "1:U9", Name: "dana", Email: "dana@example.com"}))
	updatedAt := db.FormatJiraTime(time.Now().Add(-2 * time.Hour))
	require.NoError(t, d.UpsertJiraIssue(db.JiraIssue{
		AccountID: accountID, Key: "PROJ-9", ID: "90001", ProjectKey: "PROJ", Summary: "Decay check",
		Status: "In Progress", StatusCategory: "In Progress", AssigneeSlackID: "1:U9",
		CreatedAt: updatedAt, UpdatedAt: updatedAt, SyncedAt: updatedAt,
	}))

	env := expertsEnv(t, d, `{"issue_key":"PROJ-9","emails":["dana@example.com"]}`)
	require.Len(t, env.Candidates, 1, "dana, matched two ways")

	var sawJira, sawCode bool
	for _, e := range env.Candidates[0].Evidence {
		switch e.Kind {
		case "jira":
			sawJira = true
			assert.NotEmpty(t, e.LastSeen, "dated jira evidence must carry LastSeen")
			assert.False(t, e.Undated, "dated jira evidence must not be Undated")
		case "code":
			sawCode = true
			assert.True(t, e.Undated, "code evidence must be marked Undated")
		}
	}
	assert.True(t, sawJira, "expected jira evidence")
	assert.True(t, sawCode, "expected code evidence")
}

// A case-folded email matches; an unmatchable one is reported, never dropped.
func TestFindExperts_ReportsUnmatchedEmails(t *testing.T) {
	d := openDB(t)
	seedExpertsFixture(t, d)

	env := expertsEnv(t, d, `{"emails":["PETYA@Example.COM","ghost@nowhere.invalid"]}`)
	require.Len(t, env.Candidates, 1)
	assert.Equal(t, "petya", env.Candidates[0].Name, "case-folded email matches petya")
	require.Len(t, env.Unmatched, 1)
	assert.Equal(t, "ghost@nowhere.invalid", env.Unmatched[0])
}

// A genuine DB failure on the email lookup surfaces as a note, never folded into
// unmatched_emails (DEV-03).
func TestFindExperts_DistinguishesLookupFailureFromUnmatched(t *testing.T) {
	d := openDB(t)
	_, err := d.Exec(`DROP TABLE users`)
	require.NoError(t, err)

	env := expertsEnv(t, d, `{"emails":["ghost@nowhere.invalid"]}`)
	assert.Empty(t, env.Unmatched, "a lookup failure must not be reported as unmatched")
	assert.NotEmpty(t, env.Notes, "a lookup failure must surface as a note")
}

func TestFindExperts_RequiresAnInput(t *testing.T) {
	reg := New(openDB(t))
	require.NoError(t, reg.Register(NewFindExperts()))
	_, err := reg.CallRead(context.Background(), "find_experts", json.RawMessage(`{}`))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
}
