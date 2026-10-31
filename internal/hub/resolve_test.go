package hub

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"testing"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/hub/hostkind"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/wire"
	"watchtower/internal/policy"
	"watchtower/internal/policy/policytest"
	"watchtower/internal/sessionhost"
)

// liveHome points HOME at a short fresh folder (the live hub dir's control
// socket must fit sockaddr_un), clears the hub's environment and the
// policy, and returns DefaultDir.
func liveHome(t *testing.T) string {
	t.Helper()
	base, err := os.MkdirTemp("/tmp", "hubl")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(base) })
	t.Setenv("HOME", base)
	for _, k := range []string{EnvHubDir, EnvRelayOrigin, EnvTestWorkspace, sessionhost.SocketEnv} {
		t.Setenv(k, "")
	}
	policytest.Set(t, nil)
	dir, err := DefaultDir()
	if err != nil {
		t.Fatal(err)
	}
	return dir
}

// headless is a Linux probe (always headless).
func headless() hostkind.Probe {
	return hostkind.Probe{GOOS: "linux", Stat: os.Stat, ReadFile: os.ReadFile}
}

// desktopProbe is a darwin probe whose /Applications holds the app.
func desktopProbe(home, support string) hostkind.Probe {
	return hostkind.Probe{
		GOOS: "darwin", Home: home, AppSupport: support, Stat: os.Stat,
		ReadFile: func(path string) ([]byte, error) {
			if path == "/Applications/Watchtower.app/Contents/Info.plist" {
				return []byte("<plist><dict><key>CFBundleIdentifier</key><string>" + hostkind.BundleID + "</string></dict></plist>"), nil
			}
			return nil, fs.ErrNotExist
		},
	}
}

// resolve is Resolve with the mode it put in the options beside them.
func resolve(cfg *config.Config, d *db.DB, p hostkind.Probe) (Options, Mode, error) {
	o, err := Resolve(cfg, d, p)
	return o, o.Mode, err
}

// listing is every path under root with its mode, size and mtime.
func listing(t *testing.T, root string) map[string]string {
	t.Helper()
	out := map[string]string{}
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		fi, err := d.Info()
		if err != nil {
			return err
		}
		out[path] = fi.Mode().String() + " " + fi.ModTime().Format(time.RFC3339Nano) + " " + strconv.FormatInt(fi.Size(), 10)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func TestResolve_TestModeUnchangedWhenHubDirSet(t *testing.T) {
	liveHome(t)
	dir := filepath.Join(t.TempDir(), "hub")
	t.Setenv(EnvHubDir, dir)
	t.Setenv(EnvRelayOrigin, "https://relay.example.com")
	for _, p := range []hostkind.Probe{headless(), desktopProbe("", "")} {
		for _, c := range []struct{ env, active string }{{"", "hubtest-a"}, {"hubtest-b", "hubtest-a"}, {"acme", "acme"}} {
			t.Setenv(EnvTestWorkspace, c.env)
			_, mode, err := resolve(&config.Config{ActiveWorkspace: c.active}, nil, p)
			if mode != ModeOff || !errors.Is(err, ErrNotTestWorkspace) || Refusal(err) != ReasonNotTestWorkspace {
				t.Fatalf("%+v: mode %q err %v", c, mode, err)
			}
			noEntries(t, dir)
		}
		t.Setenv(EnvTestWorkspace, "hubtest-a")
		o, mode, err := resolve(&config.Config{ActiveWorkspace: "hubtest-a"}, nil, p)
		if err != nil || mode != ModeTest || o.Mode != ModeTest || o.Dir != dir || o.RelayOrigin != "https://relay.example.com" ||
			o.RecordingsDir != filepath.Join(dir, "recordings") || o.SessionStart.Socket != "" {
			t.Fatalf("test workspace: %+v mode %q err %v", o, mode, err)
		}
		noEntries(t, dir)
		t.Setenv(EnvRelayOrigin, "")
		if _, mode, err := resolve(&config.Config{ActiveWorkspace: "hubtest-a"}, nil, p); mode != ModeOff || !errors.Is(err, ErrNoRelayOrigin) {
			t.Fatalf("a set dir fell back to live: mode %q err %v", mode, err)
		}
		t.Setenv(EnvRelayOrigin, "https://relay.example.com")
	}
	t.Setenv(EnvHubDir, "relative/hub")
	if _, mode, err := resolve(&config.Config{ActiveWorkspace: "hubtest-a"}, nil, headless()); mode != ModeOff || !errors.Is(err, ErrDirNotAbsolute) {
		t.Fatalf("relative dir: mode %q err %v", mode, err)
	}
}

// TestResolve_DesktopHostNeverStartsALiveHub is Review Focus 1: a Mac with
// the app gets no live hub even with hub_meta.enabled = 1 written by hand,
// and nothing under the live dir or MobileHub/ changes.
func TestResolve_DesktopHostNeverStartsALiveHub(t *testing.T) {
	dir := liveHome(t)
	DefaultRelayOrigin = "https://relay.example.com"
	t.Cleanup(func() { DefaultRelayOrigin = "" })
	setMeta(t, dir, state.MetaEnabled, "1")
	home, _ := os.UserHomeDir()
	support := filepath.Join(home, "Library", "Application Support", "Watchtower")
	swift := filepath.Join(support, "MobileHub")
	if err := os.MkdirAll(swift, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(swift, state.FileName), []byte("swift"), 0o600); err != nil {
		t.Fatal(err)
	}
	time.Sleep(20 * time.Millisecond) // a write by Resolve would show in the mtimes
	before, beforeSwift := listing(t, dir), listing(t, swift)

	for name, p := range map[string]hostkind.Probe{
		"app bundle": desktopProbe(home, support),
		"MobileHub/": {GOOS: "darwin", Home: home, AppSupport: support, Stat: os.Stat, ReadFile: os.ReadFile},
	} {
		o, mode, err := resolve(&config.Config{}, nil, p)
		if mode != ModeOff || !errors.Is(err, ErrDesktopHost) || Refusal(err) != ReasonDesktopHost || o.Dir != "" {
			t.Fatalf("%s: %+v mode %q err %v", name, o, mode, err)
		}
		var de *DesktopHostError
		if !errors.As(err, &de) || de.Signal == "" {
			t.Fatalf("%s: no signal in %v", name, err)
		}
		if _, _, kind, err := Dir(p); !errors.Is(err, ErrDesktopHost) || kind != hostkind.Desktop {
			t.Fatalf("%s: Dir: %v", name, err)
		}
		if r := OffReason(&config.Config{}, ModeOff); r != "" {
			t.Fatalf("%s: OffReason %q", name, r)
		}
	}
	if after := listing(t, dir); !mapsEqual(before, after) {
		t.Fatalf("the live dir changed:\n%v\n%v", before, after)
	}
	if after := listing(t, swift); !mapsEqual(beforeSwift, after) {
		t.Fatalf("MobileHub/ changed:\n%v\n%v", beforeSwift, after)
	}
}

func mapsEqual(a, b map[string]string) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if b[k] != v {
			return false
		}
	}
	return true
}

func TestResolve_LiveIsOffUntilEnabled(t *testing.T) {
	dir := liveHome(t)
	t.Setenv(EnvRelayOrigin, "https://relay.example.com")
	_, mode, err := resolve(&config.Config{}, nil, headless())
	if mode != ModeOff || !errors.Is(err, ErrHubDisabled) || Refusal(err) != ReasonDisabled {
		t.Fatalf("no sidecar: mode %q err %v", mode, err)
	}
	noEntries(t, dir)
	if r := OffReason(&config.Config{}, ModeLive); r != ReasonDisabled {
		t.Fatalf("OffReason %q", r)
	}
	noEntries(t, dir)

	setMeta(t, dir, state.MetaEnabled, "0")
	if _, mode, err := resolve(&config.Config{}, nil, headless()); mode != ModeOff || !errors.Is(err, ErrHubDisabled) {
		t.Fatalf("enabled = 0: mode %q err %v", mode, err)
	}
	setMeta(t, dir, state.MetaEnabled, "1")
	policytest.Set(t, map[string]any{"MobileSync": policy.MobileOff})
	if _, mode, err := resolve(&config.Config{}, nil, headless()); mode != ModeOff || Refusal(err) != ReasonPolicyOff {
		t.Fatalf("policy off: mode %q err %v", mode, err)
	}
	policytest.Set(t, nil)
	o, mode, err := resolve(&config.Config{}, nil, headless())
	if err != nil || mode != ModeLive || o.Mode != ModeLive || o.Host != hostkind.Headless || o.Dir != dir ||
		o.RelayOrigin != "https://relay.example.com" || o.RecordingsDir != filepath.Join(dir, "recordings") {
		t.Fatalf("enabled: %+v mode %q err %v", o, mode, err)
	}
	if _, err := os.Stat(o.RecordingsDir); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("the recordings dir was created: %v", err)
	}
	if r := OffReason(&config.Config{}, ModeLive); r != "" {
		t.Fatalf("OffReason when it would start: %q", r)
	}
}

func TestResolve_LiveNeedsARelayOrigin(t *testing.T) {
	dir := liveHome(t)
	setMeta(t, dir, state.MetaEnabled, "1")
	for _, origin := range []string{"", "relay.example.com", "http://relay.example.com", "https://relay.example.com/x"} {
		DefaultRelayOrigin = origin
		_, mode, err := resolve(&config.Config{}, nil, headless())
		if mode != ModeOff || !errors.Is(err, ErrNoRelayOrigin) || Refusal(err) != ReasonNoRelayOrigin {
			t.Fatalf("origin %q: mode %q err %v", origin, mode, err)
		}
		if r := OffReason(&config.Config{}, ModeLive); r != ReasonNoRelayOrigin {
			t.Fatalf("origin %q: OffReason %q", origin, r)
		}
	}
	DefaultRelayOrigin = ""
}

func TestRelayOriginPrecedence(t *testing.T) {
	liveHome(t)
	t.Cleanup(func() { DefaultRelayOrigin = "" })
	for _, c := range []struct{ name, def, cfg, env, want string }{
		{"ldflags default only", "https://default.example.com", "", "", "https://default.example.com"},
		{"config set overrides the default", "https://default.example.com", "https://config.example.com", "", "https://config.example.com"},
		{"env wins", "https://default.example.com", "https://config.example.com", "https://env.example.com", "https://env.example.com"},
		{"none", "", "", "", ""},
	} {
		DefaultRelayOrigin = c.def
		t.Setenv(EnvRelayOrigin, c.env)
		cfg := &config.Config{Hub: config.HubConfig{RelayOrigin: c.cfg}}
		if got := RelayOrigin(cfg); got != c.want {
			t.Fatalf("%s: %q, want %q", c.name, got, c.want)
		}
		if c.want == "" {
			setMeta(t, mustDefaultDir(t), state.MetaEnabled, "1")
			if r := OffReason(cfg, ModeLive); r != ReasonNoRelayOrigin {
				t.Fatalf("%s: reason %q", c.name, r)
			}
		}
	}
	if got := RelayOrigin(nil); got != "" {
		t.Fatalf("nil config: %q", got)
	}
}

func mustDefaultDir(t *testing.T) string {
	t.Helper()
	dir, err := DefaultDir()
	if err != nil {
		t.Fatal(err)
	}
	return dir
}

func TestCheckRelayOrigin(t *testing.T) {
	for _, ok := range []string{"https://relay.example.com", "https://relay.example.com:8443", "http://127.0.0.1:8787", "http://localhost:8787", "http://[::1]:8787"} {
		if err := CheckRelayOrigin(ok); err != nil {
			t.Fatalf("%q refused: %v", ok, err)
		}
	}
	for _, bad := range []string{"", "relay.example.com", "http://relay.example.com", "https://relay.example.com/", "https://relay.example.com/v1",
		"https://relay.example.com?x=1", "https://relay.example.com?", "https://relay.example.com#f", "https://user@relay.example.com",
		"https://relay.example.com:", "https://relay.example.com:x", "ftp://relay.example.com", "https://", "http://127.0.0.2"} {
		if err := CheckRelayOrigin(bad); !errors.Is(err, ErrBadRelayOrigin) {
			t.Fatalf("%q accepted", bad)
		}
	}
}

func TestLiveHubUsesTheDefaultSessionHostSocket(t *testing.T) {
	dir := liveHome(t)
	t.Setenv(EnvRelayOrigin, "https://relay.example.com")
	setMeta(t, dir, state.MetaEnabled, "1")
	want, err := sessionhost.DefaultSocket()
	if err != nil {
		t.Fatal(err)
	}
	d, _ := fileDB(t)
	o, _, err := resolve(&config.Config{}, d, headless())
	if err != nil || want == "" || o.SessionStart.Socket != want {
		t.Fatalf("socket %q, want %q (err %v)", o.SessionStart.Socket, want, err)
	}
	w := &wiring{}
	port, err := w.sessionPort(context.Background(), o)
	if err != nil {
		t.Fatal(err)
	}
	if _, refusing := port.(noSessionHost); refusing || w.port == nil {
		t.Fatal("the live hub got the refusing session port")
	}
	t.Cleanup(func() { _ = w.port.Close() })

	t.Setenv(sessionhost.SocketEnv, "/tmp/acme-sh.sock")
	if o, _, err := resolve(&config.Config{}, d, headless()); err != nil || o.SessionStart.Socket != "/tmp/acme-sh.sock" {
		t.Fatalf("env socket: %q, %v", o.SessionStart.Socket, err)
	}
}

// liveRun is a live Resolve's options with a test run's dir and seams.
func liveRun(t *testing.T) func(*Options) {
	t.Helper()
	dir := liveHome(t)
	t.Setenv(EnvRelayOrigin, "https://relay.example.com")
	setMeta(t, dir, state.MetaEnabled, "1")
	live, mode, err := resolve(&config.Config{}, nil, headless())
	if err != nil || mode != ModeLive {
		t.Fatalf("live Resolve: %v", err)
	}
	return func(o *Options) {
		o.RelayOrigin, o.Mode, o.Host = live.RelayOrigin, live.Mode, live.Host
	}
}

// TestLiveHubAnnouncesRelayOnly guards Phase 1 behaviour on a live hub: the
// link code and every device_grant are relay only, with no share.
func TestLiveHubAnnouncesRelayOnly(t *testing.T) {
	e := runEndToEnd(t, "", liveRun(t))
	lp, err := wire.ParseLinkURL(e.url)
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(lp.Transports, []string{wire.TransportRelay}) || lp.Transport != wire.TransportRelay ||
		lp.DataShare != nil || lp.RelayShare != nil {
		t.Fatalf("link code: %+v", lp)
	}
	s, err := ReadStatus(e.dir)
	if err != nil || s.Mode != string(ModeLive) || s.Host != string(hostkind.Headless) {
		t.Fatalf("status: %+v, %v", s, err)
	}
}

// TestLiveHubUsesTheFileIdentityStore guards the live hub's identity: the
// 0600 identity.key in the hub dir (spec §12.2).
func TestLiveHubUsesTheFileIdentityStore(t *testing.T) {
	e := runEndToEnd(t, "", liveRun(t))
	path := filepath.Join(e.dir, identity.FileName)
	fi, err := os.Stat(path)
	if err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("identity file: %v %v", fi, err)
	}
	id, err := (identity.FileStore{Path: path}).Load()
	if err != nil {
		t.Fatal(err)
	}
	id.Zero()
}

func TestHostNameStripsTheDomain(t *testing.T) {
	for _, c := range []struct {
		host string
		err  error
		want string
	}{
		{"pi-acme.local", nil, "pi-acme"}, {"pi-acme", nil, "pi-acme"}, {"", nil, "Watchtower hub"},
		{".local", nil, "Watchtower hub"}, {"x", errors.New("no name"), "Watchtower hub"},
	} {
		if got := shortHostName(func() (string, error) { return c.host, c.err }); got != c.want {
			t.Fatalf("%q: %q, want %q", c.host, got, c.want)
		}
	}
	dir := shortDir(t)
	setMeta(t, dir, state.MetaDisplayName, "acme.hub")
	st, err := state.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = st.Close() }()
	if got := (&supervisor{st: st}).hostName(); got != "acme.hub" {
		t.Fatalf("display_name: %q", got)
	}
}

// A live headless hub runs the relay-only rules (spec §7.3); the test mode
// of a set WATCHTOWER_HUB_DIR keeps Phase 1's behaviour without them.
func TestResolve_RelayOnlyRulesOnlyInLiveMode(t *testing.T) {
	dir := liveHome(t)
	t.Setenv(EnvRelayOrigin, "https://relay.example.com")
	setMeta(t, dir, state.MetaEnabled, "1")
	o, mode, err := resolve(&config.Config{}, nil, headless())
	if err != nil || mode != ModeLive || !o.RelayOnlyRules {
		t.Fatalf("live: mode %q rules %v err %v", mode, o.RelayOnlyRules, err)
	}

	t.Setenv(EnvHubDir, filepath.Join(t.TempDir(), "hub"))
	t.Setenv(EnvTestWorkspace, "hubtest-a")
	o, mode, err = resolve(&config.Config{ActiveWorkspace: "hubtest-a"}, nil, headless())
	if err != nil || mode != ModeTest || o.RelayOnlyRules {
		t.Fatalf("test mode: mode %q rules %v err %v", mode, o.RelayOnlyRules, err)
	}
}
