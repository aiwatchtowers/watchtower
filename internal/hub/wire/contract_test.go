package wire_test

import (
	"bytes"
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
	Heartbeat  []contractCase `json:"heartbeat"`
	UploadEcho []contractCase `json:"upload_echo"`
}

// contractCase is a {name, json, expect, kit} case: json decoded and
// re-encoded by Go gives expect's bytes (the fixture writes it in Go's sorted
// key order); kit is the phone's reading.
type contractCase struct {
	Name   string          `json:"name"`
	JSON   json.RawMessage `json:"json"`
	Expect json.RawMessage `json:"expect"`
	Kit    map[string]any  `json:"kit"`
}

// recordingsOffered is the phone's reading (protocol §9): recording is
// offered unless the heartbeat says "off"; absent capabilities, unknown
// values and unknown keys read as on.
func recordingsOffered(hb wire.Heartbeat) bool {
	return hb.Capabilities == nil || hb.Capabilities.Recordings != "off"
}

func compact(t *testing.T, raw json.RawMessage) string {
	t.Helper()
	var b bytes.Buffer
	require.NoError(t, json.Compact(&b, raw))
	return b.String()
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

// TestHubContractFixture_RecordingSwitch: the heartbeat's capabilities and
// the upload echo's reason (protocol §7.7, §9).
func TestHubContractFixture_RecordingSwitch(t *testing.T) {
	raw, err := os.ReadFile("../../../WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json")
	require.NoError(t, err)
	var f fixture
	require.NoError(t, json.Unmarshal(raw, &f))
	names := func(cs []contractCase) []string {
		var out []string
		for _, c := range cs {
			out = append(out, c.Name)
		}
		return out
	}
	require.ElementsMatch(t, []string{"capabilities_on", "capabilities_off", "capabilities_absent",
		"capabilities_unknown_value", "unknown_capability_key"}, names(f.Heartbeat))
	require.ElementsMatch(t, []string{"failed_not_supported", "failed_expired", "received",
		"failed_legacy_no_reason"}, names(f.UploadEcho))
	for _, c := range f.Heartbeat {
		t.Run("heartbeat/"+c.Name, func(t *testing.T) {
			var hb wire.Heartbeat
			require.NoError(t, json.Unmarshal(c.JSON, &hb))
			out, err := wire.Marshal(hb)
			require.NoError(t, err)
			require.Equal(t, compact(t, c.Expect), string(out), "Go writes the fixture's heartbeat bytes")
			require.Equal(t, c.Kit["recordings_offered"], recordingsOffered(hb))
			if c.Name == "capabilities_on" || c.Name == "capabilities_off" {
				// Go's own capabilities, built rather than decoded, are these bytes.
				hb.Capabilities = wire.RecordingsCapability(c.Name == "capabilities_on")
				out, err := wire.Marshal(hb)
				require.NoError(t, err)
				require.Equal(t, compact(t, c.Expect), string(out))
			}
		})
	}
	for _, c := range f.UploadEcho {
		t.Run("upload_echo/"+c.Name, func(t *testing.T) {
			// The hub echoes an upload as a key map: every key the phone wrote kept.
			var m map[string]json.RawMessage
			require.NoError(t, json.Unmarshal(c.JSON, &m))
			out, err := wire.Marshal(m)
			require.NoError(t, err)
			require.Equal(t, compact(t, c.Expect), string(out))
			var echo struct {
				Status string  `json:"status"`
				Reason *string `json:"reason"`
			}
			require.NoError(t, json.Unmarshal(out, &echo))
			require.Equal(t, c.Kit["status"], echo.Status)
			if c.Kit["reason"] == nil {
				require.Nil(t, echo.Reason, "no reason key")
			} else {
				require.NotNil(t, echo.Reason)
				require.Equal(t, c.Kit["reason"], *echo.Reason)
			}
			require.Equal(t, c.Kit["keeps_audio"], echo.Status != wire.StatusReceived)
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
