package cmd

import (
	"bufio"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/spf13/pflag"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"google.golang.org/protobuf/proto"

	"watchtower/internal/config"
	"watchtower/internal/hub"
	"watchtower/internal/hub/hostkind"
	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/switcher"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/transport/relay/relayv1"
	"watchtower/internal/hub/wire"
	"watchtower/internal/policy/policytest"
)

// hubShortDir is a hub dir with a short path (a unix socket path is capped
// near 104 bytes, which a t.TempDir path can pass on macOS), set as
// WATCHTOWER_HUB_DIR with every agent marker cleared.
func hubShortDir(t *testing.T) string {
	t.Helper()
	base, err := os.MkdirTemp("/tmp", "hubc")
	require.NoError(t, err)
	t.Cleanup(func() { _ = os.RemoveAll(base) })
	dir := filepath.Join(base, "h")
	t.Setenv(hubDirEnv, dir)
	for _, m := range agentEnvMarkers {
		t.Setenv(m, "")
	}
	hubOnGOOS(t, "darwin")
	return dir
}

// linkTestPhone writes a linked phone straight into dir's sidecar.
func linkTestPhone(t *testing.T, dir string) string {
	t.Helper()
	return linkTestPhoneWith(t, dir, func(*state.Device) {})
}

// linkTestPhoneWith links a phone whose row edit changed first.
func linkTestPhoneWith(t *testing.T, dir string, edit func(*state.Device)) string {
	t.Helper()
	p, err := hubtest.New(hubtest.Config{})
	require.NoError(t, err)
	st, err := state.Open(dir)
	require.NoError(t, err)
	defer func() { _ = st.Close() }()
	d := p.Device()
	edit(&d)
	require.NoError(t, st.WithTx(context.Background(), func(tx *sql.Tx) error { return state.LinkDevice(tx, d) }))
	return strings.ToUpper(p.ID().String())
}

func setHubMeta(t *testing.T, dir, key, value string) {
	t.Helper()
	st, err := state.Open(dir)
	require.NoError(t, err)
	defer func() { _ = st.Close() }()
	require.NoError(t, st.SetMeta(key, value))
}

func hubMeta(t *testing.T, dir, key string) string {
	t.Helper()
	st, err := state.OpenReadOnly(dir)
	require.NoError(t, err)
	defer func() { _ = st.Close() }()
	v, _, err := st.Meta(key)
	require.NoError(t, err)
	return v
}

// startTestHub runs hub.Run over a memfake relay until the test ends and
// waits for its control socket.
func startTestHub(t *testing.T, dir string) *memfake.Fake {
	t.Helper()
	fake := memfake.New(transport.KindRelay, nil)
	startTestHubOn(t, dir, fake)
	return fake
}

// startTestHubOn is startTestHub over the transport tr.
func startTestHubOn(t *testing.T, dir string, tr transport.Transport) {
	t.Helper()
	policytest.Set(t, nil)
	o := hub.Options{Dir: dir}.WithTransport(func(context.Context, identity.Identity, *state.Store, []string) (transport.Transport, error) {
		return tr, nil
	})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- hub.Run(ctx, o) }()
	t.Cleanup(func() {
		cancel()
		<-done
	})
	waitFor(t, "the control socket", func() bool {
		_, err := os.Stat(filepath.Join(dir, hub.SocketName))
		return err == nil
	})
}

// waitFor polls cond until it holds; the string names what is awaited for
// the reader. It has no deadline of its own: a condition that never holds
// hangs the run into go test's -timeout, which dumps every goroutine.
func waitFor(t *testing.T, _ string, cond func() bool) {
	t.Helper()
	for !cond() {
		time.Sleep(10 * time.Millisecond)
	}
}

func waitHubState(t *testing.T, dir, want string) {
	t.Helper()
	waitFor(t, "hub state "+want, func() bool {
		s, err := hub.ReadStatus(dir)
		return err == nil && s.State == want
	})
}

// hubTestConfig points flagConfig at a config whose active workspace is ws.
func hubTestConfig(t *testing.T, ws string) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	path := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(path, []byte("active_workspace: "+ws+"\n"), 0o600))
	orig := flagConfig
	flagConfig = path
	t.Cleanup(func() { flagConfig = orig })
}

func TestHubStatusJSONKeys(t *testing.T) {
	dir := hubTestDir(t)
	hubTestConfig(t, "hubtest-x")
	t.Setenv(hub.EnvTestWorkspace, "hubtest-x")
	t.Setenv(hub.EnvRelayOrigin, "https://relay.example.com")
	out, err := runHub(t, "status", "--json")
	require.NoError(t, err)
	m := decodeKeys(t, out)
	// Off, relay is absent (no runtime facts) and the lists are empty.
	assert.ElementsMatch(t, []string{"state", "reason", "hub_id", "relay_device_id", "transport", "impl", "dir", "phones", "recordings", "host", "mode",
		"adoption", "bridge", "identity", "switched_at", "switched_by", "name", "cloudkit", "off_delete", "transcriber",
		"paying_phones", "mailbox_full_phones", "epoch", "epoch_age_days"}, hubKeysOf(m))
	assert.Nil(t, m["paying_phones"], "no hub runs: who pays is unknown")
	assert.Equal(t, []any{}, m["mailbox_full_phones"])
	od, ok := m["off_delete"].(map[string]any)
	require.True(t, ok, "off_delete is an object")
	assert.ElementsMatch(t, []string{"state", "at"}, hubKeysOf(od))
	assert.Equal(t, false, m["transcriber"], "no Desktop heartbeat yet")
	ck, ok := m["cloudkit"].(map[string]any)
	require.True(t, ok, "cloudkit is an object")
	assert.ElementsMatch(t, []string{"account", "throttled_since", "signed"}, hubKeysOf(ck))
	assert.Equal(t, hub.AdoptionNone, m["adoption"])
	assert.Equal(t, hub.StateOff, m["state"])
	assert.Equal(t, "", m["reason"])
	assert.Equal(t, dir, m["dir"])
	assert.Equal(t, string(hub.ModeTest), m["mode"])

	// The daemon's hub would refuse this workspace before writing a status:
	// status says so itself.
	t.Setenv(hub.EnvTestWorkspace, "")
	out, err = runHub(t, "status", "--json")
	require.NoError(t, err)
	assert.Equal(t, hub.ReasonNotTestWorkspace, decodeKeys(t, out)["reason"])
	t.Setenv(hub.EnvTestWorkspace, "hubtest-y") // not the active workspace
	out, err = runHub(t, "status", "--json")
	require.NoError(t, err)
	assert.Equal(t, hub.ReasonNotTestWorkspace, decodeKeys(t, out)["reason"])

	// A running hub on the relay: relay with every key of its own.
	running := hubShortDir(t)
	setHubMeta(t, running, state.MetaEnabled, "1")
	startTestHub(t, running)
	waitHubState(t, running, hub.StateRunning)
	waitFor(t, "the relay indicators", func() bool {
		s, err := hub.ReadStatus(running)
		return err == nil && s.Relay != nil
	})
	out, err = runHub(t, "status", "--json")
	require.NoError(t, err)
	m = decodeKeys(t, out)
	assert.Contains(t, hubKeysOf(m), "relay")
	assert.Contains(t, hubKeysOf(m), "paying_phones")
	assert.Contains(t, hubKeysOf(m), "mailbox_full_phones")
	relay, ok := m["relay"].(map[string]any)
	require.True(t, ok, "relay is an object")
	assert.ElementsMatch(t, []string{"state", "since", "quota_hub", "push_off", "last_saved_at"}, hubKeysOf(relay))
	assert.Contains(t, []any{hub.RelayConnected, hub.RelayConnecting, hub.RelayUnavailable}, relay["state"])
}

// hubLiveCLI is a CLI run with no WATCHTOWER_HUB_DIR on a host p: a short
// fresh HOME (the live dir's control socket must fit sockaddr_un), a config
// file, no relay origin, no policy and no agent marker. It returns the live
// hub dir and the config path.
func hubLiveCLI(t *testing.T, p hostkind.Probe) (live, cfgPath string) {
	t.Helper()
	base, err := os.MkdirTemp("/tmp", "hubv")
	require.NoError(t, err)
	t.Cleanup(func() { _ = os.RemoveAll(base) })
	t.Setenv("HOME", base)
	t.Setenv(hubDirEnv, "")
	t.Setenv(hub.EnvRelayOrigin, "")
	for _, m := range agentEnvMarkers {
		t.Setenv(m, "")
	}
	policytest.Set(t, nil)
	origProbe, origConfig := hostProbe, flagConfig
	hostProbe = func() hostkind.Probe { return p }
	cfgPath = filepath.Join(base, "config.yaml")
	require.NoError(t, os.WriteFile(cfgPath, []byte("active_workspace: acme\n"), 0o600))
	flagConfig = cfgPath
	t.Cleanup(func() { hostProbe, flagConfig = origProbe, origConfig })
	live, err = hub.DefaultDir()
	require.NoError(t, err)
	return live, cfgPath
}

func linuxProbe() hostkind.Probe {
	return hostkind.Probe{GOOS: "linux", Stat: os.Stat, ReadFile: os.ReadFile}
}

func TestHubStatusPrintsTheNoRelayOriginRemedy(t *testing.T) {
	live, cfgPath := hubLiveCLI(t, linuxProbe())
	setHubMeta(t, live, state.MetaEnabled, "1")
	out, err := runHub(t, "status")
	require.NoError(t, err)
	assert.Contains(t, out, "hub: off (no_relay_origin)")
	assert.Contains(t, out, "Set the relay: watchtower config set hub.relay_origin <origin>")

	out, err = runHub(t, "status", "--json")
	require.NoError(t, err)
	m := decodeKeys(t, out)
	assert.Equal(t, hub.ReasonNoRelayOrigin, m["reason"])
	assert.Equal(t, string(hub.ModeLive), m["mode"])
	assert.Equal(t, string(hostkind.Headless), m["host"])
	assert.Equal(t, live, m["dir"])

	// Set, the remedy goes.
	require.NoError(t, os.WriteFile(cfgPath, []byte("active_workspace: acme\nhub:\n  relay_origin: https://relay.example.com\n"), 0o600))
	out, err = runHub(t, "status")
	require.NoError(t, err)
	assert.NotContains(t, out, "Set the relay")
	assert.NotContains(t, out, "no_relay_origin")
}

// A hub paused because CloudKit has no usable iCloud account says so in
// both forms: state paused, reason no_icloud, and the text form's line.
func TestHubStatusShowsTheNoICloudPause(t *testing.T) {
	dir := hubTestDir(t)
	hubTestConfig(t, "hubtest-x")
	t.Setenv(hub.EnvTestWorkspace, "hubtest-x")
	raw := fmt.Sprintf(`{"state":%q,"reason":%q,"transport":"cloudkit","cloudkit":{"account":"no_account"},"pid":%d,"run":"r"}`,
		hub.StatePaused, hub.ReasonNoICloud, os.Getpid())
	require.NoError(t, os.MkdirAll(dir, 0o700))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "status.json"), []byte(raw), 0o600))

	out, err := runHub(t, "status")
	require.NoError(t, err)
	assert.Contains(t, out, "hub: paused (no_icloud)")
	assert.Contains(t, out, hubNoICloudLine)

	out, err = runHub(t, "status", "--json")
	require.NoError(t, err)
	m := decodeKeys(t, out)
	assert.Equal(t, hub.StatePaused, m["state"])
	assert.Equal(t, hub.ReasonNoICloud, m["reason"])
	assert.NotContains(t, out, hubNoICloudLine, "the JSON form carries no sentence")
}

// desktopAppProbe is a darwin probe whose /Applications holds the app.
func desktopAppProbe() hostkind.Probe {
	return hostkind.Probe{GOOS: "darwin", Stat: os.Stat, ReadFile: func(p string) ([]byte, error) {
		if p == "/Applications/Watchtower.app/Contents/Info.plist" {
			return []byte("<key>CFBundleIdentifier</key><string>" + hostkind.BundleID + "</string>"), nil
		}
		return nil, fs.ErrNotExist
	}}
}

// TestHubCLIRefusesWritesBeforeAdoptionOnADesktopHost is Review Focus 1 on
// the CLI (never two hubs): beside the Swift hub's state a desktop host's
// status says awaiting_adoption — even over a Go sidecar with enabled = 1
// written by hand — and every write exits 1 and writes nothing; with no Go
// sidecar, nothing is created under the live dir (a sidecar there would
// make the adoption refuse it).
func TestHubCLIRefusesWritesBeforeAdoptionOnADesktopHost(t *testing.T) {
	hubOnGOOS(t, "darwin") // the desktop verbs are a Mac's; CI also runs on Linux
	live, _ := hubLiveCLI(t, desktopAppProbe())
	support, err := config.AppSupportDir()
	require.NoError(t, err)
	mobile := filepath.Join(support, "MobileHub")
	require.NoError(t, os.MkdirAll(mobile, 0o700))
	require.NoError(t, os.WriteFile(filepath.Join(mobile, state.FileName), []byte("swift"), 0o600))
	out, err := runHub(t, "status", "--json")
	require.NoError(t, err)
	m := decodeKeys(t, out)
	assert.Equal(t, hub.StateOff, m["state"])
	assert.Equal(t, hub.ReasonAwaitingAdoption, m["reason"])
	assert.Equal(t, string(hostkind.Desktop), m["host"])
	assert.Equal(t, string(hub.ModeLive), m["mode"])
	assert.Equal(t, live, m["dir"])
	for _, args := range [][]string{
		{"enable"}, {"disable"}, {"name", "acme"}, {"unlink", "X"}, {"allow", "X", "typing"},
		{"desktop", "heartbeat"}, {"recordings", "on"},
	} {
		_, err := runHub(t, args...)
		require.Error(t, err, "%v", args)
		assert.Equal(t, "Mobile on this Mac is run by the Watchtower app.", err.Error(), "%v", args)
	}
	out, err = runHub(t, "phones", "--json")
	require.NoError(t, err)
	assert.Equal(t, "[]", strings.TrimSpace(out))
	_, err = os.Stat(live)
	assert.True(t, errors.Is(err, fs.ErrNotExist), "the live dir was created beside the Swift hub's state")

	// A Go sidecar with enabled = 1 written by hand changes nothing.
	setHubMeta(t, live, state.MetaEnabled, "1")
	out, err = runHub(t, "status", "--json")
	require.NoError(t, err)
	assert.Equal(t, hub.ReasonSwiftBesideGo, decodeKeys(t, out)["reason"])
	for _, args := range [][]string{{"name", "acme"}, {"disable"}, {"desktop", "heartbeat"}} {
		_, err := runHub(t, args...)
		require.Error(t, err, "%v", args)
		assert.Equal(t, "Mobile on this Mac is run by the Watchtower app.", err.Error(), "%v", args)
	}
	assert.Equal(t, "1", hubMeta(t, live, state.MetaEnabled))
	assert.Equal(t, "", hubMeta(t, live, state.MetaDisplayName))
	require.NoError(t, os.RemoveAll(live))

	// With no Swift state (a Mac that never ran it), the owner turns it on.
	require.NoError(t, os.RemoveAll(mobile))
	_, err = runHub(t, "enable")
	require.NoError(t, err)
	assert.Equal(t, "1", hubMeta(t, live, state.MetaEnabled))
}

func TestHubEnableCreatesTheLiveDirOnAHeadlessHost(t *testing.T) {
	live, _ := hubLiveCLI(t, linuxProbe())
	out, err := runHub(t, "status", "--json")
	require.NoError(t, err)
	assert.Equal(t, hub.ReasonDisabled, decodeKeys(t, out)["reason"])
	_, err = os.Stat(live)
	require.True(t, errors.Is(err, fs.ErrNotExist), "status created the live dir")

	_, err = runHub(t, "enable")
	require.NoError(t, err)
	fi, err := os.Stat(live)
	require.NoError(t, err)
	assert.True(t, fi.IsDir())
	assert.Equal(t, os.FileMode(0o700), fi.Mode().Perm())
	assert.Equal(t, "1", hubMeta(t, live, state.MetaEnabled))
}

func TestHubEnableOnAnUnwritableDataRootFails(t *testing.T) {
	live, _ := hubLiveCLI(t, linuxProbe())
	root := filepath.Dir(live)
	require.NoError(t, os.MkdirAll(root, 0o700))
	require.NoError(t, os.Chmod(root, 0o500))
	t.Cleanup(func() { _ = os.Chmod(root, 0o700) })
	home, err := os.UserHomeDir()
	require.NoError(t, err)
	before := hubTree(t, home)

	_, err = runHub(t, "enable")
	require.Error(t, err)
	assert.Equal(t, before, hubTree(t, home), "a failed enable wrote something")
}

// hubTree is every path under root.
func hubTree(t *testing.T, root string) []string {
	t.Helper()
	var out []string
	require.NoError(t, filepath.WalkDir(root, func(path string, _ fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		out = append(out, path)
		return nil
	}))
	return out
}

func TestHubPhonesJSONKeys(t *testing.T) {
	dir := hubTestDir(t)
	out, err := runHub(t, "phones", "--json")
	require.NoError(t, err)
	assert.Equal(t, "[]", strings.TrimSpace(out), "no sidecar yet reads as no phones")
	_, statErr := os.Stat(dir)
	assert.True(t, os.IsNotExist(statErr), "a read creates nothing")

	id := linkTestPhone(t, dir)
	out, err = runHub(t, "phones", "--json")
	require.NoError(t, err)
	var list []map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &list), out)
	require.Len(t, list, 1)
	assert.ElementsMatch(t, []string{"device_id", "name", "scope", "linked_at", "typing_allowed", "typing_requested",
		"permissions_allowed", "permissions_requested", "start_sessions_allowed", "start_sessions_granted", "ordered",
		"last_applied_action_seq", "transport", "paying", "undelivered", "mailbox_full", "alerts", "keys"}, hubKeysOf(list[0]))
	assert.Equal(t, id, list[0]["device_id"])
	// No hub runs: paying is null; nothing held, no flag, no alert yet.
	assert.Nil(t, list[0]["paying"])
	assert.Equal(t, float64(0), list[0]["undelivered"])
	assert.Equal(t, false, list[0]["mailbox_full"])
	assert.Equal(t, "", list[0]["alerts"])

	// transport takes each of cloudkit|relay|pending: a relay link not yet
	// admitted is pending; an admitted one is on the relay, or on CloudKit
	// while a hub with both transports is; a CloudKit (or adopted) link is
	// on CloudKit.
	transportOf := func() map[string]any {
		t.Helper()
		out, err := runHub(t, "phones", "--json")
		require.NoError(t, err)
		var list []map[string]any
		require.NoError(t, json.Unmarshal([]byte(out), &list), out)
		got := map[string]any{}
		for _, p := range list {
			got[p["device_id"].(string)] = p["transport"]
		}
		return got
	}
	assert.Equal(t, "pending", transportOf()[id])
	ck := linkTestPhoneWith(t, dir, func(d *state.Device) { d.RelayDeviceID = "" })
	assert.Equal(t, "cloudkit", transportOf()[ck])
	st, err := state.Open(dir)
	require.NoError(t, err)
	devices, err := st.Devices()
	require.NoError(t, err)
	for _, d := range devices {
		if d.RelayDeviceID != "" {
			_, err = st.MarkRelayAdmitted([]string{d.RelayDeviceID}, time.Now())
			require.NoError(t, err)
		}
	}
	require.NoError(t, st.SetMeta(switcher.MetaTransport, "relay"))
	require.NoError(t, st.Close())
	assert.Equal(t, map[string]any{id: "relay", ck: "cloudkit"}, transportOf())
	setHubMeta(t, dir, switcher.MetaTransport, "cloudkit")
	assert.Equal(t, map[string]any{id: "cloudkit", ck: "cloudkit"}, transportOf())
}

// A phone linked over the relay shows transport "pending" until the relay
// lists it holding the hub in a slot (relay_admitted_at), "relay" after.
func TestHubPhonesTransportPendingUntilAdmitted(t *testing.T) {
	dir := hubTestDir(t)
	linkTestPhone(t, dir)
	transportOf := func() any {
		t.Helper()
		out, err := runHub(t, "phones", "--json")
		require.NoError(t, err)
		var list []map[string]any
		require.NoError(t, json.Unmarshal([]byte(out), &list), out)
		require.Len(t, list, 1)
		return list[0]["transport"]
	}
	assert.Equal(t, "pending", transportOf())

	st, err := state.Open(dir)
	require.NoError(t, err)
	devices, err := st.Devices()
	require.NoError(t, err)
	_, err = st.MarkRelayAdmitted([]string{devices[0].RelayDeviceID}, time.Now())
	require.NoError(t, err)
	require.NoError(t, st.Close())
	assert.Equal(t, "relay", transportOf())
}

// hubPhonesByID is `hub phones --json` keyed by device id.
func hubPhonesByID(t *testing.T) map[string]map[string]any {
	t.Helper()
	out, err := runHub(t, "phones", "--json")
	require.NoError(t, err)
	var list []map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &list), out)
	got := map[string]map[string]any{}
	for _, p := range list {
		got[p["device_id"].(string)] = p
	}
	return got
}

// TestUndeliveredCountsHeldAndGap: undelivered is this Mac's side — the
// phone's held actions plus one for an open gap.
func TestUndeliveredCountsHeldAndGap(t *testing.T) {
	dir := hubTestDir(t)
	id := linkTestPhone(t, dir)
	other := linkTestPhone(t, dir)
	st, err := state.Open(dir)
	require.NoError(t, err)
	devices, err := st.Devices()
	require.NoError(t, err)
	var dev string
	for _, d := range devices {
		if strings.EqualFold(d.ID, id) {
			dev = d.ID
		}
	}
	require.NoError(t, st.HoldAction(dev, 5, "act-5", []byte("sealed")))
	require.NoError(t, st.HoldAction(dev, 6, "act-6", []byte("sealed")))
	require.NoError(t, st.Close())
	got := hubPhonesByID(t)
	assert.Equal(t, float64(2), got[id]["undelivered"])
	assert.Equal(t, float64(0), got[other]["undelivered"])

	st, err = state.Open(dir)
	require.NoError(t, err)
	require.NoError(t, st.WithTx(context.Background(), func(tx *sql.Tx) error { return state.SetResendRequested(tx, dev, 3, time.Now()) }))
	require.NoError(t, st.Close())
	assert.Equal(t, float64(3), hubPhonesByID(t)[id]["undelivered"], "held + 1 for the open gap")
}

// TestHubPhonesPayingMailboxAndAlerts: on a hub running on the relay paying
// is a bool; mailbox_full follows the status file (restored from hub_meta);
// alerts is the last settled push outcome of the phone.
func TestHubPhonesPayingMailboxAndAlerts(t *testing.T) {
	dir := hubShortDir(t)
	setHubMeta(t, dir, state.MetaEnabled, "1")
	id := linkTestPhone(t, dir)
	st, err := state.Open(dir)
	require.NoError(t, err)
	devices, err := st.Devices()
	require.NoError(t, err)
	dev := devices[0].ID
	full, err := json.Marshal([]string{dev})
	require.NoError(t, err)
	require.NoError(t, st.SetMeta(state.MetaMailboxFullPhones, string(full)))
	now := time.Now()
	_, err = st.BeginAlertPushes("ask-1", []string{dev}, now.Add(-time.Minute))
	require.NoError(t, err)
	_, err = st.SettleAlertPush("ask-1", dev, state.AlertNoToken, "", 1, now.Add(-time.Minute))
	require.NoError(t, err)
	require.NoError(t, st.Close())
	assert.Equal(t, state.AlertNoToken, hubPhonesByID(t)[id]["alerts"])

	assert.Nil(t, hubPhonesByID(t)[id]["paying"], "no hub runs: unknown")

	fake := &accountFake{Fake: memfake.New(transport.KindRelay, nil)}
	startTestHubOn(t, dir, fake)
	waitHubState(t, dir, hub.StateRunning)
	waitFor(t, "the mailbox flag in the status", func() bool {
		s, err := hub.ReadStatus(dir)
		return err == nil && len(s.MailboxFullPhones) == 1
	})
	p := hubPhonesByID(t)[id]
	assert.Nil(t, p["paying"], "running on the relay with no account state known: unknown, not false")
	assert.Equal(t, true, p["mailbox_full"])
	assert.Equal(t, state.AlertNoToken, p["alerts"])

	payingOf := func(paying bool) any {
		t.Helper()
		fake.set(&relayv1.AccountState{Phones: []*relayv1.SlotHolder{{PhoneDeviceId: devices[0].RelayDeviceID, Paying: paying}}})
		waitFor(t, "the paying list in the status", func() bool {
			s, err := hub.ReadStatus(dir)
			return err == nil && s.PayingPhones != nil && slices.Contains(s.PayingPhones, dev) == paying
		})
		return hubPhonesByID(t)[id]["paying"]
	}
	assert.Equal(t, false, payingOf(false), "known, not paying")
	assert.Equal(t, true, payingOf(true), "known, paying")
}

// TestHubPhonesListedWhenTheStatusIsUnreadable: a status file that does not
// parse leaves the status-backed indicators null; the phones are listed and
// the other indicators read.
func TestHubPhonesListedWhenTheStatusIsUnreadable(t *testing.T) {
	dir := hubTestDir(t)
	id := linkTestPhone(t, dir)
	require.NoError(t, os.WriteFile(filepath.Join(dir, "status.json"), []byte("{not json"), 0o600))
	p := hubPhonesByID(t)[id]
	require.NotNil(t, p, "the phone is listed")
	assert.Nil(t, p["mailbox_full"])
	assert.Nil(t, p["paying"])
	assert.Equal(t, float64(0), p["undelivered"])
	assert.Equal(t, "", p["alerts"])
}

// accountFake is a memfake relay whose account state is known once set
// (relay.Transport's KnownAccountState).
type accountFake struct {
	*memfake.Fake
	mu   sync.Mutex
	acct *relayv1.AccountState
}

func (f *accountFake) set(st *relayv1.AccountState) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.acct = st
}

func (f *accountFake) KnownAccountState() (*relayv1.AccountState, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.acct == nil {
		return &relayv1.AccountState{}, false
	}
	return proto.Clone(f.acct).(*relayv1.AccountState), true
}

func TestHubDiagnosticsJSONKeys(t *testing.T) {
	dir := hubTestDir(t)
	linkTestPhone(t, dir) // creates the sidecar
	st, err := state.Open(dir)
	require.NoError(t, err)
	now := time.Now()
	var xs []state.LatencySample
	for i, ms := range []int64{100, 200, 300, 400} {
		at := now.Add(-time.Duration(i) * time.Minute)
		xs = append(xs,
			state.LatencySample{At: at, Transport: "relay", Step: "read_applied", MS: ms},
			state.LatencySample{At: at, Transport: "relay", Step: "read_saved", MS: ms * 2})
	}
	xs = append(xs, state.LatencySample{At: now.Add(-3 * 24 * time.Hour), Transport: "cloudkit", Step: "read_saved", MS: 900})
	require.NoError(t, st.AddLatencySamples(xs))
	_, err = st.BeginAlertPushes("ask-1", []string{"phone-a", "phone-b"}, now)
	require.NoError(t, err)
	_, err = st.SettleAlertPushes([]state.AlertPushSettle{
		{Key: "ask-1", Device: "phone-a", Outcome: state.AlertExpired, Reason: state.ReasonOverflow},
		{Key: "ask-1", Device: "phone-b", Outcome: state.AlertExpired, Reason: state.ReasonOverflow},
	}, now)
	require.NoError(t, err)
	require.NoError(t, st.Close())

	out, err := runHub(t, "diagnostics", "--json")
	require.NoError(t, err)
	m := decodeKeys(t, out)
	assert.ElementsMatch(t, []string{"window_days", "rows", "push_overflow_expired"}, hubKeysOf(m))
	assert.Equal(t, float64(7), m["window_days"])
	assert.Equal(t, float64(2), m["push_overflow_expired"])
	rows, ok := m["rows"].([]any)
	require.True(t, ok, "rows is a list")
	require.Len(t, rows, 3)
	var readSaved map[string]any
	for _, r := range rows {
		row := r.(map[string]any)
		assert.ElementsMatch(t, []string{"step", "transport", "p50_ms", "p90_ms", "samples"}, hubKeysOf(row))
		if row["step"] == "read_saved" && row["transport"] == "relay" {
			readSaved = row
		}
	}
	require.NotNil(t, readSaved, "a read_saved row on the relay")
	assert.Equal(t, float64(4), readSaved["samples"])
	assert.Equal(t, float64(400), readSaved["p50_ms"])
	assert.Equal(t, float64(800), readSaved["p90_ms"])

	// One day leaves the 3-day-old sample out.
	out, err = runHub(t, "diagnostics", "--days", "1", "--json")
	require.NoError(t, err)
	m = decodeKeys(t, out)
	assert.Equal(t, float64(1), m["window_days"])
	assert.Len(t, m["rows"], 2)
	for _, bad := range []string{"0", "8"} {
		_, err := runHub(t, "diagnostics", "--days", bad, "--json")
		assert.Error(t, err, "--days %s", bad)
	}
}

func TestHubDiagnosticsWithoutSidecarIsEmpty(t *testing.T) {
	dir := hubTestDir(t)
	out, err := runHub(t, "diagnostics", "--json")
	require.NoError(t, err)
	assert.JSONEq(t, `{"window_days":7,"rows":[],"push_overflow_expired":0}`, out)
	_, statErr := os.Stat(dir)
	assert.True(t, os.IsNotExist(statErr), "a read creates nothing")
	out, err = runHub(t, "diagnostics")
	require.NoError(t, err)
	assert.Contains(t, out, "no timings yet")
}

func TestHubAllowJSONKeys(t *testing.T) {
	dir := hubTestDir(t)
	id := linkTestPhone(t, dir)
	out, err := runHub(t, "allow", strings.ToLower(id), "typing", "--json")
	require.NoError(t, err)
	m := decodeKeys(t, out)
	assert.ElementsMatch(t, []string{"device_id", "grant", "allowed"}, hubKeysOf(m))
	assert.Equal(t, id, m["device_id"])
	assert.Equal(t, true, m["allowed"])

	out, err = runHub(t, "allow", id, "typing", "--revoke", "--json")
	require.NoError(t, err)
	assert.Equal(t, false, decodeKeys(t, out)["allowed"])

	_, err = runHub(t, "allow", id, "admin")
	assert.ErrorContains(t, err, "unknown grant")
	_, err = runHub(t, "allow", "00000000-0000-0000-0000-000000000000", "typing")
	assert.ErrorContains(t, err, "no such phone")
}

func TestHubUnlinkNameEnableJSONKeys(t *testing.T) {
	dir := hubTestDir(t)
	policytest.Set(t, nil)
	require.NoError(t, os.MkdirAll(dir, 0o700))
	ident, err := identity.New()
	require.NoError(t, err)
	require.NoError(t, identity.FileStore{Path: filepath.Join(dir, identity.FileName)}.Save(ident))
	id := linkTestPhone(t, dir)

	out, err := runHub(t, "unlink", id, "--json")
	require.NoError(t, err)
	m := decodeKeys(t, out)
	assert.ElementsMatch(t, []string{"device_id", "unlinked"}, hubKeysOf(m))
	assert.Equal(t, true, m["unlinked"])
	out, err = runHub(t, "phones", "--json")
	require.NoError(t, err)
	assert.Equal(t, "[]", strings.TrimSpace(out))

	out, err = runHub(t, "name", "Build box", "--json")
	require.NoError(t, err)
	assert.ElementsMatch(t, []string{"name"}, hubKeysOf(decodeKeys(t, out)))
	assert.Equal(t, "Build box", hubMeta(t, dir, state.MetaDisplayName))
	_, err = runHub(t, "name", strings.Repeat("n", 61))
	assert.Error(t, err)

	out, err = runHub(t, "disable", "--json")
	require.NoError(t, err)
	assert.ElementsMatch(t, []string{"enabled"}, hubKeysOf(decodeKeys(t, out)))
	assert.Equal(t, "0", hubMeta(t, dir, state.MetaEnabled))
}

func TestHubEnableWritesDirectlyWhenNoHubRuns(t *testing.T) {
	dir := hubTestDir(t)
	policytest.Set(t, nil)
	out, err := runHub(t, "enable", "--json")
	require.NoError(t, err)
	assert.Equal(t, true, decodeKeys(t, out)["enabled"])
	assert.Equal(t, "1", hubMeta(t, dir, state.MetaEnabled))

	setHubMeta(t, dir, state.MetaEnabled, "0")
	policytest.Set(t, map[string]any{"MobileSync": "off"})
	_, err = runHub(t, "enable")
	assert.ErrorContains(t, err, "policy is off")
	assert.Equal(t, "0", hubMeta(t, dir, state.MetaEnabled))
}

func TestHubOwnerVerbsRefusedUnderAgent(t *testing.T) {
	verbs := [][]string{
		{"unlink", "DEV"},
		{"allow", "DEV", "typing"},
		{"pair", "--json", "--stream"},
		{"name", "x"},
		{"enable"},
		{"disable"},
	}
	for _, v := range verbs {
		t.Run(v[0], func(t *testing.T) {
			dir := hubTestDir(t)
			t.Setenv("CLAUDECODE", "1")
			_, err := runHub(t, v...)
			require.Error(t, err)
			assert.Contains(t, err.Error(), "under an AI agent")
			_, statErr := os.Stat(dir)
			assert.True(t, os.IsNotExist(statErr), "nothing written")
		})
	}
}

func TestHubPairWithoutRunningHubFails(t *testing.T) {
	hubShortDir(t)
	_, err := runHub(t, "pair", "--json", "--stream")
	assert.ErrorContains(t, err, "the hub is not running")
	_, err = runHub(t, "pair")
	assert.Error(t, err, "not a terminal")
}

func TestHubCLIWriteGoesThroughRunningHub(t *testing.T) {
	dir := hubShortDir(t)
	setHubMeta(t, dir, state.MetaEnabled, "1")
	id := linkTestPhone(t, dir)
	startTestHub(t, dir)
	waitHubState(t, dir, hub.StateRunning)

	var opens atomic.Int32
	orig := hubOpenState
	hubOpenState = func(d string) (*state.Store, error) { opens.Add(1); return orig(d) }
	t.Cleanup(func() { hubOpenState = orig })

	out, err := runHub(t, "allow", id, "typing", "--json")
	require.NoError(t, err)
	assert.Equal(t, true, decodeKeys(t, out)["allowed"])
	out, err = runHub(t, "name", "Build box", "--json")
	require.NoError(t, err)
	assert.Equal(t, "Build box", decodeKeys(t, out)["name"])
	assert.Zero(t, opens.Load(), "the CLI never opened the sidecar for writing")

	out, err = runHub(t, "phones", "--json")
	require.NoError(t, err)
	var list []hubPhoneJSON
	require.NoError(t, json.Unmarshal([]byte(out), &list))
	require.Len(t, list, 1)
	assert.True(t, list[0].TypingAllowed)
	assert.Equal(t, "Build box", hubMeta(t, dir, state.MetaDisplayName))

	_, err = runHub(t, "allow", "00000000-0000-0000-0000-000000000000", "typing")
	assert.ErrorContains(t, err, "no such phone")
}

// pairRun is one `hub pair --json --stream` run with a scripted stdin.
type pairRun struct {
	out   *bufio.Reader
	in    *io.PipeWriter
	done  chan error
	lines []string
}

func startPair(t *testing.T) *pairRun {
	t.Helper()
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	p := &pairRun{out: bufio.NewReader(outR), in: inW, done: make(chan error, 1)}
	rootCmd.SetIn(inR)
	rootCmd.SetOut(outW)
	rootCmd.SetErr(io.Discard)
	rootCmd.SetArgs([]string{"hub", "pair", "--json", "--stream"})
	go func() {
		err := rootCmd.Execute()
		_ = outW.Close()
		p.done <- err
	}()
	t.Cleanup(func() {
		_ = inW.Close()
		_ = outR.Close()
		rootCmd.SetIn(nil)
		rootCmd.SetArgs(nil)
		for _, c := range hubCmd.Commands() {
			c.LocalNonPersistentFlags().VisitAll(func(f *pflag.Flag) { _ = f.Value.Set(f.DefValue); f.Changed = false })
		}
	})
	return p
}

func (p *pairRun) next(t *testing.T) map[string]any {
	t.Helper()
	line, err := p.out.ReadString('\n')
	require.NoError(t, err, "pair output so far: %v", p.lines)
	p.lines = append(p.lines, line)
	var m map[string]any
	require.NoError(t, json.Unmarshal([]byte(line), &m), line)
	return m
}

func (p *pairRun) wait(t *testing.T) error {
	t.Helper()
	return <-p.done
}

// pairPhone drives a pairing up to the sas line: the phone reads the QR's
// link code and says hello in a pairing slot the relay opens.
func pairPhone(t *testing.T, p *pairRun, fake *memfake.Fake) (string, map[string]any) {
	t.Helper()
	qr := p.next(t)
	assert.ElementsMatch(t, []string{"event", "url", "expires_at"}, hubKeysOf(qr))
	assert.Equal(t, "qr", qr["event"])
	waiting := p.next(t)
	assert.Equal(t, map[string]any{"event": "waiting"}, waiting)
	lp, err := wire.ParseLinkURL(qr["url"].(string))
	require.NoError(t, err)
	phone, err := hubtest.FromLink(lp, fake, nil)
	require.NoError(t, err)
	require.NoError(t, phone.Hello(transport.PairZone("slot1")))
	fake.SendEvent(transport.Event{Control: &transport.Control{Kind: transport.PairingOpened, Detail: "slot1"}})
	sas := p.next(t)
	assert.ElementsMatch(t, []string{"event", "device_id", "name", "code"}, hubKeysOf(sas))
	assert.Equal(t, "sas", sas["event"])
	assert.True(t, strings.EqualFold(phone.ID().String(), sas["device_id"].(string)))
	assert.Len(t, sas["code"], 4)
	return phone.ID().String(), sas
}

func TestHubPairStreamEvents(t *testing.T) {
	dir := hubShortDir(t)
	setHubMeta(t, dir, state.MetaEnabled, "1")
	fake := startTestHub(t, dir)
	waitHubState(t, dir, hub.StateRunning)

	t.Run("linked", func(t *testing.T) {
		p := startPair(t)
		device, _ := pairPhone(t, p, fake)
		_, err := io.WriteString(p.in, `{"confirm":true}`+"\n")
		require.NoError(t, err)
		linked := p.next(t)
		assert.ElementsMatch(t, []string{"event", "device_id"}, hubKeysOf(linked))
		assert.Equal(t, "linked", linked["event"])
		assert.True(t, strings.EqualFold(device, linked["device_id"].(string)))
		require.NoError(t, p.wait(t))
	})

	t.Run("refused", func(t *testing.T) {
		p := startPair(t)
		pairPhone(t, p, fake)
		_, err := io.WriteString(p.in, `{"confirm":false}`+"\n")
		require.NoError(t, err)
		refused := p.next(t)
		assert.ElementsMatch(t, []string{"event", "reason"}, hubKeysOf(refused))
		assert.Equal(t, "refused", refused["event"])
		assert.Equal(t, wire.RefusedNotConfirmed, refused["reason"])
		require.NoError(t, p.wait(t))
	})
}

// countStateOpens counts direct sidecar opens for writing until the test ends.
func countStateOpens(t *testing.T) *atomic.Int32 {
	t.Helper()
	var opens atomic.Int32
	orig := hubOpenState
	hubOpenState = func(d string) (*state.Store, error) { opens.Add(1); return orig(d) }
	t.Cleanup(func() { hubOpenState = orig })
	return &opens
}

// TestHubDesktopVerbsGoThroughRunningHub: spec §8 p. 4a — while a hub runs
// it writes Desktop's heartbeat and the recording jobs, so the sidecar keeps
// one writer.
func TestHubDesktopVerbsGoThroughRunningHub(t *testing.T) {
	dir := hubShortDir(t)
	setHubMeta(t, dir, state.MetaEnabled, "1")
	queueJob(t, dir, "u-1")
	startTestHub(t, dir)
	waitHubState(t, dir, hub.StateRunning)
	opens := countStateOpens(t)

	out, err := runHub(t, "desktop", "heartbeat", "--json")
	require.NoError(t, err)
	assert.NotEmpty(t, decodeKeys(t, out)["desktop_at"])
	st, err := state.OpenReadOnly(dir)
	require.NoError(t, err)
	fresh, seen, err := st.DesktopHost(time.Now())
	_ = st.Close()
	require.NoError(t, err)
	assert.True(t, fresh && seen, "the heartbeat landed")

	out, err = runHub(t, "recording", "claim", "--upload", "u-1", "--json")
	require.NoError(t, err)
	m := decodeKeys(t, out)
	assert.Equal(t, state.RecordingClaimed, m["status"])
	assert.Equal(t, filepath.Join(dir, "recordings", "u-1.m4a"), m["audio_path"])
	out, err = runHub(t, "recording", "finish", "--upload", "u-1", "--transcript", "7", "--json")
	require.NoError(t, err)
	m = decodeKeys(t, out)
	assert.Equal(t, state.RecordingDone, m["status"])
	assert.EqualValues(t, 7, m["transcript_id"])
	_, err = runHub(t, "recording", "claim", "--upload", "nope")
	assert.ErrorContains(t, err, "no recording job")
	assert.Zero(t, opens.Load(), "the CLI never opened the sidecar for writing")
}

// TestHubLinkVerbsWhileHubDisabled: the lock holder runs no hub (disabled),
// so allow and unlink are decided offline by it — never hub_off, still one
// writer.
func TestHubLinkVerbsWhileHubDisabled(t *testing.T) {
	dir := hubShortDir(t)
	require.NoError(t, os.MkdirAll(dir, 0o700))
	ident, err := identity.New()
	require.NoError(t, err)
	require.NoError(t, identity.FileStore{Path: filepath.Join(dir, identity.FileName)}.Save(ident))
	id := linkTestPhone(t, dir)
	startTestHub(t, dir)
	waitFor(t, "the hub off (disabled)", func() bool {
		s, err := hub.ReadStatus(dir)
		return err == nil && s.State == hub.StateOff && s.Reason == hub.ReasonDisabled
	})
	opens := countStateOpens(t)

	out, err := runHub(t, "allow", id, "permissions", "--json")
	require.NoError(t, err)
	assert.Equal(t, true, decodeKeys(t, out)["allowed"])
	out, err = runHub(t, "unlink", id, "--json")
	require.NoError(t, err)
	assert.Equal(t, true, decodeKeys(t, out)["unlinked"])
	_, err = runHub(t, "unlink", id)
	assert.ErrorContains(t, err, "no such phone")
	assert.Zero(t, opens.Load(), "the CLI never opened the sidecar for writing")
	out, err = runHub(t, "phones", "--json")
	require.NoError(t, err)
	assert.Equal(t, "[]", strings.TrimSpace(out))
}

// TestHubUnlinkRefusalWordedAlikeOffline: the direct path words a refusal
// through the socket's class, so both read the same.
func TestHubUnlinkRefusalWordedAlikeOffline(t *testing.T) {
	dir := hubTestDir(t)
	linkTestPhone(t, dir) // no identity file
	_, err := runHub(t, "unlink", "00000000-0000-0000-0000-000000000000")
	assert.EqualError(t, err, hubAnswerError(hub.ControlAnswer{Error: hub.ErrClassNoDevice}).Error())
	id := linkTestPhone(t, dir)
	_, err = runHub(t, "unlink", id)
	assert.EqualError(t, err, hubAnswerError(hub.ControlAnswer{Error: hub.ErrClassNoIdentity}).Error())
}
