package wire_test

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"os"
	"testing"

	"github.com/stretchr/testify/require"

	"watchtower/internal/hub/wire"
)

type fixture struct {
	DeviceGrant []struct {
		Name   string          `json:"name"`
		JSON   json.RawMessage `json:"json"`
		Expect json.RawMessage `json:"expect"`
	} `json:"device_grant"`
	LinkPayload []struct {
		Name   string          `json:"name"`
		URL    string          `json:"url"`
		Expect json.RawMessage `json:"expect"`
		Error  string          `json:"error"`
	} `json:"link_payload"`
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

func TestHubContractFixture(t *testing.T) {
	raw, err := os.ReadFile("../../../WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json")
	require.NoError(t, err)
	var f fixture
	require.NoError(t, json.Unmarshal(raw, &f))
	require.NotEmpty(t, f.DeviceGrant)
	require.NotEmpty(t, f.LinkPayload)

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
