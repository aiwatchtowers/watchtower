package link

import (
	"encoding/json"
	"os"
	"testing"

	"github.com/stretchr/testify/require"
)

// TestHelloFixtureRelayIDRule pins validRelayDeviceID, the rule openHello
// applies to a hello's relay_device_id, to the shared phone <-> hub fixture's
// `device_hello` cases: the phone's derived id passes, the bad one is dropped.
func TestHelloFixtureRelayIDRule(t *testing.T) {
	raw, err := os.ReadFile("../../../WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json")
	require.NoError(t, err)
	var f struct {
		DeviceHello []struct {
			Name   string `json:"name"`
			Accept *bool  `json:"hub_accepts_relay_id"`
			JSON   struct {
				RelayDeviceID string `json:"relay_device_id"`
			} `json:"json"`
		} `json:"device_hello"`
	}
	require.NoError(t, json.Unmarshal(raw, &f))
	checked := 0
	for _, c := range f.DeviceHello {
		if c.Accept == nil {
			require.Empty(t, c.JSON.RelayDeviceID, c.Name)
			continue
		}
		require.Equal(t, *c.Accept, validRelayDeviceID(c.JSON.RelayDeviceID), c.Name)
		checked++
	}
	require.Equal(t, 2, checked)
}
