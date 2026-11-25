package link

import (
	"encoding/json"
	"os"
	"testing"

	"github.com/stretchr/testify/require"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/wire"
)

// TestHelloFixtureRelayIDRule pins validRelayDeviceID, the rule openHello
// applies to a hello's relay_device_id, to the shared phone <-> hub fixture's
// `device_hello` cases: the phone's derived id passes, the bad one is dropped.
// Every case the hub reads also pins slotRelayIDProof (#2387): its
// `slot_relay_link` is whether a slot hello of these bytes, to the case's
// hub, marks the phone as linked over Relay (a proof in the device data of
// the id the hello names; a hello naming no relay id is never marked); the
// Kit's hello cases check the same verdict.
func TestHelloFixtureRelayIDRule(t *testing.T) {
	raw, err := os.ReadFile("../../../WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json")
	require.NoError(t, err)
	var f struct {
		DeviceHello []struct {
			Name   string           `json:"name"`
			Accept *bool            `json:"hub_accepts_relay_id"`
			HubID  string           `json:"hub_id"`
			Mark   *bool            `json:"slot_relay_link"`
			JSON   wire.DeviceHello `json:"json"`
		} `json:"device_hello"`
	}
	require.NoError(t, json.Unmarshal(raw, &f))
	checked, marked, verdicts := 0, 0, 0
	for _, c := range f.DeviceHello {
		if c.Accept == nil {
			require.Empty(t, c.JSON.RelayDeviceID, c.Name)
		} else {
			require.Equal(t, *c.Accept, validRelayDeviceID(c.JSON.RelayDeviceID), c.Name)
			checked++
		}
		if c.Accept != nil && !*c.Accept {
			require.Nil(t, c.Mark, c.Name) // dropped before any verdict
			continue
		}
		// Every hello the hub reads has a verdict, one naming no relay id too.
		require.NotNil(t, c.Mark, c.Name)
		verdicts++
		hub, err := secure.ParseID(c.HubID)
		require.NoError(t, err, c.Name)
		device, err := secure.ParseID(c.JSON.Device.DeviceID)
		require.NoError(t, err, c.Name)
		require.Equal(t, *c.Mark, slotRelayIDProof(hub, device, c.JSON) == "", c.Name)
		if *c.Mark {
			marked++
		}
	}
	require.Equal(t, 4, checked)
	require.Equal(t, 1, marked)
	require.Equal(t, 4, verdicts)
}
