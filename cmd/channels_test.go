package cmd

import (
	"bytes"
	"encoding/json"
	"testing"

	"github.com/spf13/cobra"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func TestChannelsCommandRegistered(t *testing.T) {
	found := false
	for _, cmd := range rootCmd.Commands() {
		if cmd.Name() == "channels" {
			found = true
			break
		}
	}
	assert.True(t, found, "channels command should be registered")
}

func TestRunChannelsEmpty(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	// The setupWatchTestEnv already creates channels, so we need a fresh DB.
	// Re-use the setup but test with a filter that won't match.
	buf := new(bytes.Buffer)
	channelsCmd.SetOut(buf)
	channelsFlagType = "dm"
	channelsFlagSort = "name"
	defer func() { channelsFlagType = ""; channelsFlagSort = "name" }()

	err := channelsCmd.RunE(channelsCmd, nil)
	require.NoError(t, err)
	assert.Contains(t, buf.String(), "No channels found")
}

func TestRunChannelsList(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	buf := new(bytes.Buffer)
	channelsCmd.SetOut(buf)
	channelsFlagType = ""
	channelsFlagSort = "name"

	err := channelsCmd.RunE(channelsCmd, nil)
	require.NoError(t, err)

	output := buf.String()
	assert.Contains(t, output, "general")
	assert.Contains(t, output, "random")
	assert.Contains(t, output, "2 channels total")
}

func TestRunChannelsFilterByType(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	buf := new(bytes.Buffer)
	channelsCmd.SetOut(buf)
	channelsFlagType = "public"
	channelsFlagSort = "name"
	defer func() { channelsFlagType = "" }()

	err := channelsCmd.RunE(channelsCmd, nil)
	require.NoError(t, err)
	assert.Contains(t, buf.String(), "general")
}

func TestRunChannelsInvalidType(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	channelsFlagType = "invalid"
	defer func() { channelsFlagType = "" }()

	err := channelsCmd.RunE(channelsCmd, nil)
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "invalid type")
}

func TestRunChannelsInvalidSort(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	channelsFlagSort = "invalid"
	defer func() { channelsFlagSort = "name" }()

	err := channelsCmd.RunE(channelsCmd, nil)
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "invalid sort")
}

func TestRunChannelsShowsWatched(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	// Add a watch on general
	database, err := openDBFromConfig()
	require.NoError(t, err)
	require.NoError(t, database.AddWatch("channel", "C001", "general", "high"))
	database.Close()

	buf := new(bytes.Buffer)
	channelsCmd.SetOut(buf)
	channelsFlagType = ""
	channelsFlagSort = "name"

	err = channelsCmd.RunE(channelsCmd, nil)
	require.NoError(t, err)
	assert.Contains(t, buf.String(), "[watched]")
}

func TestRunChannelsShowsMessageCount(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	// Add messages
	database, err := openDBFromConfig()
	require.NoError(t, err)
	require.NoError(t, database.UpsertMessage(db.Message{ChannelID: "C001", TS: "1700000000.000001", Text: "hello"}))
	require.NoError(t, database.UpsertMessage(db.Message{ChannelID: "C001", TS: "1700000001.000001", Text: "world"}))
	database.Close()

	buf := new(bytes.Buffer)
	channelsCmd.SetOut(buf)
	channelsFlagType = ""
	channelsFlagSort = "name"

	err = channelsCmd.RunE(channelsCmd, nil)
	require.NoError(t, err)
	// Should show "2" for message count of general
	assert.Contains(t, buf.String(), "2")
}

func runChannelsExcludeCLI(t *testing.T, sub *cobra.Command, args []string, id string, asJSON bool) (string, error) {
	t.Helper()
	buf := new(bytes.Buffer)
	sub.SetOut(buf)
	channelsExcludeFlagID, channelsExcludeFlagJSON = id, asJSON
	defer func() { channelsExcludeFlagID, channelsExcludeFlagJSON = "", false }()
	err := sub.RunE(sub, args)
	return buf.String(), err
}

func TestChannelsExcludeCLI(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	out, err := runChannelsExcludeCLI(t, channelsExcludeCmd, []string{"#general"}, "", false)
	require.NoError(t, err)
	assert.Contains(t, out, "Stopped syncing #general (muted for AI)")

	database, err := openDBFromConfig()
	require.NoError(t, err)
	cs, err := database.GetChannelSettings("C001")
	require.NoError(t, err)
	database.Close()
	require.NotNil(t, cs)
	assert.True(t, cs.SyncExcluded)
	assert.True(t, cs.IsMutedForLLM)
	assert.NotEmpty(t, cs.ExcludedAt)

	out, err = runChannelsExcludeCLI(t, channelsIncludeCmd, nil, "C001", true)
	require.NoError(t, err)
	var res channelExcludeResult
	require.NoError(t, json.Unmarshal([]byte(out), &res))
	assert.Equal(t, channelExcludeResult{OK: true, ChannelID: "C001", SyncExcluded: false, Muted: false}, res)

	out, err = runChannelsExcludeCLI(t, channelsExcludeCmd, nil, "C001", true)
	require.NoError(t, err)
	res = channelExcludeResult{}
	require.NoError(t, json.Unmarshal([]byte(out), &res))
	assert.Equal(t, channelExcludeResult{OK: true, ChannelID: "C001", SyncExcluded: true, Muted: true}, res)

	_, err = runChannelsExcludeCLI(t, channelsExcludeCmd, []string{"nope"}, "", false)
	assert.ErrorContains(t, err, `no channel named "nope"`)
	_, err = runChannelsExcludeCLI(t, channelsExcludeCmd, nil, "C999", false)
	assert.ErrorContains(t, err, `no channel with id "C999"`)
	_, err = runChannelsExcludeCLI(t, channelsExcludeCmd, []string{"general"}, "C001", false)
	assert.Error(t, err, "a name and --id together")
	_, err = runChannelsExcludeCLI(t, channelsExcludeCmd, nil, "", false)
	assert.Error(t, err)
}

func TestChannelsExcludeCLI_AmbiguousNameNeedsID(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	database, err := openDBFromConfig()
	require.NoError(t, err)
	require.NoError(t, database.UpsertChannel(db.Channel{ID: "2:C001", Name: "general", Type: "public"}))
	database.Close()

	_, err = runChannelsExcludeCLI(t, channelsExcludeCmd, []string{"general"}, "", false)
	assert.ErrorContains(t, err, "pass --id")
}

// TestChannelsExcludeJSON pins the answer the Desktop's Stop syncing /
// Sync again buttons decode.
func TestChannelsExcludeJSON(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	out, err := runChannelsExcludeCLI(t, channelsExcludeCmd, nil, "C001", true)
	require.NoError(t, err)
	assert.JSONEq(t, `{"ok":true,"channel_id":"C001","sync_excluded":true,"muted":true}`, out)

	out, err = runChannelsExcludeCLI(t, channelsIncludeCmd, nil, "C001", true)
	require.NoError(t, err)
	assert.JSONEq(t, `{"ok":true,"channel_id":"C001","sync_excluded":false,"muted":false}`, out)
}
