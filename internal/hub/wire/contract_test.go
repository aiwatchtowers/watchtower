package wire_test

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"os"
	"testing"

	"github.com/stretchr/testify/require"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/wire"
)

type fixture struct {
	DeviceGrant []struct {
		Name          string          `json:"name"`
		RelayAuthSeed string          `json:"relay_auth_seed"`
		JSON          json.RawMessage `json:"json"`
		Expect        json.RawMessage `json:"expect"`
	} `json:"device_grant"`
	LinkPayload []struct {
		Name          string          `json:"name"`
		RelayAuthSeed string          `json:"relay_auth_seed"`
		URL           string          `json:"url"`
		Expect        json.RawMessage `json:"expect"`
		Error         string          `json:"error"`
	} `json:"link_payload"`
	DeviceHello []struct {
		Name          string          `json:"name"`
		RelayAuthSeed string          `json:"relay_auth_seed"`
		JSON          json.RawMessage `json:"json"`
		RelayCoder    string          `json:"relay_coder"`
	} `json:"device_hello"`
	Encoding []struct {
		Name        string          `json:"name"`
		Kind        string          `json:"kind"`
		Value       json.RawMessage `json:"value"`
		RelayCoder  string          `json:"relay_coder"`
		LinkEncoder string          `json:"link_encoder"`
	} `json:"encoding"`
}

func errFor(t *testing.T, s string) error {
	t.Helper()
	switch s {
	case "newer_version":
		return wire.ErrNewerVersion
	case "older_version":
		return wire.ErrOlderVersion
	case "bad_hub_key":
		return wire.ErrBadHubKey
	case "missing_field":
		return wire.ErrMissingField
	}
	t.Fatalf("unknown error %q in fixture", s)
	return nil
}

// relayPair is the relay identity a case derives from its fixed seed: the
// base64url `relay_auth` public key and its relay device id.
func relayPair(t *testing.T, seed string) (pub, id string) {
	t.Helper()
	raw, err := base64.RawURLEncoding.DecodeString(seed)
	require.NoError(t, err)
	key := ed25519.NewKeyFromSeed(raw).Public().(ed25519.PublicKey)
	return base64.RawURLEncoding.EncodeToString(key), identity.RelayDeviceID(key)
}

// requireCoherentRelay checks that a case's relay_auth_pub and relay_device_id
// are the pair its seed derives (the hub derives both from one key).
func requireCoherentRelay(t *testing.T, seed, gotPub, gotID string) {
	t.Helper()
	if seed == "" {
		return
	}
	pub, id := relayPair(t, seed)
	require.Equal(t, pub, gotPub, "relay_auth_pub derives from the case's seed")
	require.Equal(t, id, gotID, "relay_device_id derives from the case's seed")
}

func TestHubContractFixture(t *testing.T) {
	raw, err := os.ReadFile("../../../WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json")
	require.NoError(t, err)
	var f fixture
	require.NoError(t, json.Unmarshal(raw, &f))
	require.NotEmpty(t, f.DeviceGrant)
	require.NotEmpty(t, f.LinkPayload)
	require.Len(t, f.DeviceHello, 3)

	for _, c := range f.DeviceGrant {
		t.Run("grant/"+c.Name, func(t *testing.T) {
			var g wire.DeviceGrant
			require.NoError(t, json.Unmarshal(c.JSON, &g))
			out, err := wire.Marshal(g)
			require.NoError(t, err)
			require.JSONEq(t, string(c.Expect), string(out))
			// The re-encoding is stable.
			var g2 wire.DeviceGrant
			require.NoError(t, json.Unmarshal(out, &g2))
			require.Equal(t, g, g2)
			requireCoherentRelay(t, c.RelayAuthSeed, g.RelayAuthPub, g.RelayDeviceID)
		})
	}
	for _, c := range f.LinkPayload {
		t.Run("link/"+c.Name, func(t *testing.T) {
			p, err := wire.ParseLinkURL(c.URL)
			if c.Error != "" {
				require.ErrorIs(t, err, errFor(t, c.Error))
				return
			}
			require.NoError(t, err)
			out, err := wire.Marshal(p)
			require.NoError(t, err)
			require.JSONEq(t, string(c.Expect), string(out))
			u, err := p.URL()
			require.NoError(t, err)
			p2, err := wire.ParseLinkURL(u)
			require.NoError(t, err)
			require.Equal(t, p, p2)
			require.Equal(t, c.URL, u, "Go writes the fixture's link bytes")
			requireCoherentRelay(t, c.RelayAuthSeed, p.RelayAuthPub, p.RelayDeviceID)
		})
	}
	for _, c := range f.DeviceHello {
		t.Run("hello/"+c.Name, func(t *testing.T) {
			var h wire.DeviceHello
			require.NoError(t, json.Unmarshal(c.JSON, &h))
			out, err := wire.Marshal(h)
			require.NoError(t, err)
			require.JSONEq(t, string(c.JSON), string(out))
			if c.RelayCoder != "" {
				require.Equal(t, c.RelayCoder, string(out), "Go writes the Kit's hello bytes")
			}
			switch c.Name {
			case "with_relay_id":
				_, id := relayPair(t, c.RelayAuthSeed)
				require.Equal(t, wire.DeviceHello{
					Device: h.Device, SigningKey: h.SigningKey, AgreementKey: h.AgreementKey, RelayDeviceID: id,
				}, h)
			case "without_relay_id":
				require.Empty(t, h.RelayDeviceID)
			case "bad_relay_id":
				// Decodes; the hub's link drops it (pinned in internal/hub/link's TestHelloFixtureRelayIDRule).
				require.NotEmpty(t, h.RelayDeviceID)
			default:
				t.Fatalf("unknown hello case %q", c.Name)
			}
		})
	}
	require.NotEmpty(t, f.Encoding)
	for _, c := range f.Encoding {
		t.Run("encoding/"+c.Name, func(t *testing.T) {
			var v any
			switch c.Kind {
			case "strings":
				v = map[string]string{}
			case "dates":
				v = map[string]wire.Time{}
			default:
				t.Fatalf("unknown kind %q", c.Kind)
			}
			require.NoError(t, json.Unmarshal(c.Value, &v))
			out, err := wire.Marshal(v)
			require.NoError(t, err)
			require.Equal(t, c.RelayCoder, string(out))
			if c.LinkEncoder != "" {
				out, err = wire.MarshalUnescapedSlashes(v)
				require.NoError(t, err)
				require.Equal(t, c.LinkEncoder, string(out))
			}
		})
	}
}

func TestParseLinkURL_Refusals(t *testing.T) {
	_, err := wire.ParseLinkURL("https://example.com/link?d=e30")
	require.ErrorIs(t, err, wire.ErrNotALink)
	_, err = wire.ParseLinkURL("watchtower://link?d=e30=")
	require.ErrorIs(t, err, wire.ErrBadEncoding)
	_, err = wire.ParseLinkURL("watchtower://link?d=e30") // {}
	require.ErrorIs(t, err, wire.ErrMissingField)
	// {"v":4}: a required key is named.
	_, err = wire.ParseLinkURL("watchtower://link?d=eyJ2Ijo0fQ")
	require.ErrorIs(t, err, wire.ErrMissingField)
	require.ErrorContains(t, err, "hub_sig") // the Kit reads the hub keys first

	// "v": null is a missing v (the Kit's missingField), not an older version.
	_, err = wire.ParseLinkURL(linkURL(t, `{"v":null}`))
	require.ErrorIs(t, err, wire.ErrMissingField)
	require.ErrorContains(t, err, "v")

	// Kit order: a zero hub key is reported before a missing hub_id.
	zero := base64.RawURLEncoding.EncodeToString(make([]byte, 32))
	one := base64.RawURLEncoding.EncodeToString(append(make([]byte, 31), 1))
	_, err = wire.ParseLinkURL(linkURL(t, `{"v":4,"hub_sig":"`+zero+`","hub_kx":"`+one+`"}`))
	require.ErrorIs(t, err, wire.ErrBadHubKey)
	_, err = wire.ParseLinkURL(linkURL(t, `{"v":4,"hub_sig":"`+one+`","hub_kx":"`+one+`"}`))
	require.ErrorContains(t, err, "hub_id")
}

func linkURL(t *testing.T, js string) string {
	t.Helper()
	return "watchtower://link?d=" + base64.RawURLEncoding.EncodeToString([]byte(js))
}
