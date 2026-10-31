package wire_test

import (
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"watchtower/internal/hub/wire"
)

func TestMarshal_SortedKeysUnixSeconds(t *testing.T) {
	half := wire.Time{Time: time.Unix(1730000000, 500_000_000)}
	b, err := wire.Marshal(map[string]any{"b": 1, "a": half})
	require.NoError(t, err)
	require.Equal(t, `{"a":1730000000.5,"b":1}`, string(b))

	b, err = wire.Marshal(map[string]any{"t": wire.Time{Time: time.Unix(1730000000, 0)}, "s": "<&>/"})
	require.NoError(t, err)
	require.Equal(t, `{"s":"<&>\/","t":1730000000}`, string(b))

	var back wire.Time
	require.NoError(t, back.UnmarshalJSON([]byte("1730000000.5")))
	require.True(t, back.Equal(half.Time))
}

func TestDeviceGrant_PermissionsFalseIsAbsent(t *testing.T) {
	f := false
	b, err := wire.Marshal(wire.DeviceGrant{DeviceID: "d", PermissionsAllowed: &f})
	require.NoError(t, err)
	require.NotContains(t, string(b), "permissions_allowed")

	tr := true
	b, err = wire.Marshal(wire.DeviceGrant{DeviceID: "d", PermissionsAllowed: &tr})
	require.NoError(t, err)
	require.Contains(t, string(b), `"permissions_allowed":true`)
}

func TestMarshalUnescapedSlashes(t *testing.T) {
	b, err := wire.MarshalUnescapedSlashes(map[string]any{"u": "https://example.com/a", "a": 1})
	require.NoError(t, err)
	require.Equal(t, `{"a":1,"u":"https://example.com/a"}`, string(b))
}

func TestTime_NegativeAndFraction(t *testing.T) {
	b, err := wire.Marshal(map[string]wire.Time{"x": {Time: time.Unix(-2, 500_000_000)}})
	require.NoError(t, err)
	require.Equal(t, `{"x":-1.5}`, string(b))
}

func TestControl_TransportSwitchedCarriesTargetAndKeybox(t *testing.T) {
	target, by := wire.TransportRelay, "dev"
	ep := uint32(2)
	b, err := wire.Marshal(wire.Control{ID: "c1", Kind: wire.ControlSwitched, Target: &target, By: &by, Epoch: &ep,
		Keybox: &wire.Keybox{Grant: wire.DeviceGrant{DeviceID: "dev"}, Keys: &wire.KeyboxKeys{Epoch: 2}}})
	require.NoError(t, err)
	require.Contains(t, string(b), `"target":"relay"`)
	require.Contains(t, string(b), `"keybox":{`)
	secs := uint32(300)
	b, err = wire.Marshal(wire.Control{ID: "c2", Kind: wire.ControlSwitchRejected, RetryAfterS: &secs})
	require.NoError(t, err)
	require.Contains(t, string(b), `"retry_after_s":300`)
}
