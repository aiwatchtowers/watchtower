package wire_test

import (
	"encoding/base64"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"watchtower/internal/hub/wire"
)

// relay_switch is optional: a code from an older Mac has no key and reads
// false, and a false one renders without it; true renders as the JSON key
// "relay_switch" and reads back.
func TestLinkPayloadRelaySwitchIsOptional(t *testing.T) {
	p := wire.LinkPayload{V: wire.LinkPayloadVersion, HubID: "hub", MacName: "acme", Nonce: "n", Iat: 1, Exp: 2,
		HubSig: validHubKeyText(), HubKX: validHubKeyText()}
	u, err := p.URL()
	require.NoError(t, err)
	require.NotContains(t, linkJSON(t, u), "relay_switch")
	back, err := wire.ParseLinkURL(u)
	require.NoError(t, err)
	require.False(t, back.RelaySwitch)

	p.RelaySwitch = true
	u, err = p.URL()
	require.NoError(t, err)
	require.Contains(t, linkJSON(t, u), `"relay_switch":true`)
	back, err = wire.ParseLinkURL(u)
	require.NoError(t, err)
	require.True(t, back.RelaySwitch)
}

func validHubKeyText() string {
	b := make([]byte, 32)
	b[0] = 1
	return base64.RawURLEncoding.EncodeToString(b)
}

func linkJSON(t *testing.T, u string) string {
	t.Helper()
	raw, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(u, "watchtower://link?d="))
	require.NoError(t, err)
	return string(raw)
}
