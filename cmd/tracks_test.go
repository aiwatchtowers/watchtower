package cmd

import (
	"bytes"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func TestTracksCommandRegistered(t *testing.T) {
	found := false
	for _, cmd := range rootCmd.Commands() {
		if cmd.Name() == "tracks" {
			found = true
			break
		}
	}
	assert.True(t, found, "tracks command should be registered")
}

func TestTracksSubcommandsRegistered(t *testing.T) {
	subs := map[string]bool{"show": false, "read": false, "generate": false}
	for _, cmd := range tracksCmd.Commands() {
		if _, ok := subs[cmd.Name()]; ok {
			subs[cmd.Name()] = true
		}
	}
	for name, found := range subs {
		assert.True(t, found, "tracks %s subcommand should be registered", name)
	}
}

func TestRunTracks_WithTracks(t *testing.T) {
	cleanup := setupTracksTestEnv(t)
	defer cleanup()

	database, err := openDBFromConfig()
	require.NoError(t, err)

	_, err = database.UpsertTrack(db.Track{
		Text:       "Review the PR for auth changes",
		Priority:   "high",
		ChannelIDs: `["C001"]`,
		Tags:       `["api"]`,
	})
	require.NoError(t, err)

	_, err = database.UpsertTrack(db.Track{
		Text:       "Deploy the new version",
		Priority:   "medium",
		ChannelIDs: `["C001"]`,
	})
	require.NoError(t, err)
	database.Close()

	buf := new(bytes.Buffer)
	tracksCmd.SetOut(buf)
	tracksFlagPriority = ""
	tracksFlagOwnership = ""
	tracksFlagChannel = ""
	tracksFlagUpdates = false

	err = tracksCmd.RunE(tracksCmd, nil)
	require.NoError(t, err)

	output := buf.String()
	assert.Contains(t, output, "Review the PR")
	assert.Contains(t, output, "Deploy the new version")
}

func TestRunTracks_ChannelFilter(t *testing.T) {
	cleanup := setupTracksTestEnv(t)
	defer cleanup()

	tracksFlagPriority = ""
	tracksFlagOwnership = ""
	tracksFlagChannel = "nonexistent"
	tracksFlagUpdates = false
	defer func() { tracksFlagChannel = "" }()

	err := tracksCmd.RunE(tracksCmd, nil)
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "not found")
}

func TestRunTracks_RequiresConfig(t *testing.T) {
	oldFlagConfig := flagConfig
	flagConfig = "/nonexistent/config.yaml"
	defer func() { flagConfig = oldFlagConfig }()

	tracksFlagPriority = ""
	tracksFlagOwnership = ""
	tracksFlagChannel = ""
	tracksFlagUpdates = false

	err := tracksCmd.RunE(tracksCmd, nil)
	assert.Error(t, err)
}

func TestTracksFlags(t *testing.T) {
	assert.NotNil(t, tracksCmd.Flags().Lookup("priority"))
	assert.NotNil(t, tracksCmd.Flags().Lookup("ownership"))
	assert.NotNil(t, tracksCmd.Flags().Lookup("channel"))
	assert.NotNil(t, tracksCmd.Flags().Lookup("updates"))
}

func TestPrintTracks(t *testing.T) {
	tmpDir := t.TempDir()
	database, err := db.Open(tmpDir + "/test.db")
	require.NoError(t, err)
	defer database.Close()

	require.NoError(t, database.UpsertChannel(db.Channel{ID: "C001", Name: "general", Type: "public"}))

	tracks := []db.Track{
		{
			ID:         1,
			Text:       "Review PR #42",
			Context:    "Needs reviewer",
			Priority:   "high",
			Ownership:  "mine",
			Category:   "code_review",
			ChannelIDs: `["C001"]`,
			Tags:       `["api","frontend"]`,
			HasUpdates: true,
		},
		{
			ID:        2,
			Text:      "Deploy new version",
			Priority:  "medium",
			Ownership: "mine",
			Category:  "task",
		},
	}

	buf := new(bytes.Buffer)
	printTracks(buf, tracks, database, false)

	output := buf.String()
	assert.Contains(t, output, "Review PR #42")
	assert.Contains(t, output, "Deploy new version")
}

func TestTracksCustomSubcommandsRegistered(t *testing.T) {
	subs := map[string]bool{"create": false, "watch": false, "scan": false, "events": false, "enable": false, "disable": false}
	for _, cmd := range tracksCmd.Commands() {
		if _, ok := subs[cmd.Name()]; ok {
			subs[cmd.Name()] = true
		}
	}
	for name, found := range subs {
		assert.True(t, found, "tracks %s subcommand should be registered", name)
	}
}

func TestRunTracksEvents(t *testing.T) {
	cleanup := setupTracksTestEnv(t)
	defer cleanup()

	database, err := openDBFromConfig()
	require.NoError(t, err)
	tid, err := database.CreateCustomTrack(db.Track{
		AssigneeUserID: "U001", Text: "Watch the release cut",
		Instruction: "watch release", Context: "release cut",
	})
	require.NoError(t, err)
	_, err = database.InsertTrackEvent(db.TrackEvent{
		TrackID: int(tid), Summary: "release branch cut", SourceType: "digest",
	})
	require.NoError(t, err)
	database.Close()

	buf := new(bytes.Buffer)
	tracksEventsCmd.SetOut(buf)
	err = tracksEventsCmd.RunE(tracksEventsCmd, []string{strconv.Itoa(int(tid))})
	require.NoError(t, err)
	assert.Contains(t, buf.String(), "release branch cut")
}

func TestRunTracksEnableDisable(t *testing.T) {
	cleanup := setupTracksTestEnv(t)
	defer cleanup()

	database, err := openDBFromConfig()
	require.NoError(t, err)
	tid, err := database.CreateCustomTrack(db.Track{
		AssigneeUserID: "U001", Text: "Watch refund", Instruction: "watch refund",
	})
	require.NoError(t, err)
	database.Close()

	buf := new(bytes.Buffer)
	tracksDisableCmd.SetOut(buf)
	err = tracksDisableCmd.RunE(tracksDisableCmd, []string{strconv.Itoa(int(tid))})
	require.NoError(t, err)
	assert.Contains(t, buf.String(), "enabled=false")

	database, err = openDBFromConfig()
	require.NoError(t, err)
	enabled, err := database.GetEnabledCustomTracks()
	require.NoError(t, err)
	assert.Empty(t, enabled)
	database.Close()

	buf.Reset()
	tracksEnableCmd.SetOut(buf)
	err = tracksEnableCmd.RunE(tracksEnableCmd, []string{strconv.Itoa(int(tid))})
	require.NoError(t, err)
	assert.Contains(t, buf.String(), "enabled=true")
}

func TestRunTracksEventsInvalidID(t *testing.T) {
	cleanup := setupTracksTestEnv(t)
	defer cleanup()
	err := tracksEventsCmd.RunE(tracksEventsCmd, []string{"not-a-number"})
	assert.Error(t, err)
	assert.True(t, strings.Contains(err.Error(), "invalid"))
}

func setupTracksTestEnv(t *testing.T) func() {
	t.Helper()
	cleanup := setupWatchTestEnv(t)
	database, err := openDBFromConfig()
	require.NoError(t, err)
	require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "T001", Name: "test-ws", Domain: "test-ws"}))
	_, acctErr := database.CreateSlackAccount(db.SlackAccount{CurrentUserID: "U001"})
	require.NoError(t, acctErr)
	database.Close()
	return cleanup
}
