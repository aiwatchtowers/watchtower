package service

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"
)

// SystemdUnit renders the systemd user unit that runs `<exe> sync --daemon`.
// Its only environment is PATH (FILES-01).
func SystemdUnit(u Unit) string {
	var b strings.Builder
	b.WriteString("[Unit]\n")
	b.WriteString("Description=Watchtower daemon (workbenches and the phone hub)\n")
	b.WriteString("After=network-online.target\n")
	b.WriteString("Wants=network-online.target\n")
	b.WriteString("\n[Service]\n")
	b.WriteString("Type=simple\n")
	b.WriteString("ExecStart=" + systemdExecArg(u.Exe) + " sync --daemon\n")
	b.WriteString("Restart=on-failure\n")
	b.WriteString("RestartSec=10\n")
	b.WriteString("TimeoutStopSec=30\n")
	b.WriteString("UMask=0077\n")
	b.WriteString("Environment=" + systemdQuote("PATH="+systemdSpecifiers(u.Path)) + "\n")
	b.WriteString("\n[Install]\n")
	b.WriteString("WantedBy=default.target\n")
	return b.String()
}

// systemdSpecifiers escapes '%', which systemd expands as a specifier.
func systemdSpecifiers(s string) string { return strings.ReplaceAll(s, "%", "%%") }

// systemdExecArg escapes one ExecStart word: specifiers, '$' variable
// expansion, and quotes when the word holds whitespace, a quote or a backslash.
func systemdExecArg(s string) string {
	return systemdQuote(strings.ReplaceAll(systemdSpecifiers(s), "$", "$$"))
}

func systemdQuote(s string) string {
	if !strings.ContainsAny(s, " \t\"'\\") {
		return s
	}
	r := strings.NewReplacer(`\`, `\\`, `"`, `\"`)
	return `"` + r.Replace(s) + `"`
}

func (i Installer) systemdUnitPath() string {
	base := i.ConfigHome
	if base == "" {
		base = filepath.Join(i.Home, ".config")
	}
	return filepath.Join(base, "systemd", "user", SystemdUnitName)
}

func (i Installer) systemctl(ctx context.Context, args ...string) error {
	full := append([]string{"--user"}, args...)
	out, err := i.Run(ctx, "systemctl", full...)
	if err != nil {
		return runErr("systemctl "+strings.Join(full, " "), out, err)
	}
	return nil
}

func (i Installer) installSystemd(ctx context.Context, u Unit) (Status, error) {
	if err := i.hostCheck(); err != nil {
		return Status{}, err
	}
	// Nothing is written until the user manager answers: a `su` shell or a
	// login with no user bus would leave a unit that never starts.
	if _, err := i.Run(ctx, "systemctl", "--user", "show-environment"); err != nil {
		return Status{}, noUserManagerError{user: i.User}
	}
	linger := i.linger(ctx)
	if linger == nil || !*linger {
		fmt.Fprintln(i.out(), LingerHint(i.User))
	}
	if err := i.prepare(ctx); err != nil {
		return Status{}, err
	}

	path := i.systemdUnitPath()
	existed, err := fileExists(path)
	if err != nil {
		return Status{}, err
	}
	changed, err := writeIfChanged(path, SystemdUnit(u))
	if err != nil {
		return Status{}, err
	}
	if changed {
		if err := i.systemctl(ctx, "daemon-reload"); err != nil {
			return Status{}, err
		}
	}
	// enable --now starts a stopped unit and leaves a running one alone.
	if err := i.systemctl(ctx, "enable", "--now", SystemdUnitName); err != nil {
		return Status{}, err
	}
	if changed && existed {
		if err := i.systemctl(ctx, "restart", SystemdUnitName); err != nil {
			return Status{}, err
		}
	}
	return i.systemdStatus(ctx, linger)
}

func (i Installer) uninstallSystemd(ctx context.Context) (Status, error) {
	path := i.systemdUnitPath()
	exists, err := fileExists(path)
	if err != nil {
		return Status{}, err
	}
	if exists {
		if err := i.systemctl(ctx, "disable", "--now", SystemdUnitName); err != nil {
			return Status{}, err
		}
		if err := removeIfExists(path); err != nil {
			return Status{}, err
		}
		if err := i.systemctl(ctx, "daemon-reload"); err != nil {
			return Status{}, err
		}
	}
	return i.systemdStatus(ctx, i.linger(ctx))
}

func (i Installer) statusSystemd(ctx context.Context) (Status, error) {
	return i.systemdStatus(ctx, i.linger(ctx))
}

func (i Installer) systemdStatus(ctx context.Context, linger *bool) (Status, error) {
	installed, err := fileExists(i.systemdUnitPath())
	if err != nil {
		return Status{}, err
	}
	st := Status{Manager: managerSystemd, Installed: installed, Linger: linger}
	if installed {
		_, err := i.Run(ctx, "systemctl", "--user", "is-active", "--quiet", SystemdUnitName)
		st.Running = err == nil
	}
	return st, nil
}

// linger reads the user's linger flag; nil when loginctl is missing, fails or
// answers something else (the hint is printed then too).
func (i Installer) linger(ctx context.Context) *bool {
	if i.User == "" {
		return nil
	}
	out, err := i.Run(ctx, "loginctl", "show-user", i.User, "--property=Linger", "--value")
	if err != nil {
		return nil
	}
	var v bool
	switch strings.TrimSpace(string(out)) {
	case "yes":
		v = true
	case "no":
		v = false
	default:
		return nil
	}
	return &v
}
