package sessionhost

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// serveOn runs an in-process host on socket (a stand-in for a host that a
// launcher started) until the test ends.
func serveOn(t *testing.T, socket string) {
	t.Helper()
	l, err := Listen(socket)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { _ = NewServer(Options{}).Serve(ctx, l); close(done) }()
	t.Cleanup(func() { cancel(); <-done })
}

// markerExe is a fake watchtower that leaves a mark when run.
func markerExe(t *testing.T) (exe, marker string) {
	t.Helper()
	dir := t.TempDir()
	exe = filepath.Join(dir, "fake-watchtower")
	marker = filepath.Join(dir, "started")
	if err := os.WriteFile(exe, []byte("#!/bin/sh\ntouch "+marker+"\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	return exe, marker
}

func assertNotRun(t *testing.T, marker string) {
	t.Helper()
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("the host binary was run directly")
	}
}

func fakeLookPath(name string) (string, error) { return "/usr/bin/" + name, nil }

// exitError is a real *exec.ExitError with code (a reaped /bin/sh).
func exitError(t *testing.T, code string) error {
	t.Helper()
	err := exec.Command("/bin/sh", "-c", "exit "+code).Run()
	var exit *exec.ExitError
	if !errors.As(err, &exit) {
		t.Fatalf("exit %s = %v", code, err)
	}
	return err
}

// linuxLauncher is the production Linux launcher with run replaced.
func linuxLauncher(t *testing.T, lookPath func(string) (string, error),
	run func(context.Context, []string) ([]byte, error),
) *systemdRun {
	t.Helper()
	l, ok := productionLauncher("linux", lookPath).(*systemdRun)
	if !ok {
		t.Fatalf("productionLauncher(linux) = %T, want *systemdRun", l)
	}
	l.run = run
	return l
}

// Guard: on Linux the host starts only through systemd-run, whatever the
// environment says (no systemd marker, no PATH).
func TestProductionLauncherOnLinuxIsSystemdRun(t *testing.T) {
	for _, env := range []map[string]string{
		{"INVOCATION_ID": "", "PATH": ""},
		{"INVOCATION_ID": "abc", "DBUS_SESSION_BUS_ADDRESS": ""},
		{"XDG_RUNTIME_DIR": ""},
	} {
		for k, v := range env {
			t.Setenv(k, v)
		}
		if l := productionLauncher("linux", exec.LookPath); reflect.TypeOf(l) != reflect.TypeOf(&systemdRun{}) {
			t.Fatalf("productionLauncher(linux) with %v = %T, want *systemdRun", env, l)
		}
	}
	if l := productionLauncher("darwin", exec.LookPath); reflect.TypeOf(l) != reflect.TypeOf(&detached{}) {
		t.Fatalf("productionLauncher(darwin) = %T, want *detached", l)
	}
}

// Guard: sessionhosttest is a test-only package; no non-test package
// imports it.
func TestSessionhosttestIsImportedOnlyByTests(t *testing.T) {
	const pkg = "watchtower/internal/sessionhost/sessionhosttest"
	cmd := exec.Command("go", "list", "-f", "{{.ImportPath}} {{join .Imports \" \"}}", "watchtower/...")
	cmd.Dir = filepath.Join("..", "..")
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("go list: %v", err)
	}
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 || fields[0] == pkg {
			continue
		}
		for _, imp := range fields[1:] {
			if imp == pkg {
				t.Errorf("%s imports %s from a non-test file", fields[0], pkg)
			}
		}
	}
}

// Review Focus 2: the host runs as its own transient unit, never as a child
// of the caller, so a daemon unit restart keeps every session.
func TestEnsureUnderSystemdUsesATransientUnit(t *testing.T) {
	t.Setenv("PATH", "/home/owner/.local/bin:/usr/bin:/bin")
	for _, tc := range []struct {
		name, socketEnv string
		want            []string
	}{
		{"no socket override", "", []string{"/usr/bin/systemd-run", "--user", "--unit=watchtower-session-host",
			"--collect", "--quiet", "--property=UMask=0077", "--setenv=PATH=/home/owner/.local/bin:/usr/bin:/bin",
			"--", "/opt/watchtower/watchtower", "session-host", "--socket", "SOCKET"}},
		{"socket override", "/run/user/1000/h.sock", []string{"/usr/bin/systemd-run", "--user",
			"--unit=watchtower-session-host", "--collect", "--quiet", "--property=UMask=0077",
			"--setenv=PATH=/home/owner/.local/bin:/usr/bin:/bin",
			"--setenv=WATCHTOWER_SESSION_HOST_SOCKET=/run/user/1000/h.sock",
			"--", "/opt/watchtower/watchtower", "session-host", "--socket", "SOCKET"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv(SocketEnv, tc.socketEnv)
			socket := socketPath(t)
			var got [][]string
			useLauncher(t, linuxLauncher(t, fakeLookPath, func(_ context.Context, argv []string) ([]byte, error) {
				got = append(got, argv)
				serveOn(t, socket)
				return nil, nil
			}))
			ctx := ctxT(t)
			if err := Ensure(ctx, socket, "/opt/watchtower/watchtower"); err != nil {
				t.Fatal(err)
			}
			want := append([]string(nil), tc.want...)
			want[len(want)-1] = socket
			if len(got) != 1 || !reflect.DeepEqual(got[0], want) {
				t.Fatalf("systemd-run argv = %q, want %q", got, want)
			}
			cl, err := Dial(ctx, socket)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = cl.Close() }()
			if cl.Pid() != os.Getpid() {
				t.Fatalf("host pid %d: Ensure started a process", cl.Pid())
			}
		})
	}
}

// No systemd marker in the environment still means systemd-run, and a
// refused systemd-run is never followed by a direct spawn.
func TestEnsureOnLinuxNeverSpawnsDetached(t *testing.T) {
	t.Setenv("INVOCATION_ID", "")
	if err := os.Unsetenv("INVOCATION_ID"); err != nil {
		t.Fatal(err)
	}
	exe, marker := markerExe(t)
	var looked []string
	calls := 0
	useLauncher(t, linuxLauncher(t, func(name string) (string, error) {
		looked = append(looked, name)
		return fakeLookPath(name)
	}, func(context.Context, []string) ([]byte, error) {
		calls++
		return []byte("Job failed\n"), exitError(t, "1")
	}))
	err := Ensure(ctxT(t), socketPath(t), exe)
	if !errors.Is(err, ErrNoUserManager) {
		t.Fatalf("Ensure = %v, want ErrNoUserManager", err)
	}
	if calls != 1 || !reflect.DeepEqual(looked, []string{"systemd-run"}) {
		t.Fatalf("systemd-run calls = %d, looked up %q", calls, looked)
	}
	assertNotRun(t, marker)
}

func TestEnsureOnDarwinSpawnsDetached(t *testing.T) {
	looked := 0
	l, ok := productionLauncher("darwin", func(string) (string, error) { looked++; return "", exec.ErrNotFound }).(*detached)
	if !ok {
		t.Fatalf("productionLauncher(darwin) = %T, want *detached", l)
	}
	socket := socketPath(t)
	var spawned [][2]string
	l.spawn = func(exe, sock string) error {
		spawned = append(spawned, [2]string{exe, sock})
		serveOn(t, sock)
		return nil
	}
	useLauncher(t, l)
	if err := Ensure(ctxT(t), socket, "/opt/watchtower/watchtower"); err != nil {
		t.Fatal(err)
	}
	if want := [][2]string{{"/opt/watchtower/watchtower", socket}}; !reflect.DeepEqual(spawned, want) {
		t.Fatalf("spawned %q, want %q", spawned, want)
	}
	if looked != 0 {
		t.Fatal("darwin looked up systemd-run")
	}
}

// A refused systemd-run is ErrNoUserManager with its class; nothing runs.
func TestSystemdRunFailureIsASessionStartError(t *testing.T) {
	for _, tc := range []struct {
		name, class string
		lookPath    func(string) (string, error)
		out         string
		code        string
	}{
		{"no user bus", "no_user_bus", fakeLookPath,
			"Failed to connect to bus: No medium found\n", "1"},
		{"no user bus, scope wording", "no_user_bus", fakeLookPath,
			"Failed to connect to user scope bus via local transport: No such file or directory\n", "1"},
		{"systemd-run not on PATH", "not_found", func(string) (string, error) { return "", exec.ErrNotFound }, "", ""},
		{"another exit", "exit_1", fakeLookPath, "Job for watchtower-session-host.service failed.\n", "1"},
		{"another exit code", "exit_4", fakeLookPath, "Unknown assignment\n", "4"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			exe, marker := markerExe(t)
			useLauncher(t, linuxLauncher(t, tc.lookPath, func(context.Context, []string) ([]byte, error) {
				return []byte(tc.out), exitError(t, tc.code)
			}))
			err := Ensure(ctxT(t), socketPath(t), exe)
			if !errors.Is(err, ErrNoUserManager) {
				t.Fatalf("Ensure = %v, want ErrNoUserManager", err)
			}
			var um *UserManagerError
			if !errors.As(err, &um) || um.Class != tc.class {
				t.Fatalf("Ensure = %v, want class %s", err, tc.class)
			}
			assertNotRun(t, marker)
		})
	}
}

// systemd-run saying the unit exists means another Ensure won the race:
// dial again, no error.
func TestEnsureTreatsAnExistingUnitAsRunning(t *testing.T) {
	for _, out := range []string{
		"Failed to start transient service unit: Unit watchtower-session-host.service already exists.\n",
		"Failed to start transient service unit: Unit watchtower-session-host.service was already loaded or has a fragment file.\n",
	} {
		socket := socketPath(t)
		useLauncher(t, linuxLauncher(t, fakeLookPath, func(context.Context, []string) ([]byte, error) {
			serveOn(t, socket) // the winner's host
			return []byte(out), exitError(t, "1")
		}))
		if err := Ensure(ctxT(t), socket, "/opt/watchtower/watchtower"); err != nil {
			t.Fatalf("Ensure after %q = %v", out, err)
		}
	}
}
