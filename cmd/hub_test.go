package cmd

import (
	"bufio"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/spf13/pflag"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/hub"
	"watchtower/internal/hub/hostkind"
	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
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
	p, err := hubtest.New(hubtest.Config{})
	require.NoError(t, err)
	st, err := state.Open(dir)
	require.NoError(t, err)
	defer func() { _ = st.Close() }()
	require.NoError(t, st.WithTx(context.Background(), func(tx *sql.Tx) error { return state.LinkDevice(tx, p.Device()) }))
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
	policytest.Set(t, nil)
	fake := memfake.New(transport.KindRelay, nil)
	o := hub.Options{Dir: dir}.WithTransport(func(context.Context, identity.Identity, *state.Store, []string) (transport.Transport, error) {
		return fake, nil
	})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- hub.Run(ctx, o) }()
	t.Cleanup(func() {
		cancel()
		select {
		case <-done:
		case <-time.After(10 * time.Second):
			t.Error("hub.Run did not return")
		}
	})
	waitFor(t, "the control socket", func() bool {
		_, err := os.Stat(filepath.Join(dir, hub.SocketName))
		return err == nil
	})
	return fake
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(20 * time.Millisecond)
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
	assert.ElementsMatch(t, []string{"state", "reason", "hub_id", "relay_device_id", "transport", "impl", "dir", "phones", "recordings", "host", "mode"}, hubKeysOf(m))
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
	origProbe, origConfig := hubProbe, flagConfig
	hubProbe = func() hostkind.Probe { return p }
	cfgPath = filepath.Join(base, "config.yaml")
	require.NoError(t, os.WriteFile(cfgPath, []byte("active_workspace: acme\n"), 0o600))
	flagConfig = cfgPath
	t.Cleanup(func() { hubProbe, flagConfig = origProbe, origConfig })
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
	flagConfig = cfgPath // runHub reset the inherited --config flag to its default
	out, err = runHub(t, "status")
	require.NoError(t, err)
	assert.NotContains(t, out, "Set the relay")
	assert.NotContains(t, out, "no_relay_origin")
}

// TestHubCLIRefusesTheLiveDirOnADesktopHost is Review Focus 1 on the CLI: a
// Mac with the app shows off/desktop_host, every other verb exits 1, and
// nothing is created under the live dir.
func TestHubCLIRefusesTheLiveDirOnADesktopHost(t *testing.T) {
	desktop := hostkind.Probe{GOOS: "darwin", Stat: os.Stat, ReadFile: func(p string) ([]byte, error) {
		if p == "/Applications/Watchtower.app/Contents/Info.plist" {
			return []byte("<key>CFBundleIdentifier</key><string>" + hostkind.BundleID + "</string>"), nil
		}
		return nil, fs.ErrNotExist
	}}
	live, _ := hubLiveCLI(t, desktop)
	out, err := runHub(t, "status", "--json")
	require.NoError(t, err)
	m := decodeKeys(t, out)
	assert.Equal(t, hub.StateOff, m["state"])
	assert.Equal(t, hub.ReasonDesktopHost, m["reason"])
	assert.Equal(t, string(hostkind.Desktop), m["host"])
	assert.Equal(t, "", m["dir"])
	for _, args := range [][]string{
		{"enable"}, {"disable"}, {"phones"}, {"name", "acme"}, {"unlink", "X"}, {"allow", "X", "typing"}, {"pair", "--json", "--stream"},
	} {
		_, err := runHub(t, args...)
		require.Error(t, err, "%v", args)
		assert.Equal(t, "Mobile on this Mac is run by the Watchtower app.", err.Error(), "%v", args)
	}
	_, err = os.Stat(live)
	assert.True(t, errors.Is(err, fs.ErrNotExist), "the live dir was created on a desktop host")
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
		"last_applied_action_seq", "transport"}, hubKeysOf(list[0]))
	assert.Equal(t, id, list[0]["device_id"])
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
	assert.Error(t, err, "the terminal flow is phase 2")
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
			c.Flags().VisitAll(func(f *pflag.Flag) { _ = f.Value.Set(f.DefValue); f.Changed = false })
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
	select {
	case err := <-p.done:
		return err
	case <-time.After(10 * time.Second):
		t.Fatal("hub pair did not finish")
		return nil
	}
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
