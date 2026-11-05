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
	"watchtower/internal/hub/link"
	"watchtower/internal/hub/secure"
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
	Heartbeat         []contractCase `json:"heartbeat"`
	UploadEcho        []contractCase `json:"upload_echo"`
	TransportSwitched []contractCase `json:"transport_switched"`
	SwitchRejected    []contractCase `json:"transport_switch_rejected"`
	DevicePayload     []struct {
		Name          string          `json:"name"`
		RelayAuthSeed string          `json:"relay_auth_seed"`
		HubID         string          `json:"hub_id"`
		JSON          json.RawMessage `json:"json"`
		RelayCoder    string          `json:"relay_coder"`
		Proof         bool            `json:"proof"`
		Kit           struct {
			RelayDeviceID *string `json:"relay_device_id"`
		} `json:"kit"`
	} `json:"device_payload"`
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

// TestHubContractFixture_TransportSwitched pins transport_switched (phone
// contract point 3): keybox is a base64url string of the sealed keybox
// envelope (a phone reads any other value as no keybox; the hub never writes
// one and refuses to read one), and the transport marker (point 4) is the
// control without keybox and device_id.
func TestHubContractFixture_TransportSwitched(t *testing.T) {
	raw, err := os.ReadFile("../../../WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json")
	require.NoError(t, err)
	var f fixture
	require.NoError(t, json.Unmarshal(raw, &f))
	byName := map[string]contractCase{}
	for _, c := range f.TransportSwitched {
		byName[c.Name] = c
	}
	require.Len(t, byName, 4)
	for _, c := range f.TransportSwitched {
		t.Run(c.Name, func(t *testing.T) {
			var ctl wire.Control
			err := json.Unmarshal(c.JSON, &ctl)
			if string(c.Expect) == "null" {
				require.Error(t, err, "Go never reads a keybox that is not a string")
				require.Nil(t, c.Kit["keybox"], "the phone reads it as no keybox")
				return
			}
			require.NoError(t, err)
			out, err := wire.Marshal(ctl)
			require.NoError(t, err)
			require.Equal(t, compact(t, c.Expect), string(out), "Go writes the fixture's bytes")
			require.Equal(t, wire.ControlSwitched, ctl.Kind)
			require.Equal(t, c.Kit["target"], *ctl.Target)
			require.InDelta(t, c.Kit["epoch"], float64(*ctl.Epoch), 0)
			if c.Kit["keybox"] == nil {
				require.Nil(t, ctl.Keybox)
			} else {
				require.Equal(t, c.Kit["keybox"], *ctl.Keybox)
				_, err := base64.RawURLEncoding.DecodeString(*ctl.Keybox)
				require.NoError(t, err, "unpadded base64url")
			}
		})
	}
	var switched wire.Control
	require.NoError(t, json.Unmarshal(byName["switched_with_keybox"].JSON, &switched))
	out, err := wire.Marshal(switched.Marker())
	require.NoError(t, err)
	require.Equal(t, compact(t, byName["transport_marker"].Expect), string(out), "the marker is the control minus keybox and device_id")
}

// TestHubContractFixture_SwitchRejected pins every
// transport_switch_rejected reason the hub writes and its retry_after_s.
func TestHubContractFixture_SwitchRejected(t *testing.T) {
	raw, err := os.ReadFile("../../../WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json")
	require.NoError(t, err)
	var f fixture
	require.NoError(t, json.Unmarshal(raw, &f))
	var reasons []string
	for _, c := range f.SwitchRejected {
		t.Run(c.Name, func(t *testing.T) {
			var ctl wire.Control
			require.NoError(t, json.Unmarshal(c.JSON, &ctl))
			out, err := wire.Marshal(ctl)
			require.NoError(t, err)
			require.Equal(t, compact(t, c.Expect), string(out))
			require.Equal(t, wire.ControlSwitchRejected, ctl.Kind)
			require.Equal(t, c.Kit["reason"], *ctl.Reason)
			if c.Kit["retry_after_s"] == nil {
				require.Nil(t, ctl.RetryAfterS)
			} else {
				require.InDelta(t, c.Kit["retry_after_s"], float64(*ctl.RetryAfterS), 0)
			}
		})
		reasons = append(reasons, c.Kit["reason"].(string))
	}
	require.ElementsMatch(t, []string{wire.SwitchTooSoon, wire.SwitchNotPaying, wire.SwitchUnavailable, wire.SwitchNotSupported}, reasons)
}

func linkURL(t *testing.T, js string) string {
	t.Helper()
	return "watchtower://link?d=" + base64.RawURLEncoding.EncodeToString([]byte(js))
}

// TestDevicePayloadCases pins a device record's relay id fields (Task 23) and
// its "When work stops" switch (work_alerts_off, Open decision 1, option A):
// Go reads and writes the Kit's bytes, and the hub's proof check
// (link.VerifyRelayIDProof) gives each case's `proof` verdict, which the Kit's
// RelayIDProof.verify gives too.
func TestDevicePayloadCases(t *testing.T) {
	raw, err := os.ReadFile("../../../WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json")
	require.NoError(t, err)
	var f fixture
	require.NoError(t, json.Unmarshal(raw, &f))
	names := map[string]bool{}
	for _, c := range f.DevicePayload {
		names[c.Name] = true
		t.Run(c.Name, func(t *testing.T) {
			var p wire.DevicePayload
			require.NoError(t, json.Unmarshal(c.JSON, &p))
			out, err := wire.Marshal(p)
			require.NoError(t, err)
			require.JSONEq(t, string(c.JSON), string(out))
			if c.RelayCoder != "" {
				require.Equal(t, c.RelayCoder, string(out), "Go writes the Kit's device record bytes")
			}
			hub, err := secure.ParseID(c.HubID)
			require.NoError(t, err)
			device, err := secure.ParseID(p.DeviceID)
			require.NoError(t, err)
			id, ok := link.VerifyRelayIDProof(hub, device, p)
			require.Equal(t, c.Proof, ok)
			if c.Proof {
				require.Equal(t, p.RelayDeviceID, id)
				requireCoherentRelay(t, c.RelayAuthSeed, p.RelayAuthPub, p.RelayDeviceID)
				require.NotNil(t, c.Kit.RelayDeviceID)
				require.Equal(t, *c.Kit.RelayDeviceID, id, "the Kit reads the id the hub takes")
			}
		})
	}
	for _, c := range f.DevicePayload {
		if c.Name != "work_alerts_off" {
			continue
		}
		var p wire.DevicePayload
		require.NoError(t, json.Unmarshal(c.JSON, &p))
		require.NotNil(t, p.WorkAlertsOff, "Go reads the Kit's key")
		require.True(t, *p.WorkAlertsOff)
	}
	for _, n := range []string{"with_proven_relay_id", "without_relay_id", "invalid_relay_id_reads_as_none",
		"wrong_key", "bad_signature", "other_hub", "work_alerts_off"} {
		require.True(t, names[n], "missing case %s", n)
	}
}
