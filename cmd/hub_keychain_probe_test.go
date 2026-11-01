package cmd

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/hub/identity"
)

// Neither case reaches the Keychain: both are refused before any call.

func TestHubKeychainProbeRefusedUnderAnAgentMarker(t *testing.T) {
	for _, marker := range agentEnvMarkers {
		t.Run(marker, func(t *testing.T) {
			hubTestDir(t)
			t.Setenv(marker, "1")
			_, err := runHub(t, "keychain-probe", "write")
			require.Error(t, err)
			assert.Contains(t, err.Error(), "under an AI agent")
			assert.Contains(t, err.Error(), marker)
		})
	}
}

func TestHubKeychainProbeNeverUsesTheHubService(t *testing.T) {
	hubTestDir(t)
	_, err := runHub(t, "keychain-probe", "delete", "--service", identity.KeychainService)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "never touches the hub's Keychain service")
}
