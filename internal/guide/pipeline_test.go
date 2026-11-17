package guide

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/llmusage"
	"watchtower/internal/slack"
)

type mockGenerator struct {
	response string
	err      error
	calls    atomic.Int32
}

func (m *mockGenerator) Generate(_ context.Context, _, _, _ string) (string, *digest.Usage, string, error) {
	m.calls.Add(1)
	return m.response, &digest.Usage{Tokens: llmusage.Tokens{Input: 100, Output: 50}}, "mock-session", m.err
}

func testDB(t *testing.T) *db.DB {
	t.Helper()
	database, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })
	return database
}

func testConfig() *config.Config {
	return &config.Config{
		Digest: config.DigestConfig{
			Enabled:     true,
			MinMessages: 3,
		},
	}
}

func testLogger() *log.Logger {
	return log.New(os.Stderr, "test: ", 0)
}

func seedUser(t *testing.T, database *db.DB, id, name string) {
	t.Helper()
	err := database.UpsertUser(db.User{ID: id, Name: name, DisplayName: name})
	require.NoError(t, err)
}

func seedChannel(t *testing.T, database *db.DB, id, name string) {
	t.Helper()
	err := database.UpsertChannel(db.Channel{ID: id, Name: name, Type: "public"})
	require.NoError(t, err)
}

func seedMessage(t *testing.T, database *db.DB, channelID, ts, userID, text string) {
	t.Helper()
	err := database.UpsertMessage(db.Message{
		ChannelID: channelID,
		TS:        ts,
		UserID:    userID,
		Text:      text,
	})
	require.NoError(t, err)
}

// testOwnerRaw is the raw Slack id of the owner the people tests' users work
// with. Only the owner's interaction partners get a card (spec 2026-11-17
// §5.3, A13), so seedPartnerMessage stores a user's message together with the
// owner's reply in its thread and registers the owner on the user's account.
// The owner has no users row, so it gets no card of its own.
const testOwnerRaw = "UOWNER"

func seedPartnerMessage(t *testing.T, database *db.DB, channelID, ts, userID, text string) {
	t.Helper()
	seedMessage(t, database, channelID, ts, userID, text)
	acct, _, ok := slack.SplitAccountID(userID)
	require.True(t, ok, "a partner id is namespaced: %s", userID)
	owner := fmt.Sprintf("%d:%s", acct, testOwnerRaw)
	_, err := database.Exec(`INSERT OR IGNORE INTO slack_accounts (id, current_user_id) VALUES (?, ?)`, acct, owner)
	require.NoError(t, err)
	require.NoError(t, database.UpsertMessage(db.Message{
		ChannelID: channelID, TS: ts + "1", UserID: owner, Text: "thanks",
		ThreadTS: sql.NullString{String: ts, Valid: true},
	}))
}

func seedDigestWithSignals(t *testing.T, database *db.DB, channelID string, from, to float64, signals string) {
	t.Helper()
	seedDigestFull(t, database, channelID, from, to, signals, "[]")
}

func seedDigestWithSituations(t *testing.T, database *db.DB, channelID string, from, to float64, signals, situations string) {
	t.Helper()
	seedDigestFull(t, database, channelID, from, to, signals, situations)
}

func seedDigestFull(t *testing.T, database *db.DB, channelID string, from, to float64, signals, situations string) {
	t.Helper()
	_, err := database.UpsertDigest(db.Digest{
		ChannelID:     channelID,
		Type:          "channel",
		PeriodFrom:    from,
		PeriodTo:      to,
		Summary:       "test digest",
		Topics:        "[]",
		Decisions:     "[]",
		ActionItems:   "[]",
		PeopleSignals: signals,
		Situations:    situations,
		MessageCount:  10,
		Model:         "haiku",
	})
	require.NoError(t, err)
}

func TestPipeline_Run(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()
	logger := testLogger()

	err := database.UpsertWorkspace(db.Workspace{ID: "W1", Name: "test"})
	require.NoError(t, err)

	seedUser(t, database, "1:U1", "alice")
	seedChannel(t, database, "C1", "general")

	from := float64(time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC).Unix())
	to := float64(time.Date(2025, 1, 8, 0, 0, 0, 0, time.UTC).Unix())
	base := from + 86400
	for i := range 5 {
		ts := base + float64(i*60)
		tsStr := fmt.Sprintf("%.6f", ts)
		seedPartnerMessage(t, database, "C1", tsStr, "1:U1", "test message "+string(rune('a'+i)))
	}

	// Seed channel digest with situations for U1
	seedDigestWithSituations(t, database, "C1", from, to,
		`[]`,
		`[{"topic":"Auth refactor","type":"collaboration","participants":[{"user_id":"1:U1","role":"lead"}],"dynamic":"Led auth refactor with team","outcome":"Refactor completed","red_flags":[],"observations":["proactive"],"message_refs":[]},{"topic":"Deployment docs","type":"knowledge_transfer","participants":[{"user_id":"1:U1","role":"author"}],"dynamic":"Shared deployment docs","outcome":"Docs published","red_flags":[],"observations":[],"message_refs":[]},{"topic":"API versioning","type":"decision_deadlock","participants":[{"user_id":"1:U1","role":"mediator"}],"dynamic":"Resolved API versioning debate","outcome":"Agreement reached","red_flags":[],"observations":[],"message_refs":[]}]`)

	mockResp := `{
		"summary": "Alice is a proactive contributor",
		"communication_style": "driver",
		"decision_role": "decision-maker",
		"red_flags": [],
		"highlights": ["Led auth refactor"],
		"accomplishments": ["Shipped auth module"],
		"communication_guide": "Be direct, send structured asks",
		"decision_style": "Quick decisions with data backing",
		"tactics": ["If blocked, send data-backed proposal"]
	}`

	gen := &mockGenerator{response: mockResp}
	pipe := New(database, cfg, gen, logger)
	pipe.ForceRegenerate = true
	cfg.AI.Workers = 1

	n, err := pipe.RunForWindow(context.Background(), from, to)
	require.NoError(t, err)
	assert.Equal(t, 1, n)
	assert.GreaterOrEqual(t, int(gen.calls.Load()), 1)

	// Verify stored people card
	card, err := database.GetLatestPeopleCard("1:U1")
	require.NoError(t, err)
	require.NotNil(t, card)
	assert.Equal(t, "Alice is a proactive contributor", card.Summary)
	assert.Equal(t, "driver", card.CommunicationStyle)
	assert.Equal(t, "decision-maker", card.DecisionRole)
	assert.Equal(t, "Be direct, send structured asks", card.CommunicationGuide)
	assert.Equal(t, 5, card.MessageCount)

	var tactics []string
	err = json.Unmarshal([]byte(card.Tactics), &tactics)
	require.NoError(t, err)
	assert.Equal(t, []string{"If blocked, send data-backed proposal"}, tactics)
}

func TestPipeline_SkipsExistingWindow(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()
	logger := testLogger()

	err := database.UpsertWorkspace(db.Workspace{ID: "W1", Name: "test"})
	require.NoError(t, err)

	seedUser(t, database, "1:U1", "bob")
	seedChannel(t, database, "C1", "general")

	from := float64(time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC).Unix())
	to := float64(time.Date(2025, 1, 8, 0, 0, 0, 0, time.UTC).Unix())
	base := from + 86400
	for i := range 5 {
		ts := base + float64(i*60)
		tsStr := fmt.Sprintf("%.6f", ts)
		seedPartnerMessage(t, database, "C1", tsStr, "1:U1", "message "+string(rune('a'+i)))
	}

	// A batch-shaped reply naming U1, so the first run stores a real AI card —
	// only an AI card completes the window (a fallback card does not).
	gen := &mockGenerator{response: `[{"user_id":"1:U1","summary":"test","communication_style":"","decision_role":"","red_flags":[],"highlights":[],"accomplishments":[],"communication_guide":"","decision_style":"","tactics":[]}]`}
	pipe := New(database, cfg, gen, logger)
	pipe.ForceRegenerate = true
	cfg.AI.Workers = 1

	n1, err := pipe.RunForWindow(context.Background(), from, to)
	require.NoError(t, err)
	assert.Equal(t, 1, n1)

	pipe2 := New(database, cfg, gen, logger)
	n2, err := pipe2.RunForWindow(context.Background(), from, to)
	require.NoError(t, err)
	assert.Equal(t, 0, n2)
}

func TestPipeline_NoUsers(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()
	logger := testLogger()

	gen := &mockGenerator{response: "{}"}
	pipe := New(database, cfg, gen, logger)

	n, err := pipe.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 0, n)
	assert.Equal(t, int32(0), gen.calls.Load())
}

func TestParsePeopleCardResult(t *testing.T) {
	raw := `{
		"summary": "Good communicator",
		"communication_style": "collaborator",
		"decision_role": "contributor",
		"red_flags": ["Missed deadline"],
		"highlights": ["Led deployment"],
		"accomplishments": ["Shipped v2"],
		"communication_guide": "Be concise",
		"decision_style": "Data-driven",
		"tactics": ["If blocked, escalate"]
	}`
	result, err := parsePeopleCardResult(raw)
	require.NoError(t, err)
	assert.Equal(t, "Good communicator", result.Summary)
	assert.Equal(t, "collaborator", result.CommunicationStyle)
	assert.Equal(t, []string{"If blocked, escalate"}, result.Tactics)
}

func TestParsePeopleCardResult_WithMarkdownFences(t *testing.T) {
	raw := "```json\n{\"summary\":\"test\",\"communication_style\":\"\",\"decision_role\":\"\",\"red_flags\":[],\"highlights\":[],\"accomplishments\":[],\"communication_guide\":\"\",\"decision_style\":\"\",\"tactics\":[]}\n```"
	result, err := parsePeopleCardResult(raw)
	require.NoError(t, err)
	assert.Equal(t, "test", result.Summary)
}

func TestParseTeamSummaryResult(t *testing.T) {
	raw := `{"summary": "Team is healthy", "attention": ["Check on Bob"], "tips": ["Use threads more"]}`
	result, err := parseTeamSummaryResult(raw)
	require.NoError(t, err)
	assert.Equal(t, "Team is healthy", result.Summary)
	assert.Equal(t, []string{"Check on Bob"}, result.Attention)
	assert.Equal(t, []string{"Use threads more"}, result.Tips)
}

func TestDBPeopleCardOperations(t *testing.T) {
	database := testDB(t)

	card := db.PeopleCard{
		UserID:             "U1",
		PeriodFrom:         1000,
		PeriodTo:           2000,
		MessageCount:       10,
		ChannelsActive:     3,
		Summary:            "Test card",
		CommunicationStyle: "driver",
		DecisionRole:       "decision-maker",
		RedFlags:           `["flag1"]`,
		Highlights:         `["highlight1"]`,
		Accomplishments:    `["shipped v2"]`,
		CommunicationGuide: "Be direct",
		DecisionStyle:      "Quick",
		Tactics:            `["tactic1"]`,
		ActiveHoursJSON:    `{"9":5}`,
		Model:              "test",
	}

	id, err := database.UpsertPeopleCard(card)
	require.NoError(t, err)
	assert.Greater(t, id, int64(0))

	latest, err := database.GetLatestPeopleCard("U1")
	require.NoError(t, err)
	require.NotNil(t, latest)
	assert.Equal(t, "Test card", latest.Summary)
	assert.Equal(t, "driver", latest.CommunicationStyle)
	assert.Equal(t, "Be direct", latest.CommunicationGuide)

	cards, err := database.GetPeopleCardsForWindow(1000, 2000)
	require.NoError(t, err)
	assert.Len(t, cards, 1)

	filtered, err := database.GetPeopleCards(db.PeopleCardFilter{UserID: "U1"})
	require.NoError(t, err)
	assert.Len(t, filtered, 1)

	card.Summary = "Updated card"
	_, err = database.UpsertPeopleCard(card)
	require.NoError(t, err)
	latest2, err := database.GetLatestPeopleCard("U1")
	require.NoError(t, err)
	assert.Equal(t, "Updated card", latest2.Summary)
}

func TestDBPeopleCardSummaryOperations(t *testing.T) {
	database := testDB(t)

	s := db.PeopleCardSummary{
		PeriodFrom: 1000,
		PeriodTo:   2000,
		Summary:    "Team is healthy",
		Attention:  `["Check on Bob"]`,
		Tips:       `["Use threads"]`,
		Model:      "test",
	}
	err := database.UpsertPeopleCardSummary(s)
	require.NoError(t, err)

	got, err := database.GetPeopleCardSummary(1000, 2000)
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "Team is healthy", got.Summary)
	assert.Equal(t, `["Check on Bob"]`, got.Attention)

	missing, err := database.GetPeopleCardSummary(9999, 9999)
	require.NoError(t, err)
	assert.Nil(t, missing)
}

func TestGetPeopleSignals(t *testing.T) {
	database := testDB(t)

	seedChannel(t, database, "C1", "general")
	seedChannel(t, database, "C2", "random")

	// Seed digests with signals
	seedDigestWithSignals(t, database, "C1", 1000, 2000,
		`[{"user_id":"U1","signals":[{"type":"initiative","detail":"Started discussion"}]},{"user_id":"U2","signals":[{"type":"bottleneck","detail":"Blocked PR"}]}]`)
	seedDigestWithSignals(t, database, "C2", 1000, 2000,
		`[{"user_id":"U1","signals":[{"type":"accomplishment","detail":"Shipped feature"}]}]`)

	// Get signals for U1
	signals, err := database.GetPeopleSignalsForUser("U1", 1000, 2000)
	require.NoError(t, err)
	assert.Len(t, signals, 2) // from C1 and C2
	assert.Equal(t, "initiative", signals[0].Signals[0].Type)

	// Get all signals
	allSignals, err := database.GetAllPeopleSignals(1000, 2000)
	require.NoError(t, err)
	assert.Len(t, allSignals, 2) // U1 and U2
	assert.Len(t, allSignals["U1"], 2)
	assert.Len(t, allSignals["U2"], 1)
}

func TestComputeTeamNorms(t *testing.T) {
	stats := []db.UserStats{
		{UserID: "U1", MessageCount: 20, ChannelsActive: 4, AvgMessageLength: 100, ThreadsInitiated: 3},
		{UserID: "U2", MessageCount: 40, ChannelsActive: 6, AvgMessageLength: 80, ThreadsInitiated: 7},
	}
	norms := computeTeamNorms(stats)
	assert.Equal(t, 2, norms.TotalUsers)
	assert.InDelta(t, 30, norms.AvgMessages, 0.01)
	assert.InDelta(t, 5, norms.AvgChannels, 0.01)
	assert.InDelta(t, 90, norms.AvgMsgLength, 0.01)
	assert.InDelta(t, 5, norms.AvgThreadsStart, 0.01)
}

func TestParseBatchCardResult(t *testing.T) {
	raw := `[
		{"user_id": "U1", "summary": "Active contributor", "communication_style": "collaborator", "decision_role": "contributor", "red_flags": [], "highlights": ["Fast responder"], "accomplishments": [], "communication_guide": "Be direct", "decision_style": "Quick", "tactics": ["Ping in thread"]},
		{"user_id": "U2", "summary": "Observer", "communication_style": "observer", "decision_role": "observer", "red_flags": [], "highlights": [], "accomplishments": [], "communication_guide": "Use async", "decision_style": "Limited data", "tactics": []}
	]`
	results, err := parseBatchCardResult(raw)
	require.NoError(t, err)
	assert.Len(t, results, 2)
	assert.Equal(t, "U1", results[0].UserID)
	assert.Equal(t, "Active contributor", results[0].Summary)
	assert.Equal(t, "collaborator", results[0].CommunicationStyle)
	assert.Equal(t, "U2", results[1].UserID)
	assert.Equal(t, "Observer", results[1].Summary)
}

func TestParseBatchCardResult_FiltersEmpty(t *testing.T) {
	raw := `[
		{"user_id": "U1", "summary": "Active contributor", "communication_style": "collaborator", "decision_role": "contributor", "red_flags": [], "highlights": [], "accomplishments": [], "communication_guide": "", "decision_style": "", "tactics": []},
		{"user_id": "", "summary": "", "communication_style": "", "decision_role": "", "red_flags": [], "highlights": [], "accomplishments": [], "communication_guide": "", "decision_style": "", "tactics": []},
		{"user_id": "U3", "summary": "", "communication_style": "", "decision_role": "", "red_flags": [], "highlights": [], "accomplishments": [], "communication_guide": "", "decision_style": "", "tactics": []}
	]`
	results, err := parseBatchCardResult(raw)
	require.NoError(t, err)
	assert.Len(t, results, 1) // Only U1 has both user_id and summary
	assert.Equal(t, "U1", results[0].UserID)
}

func TestParseBatchCardResult_WithMarkdownFences(t *testing.T) {
	raw := "```json\n[{\"user_id\":\"U1\",\"summary\":\"test\",\"communication_style\":\"\",\"decision_role\":\"\",\"red_flags\":[],\"highlights\":[],\"accomplishments\":[],\"communication_guide\":\"\",\"decision_style\":\"\",\"tactics\":[]}]\n```"
	results, err := parseBatchCardResult(raw)
	require.NoError(t, err)
	assert.Len(t, results, 1)
	assert.Equal(t, "U1", results[0].UserID)
}

func TestGroupUsersIntoBatches(t *testing.T) {
	entries := make([]batchUserEntry, 25)
	for i := range entries {
		entries[i] = batchUserEntry{
			stats: db.UserStats{UserID: fmt.Sprintf("U%d", i+1)},
		}
	}

	batches := groupUsersIntoBatches(entries, 10)
	assert.Len(t, batches, 3)
	assert.Len(t, batches[0], 10)
	assert.Len(t, batches[1], 10)
	assert.Len(t, batches[2], 5)

	// Edge: empty input
	assert.Nil(t, groupUsersIntoBatches(nil, 10))

	// Edge: maxUsers <= 0
	batches = groupUsersIntoBatches(entries[:3], 0)
	assert.Len(t, batches, 1)
	assert.Len(t, batches[0], 3)

	// Edge: fewer than max
	batches = groupUsersIntoBatches(entries[:3], 10)
	assert.Len(t, batches, 1)
	assert.Len(t, batches[0], 3)
}

// multiMockGenerator returns different responses based on prompt content heuristics.
type multiMockGenerator struct {
	batchResponse      string
	individualResponse string
	teamResponse       string
	batchErr           error
	calls              atomic.Int32
}

func (m *multiMockGenerator) Generate(_ context.Context, sys, user, _ string) (string, *digest.Usage, string, error) {
	m.calls.Add(1)
	combined := sys + user
	// Detect batch call by looking for USERS and TEAM NORMS markers in prompt.
	if strings.Contains(combined, "=== USERS ===") && strings.Contains(combined, "=== TEAM NORMS ===") {
		return m.batchResponse, &digest.Usage{Tokens: llmusage.Tokens{Input: 200, Output: 100}}, "mock-session", m.batchErr
	}
	// Detect team summary call.
	if strings.Contains(combined, "=== PEOPLE CARDS ===") {
		return m.teamResponse, &digest.Usage{Tokens: llmusage.Tokens{Input: 50, Output: 30}}, "mock-session", nil
	}
	// Default: individual card.
	return m.individualResponse, &digest.Usage{Tokens: llmusage.Tokens{Input: 100, Output: 50}}, "mock-session", nil
}

func TestPipeline_BatchProcessing(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()
	logger := testLogger()

	err := database.UpsertWorkspace(db.Workspace{ID: "W1", Name: "test"})
	require.NoError(t, err)

	seedUser(t, database, "1:U1", "alice") // Will be low-data (batch)
	seedUser(t, database, "1:U2", "bob")   // Will be full-data (individual)
	seedChannel(t, database, "C1", "general")

	from := float64(time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC).Unix())
	to := float64(time.Date(2025, 1, 8, 0, 0, 0, 0, time.UTC).Unix())
	base := from + 86400

	// U1: 4 messages (< MinSituationMessages=10), 1 situation (< MinSituations=3)  → batch
	for i := range 4 {
		ts := base + float64(i*60)
		seedPartnerMessage(t, database, "C1", fmt.Sprintf("%.6f", ts), "1:U1", "msg "+string(rune('a'+i)))
	}
	// U2: 12 messages (>= MinSituationMessages=10) → full-data
	for i := range 12 {
		ts := base + float64((i+10)*60)
		seedPartnerMessage(t, database, "C1", fmt.Sprintf("%.6f", ts), "1:U2", "msg "+string(rune('a'+i)))
	}

	// Seed situations: U1 gets 1 situation, U2 gets 3 situations
	seedDigestWithSituations(t, database, "C1", from, to,
		`[]`,
		`[{"topic":"Topic A","type":"collaboration","participants":[{"user_id":"1:U1","role":"contributor"},{"user_id":"1:U2","role":"lead"}],"dynamic":"worked together","outcome":"done","red_flags":[],"observations":[],"message_refs":[]},{"topic":"Topic B","type":"knowledge_transfer","participants":[{"user_id":"1:U2","role":"author"}],"dynamic":"shared docs","outcome":"published","red_flags":[],"observations":[],"message_refs":[]},{"topic":"Topic C","type":"decision_deadlock","participants":[{"user_id":"1:U2","role":"mediator"}],"dynamic":"resolved debate","outcome":"agreed","red_flags":[],"observations":[],"message_refs":[]}]`)

	gen := &multiMockGenerator{
		batchResponse:      `[{"user_id":"1:U1","summary":"Low activity contributor","communication_style":"observer","decision_role":"contributor","red_flags":[],"highlights":["Responsive"],"accomplishments":[],"communication_guide":"Use async","decision_style":"Limited data","tactics":["Follow up in thread"]},{"user_id":"1:U2","summary":"Active contributor","communication_style":"driver","decision_role":"decision-maker","red_flags":[],"highlights":["Led project"],"accomplishments":["Shipped v2"],"communication_guide":"Be direct","decision_style":"Quick","tactics":["Send summary"]}]`,
		individualResponse: `{"summary":"Active contributor","communication_style":"driver","decision_role":"decision-maker","red_flags":[],"highlights":["Led project"],"accomplishments":["Shipped v2"],"communication_guide":"Be direct","decision_style":"Quick","tactics":["Send summary"]}`,
		teamResponse:       `{"summary":"Team is healthy","attention":[],"tips":["Use threads"]}`,
	}

	pipe := New(database, cfg, gen, logger)
	pipe.ForceRegenerate = true
	cfg.AI.Workers = 1

	n, err := pipe.RunForWindow(context.Background(), from, to)
	require.NoError(t, err)
	assert.Equal(t, 2, n)

	// 3 calls: 1 batch (low-data) + 1 batch (full-data) + 1 team summary
	assert.Equal(t, int32(3), gen.calls.Load())

	// Verify batch card (U1)
	cardU1, err := database.GetLatestPeopleCard("1:U1")
	require.NoError(t, err)
	require.NotNil(t, cardU1)
	assert.Equal(t, "Low activity contributor", cardU1.Summary)
	assert.Equal(t, "observer", cardU1.CommunicationStyle)
	assert.Equal(t, "active", cardU1.Status) // batch cards get active status

	// Verify full-data batch card (U2)
	cardU2, err := database.GetLatestPeopleCard("1:U2")
	require.NoError(t, err)
	require.NotNil(t, cardU2)
	assert.Equal(t, "Active contributor", cardU2.Summary)
	assert.Equal(t, "driver", cardU2.CommunicationStyle)
	assert.Equal(t, "active", cardU2.Status)
}

func TestPipeline_BatchFallback(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()
	logger := testLogger()

	err := database.UpsertWorkspace(db.Workspace{ID: "W1", Name: "test"})
	require.NoError(t, err)

	seedUser(t, database, "1:U1", "alice") // Low-data → batch
	seedUser(t, database, "1:U2", "bob")   // Low-data → batch
	seedChannel(t, database, "C1", "general")

	from := float64(time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC).Unix())
	to := float64(time.Date(2025, 1, 8, 0, 0, 0, 0, time.UTC).Unix())
	base := from + 86400

	// Both users: 4 messages, 0 situations → batch tier
	for i := range 4 {
		ts := base + float64(i*60)
		seedPartnerMessage(t, database, "C1", fmt.Sprintf("%.6f", ts), "1:U1", "msg "+string(rune('a'+i)))
	}
	for i := range 4 {
		ts := base + float64((i+10)*60)
		seedPartnerMessage(t, database, "C1", fmt.Sprintf("%.6f", ts), "1:U2", "msg "+string(rune('a'+i)))
	}

	// Seed a digest with situations for neither user, just to pass the "no situations" skip
	seedDigestWithSituations(t, database, "C1", from, to,
		`[]`,
		`[{"topic":"Topic X","type":"collaboration","participants":[{"user_id":"1:U3","role":"lead"}],"dynamic":"unrelated","outcome":"done","red_flags":[],"observations":[],"message_refs":[]}]`)

	gen := &multiMockGenerator{
		batchErr:     fmt.Errorf("AI overloaded"),
		teamResponse: `{"summary":"N/A","attention":[],"tips":[]}`,
	}

	pipe := New(database, cfg, gen, logger)
	pipe.ForceRegenerate = true
	cfg.AI.Workers = 1

	// Every user fell back: the AI produced nothing, so the run is an error
	// (not a clean run the daemon would stamp for 24h), and the team summary
	// is not generated over fallback cards.
	n, err := pipe.RunForWindow(context.Background(), from, to)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no people card produced by AI")
	assert.Equal(t, 2, n)
	assert.Equal(t, int32(1), gen.calls.Load(), "one failed batch call, no team summary")

	// Both users should get insufficient_data cards (fallback)
	cardU1, err := database.GetLatestPeopleCard("1:U1")
	require.NoError(t, err)
	require.NotNil(t, cardU1)
	assert.Equal(t, "insufficient_data", cardU1.Status)
	assert.Equal(t, "Insufficient data for analysis this period.", cardU1.Summary)

	cardU2, err := database.GetLatestPeopleCard("1:U2")
	require.NoError(t, err)
	require.NotNil(t, cardU2)
	assert.Equal(t, "insufficient_data", cardU2.Status)
}

// TestPeopleCards_NoOwnerNoCards: active users but no Slack account with a
// known owner → no stats, no AI call, no error; the run records the
// owner-unknown outcome and HasData says there is nothing to do (A13: never
// fall back to everyone).
func TestPeopleCards_NoOwnerNoCards(t *testing.T) {
	database := testDB(t)
	from, to := (&Pipeline{}).currentWindow()
	seedUser(t, database, "1:U1", "alice")
	seedChannel(t, database, "C1", "general")
	for i := range DefaultMinMessages + 1 {
		seedMessage(t, database, "C1", fmt.Sprintf("%.6f", from+86400+float64(i*60)), "1:U1", "msg")
	}
	seedOutcomeSituation(t, database, from, to)
	gen := &mockGenerator{response: outcomeBatchReply}
	pipe := New(database, testConfig(), gen, testLogger())
	pipe.ForceRegenerate = true

	has, err := pipe.HasData()
	require.NoError(t, err)
	assert.False(t, has)
	n, err := pipe.RunForWindow(context.Background(), from, to)
	require.NoError(t, err)
	assert.Equal(t, 0, n)
	assert.Equal(t, OutcomeNoOwner, pipe.LastOutcome())
	assert.Equal(t, int32(0), gen.calls.Load())
	cards, err := database.GetPeopleCardsForWindow(from, to)
	require.NoError(t, err)
	assert.Empty(t, cards)
}

// TestPeopleExclude_BlocksFutureCards: a person excluded before any card is
// made gets none on the next run; after include the next run makes one.
func TestPeopleExclude_BlocksFutureCards(t *testing.T) {
	database := testDB(t)
	from, to := (&Pipeline{}).currentWindow()
	seedOutcomeUser(t, database, from)
	seedOutcomeSituation(t, database, from, to)
	cfg := testConfig()
	cfg.AI.Workers = 1
	run := func() int {
		pipe := New(database, cfg, &mockGenerator{response: outcomeBatchReply}, testLogger())
		pipe.ForceRegenerate = true
		n, err := pipe.RunForWindow(context.Background(), from, to)
		require.NoError(t, err)
		return n
	}

	require.NoError(t, database.ExcludePerson("1:U1"))
	assert.Equal(t, 0, run())
	card, err := database.GetLatestPeopleCard("1:U1")
	require.NoError(t, err)
	assert.Nil(t, card)

	require.NoError(t, database.IncludePerson("1:U1"))
	assert.Equal(t, 1, run())
	card, err = database.GetLatestPeopleCard("1:U1")
	require.NoError(t, err)
	require.NotNil(t, card)
}

// excludingGenerator excludes a person while the run is generating, the race
// between `people exclude` and an in-flight run.
type excludingGenerator struct {
	mockGenerator
	database *db.DB
	userID   string
	after    func() // instead of excluding userID, when set
}

func (g *excludingGenerator) Generate(ctx context.Context, a, b, c string) (string, *digest.Usage, string, error) {
	if g.calls.Load() == 0 {
		if g.after != nil {
			g.after()
		} else if err := g.database.ExcludePerson(g.userID); err != nil {
			return "", nil, "", err
		}
	}
	return g.mockGenerator.Generate(ctx, a, b, c)
}

// TestPeopleExclude_DuringRunWritesNoCard: exclude lands between the stats
// and the card write → the run succeeds and stores no card for the person.
func TestPeopleExclude_DuringRunWritesNoCard(t *testing.T) {
	database := testDB(t)
	from, to := (&Pipeline{}).currentWindow()
	seedOutcomeUser(t, database, from)
	seedOutcomeSituation(t, database, from, to)
	cfg := testConfig()
	cfg.AI.Workers = 1
	gen := &excludingGenerator{mockGenerator: mockGenerator{response: outcomeBatchReply}, database: database, userID: "1:U1"}
	pipe := New(database, cfg, gen, testLogger())
	pipe.ForceRegenerate = true

	n, err := pipe.RunForWindow(context.Background(), from, to)
	require.NoError(t, err)
	assert.Equal(t, int32(1), gen.calls.Load())
	assert.Equal(t, 0, n, "a skipped person is not a generated card")
	assert.Equal(t, OutcomeNoData, pipe.LastOutcome(), "nothing made: not a success to stamp")
	card, err := database.GetLatestPeopleCard("1:U1")
	require.NoError(t, err)
	assert.Nil(t, card)
}

// TestPeopleExclude_DuringRunCountsOnlyWrittenCards: of two people, one is
// excluded mid-run → the run reports one card, generated, and no failure.
func TestPeopleExclude_DuringRunCountsOnlyWrittenCards(t *testing.T) {
	database := testDB(t)
	from, to := seedLowDataUsers(t, database)
	cfg := testConfig()
	cfg.AI.Workers = 1
	gen := &excludingGenerator{
		mockGenerator: mockGenerator{response: batchCardJSON("1:U1", "1:U2")},
		database:      database, userID: "1:U2",
	}
	pipe := New(database, cfg, gen, testLogger())
	pipe.ForceRegenerate = true

	n, err := pipe.RunForWindow(context.Background(), from, to)
	require.NoError(t, err)
	assert.Equal(t, 1, n)
	assert.Equal(t, OutcomeGenerated, pipe.LastOutcome())
	assert.Equal(t, "active", cardStatus(t, database, "1:U1"))
	card, err := database.GetLatestPeopleCard("1:U2")
	require.NoError(t, err)
	assert.Nil(t, card)
}

// TestPeopleExclude_DuringRunLowDataPathsAreSkips: in the low-data batch
// phase, a person excluded mid-run is a skip on the whole-batch error path
// and on the AI-omitted path alike: an all-excluded batch ends with no data,
// never a failure, and progress still reaches the total.
func TestPeopleExclude_DuringRunLowDataPathsAreSkips(t *testing.T) {
	for name, gen := range map[string]struct {
		response string
		err      error
	}{
		"batch error": {err: errors.New("model failed")},
		"AI omitted":  {response: `[]`},
	} {
		t.Run(name, func(t *testing.T) {
			database := testDB(t)
			from, to := seedLowDataUsers(t, database)
			cfg := testConfig()
			cfg.AI.Workers = 1
			g := &excludingGenerator{mockGenerator: mockGenerator{response: gen.response, err: gen.err}, database: database}
			g.after = func() {
				require.NoError(t, database.ExcludePerson("1:U1"))
				require.NoError(t, database.ExcludePerson("1:U2"))
			}
			pipe := New(database, cfg, g, testLogger())
			pipe.ForceRegenerate = true
			var lastDone, lastTotal int
			pipe.OnProgress = func(done, total int, _ string) {
				if total > 0 {
					lastDone, lastTotal = done, total
				}
			}

			n, err := pipe.RunForWindow(context.Background(), from, to)
			require.NoError(t, err)
			assert.Equal(t, 0, n)
			assert.Equal(t, OutcomeNoData, pipe.LastOutcome())
			assert.Equal(t, 2, lastTotal)
			assert.Equal(t, lastTotal, lastDone, "progress reaches the total")
			cards, err := database.GetPeopleCardsForWindow(from, to)
			require.NoError(t, err)
			assert.Empty(t, cards)
		})
	}
}

// TestPrunePreUpgradeCards_Helper: the shared entry-point helper prunes a
// non-partner card and reports done.
func TestPrunePreUpgradeCards_Helper(t *testing.T) {
	database := testDB(t)
	_, err := database.Exec(`INSERT INTO slack_accounts (id, current_user_id) VALUES (1, '1:UOWNER')`)
	require.NoError(t, err)
	_, err = database.UpsertPeopleCard(db.PeopleCard{UserID: "1:UREADONLY", PeriodFrom: 1, PeriodTo: 2, Summary: "old"})
	require.NoError(t, err)
	done, err := PrunePreUpgradeCards(context.Background(), database, testLogger())
	require.NoError(t, err)
	assert.True(t, done)
	card, err := database.GetLatestPeopleCard("1:UREADONLY")
	require.NoError(t, err)
	assert.Nil(t, card)
}

// TestPeopleExclude_SkipRecordsNoStep: the progress event of a person
// excluded mid-run carries no step metrics, so an OnProgress consumer that
// records pipeline steps (cmd/people.go) records none for it, not the
// previous card's.
func TestPeopleExclude_SkipRecordsNoStep(t *testing.T) {
	database := testDB(t)
	from, to := seedLowDataUsers(t, database)
	cfg := testConfig()
	cfg.AI.Workers = 1
	gen := &excludingGenerator{
		mockGenerator: mockGenerator{response: batchCardJSON("1:U1", "1:U2")},
		database:      database, userID: "1:U2",
	}
	pipe := New(database, cfg, gen, testLogger())
	pipe.ForceRegenerate = true
	var stepped, skippedEvents int
	pipe.OnProgress = func(_, _ int, status string) {
		switch {
		case strings.Contains(status, "skipped"):
			skippedEvents++
			assert.Zero(t, pipe.LastStepMessageCount, status)
			assert.Zero(t, pipe.LastStepDurationSeconds, status)
			assert.Zero(t, pipe.LastStepInputTokens, status)
			assert.Zero(t, pipe.LastStepOutputTokens, status)
			assert.True(t, pipe.LastStepPeriodFrom.IsZero(), status)
		case strings.Contains(status, "done (batch)"):
			stepped++
			assert.Positive(t, pipe.LastStepMessageCount, status)
		}
	}

	n, err := pipe.RunForWindow(context.Background(), from, to)
	require.NoError(t, err)
	assert.Equal(t, 1, n)
	assert.Equal(t, 1, stepped)
	assert.Equal(t, 1, skippedEvents)
}
