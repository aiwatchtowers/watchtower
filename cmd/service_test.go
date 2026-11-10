package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strings"
	"testing"

	"github.com/spf13/pflag"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/hub/hostkind"
	"watchtower/internal/hub/state"
	"watchtower/internal/service"
)

// serviceFake answers the service manager's commands from a table keyed by
// the whole command line; nothing real is ever run.
type serviceFake struct {
	calls   []string
	answers map[string]error
	outputs map[string]string
}

func (f *serviceFake) run(_ context.Context, name string, args ...string) ([]byte, error) {
	line := strings.Join(append([]string{name}, args...), " ")
	f.calls = append(f.calls, line)
	return []byte(f.outputs[line]), f.answers[line]
}

func currentUsername(t *testing.T) string {
	t.Helper()
	u, err := user.Current()
	require.NoError(t, err)
	return u.Username
}

// serviceCLI is a `service` run on a host p with GOOS goos and a fake
// service manager: hubLiveCLI's fresh HOME, config (active_workspace: acme)
// and probe, no XDG_CONFIG_HOME. It returns the fake and the live hub dir.
func serviceCLI(t *testing.T, goos string, p hostkind.Probe) (*serviceFake, string) {
	t.Helper()
	live, _ := hubLiveCLI(t, p)
	t.Setenv("XDG_CONFIG_HOME", "")
	f := &serviceFake{answers: map[string]error{}}
	origGOOS, origRunner := serviceGOOS, serviceRunner
	serviceGOOS, serviceRunner = goos, f.run
	t.Cleanup(func() { serviceGOOS, serviceRunner = origGOOS, origRunner })
	home, err := os.UserHomeDir()
	require.NoError(t, err)
	fakeServiceBinary(t, filepath.Join(home, "bin", "watchtower"), filepath.Join(home, "tmp"))
	return f, live
}

// fakeServiceBinary makes serviceExe see exe (created) as the running binary,
// os.Args[0] not found on PATH, and tmp as the temp dir.
func fakeServiceBinary(t *testing.T, exe, tmp string) {
	t.Helper()
	require.NoError(t, os.MkdirAll(filepath.Dir(exe), 0o700))
	require.NoError(t, os.WriteFile(exe, []byte("#!/bin/sh\n"), 0o700))
	origArgs0, origExe, origLook, origTmp := serviceArgs0, serviceExecutable, serviceLookPath, serviceTempDir
	serviceArgs0 = func() string { return "watchtower" }
	serviceExecutable = func() (string, error) { return exe, nil }
	serviceLookPath = func(string) (string, error) { return "", exec.ErrNotFound }
	serviceTempDir = func() string { return tmp }
	t.Cleanup(func() {
		serviceArgs0, serviceExecutable, serviceLookPath, serviceTempDir = origArgs0, origExe, origLook, origTmp
	})
}

func TestServiceUnitCarriesTheGlobalFlags(t *testing.T) {
	serviceCLI(t, "linux", linuxProbe())
	cfgPath := flagConfig
	_, err := runService(t, "install", "--workspace", "acme")
	require.NoError(t, err)
	b, err := os.ReadFile(systemdUnitFile(t))
	require.NoError(t, err)
	home, err := os.UserHomeDir()
	require.NoError(t, err)
	assert.Contains(t, string(b), "ExecStart="+filepath.Join(home, "bin", "watchtower")+
		" --config "+cfgPath+" --workspace acme sync --daemon\n")
}

func TestServiceExePrefersTheInvokedPath(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "opt", "watchtower-1.2.3")
	link := filepath.Join(dir, "bin", "watchtower")
	fakeServiceBinary(t, target, filepath.Join(dir, "tmp"))
	require.NoError(t, os.MkdirAll(filepath.Dir(link), 0o700))
	require.NoError(t, os.Symlink(target, link))

	// The invoked path resolves to the running binary: the stable symlink.
	serviceLookPath = func(name string) (string, error) {
		assert.Equal(t, "watchtower", name)
		return link, nil
	}
	exe, err := serviceExe()
	require.NoError(t, err)
	assert.Equal(t, link, exe)

	// It resolves to another file: os.Executable.
	other := filepath.Join(dir, "bin", "other")
	require.NoError(t, os.WriteFile(other, []byte("x"), 0o700))
	serviceLookPath = func(string) (string, error) { return other, nil }
	exe, err = serviceExe()
	require.NoError(t, err)
	assert.Equal(t, target, exe)

	// Not found on PATH: os.Executable.
	serviceLookPath = func(string) (string, error) { return "", exec.ErrNotFound }
	exe, err = serviceExe()
	require.NoError(t, err)
	assert.Equal(t, target, exe)
}

func TestServiceExeRefusesATemporaryBuild(t *testing.T) {
	dir := t.TempDir()
	for name, exe := range map[string]string{
		"temp dir":       filepath.Join(dir, "tmp", "x", "watchtower"),
		"go build cache": filepath.Join(dir, "cache", "go-build123", "b001", "exe", "watchtower"),
	} {
		t.Run(name, func(t *testing.T) {
			fakeServiceBinary(t, exe, filepath.Join(dir, "tmp"))
			_, err := serviceExe()
			require.Error(t, err)
			assert.Contains(t, err.Error(), "temporary build")
		})
	}
}

func TestServiceInstallRefusesATemporaryBuildBeforeWritingAnything(t *testing.T) {
	f, live := serviceCLI(t, "linux", linuxProbe())
	home, err := os.UserHomeDir()
	require.NoError(t, err)
	fakeServiceBinary(t, filepath.Join(home, "go-build42", "exe", "watchtower"), filepath.Join(home, "tmp"))
	_, err = runService(t, "install")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "temporary build")
	assert.Empty(t, f.calls)
	assert.NoFileExists(t, systemdUnitFile(t))
	assert.NoDirExists(t, workspaceDir(t, "acme"))
	assert.NoDirExists(t, live)
}

func runService(t *testing.T, args ...string) (string, error) {
	t.Helper()
	// Only the verbs' own flags are reset: resetting the inherited --config
	// would point the next run at the real config file.
	cfgPath, ws := flagConfig, flagWorkspace
	var out, errOut bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&errOut)
	rootCmd.SetArgs(append([]string{"service", "--config", cfgPath}, args...))
	err := rootCmd.Execute()
	rootCmd.SetArgs(nil)
	for _, c := range serviceCmd.Commands() {
		c.LocalNonPersistentFlags().VisitAll(func(f *pflag.Flag) { _ = f.Value.Set(f.DefValue); f.Changed = false })
	}
	flagConfig, flagWorkspace = cfgPath, ws
	return out.String(), err
}

func desktopProbe() hostkind.Probe {
	return hostkind.Probe{GOOS: "darwin", Stat: os.Stat, ReadFile: func(p string) ([]byte, error) {
		if p == "/Applications/Watchtower.app/Contents/Info.plist" {
			return []byte("<key>CFBundleIdentifier</key><string>" + hostkind.BundleID + "</string>"), nil
		}
		return nil, fs.ErrNotExist
	}}
}

func cliOnlyMacProbe() hostkind.Probe {
	return hostkind.Probe{GOOS: "darwin", AppSupport: "/nonexistent-app-support",
		Stat:     func(string) (os.FileInfo, error) { return nil, fs.ErrNotExist },
		ReadFile: func(string) ([]byte, error) { return nil, fs.ErrNotExist }}
}

func workspaceDir(t *testing.T, name string) string {
	t.Helper()
	root, err := config.DataRoot()
	require.NoError(t, err)
	return filepath.Join(root, name)
}

func systemdUnitFile(t *testing.T) string {
	t.Helper()
	home, err := os.UserHomeDir()
	require.NoError(t, err)
	return filepath.Join(home, ".config", "systemd", "user", service.SystemdUnitName)
}

func TestInstallRefusedOnADesktopHost(t *testing.T) {
	f, live := serviceCLI(t, "darwin", desktopProbe())
	_, err := runService(t, "install")
	require.Error(t, err)
	assert.Equal(t, "This Mac has the Watchtower app, which runs the daemon itself.", err.Error())
	assert.Empty(t, f.calls, "nothing run")
	home, herr := os.UserHomeDir()
	require.NoError(t, herr)
	assert.NoFileExists(t, filepath.Join(home, "Library", "LaunchAgents", service.LaunchdLabel+".plist"))
	assert.NoDirExists(t, workspaceDir(t, "acme"), "no workspace created")
	assert.NoDirExists(t, live, "no hub dir created")
}

func TestServiceVerbsRefusedUnderAnAgentMarker(t *testing.T) {
	f, live := serviceCLI(t, "linux", linuxProbe())
	t.Setenv("CLAUDECODE", "1")
	for _, verb := range []string{"install", "uninstall"} {
		_, err := runService(t, verb)
		require.Error(t, err, verb)
		assert.Contains(t, err.Error(), "under an AI agent", verb)
	}
	assert.Empty(t, f.calls, "nothing run under an agent")
	assert.NoFileExists(t, systemdUnitFile(t))
	assert.NoDirExists(t, workspaceDir(t, "acme"))
	assert.NoDirExists(t, live)

	// status reads only: allowed.
	_, err := runService(t, "status")
	require.NoError(t, err)
}

func TestServiceStatusJSONKeys(t *testing.T) {
	for _, tc := range []struct {
		goos    string
		probe   hostkind.Probe
		manager string
		linger  string
	}{
		{"linux", linuxProbe(), `"systemd"`, "true"},
		{"darwin", cliOnlyMacProbe(), `"launchd"`, "null"},
	} {
		t.Run(tc.goos, func(t *testing.T) {
			f, _ := serviceCLI(t, tc.goos, tc.probe)
			f.outputs = map[string]string{"loginctl show-user " + currentUsername(t) + " --property=Linger --value": "yes\n"}
			out, err := runService(t, "status", "--json")
			require.NoError(t, err)
			var m map[string]json.RawMessage
			require.NoError(t, json.Unmarshal([]byte(out), &m))
			assert.ElementsMatch(t, []string{"manager", "installed", "running", "linger"}, mapKeys(m))
			assert.Equal(t, tc.manager, string(m["manager"]))
			assert.Equal(t, tc.linger, string(m["linger"]), "linger is null on darwin")
		})
	}
}

func TestServiceInstallRefusedWhenSystemctlUserIsUnreachable(t *testing.T) {
	f, live := serviceCLI(t, "linux", linuxProbe())
	f.answers["systemctl --user show-environment"] = errors.New("exit status 1")
	_, err := runService(t, "install")
	require.Error(t, err)
	require.ErrorIs(t, err, service.ErrNoUserManager)
	assert.Contains(t, err.Error(), "Watchtower needs a systemd user manager, and this shell cannot reach one.")
	assert.Equal(t, []string{"systemctl --user show-environment"}, f.calls)
	assert.NoFileExists(t, systemdUnitFile(t))
	assert.NoDirExists(t, workspaceDir(t, "acme"), "no workspace before the user manager answers")
	assert.NoDirExists(t, live, "no hub enable before the user manager answers")
}

func TestServiceInstallSetsUpAHeadlessLinuxHost(t *testing.T) {
	f, live := serviceCLI(t, "linux", linuxProbe())
	require.NoError(t, os.Remove(flagConfig)) // a fresh host: no config yet

	out, err := runService(t, "install")
	require.NoError(t, err)
	assert.Contains(t, out, "manager: systemd")
	assert.Contains(t, out, "Next: watchtower hub pair")
	assert.Contains(t, out, "sudo loginctl enable-linger", "the hint is printed (linger unknown)")

	assert.FileExists(t, systemdUnitFile(t))
	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	assert.Equal(t, defaultWorkspaceName, cfg.ActiveWorkspace)
	assert.False(t, cfg.Digest.Enabled, "the headless profile")
	assert.DirExists(t, workspaceDir(t, defaultWorkspaceName))
	assert.Equal(t, "1", hubMeta(t, live, state.MetaEnabled))
	assert.Contains(t, f.calls, "systemctl --user enable --now watchtower.service")
	for _, c := range f.calls {
		assert.NotContains(t, c, "sudo")
	}

	// --json: one JSON line on stdout (the hint goes to stderr).
	out, err = runService(t, "install", "--json")
	require.NoError(t, err)
	assert.Equal(t, 1, strings.Count(out, "\n"), "%q", out)
	var m map[string]json.RawMessage
	require.NoError(t, json.Unmarshal([]byte(out), &m))
	assert.Equal(t, `"systemd"`, string(m["manager"]))
}

func TestServiceUninstallKeepsTheWorkspaceAndTheHub(t *testing.T) {
	_, live := serviceCLI(t, "linux", linuxProbe())
	_, err := runService(t, "install")
	require.NoError(t, err)

	out, err := runService(t, "uninstall", "--json")
	require.NoError(t, err)
	var m map[string]json.RawMessage
	require.NoError(t, json.Unmarshal([]byte(out), &m))
	assert.Equal(t, "false", string(m["installed"]))
	assert.NoFileExists(t, systemdUnitFile(t))
	assert.DirExists(t, workspaceDir(t, "acme"))
	assert.Equal(t, "1", hubMeta(t, live, state.MetaEnabled))
}
