package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
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

// Shared with ChatRoutingPresentationTests: these DTOs come from the real
// command with a missing installation health store, not a successful recovery.
func TestRoutingStatusFreshCommandMatchesDesktopContract(t *testing.T) {
	fixture, err := os.ReadFile("testdata/routing/fresh_status.json")
	require.NoError(t, err)
	var expected []json.RawMessage
	require.NoError(t, json.Unmarshal(fixture, &expected))
	for i, preferred := range []string{"claude", "codex"} {
		t.Run(preferred, func(t *testing.T) {
			t.Setenv("HOME", t.TempDir())
			reserve := "codex"
			if preferred == reserve {
				reserve = "claude"
			}
			dir := t.TempDir()
			marker := filepath.Join(dir, "inference-started")
			bin := filepath.Join(dir, "forbidden-provider")
			require.NoError(t, os.WriteFile(bin, []byte("#!/bin/sh\ntouch '"+marker+"'\nexit 1\n"), 0700))
			cfg := filepath.Join(dir, "config.yaml")
			data := []byte("claude_path: '" + bin + "'\ncodex_path: '" + bin + "'\nai: {provider: " + preferred + ", fallback: {enabled: true, provider: " + reserve + "}}\n")
			require.NoError(t, os.WriteFile(cfg, data, 0600))
			p := startCLI(t, "--config", cfg, "ai", "routing-status")
			line, ok := p.next(t, 10*time.Second)
			require.True(t, ok)
			require.NoError(t, p.wait())
			var dto map[string]any
			require.NoError(t, json.Unmarshal([]byte(line), &dto))
			require.NotEmpty(t, dto["saved_version"])
			require.NotEmpty(t, dto["revision"])
			delete(dto, "saved_version")
			dto["revision"] = "normalized-test-revision"
			normalized, err := json.Marshal(dto)
			require.NoError(t, err)
			require.JSONEq(t, string(expected[i]), string(normalized))
			_, err = os.Stat(marker)
			require.ErrorIs(t, err, os.ErrNotExist)
			after, err := os.ReadFile(cfg)
			require.NoError(t, err)
			require.Equal(t, data, after)
		})
	}
}
