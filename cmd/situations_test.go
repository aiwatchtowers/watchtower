package cmd

import (
	"bytes"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func TestSituationsCommandRegistered(t *testing.T) {
	found := false
	for _, cmd := range rootCmd.Commands() {
		if cmd.Name() == "situations" {
			found = true
			break
		}
	}
	assert.True(t, found, "situations command should be registered")
}

func TestSituationsSubcommandsRegistered(t *testing.T) {
	subs := map[string]bool{"show": false}
	for _, cmd := range situationsCmd.Commands() {
		if _, ok := subs[cmd.Name()]; ok {
			subs[cmd.Name()] = true
		}
	}
	for name, found := range subs {
		assert.True(t, found, "situations %s subcommand should be registered", name)
	}
}

var situationsTestSeq int

func seedSituation(t *testing.T, title string, rank float64, priority string) int {
	t.Helper()
	database, err := openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()

	situationsTestSeq++
	id, err := database.CreateSituation(db.DashboardSituation{
		Title:      title,
		Rank:       rank,
		Priority:   priority,
		AIReason:   fmt.Sprintf("reason-%d", situationsTestSeq),
		Summary:    "summary text",
		WhyMatters: "why it matters text",
		Chronology: "chronology text",
	})
	require.NoError(t, err)
	return int(id)
}

func seedSituationSignal(t *testing.T, situationID int, snippet string) {
	t.Helper()
	database, err := openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()

	situationsTestSeq++
	item := db.InboxItem{
		ChannelID:    "C001",
		MessageTS:    fmt.Sprintf("1712000%03d.000100", situationsTestSeq),
		SenderUserID: "U002",
		TriggerType:  "mention",
		Snippet:      snippet,
		Status:       "pending",
		Priority:     "high",
		Permalink:    "https://example.slack.com/archives/C001/p123",
	}
	itemID, err := database.CreateInboxItem(item)
	require.NoError(t, err)

	require.NoError(t, database.AddSituationSignals(situationID, []int{int(itemID)}))
}

func TestRunSituations_OrdersByRank(t *testing.T) {
	cleanup := setupInboxTestEnv(t)
	defer cleanup()

	seedSituation(t, "Low rank situation", 0.2, "low")
	seedSituation(t, "High rank situation", 0.9, "high")

	buf := new(bytes.Buffer)
	situationsCmd.SetOut(buf)

	err := situationsCmd.RunE(situationsCmd, nil)
	require.NoError(t, err)

	output := buf.String()
	assert.Contains(t, output, "High rank situation")
	assert.Contains(t, output, "Low rank situation")

	highIdx := indexOf(output, "High rank situation")
	lowIdx := indexOf(output, "Low rank situation")
	assert.True(t, highIdx < lowIdx, "high rank situation should be listed before low rank situation")
}

func indexOf(s, substr string) int {
	for i := 0; i+len(substr) <= len(s); i++ {
		if s[i:i+len(substr)] == substr {
			return i
		}
	}
	return -1
}

func TestRunSituationsShow(t *testing.T) {
	cleanup := setupInboxTestEnv(t)
	defer cleanup()

	id := seedSituation(t, "Release blocked", 0.7, "high")
	seedSituationSignal(t, id, "Deploy is blocked on staging")

	buf := new(bytes.Buffer)
	situationsShowCmd.SetOut(buf)

	err := situationsShowCmd.RunE(situationsShowCmd, []string{fmt.Sprintf("%d", id)})
	require.NoError(t, err)

	output := buf.String()
	assert.Contains(t, output, "Release blocked")
	assert.Contains(t, output, "why it matters text")
	assert.Contains(t, output, "summary text")
	assert.Contains(t, output, "chronology text")
	assert.Contains(t, output, "Deploy is blocked on staging")
	assert.Contains(t, output, "U002")
	assert.Contains(t, output, "https://example.slack.com/archives/C001/p123")
}

func TestRunSituationsShow_UnknownID(t *testing.T) {
	cleanup := setupInboxTestEnv(t)
	defer cleanup()

	err := situationsShowCmd.RunE(situationsShowCmd, []string{"999"})
	assert.Error(t, err)
}

func TestRunSituationsShow_InvalidID(t *testing.T) {
	err := situationsShowCmd.RunE(situationsShowCmd, []string{"abc"})
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "invalid situation ID")
}
