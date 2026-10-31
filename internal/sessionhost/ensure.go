package sessionhost

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// ensureWait bounds how long Ensure waits for a host it started to answer.
const ensureWait = 5 * time.Second

// ensurePoll is the dial retry interval while a started host comes up.
const ensurePoll = 50 * time.Millisecond

// SystemdUnit is the transient user unit the host runs as on Linux: its own
// unit, outside the daemon unit's cgroup, so a stop or restart of the daemon
// (an update) leaves every session running (PROJ-20, Linux amendment).
const SystemdUnit = "watchtower-session-host"

// ErrNoUserManager is a Linux host start that `systemd-run --user` refused.
// It comes as a *UserManagerError naming the class.
var ErrNoUserManager = errors.New("sessionhost: systemd-run --user failed")

// UserManagerError is ErrNoUserManager with its class: no_user_bus,
// not_found or exit_<code>.
type UserManagerError struct{ Class string }

func (e *UserManagerError) Error() string { return ErrNoUserManager.Error() + " (" + e.Class + ")" }

// Is makes errors.Is(err, ErrNoUserManager) hold.
func (e *UserManagerError) Is(target error) bool { return target == ErrNoUserManager }

// launcher starts `exe session-host --socket socket` and returns once it is
// started, not yet answering.
type launcher interface {
	launch(ctx context.Context, exe, socket string) error
}

// testLauncher replaces the production launcher (set by export_test.go only).
var testLauncher launcher

// Ensure makes sure a v2 host answers on socket. When nothing answers it
// starts `exe session-host --socket socket` — on Linux as the transient user
// unit SystemdUnit, elsewhere detached (its own session, no terminal, stdio
// to /dev/null) — and waits for it. A v1 host is never replaced: Ensure
// returns ErrHostV1 (and a started host would find the socket live and exit
// anyway).
func Ensure(ctx context.Context, socket, exe string) error {
	err := ping(ctx, socket)
	if err == nil || !nothingAnswers(err) {
		return err
	}
	l := testLauncher
	if l == nil {
		l = productionLauncher(runtime.GOOS, exec.LookPath)
	}
	if err := l.launch(ctx, exe, socket); err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(ctx, ensureWait)
	defer cancel()
	t := time.NewTicker(ensurePoll)
	defer t.Stop()
	for {
		err := ping(ctx, socket)
		if err == nil || !nothingAnswers(err) {
			return err
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("session host did not answer: %w", err)
		case <-t.C:
		}
	}
}

// productionLauncher is the one way the host starts on goos: on Linux always
// systemd-run (no detached fallback), elsewhere the detached spawn.
func productionLauncher(goos string, lookPath func(string) (string, error)) launcher {
	if goos == "linux" {
		return &systemdRun{lookPath: lookPath, run: runCommand, getenv: os.Getenv}
	}
	return &detached{spawn: spawnDetached}
}

// detached starts the host in its own session (darwin; on a CLI-only Mac the
// daemon's LaunchAgent sets AbandonProcessGroup, so a restart spares it).
type detached struct {
	spawn func(exe, socket string) error
}

func (d *detached) launch(_ context.Context, exe, socket string) error { return d.spawn(exe, socket) }

func spawnDetached(exe, socket string) error {
	cmd := exec.Command(exe, "session-host", "--socket", socket) // our own CLI binary
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start session host: %w", err)
	}
	go func() { _ = cmd.Wait() }() // reap the host whenever it exits
	return nil
}

// systemdRun starts the host as the transient user unit SystemdUnit.
type systemdRun struct {
	lookPath func(string) (string, error)
	// run runs argv and returns its combined output; an exit other than 0
	// is an *exec.ExitError in the chain.
	run    func(ctx context.Context, argv []string) ([]byte, error)
	getenv func(string) string
}

// argv is the unit's command line. A `systemd-run --user` unit gets the user
// manager's environment, not the caller's: PATH (so hosted sessions find
// `claude` in ~/.local/bin) and the socket override, when set, are the only
// variables passed (ask #881), so the unit holds no secret.
func (s *systemdRun) argv(bin, exe, socket string) []string {
	argv := []string{bin, "--user", "--unit=" + SystemdUnit, "--collect", "--quiet",
		"--property=UMask=0077", "--setenv=PATH=" + s.getenv("PATH")}
	if v := s.getenv(SocketEnv); v != "" {
		argv = append(argv, "--setenv="+SocketEnv+"="+v)
	}
	return append(argv, "--", exe, "session-host", "--socket", socket)
}

func (s *systemdRun) launch(ctx context.Context, exe, socket string) error {
	bin, err := s.lookPath("systemd-run")
	if err != nil {
		return &UserManagerError{Class: "not_found"}
	}
	out, err := s.run(ctx, s.argv(bin, exe, socket))
	if err == nil {
		return nil
	}
	if ctx.Err() != nil {
		return fmt.Errorf("start session host: %w", ctx.Err())
	}
	var exit *exec.ExitError
	if !errors.As(err, &exit) {
		return &UserManagerError{Class: "not_found"} // systemd-run could not be run at all
	}
	msg := strings.ToLower(string(out))
	switch {
	case strings.Contains(msg, "already exists") || strings.Contains(msg, "already loaded"):
		return nil // another Ensure started the unit first: dial it
	case strings.Contains(msg, "failed to connect to") && strings.Contains(msg, "bus"):
		return &UserManagerError{Class: "no_user_bus"}
	default:
		return &UserManagerError{Class: "exit_" + strconv.Itoa(exit.ExitCode())}
	}
}

func runCommand(ctx context.Context, argv []string) ([]byte, error) {
	out, err := exec.CommandContext(ctx, argv[0], argv[1:]...).CombinedOutput() // systemd-run, from PATH
	if err != nil {
		return out, fmt.Errorf("systemd-run: %w", err)
	}
	return out, nil
}

// ping dials and says Hello, then hangs up.
func ping(ctx context.Context, socket string) error {
	c, err := Dial(ctx, socket)
	if err != nil {
		return err
	}
	_ = c.Close()
	return nil
}

// nothingAnswers reports a dial error meaning no host serves the socket.
func nothingAnswers(err error) bool {
	return errors.Is(err, syscall.ENOENT) || errors.Is(err, syscall.ECONNREFUSED)
}
