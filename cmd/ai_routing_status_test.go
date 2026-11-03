package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"watchtower/internal/config"

	"github.com/stretchr/testify/require"

	"watchtower/internal/ai"
	"watchtower/internal/providers"
)

func TestRoutingStatusCommandReturnsMetadataOnly(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	command, _, err := aiCmd.Find([]string{"routing-status"})
	require.NoError(t, err)
	require.Equal(t, "routing-status", command.Name())
	output := &bytes.Buffer{}
	command.SetContext(context.Background())
	command.SetOut(output)
	defer command.SetOut(nil)
	require.NoError(t, command.RunE(command, nil))
	var status routingStatusOutput
	require.NoError(t, json.Unmarshal(output.Bytes(), &status))
	require.Equal(t, "claude", status.PreferredProvider)
	require.NotEmpty(t, status.Revision)
	require.NotNil(t, status.Providers)
	require.NotContains(t, output.String(), "lease")
	require.NotContains(t, output.String(), "identity")
	require.NotContains(t, output.String(), "health.json")
}

func TestQueryV1RetainsActualAndStartedQuotaMetadata(t *testing.T) {
	for _, provider := range []string{"claude", "codex"} {
		chunks := make(chan ai.StreamChunk, 1)
		chunks <- ai.StreamChunk{Routing: &ai.RoutingMetadata{Provider: provider, Model: "actual-model", PreferredProvider: "preferred", Mode: "preferred_reserve"}}
		close(chunks)
		failures := make(chan error, 1)
		failures <- &providers.Failure{Provider: provider, Category: providers.Quota}
		close(failures)
		sessions := make(chan string)
		close(sessions)
		var output bytes.Buffer
		streamQueryV1(json.NewEncoder(&output), chunks, failures, sessions)
		decoder := json.NewDecoder(&output)
		var route, failure aiStreamEvent
		require.NoError(t, decoder.Decode(&route))
		require.Equal(t, "routing", route.Type)
		require.Equal(t, provider, route.Provider)
		require.Equal(t, "actual-model", route.Model)
		require.NoError(t, decoder.Decode(&failure))
		require.Equal(t, "error", failure.Type)
		require.Equal(t, "quota_exhausted", failure.Reason)
		require.False(t, failure.Retryable)
	}
}

func TestRoutingStatusExplicitWorkspaceReadsThatDaemonOnly(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	oldWorkspace, oldRead := flagWorkspace, routingStatusApplication
	defer func() { flagWorkspace, routingStatusApplication = oldWorkspace, oldRead }()
	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	for _, workspace := range []string{"first", "second"} {
		local := *cfg
		local.ActiveWorkspace = workspace
		require.NoError(t, os.MkdirAll(filepath.Dir(pidFilePath(&local)), 0700))
		require.NoError(t, os.WriteFile(pidFilePath(&local), []byte("fake-"+workspace), 0600))
		require.NoError(t, writeRoutingAck(routingAckPath(&local), routingApplication{Identity: "fake-" + workspace, Revision: workspace}))
	}
	routingStatusApplication = func(cfg *config.Config) (*routingApplication, error) {
		return readRoutingAck(routingAckPath(cfg), func() (string, error) { data, err := os.ReadFile(pidFilePath(cfg)); return string(data), err })
	}
	before, err := os.ReadFile(flagConfig)
	require.NoError(t, err)
	command, _, err := aiCmd.Find([]string{"routing-status"})
	require.NoError(t, err)
	output := &bytes.Buffer{}
	command.SetContext(context.Background())
	command.SetOut(output)
	defer command.SetOut(nil)
	for _, workspace := range []string{"second", "first"} {
		flagWorkspace = workspace
		output.Reset()
		require.NoError(t, command.RunE(command, nil))
		var status routingStatusOutput
		require.NoError(t, json.Unmarshal(output.Bytes(), &status))
		require.NotNil(t, status.Application)
		require.Equal(t, workspace, status.Application.Revision)
		require.Equal(t, "fake-"+workspace, status.Application.Identity)
	}
	after, err := os.ReadFile(flagConfig)
	require.NoError(t, err)
	require.Equal(t, before, after, "workspace-scoped status never rewrites global configuration")
}
