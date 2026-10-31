// Package service installs the Watchtower daemon under the host's own service
// manager on a headless host: a systemd user unit on Linux, a LaunchAgent on a
// CLI-only Mac. It writes only the unit file and asks the service manager to
// load, start or stop it; it never runs sudo, never touches the workspace
// data, the hub dir or a running session-host, and the unit holds no secret
// (only PATH, FILES-01). Every external command goes through Installer.Run, so
// tests use a fake runner and never reach a real systemctl, launchctl or
// loginctl.
package service

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"

	"watchtower/internal/fsutil"
)

// SystemdUnitName is the systemd user unit's name.
const SystemdUnitName = "watchtower.service"

// LaunchdLabel is the LaunchAgent's label (and its plist's base name).
const LaunchdLabel = "com.watchtower.daemon"

// Manager names in Status.
const (
	managerSystemd = "systemd"
	managerLaunchd = "launchd"
)

// unitFileMode: the unit is read only by its own user's service manager.
const unitFileMode = 0o600

// Unit is what a unit file says: the binary and the PATH its sessions need.
type Unit struct {
	Exe  string // absolute: the path the owner invoked when it is the running binary, else os.Executable
	Path string // the installing shell's PATH
	// Flags are the global flags the install ran with (--config <abs>,
	// --workspace <name>), placed before `sync --daemon` so the daemon reads
	// the config the install wrote.
	Flags []string
}

// daemonArgv is the daemon's command line: the binary, the global flags,
// then `sync --daemon`.
func (u Unit) daemonArgv() []string {
	argv := append([]string{u.Exe}, u.Flags...)
	return append(argv, "sync", "--daemon")
}

// Runner runs an external command and returns its combined output. A missing
// binary answers with an error wrapping exec.ErrNotFound.
type Runner func(ctx context.Context, name string, args ...string) ([]byte, error)

// Installer installs, removes and reports the daemon's service.
type Installer struct {
	GOOS       string
	Home       string
	ConfigHome string // $XDG_CONFIG_HOME; "" = <Home>/.config
	User       string
	UID        int
	Run        Runner

	// Out receives the hints Install prints (the linger hint); nil discards.
	Out io.Writer
	// HostCheck, when set, runs first: an error refuses the install before
	// anything is run or written (cmd: the desktop-host refusal).
	HostCheck func() error
	// Prepare, when set, runs after the service manager answered and before
	// the unit is written (cmd: workspace init --headless, hub enable). An
	// error stops the install with no unit written.
	Prepare func(ctx context.Context) error
	// Sleep waits between launchctl bootstrap retries; nil = time.Sleep.
	Sleep func(time.Duration)
}

// Status reports the daemon's service.
type Status struct {
	Manager   string // "systemd" | "launchd"
	Installed bool   // the unit file exists
	Running   bool
	Linger    *bool // nil on darwin or when loginctl is missing or fails
}

// ErrNoUserManager means that on Linux `systemctl --user` cannot reach a user manager
// from this shell.
var ErrNoUserManager = errors.New("service: no systemd user manager is reachable")

// ErrUnsupportedOS means the OS is neither Linux nor darwin.
var ErrUnsupportedOS = errors.New("service: no supported service manager on this OS")

// noUserManagerError carries the owner's remedy as its text and unwraps to
// ErrNoUserManager.
type noUserManagerError struct{ user string }

func (e noUserManagerError) Error() string { return NoUserManagerMessage(e.user) }
func (e noUserManagerError) Unwrap() error { return ErrNoUserManager }

// NoUserManagerMessage is the pinned text of a refused Linux install.
func NoUserManagerMessage(user string) string {
	return "Watchtower needs a systemd user manager, and this shell cannot reach one. " +
		"Log in through a real session (a console or SSH login, not `su` or `sudo -u`), " +
		"or run `sudo loginctl enable-linger " + user + "` for a host that should run without a login, then try again."
}

// LingerHint is printed when linger is off or unknown. Watchtower never runs it.
func LingerHint(user string) string {
	return "Run `sudo loginctl enable-linger " + user +
		"` so Watchtower starts at boot and keeps running after you log out."
}

// Install writes the unit (rewritten only when it differs) and starts it; a
// changed unit is restarted. Idempotent.
func (i Installer) Install(ctx context.Context, u Unit) (Status, error) {
	if err := validateUnit(u); err != nil {
		return Status{}, err
	}
	switch i.GOOS {
	case "linux":
		return i.installSystemd(ctx, u)
	case "darwin":
		return i.installLaunchd(ctx, u)
	default:
		return Status{}, ErrUnsupportedOS
	}
}

// Uninstall stops and removes the unit. Data, the hub dir and a running
// session-host are left alone. Uninstalling twice is not an error.
func (i Installer) Uninstall(ctx context.Context) (Status, error) {
	switch i.GOOS {
	case "linux":
		return i.uninstallSystemd(ctx)
	case "darwin":
		return i.uninstallLaunchd(ctx)
	default:
		return Status{}, ErrUnsupportedOS
	}
}

// Status reports whether the unit is installed and running.
func (i Installer) Status(ctx context.Context) (Status, error) {
	switch i.GOOS {
	case "linux":
		return i.statusSystemd(ctx)
	case "darwin":
		return i.statusLaunchd(ctx)
	default:
		return Status{}, ErrUnsupportedOS
	}
}

func (i Installer) prepare(ctx context.Context) error {
	if i.Prepare == nil {
		return nil
	}
	return i.Prepare(ctx)
}

func (i Installer) hostCheck() error {
	if i.HostCheck == nil {
		return nil
	}
	return i.HostCheck()
}

func (i Installer) out() io.Writer {
	if i.Out == nil {
		return io.Discard
	}
	return i.Out
}

// validateUnit refuses a binary that is not absolute and any control
// character, which would let a value add lines to the unit file.
func validateUnit(u Unit) error {
	if !filepath.IsAbs(u.Exe) {
		return fmt.Errorf("service: the binary path must be absolute")
	}
	if u.Path == "" {
		return fmt.Errorf("service: PATH is empty")
	}
	for _, s := range append([]string{u.Exe, u.Path}, u.Flags...) {
		if strings.ContainsFunc(s, func(r rune) bool { return r < 0x20 || r == 0x7f }) {
			return fmt.Errorf("service: the binary path, a flag or PATH holds a control character")
		}
	}
	return nil
}

// writeIfChanged writes content to path unless the file already holds exactly
// it; changed reports a write. An identical file with another mode gets its
// mode fixed and counts as unchanged. A symlink or a directory at path is
// refused.
func writeIfChanged(path, content string) (changed bool, err error) {
	exists, err := fileExists(path)
	if err != nil {
		return false, err
	}
	if exists {
		old, err := os.ReadFile(path)
		if err != nil {
			return false, fmt.Errorf("service: reading %s: %w", filepath.Base(path), err)
		}
		if bytes.Equal(old, []byte(content)) {
			return false, fixMode(path)
		}
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return false, fmt.Errorf("service: creating the unit directory: %w", err)
	}
	if err := fsutil.WriteFileAtomic(path, []byte(content), unitFileMode); err != nil {
		return false, fmt.Errorf("service: writing %s: %w", filepath.Base(path), err)
	}
	return true, nil
}

// fixMode sets an existing unit file's mode to unitFileMode when it differs.
func fixMode(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("service: checking %s: %w", filepath.Base(path), err)
	}
	if info.Mode().Perm() == unitFileMode {
		return nil
	}
	if err := os.Chmod(path, unitFileMode); err != nil {
		return fmt.Errorf("service: setting the mode of %s: %w", filepath.Base(path), err)
	}
	return nil
}

// fileExists reports a regular file at path (not followed through a
// symlink). Anything else at path — a symlink, a directory — is an error, as
// is any failure but "not there".
func fileExists(path string) (bool, error) {
	info, err := os.Lstat(path)
	if errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("service: checking %s: %w", filepath.Base(path), err)
	}
	if !info.Mode().IsRegular() {
		return false, fmt.Errorf("service: %s is not a regular file", filepath.Base(path))
	}
	return true, nil
}

// runErr wraps a failed service-manager command with the first line of its
// output, for the owner's terminal.
func runErr(cmdline string, out []byte, err error) error {
	line, _, _ := strings.Cut(strings.TrimSpace(string(out)), "\n")
	if len(line) > 200 {
		line = line[:200]
	}
	if line == "" {
		return fmt.Errorf("service: %s: %w", cmdline, err)
	}
	return fmt.Errorf("service: %s: %w (%s)", cmdline, err, line)
}

func removeIfExists(path string) error {
	if err := os.Remove(path); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("service: removing %s: %w", filepath.Base(path), err)
	}
	return nil
}
