package service

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

var testUnit = Unit{
	Exe:  "/home/acme/.local/bin/watchtower",
	Path: "/home/acme/.local/bin:/usr/local/bin:/usr/bin:/bin",
}

// fakeRunner records every command and answers from a table keyed by the
// whole command line; a missing key answers with empty output and no error.
// Nothing real is ever executed.
type fakeRunner struct {
	calls   []string
	answers map[string]fakeAnswer
}

type fakeAnswer struct {
	out string
	err error
}

func newFakeRunner() *fakeRunner { return &fakeRunner{answers: map[string]fakeAnswer{}} }

func (f *fakeRunner) on(cmdline, out string, err error) {
	f.answers[cmdline] = fakeAnswer{out: out, err: err}
}

func (f *fakeRunner) run(_ context.Context, name string, args ...string) ([]byte, error) {
	line := strings.Join(append([]string{name}, args...), " ")
	f.calls = append(f.calls, line)
	a := f.answers[line]
	return []byte(a.out), a.err
}

func (f *fakeRunner) called(prefix string) bool {
	for _, c := range f.calls {
		if strings.HasPrefix(c, prefix) {
			return true
		}
	}
	return false
}

func linuxInstaller(t *testing.T, r *fakeRunner, out *bytes.Buffer) Installer {
	t.Helper()
	home := t.TempDir()
	return Installer{GOOS: "linux", Home: home, User: "acme", UID: 1000, Run: r.run, Out: out}
}

func darwinInstaller(t *testing.T, r *fakeRunner) Installer {
	t.Helper()
	return Installer{GOOS: "darwin", Home: t.TempDir(), User: "acme", UID: 501, Run: r.run}
}

func readGolden(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", name))
	require.NoError(t, err)
	return string(b)
}

func TestSystemdUnitGolden(t *testing.T) {
	assert.Equal(t, readGolden(t, "watchtower.service.golden"), SystemdUnit(testUnit))
}

func TestLaunchdPlistGolden(t *testing.T) {
	assert.Equal(t, readGolden(t, "com.watchtower.daemon.plist.golden"), LaunchdPlist(testUnit))
}

func TestUnitsHoldNoSecret(t *testing.T) {
	t.Setenv("WATCHTOWER_TEST_TOKEN", "xoxp-secret-token")
	t.Setenv("ANTHROPIC_API_KEY", "sk-secret-key")

	unit := SystemdUnit(testUnit)
	var envLines []string
	for _, line := range strings.Split(unit, "\n") {
		if strings.HasPrefix(line, "Environment") {
			envLines = append(envLines, line)
		}
	}
	assert.Equal(t, []string{"Environment=PATH=" + testUnit.Path}, envLines,
		"the unit's only environment is PATH")

	plist := LaunchdPlist(testUnit)
	env := plist[strings.Index(plist, "<key>EnvironmentVariables</key>")+len("<key>EnvironmentVariables</key>"):]
	env = env[:strings.Index(env, "</dict>")]
	assert.Equal(t, 1, strings.Count(env, "<key>"), "the plist's only environment is PATH")
	assert.Contains(t, env, "<key>PATH</key>")

	for _, s := range []string{unit, plist} {
		assert.NotContains(t, s, "secret")
		assert.NotContains(t, s, "TOKEN")
		assert.NotContains(t, s, "KEY=")
	}
}

func TestUnitEscapesSystemdSpecifiers(t *testing.T) {
	u := SystemdUnit(Unit{Exe: "/opt/my tools/watchtower", Path: "/opt/100%/bin:/usr/bin"})
	assert.Contains(t, u, `ExecStart="/opt/my tools/watchtower" sync --daemon`)
	assert.Contains(t, u, "Environment=PATH=/opt/100%%/bin:/usr/bin")
}

func TestInstallRefusesAnUnsafeUnit(t *testing.T) {
	for name, u := range map[string]Unit{
		"relative exe": {Exe: "watchtower", Path: "/usr/bin"},
		"newline path": {Exe: "/usr/bin/watchtower", Path: "/usr/bin\nExecStartPre=/bin/evil"},
		"newline exe":  {Exe: "/usr/bin/watch\ntower", Path: "/usr/bin"},
	} {
		t.Run(name, func(t *testing.T) {
			r := newFakeRunner()
			i := linuxInstaller(t, r, &bytes.Buffer{})
			_, err := i.Install(context.Background(), u)
			require.Error(t, err)
			assert.NoFileExists(t, i.systemdUnitPath())
			assert.Empty(t, r.calls)
		})
	}
}

func TestInstallRunsSystemctlInOrder(t *testing.T) {
	r := newFakeRunner()
	r.on("loginctl show-user acme --property=Linger --value", "yes\n", nil)
	i := linuxInstaller(t, r, &bytes.Buffer{})

	st, err := i.Install(context.Background(), testUnit)
	require.NoError(t, err)

	var systemctl []string
	for _, c := range r.calls {
		if strings.HasPrefix(c, "systemctl") {
			systemctl = append(systemctl, c)
		}
	}
	require.GreaterOrEqual(t, len(systemctl), 3)
	assert.Equal(t, []string{
		"systemctl --user show-environment",
		"systemctl --user daemon-reload",
		"systemctl --user enable --now watchtower.service",
	}, systemctl[:3])
	assert.False(t, r.called("systemctl --user restart"), "a first install starts, it does not restart")

	unitPath := filepath.Join(i.Home, ".config", "systemd", "user", "watchtower.service")
	b, err := os.ReadFile(unitPath)
	require.NoError(t, err)
	assert.Equal(t, SystemdUnit(testUnit), string(b))
	info, err := os.Stat(unitPath)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm())

	assert.Equal(t, "systemd", st.Manager)
	assert.True(t, st.Installed)
	require.NotNil(t, st.Linger)
	assert.True(t, *st.Linger)
}

func TestInstallHonoursXDGConfigHome(t *testing.T) {
	r := newFakeRunner()
	i := linuxInstaller(t, r, &bytes.Buffer{})
	i.ConfigHome = filepath.Join(i.Home, "xdg")
	_, err := i.Install(context.Background(), testUnit)
	require.NoError(t, err)
	assert.FileExists(t, filepath.Join(i.Home, "xdg", "systemd", "user", "watchtower.service"))
}

func TestInstallPrintsTheLingerHintWhenOff(t *testing.T) {
	r := newFakeRunner()
	r.on("loginctl show-user acme --property=Linger --value", "no\n", nil)
	var out bytes.Buffer
	i := linuxInstaller(t, r, &out)

	st, err := i.Install(context.Background(), testUnit)
	require.NoError(t, err)
	assert.Contains(t, out.String(),
		"Run `sudo loginctl enable-linger acme` so Watchtower starts at boot and keeps running after you log out.")
	assert.Equal(t, LingerHint("acme"),
		"Run `sudo loginctl enable-linger acme` so Watchtower starts at boot and keeps running after you log out.")
	require.NotNil(t, st.Linger)
	assert.False(t, *st.Linger)
	assert.False(t, r.called("sudo"), "Watchtower never runs sudo")
	for _, c := range r.calls {
		assert.NotContains(t, c, "enable-linger", "the hint is printed, never run")
	}
}

func TestInstallRefusedWhenSystemctlUserIsUnreachable(t *testing.T) {
	r := newFakeRunner()
	r.on("systemctl --user show-environment", "", errors.New("exit status 1"))
	var out bytes.Buffer
	i := linuxInstaller(t, r, &out)
	prepared := false
	i.Prepare = func(context.Context) error { prepared = true; return nil }

	_, err := i.Install(context.Background(), testUnit)
	require.Error(t, err)
	require.ErrorIs(t, err, ErrNoUserManager)
	assert.Equal(t, "Watchtower needs a systemd user manager, and this shell cannot reach one. "+
		"Log in through a real session (a console or SSH login, not `su` or `sudo -u`), "+
		"or run `sudo loginctl enable-linger acme` for a host that should run without a login, then try again.",
		err.Error())
	assert.False(t, prepared, "no workspace and no hub enable before the user manager answers")
	assert.NoFileExists(t, i.systemdUnitPath())
	assert.Equal(t, []string{"systemctl --user show-environment"}, r.calls)
}

func TestInstallWithoutLoginctlPrintsTheHintAndContinues(t *testing.T) {
	r := newFakeRunner()
	r.on("loginctl show-user acme --property=Linger --value", "",
		fmt.Errorf("exec: \"loginctl\": %w", exec.ErrNotFound))
	var out bytes.Buffer
	i := linuxInstaller(t, r, &out)

	st, err := i.Install(context.Background(), testUnit)
	require.NoError(t, err)
	assert.Nil(t, st.Linger, "linger unknown without loginctl")
	assert.Contains(t, out.String(), LingerHint("acme"))
	assert.True(t, r.called("systemctl --user enable --now watchtower.service"))
}

func TestInstallRunsTheHooksInOrder(t *testing.T) {
	r := newFakeRunner()
	i := linuxInstaller(t, r, &bytes.Buffer{})
	var order []string
	i.HostCheck = func() error { order = append(order, "host"); return nil }
	i.Prepare = func(context.Context) error {
		order = append(order, "prepare")
		assert.NoFileExists(t, i.systemdUnitPath(), "Prepare runs before the unit is written")
		assert.True(t, r.called("systemctl --user show-environment"))
		return nil
	}
	_, err := i.Install(context.Background(), testUnit)
	require.NoError(t, err)
	assert.Equal(t, []string{"host", "prepare"}, order)
}

func TestInstallStopsAtAFailingHook(t *testing.T) {
	refused := errors.New("refused")
	for name, set := range map[string]func(*Installer){
		"host check": func(i *Installer) { i.HostCheck = func() error { return refused } },
		"prepare":    func(i *Installer) { i.Prepare = func(context.Context) error { return refused } },
	} {
		t.Run(name, func(t *testing.T) {
			r := newFakeRunner()
			i := linuxInstaller(t, r, &bytes.Buffer{})
			set(&i)
			_, err := i.Install(context.Background(), testUnit)
			require.ErrorIs(t, err, refused)
			assert.NoFileExists(t, i.systemdUnitPath())
			assert.False(t, r.called("systemctl --user enable"))
		})
	}
}

func TestInstallIsIdempotent(t *testing.T) {
	r := newFakeRunner()
	i := linuxInstaller(t, r, &bytes.Buffer{})
	_, err := i.Install(context.Background(), testUnit)
	require.NoError(t, err)
	old := time.Now().Add(-time.Hour)
	require.NoError(t, os.Chtimes(i.systemdUnitPath(), old, old))

	r.calls = nil
	_, err = i.Install(context.Background(), testUnit)
	require.NoError(t, err)
	info, err := os.Stat(i.systemdUnitPath())
	require.NoError(t, err)
	assert.True(t, info.ModTime().Equal(old), "an unchanged unit is not rewritten")
	assert.False(t, r.called("systemctl --user restart"), "no restart on a second run")
	assert.False(t, r.called("systemctl --user daemon-reload"))

	// A changed unit (a new binary path) is rewritten and restarted.
	r.calls = nil
	moved := testUnit
	moved.Exe = "/home/acme/bin/watchtower"
	_, err = i.Install(context.Background(), moved)
	require.NoError(t, err)
	b, err := os.ReadFile(i.systemdUnitPath())
	require.NoError(t, err)
	assert.Equal(t, SystemdUnit(moved), string(b))
	assert.True(t, r.called("systemctl --user daemon-reload"))
	assert.True(t, r.called("systemctl --user restart watchtower.service"))
}

func TestUninstallKeepsData(t *testing.T) {
	r := newFakeRunner()
	i := linuxInstaller(t, r, &bytes.Buffer{})
	data := filepath.Join(i.Home, ".local", "share", "watchtower")
	hubDir := filepath.Join(data, ".hub")
	require.NoError(t, os.MkdirAll(hubDir, 0o700))
	dbFile := filepath.Join(data, "default", "watchtower.db")
	require.NoError(t, os.MkdirAll(filepath.Dir(dbFile), 0o700))
	require.NoError(t, os.WriteFile(dbFile, []byte("db"), 0o600))
	require.NoError(t, os.WriteFile(filepath.Join(hubDir, "identity.key"), []byte("k"), 0o600))

	_, err := i.Install(context.Background(), testUnit)
	require.NoError(t, err)
	r.calls = nil
	st, err := i.Uninstall(context.Background())
	require.NoError(t, err)

	assert.Equal(t, []string{
		"systemctl --user disable --now watchtower.service",
		"systemctl --user daemon-reload",
	}, filterPrefix(r.calls, "systemctl --user disable", "systemctl --user daemon-reload"))
	assert.NoFileExists(t, i.systemdUnitPath())
	assert.FileExists(t, dbFile)
	assert.FileExists(t, filepath.Join(hubDir, "identity.key"))
	for _, c := range r.calls {
		assert.NotContains(t, c, "session-host", "uninstall leaves a running session-host alone")
	}
	assert.False(t, st.Installed)

	// A second uninstall finds nothing to do and does not fail.
	_, err = i.Uninstall(context.Background())
	require.NoError(t, err)
}

func TestStatusOnLinux(t *testing.T) {
	r := newFakeRunner()
	r.on("systemctl --user is-active --quiet watchtower.service", "", errors.New("exit status 3"))
	i := linuxInstaller(t, r, &bytes.Buffer{})
	st, err := i.Status(context.Background())
	require.NoError(t, err)
	assert.Equal(t, "systemd", st.Manager)
	assert.False(t, st.Installed)
	assert.False(t, st.Running)

	r = newFakeRunner()
	r.on("loginctl show-user acme --property=Linger --value", "yes\n", nil)
	i.Run = r.run
	_, err = i.Install(context.Background(), testUnit)
	require.NoError(t, err)
	st, err = i.Status(context.Background())
	require.NoError(t, err)
	assert.True(t, st.Installed)
	assert.True(t, st.Running)
	require.NotNil(t, st.Linger)
	assert.True(t, *st.Linger)
}

func TestLaunchdFallsBackToTheUserDomain(t *testing.T) {
	r := newFakeRunner()
	r.on("launchctl print gui/501", "", errors.New("exit status 113"))
	r.on("launchctl print gui/501/com.watchtower.daemon", "", errors.New("exit status 113"))
	r.on("launchctl print user/501/com.watchtower.daemon", "", errors.New("exit status 113"))
	i := darwinInstaller(t, r)

	st, err := i.Install(context.Background(), testUnit)
	require.NoError(t, err)
	plist := filepath.Join(i.Home, "Library", "LaunchAgents", "com.watchtower.daemon.plist")
	assert.True(t, r.called("launchctl bootstrap user/501 "+plist))
	assert.False(t, r.called("launchctl bootstrap gui/"))
	assert.Equal(t, "launchd", st.Manager)
	assert.Nil(t, st.Linger, "no linger on darwin")
	assert.False(t, r.called("systemctl"))
	assert.False(t, r.called("loginctl"))
}

func TestLaunchdUsesTheGUIDomainWhenLoggedIn(t *testing.T) {
	r := newFakeRunner()
	r.on("launchctl print gui/501/com.watchtower.daemon", "", errors.New("exit status 113"))
	i := darwinInstaller(t, r)

	_, err := i.Install(context.Background(), testUnit)
	require.NoError(t, err)
	plist := filepath.Join(i.Home, "Library", "LaunchAgents", "com.watchtower.daemon.plist")
	b, err := os.ReadFile(plist)
	require.NoError(t, err)
	assert.Equal(t, LaunchdPlist(testUnit), string(b))
	assert.True(t, r.called("launchctl bootstrap gui/501 "+plist))
}

func TestLaunchdInstallIsIdempotentAndUninstallKeepsData(t *testing.T) {
	r := newFakeRunner()
	r.on("launchctl print gui/501/com.watchtower.daemon", "", errors.New("exit status 113"))
	i := darwinInstaller(t, r)
	_, err := i.Install(context.Background(), testUnit)
	require.NoError(t, err)

	// Loaded now: a second install with the same plist touches nothing.
	r.on("launchctl print gui/501/com.watchtower.daemon", "state = running\n", nil)
	r.calls = nil
	st, err := i.Install(context.Background(), testUnit)
	require.NoError(t, err)
	assert.False(t, r.called("launchctl bootstrap"))
	assert.False(t, r.called("launchctl bootout"))
	assert.True(t, st.Running)

	data := filepath.Join(i.Home, ".local", "share", "watchtower", "default")
	require.NoError(t, os.MkdirAll(data, 0o700))
	r.calls = nil
	st, err = i.Uninstall(context.Background())
	require.NoError(t, err)
	assert.True(t, r.called("launchctl bootout gui/501/com.watchtower.daemon"))
	assert.NoFileExists(t, filepath.Join(i.Home, "Library", "LaunchAgents", "com.watchtower.daemon.plist"))
	assert.DirExists(t, data)
	assert.False(t, st.Installed)
}

func TestInstallRefusesAnUnsupportedOS(t *testing.T) {
	r := newFakeRunner()
	i := Installer{GOOS: "windows", Home: t.TempDir(), Run: r.run}
	_, err := i.Install(context.Background(), testUnit)
	require.ErrorIs(t, err, ErrUnsupportedOS)
	assert.Empty(t, r.calls)
}

func filterPrefix(calls []string, prefixes ...string) []string {
	var out []string
	for _, c := range calls {
		for _, p := range prefixes {
			if strings.HasPrefix(c, p) {
				out = append(out, c)
				break
			}
		}
	}
	return out
}
