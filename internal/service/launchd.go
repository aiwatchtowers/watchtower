package service

import (
	"context"
	"encoding/xml"
	"path/filepath"
	"strconv"
	"strings"
)

// LaunchdPlist renders the LaunchAgent that runs `<exe> sync --daemon`. Its
// only environment is PATH; stdout and stderr go to /dev/null (the daemon
// writes watchtower.log itself, FILES-01); AbandonProcessGroup keeps a
// session-host the daemon started alive when launchd stops the daemon.
func LaunchdPlist(u Unit) string {
	var b strings.Builder
	b.WriteString(`<?xml version="1.0" encoding="UTF-8"?>` + "\n")
	b.WriteString(`<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">` + "\n")
	b.WriteString(`<plist version="1.0">` + "\n<dict>\n")
	key := func(indent, k string) { b.WriteString(indent + "<key>" + plistEscape(k) + "</key>\n") }
	str := func(indent, v string) { b.WriteString(indent + "<string>" + plistEscape(v) + "</string>\n") }

	key("\t", "Label")
	str("\t", LaunchdLabel)
	key("\t", "ProgramArguments")
	b.WriteString("\t<array>\n")
	for _, arg := range []string{u.Exe, "sync", "--daemon"} {
		str("\t\t", arg)
	}
	b.WriteString("\t</array>\n")
	key("\t", "RunAtLoad")
	b.WriteString("\t<true/>\n")
	key("\t", "KeepAlive")
	b.WriteString("\t<dict>\n")
	key("\t\t", "SuccessfulExit")
	b.WriteString("\t\t<false/>\n\t</dict>\n")
	key("\t", "AbandonProcessGroup")
	b.WriteString("\t<true/>\n")
	key("\t", "ProcessType")
	str("\t", "Background")
	key("\t", "EnvironmentVariables")
	b.WriteString("\t<dict>\n")
	key("\t\t", "PATH")
	str("\t\t", u.Path)
	b.WriteString("\t</dict>\n")
	key("\t", "StandardOutPath")
	str("\t", "/dev/null")
	key("\t", "StandardErrorPath")
	str("\t", "/dev/null")
	b.WriteString("</dict>\n</plist>\n")
	return b.String()
}

func plistEscape(s string) string {
	var b strings.Builder
	_ = xml.EscapeText(&b, []byte(s)) // a strings.Builder never fails
	return b.String()
}

func (i Installer) launchdPlistPath() string {
	return filepath.Join(i.Home, "Library", "LaunchAgents", LaunchdLabel+".plist")
}

// launchdDomain is gui/<uid> when the owner has a console login, else
// user/<uid> (a CLI-only Mac reached over SSH with nobody logged in).
func (i Installer) launchdDomain(ctx context.Context) string {
	gui := "gui/" + strconv.Itoa(i.UID)
	if _, err := i.Run(ctx, "launchctl", "print", gui); err == nil {
		return gui
	}
	return "user/" + strconv.Itoa(i.UID)
}

// launchdLoaded reports whether the agent is loaded in domain, and running.
func (i Installer) launchdLoaded(ctx context.Context, domain string) (loaded, running bool) {
	out, err := i.Run(ctx, "launchctl", "print", domain+"/"+LaunchdLabel)
	if err != nil {
		return false, false
	}
	return true, strings.Contains(string(out), "state = running")
}

func (i Installer) launchctl(ctx context.Context, args ...string) error {
	out, err := i.Run(ctx, "launchctl", args...)
	if err != nil {
		return runErr("launchctl "+strings.Join(args, " "), out, err)
	}
	return nil
}

func (i Installer) installLaunchd(ctx context.Context, u Unit) (Status, error) {
	if err := i.hostCheck(); err != nil {
		return Status{}, err
	}
	if err := i.prepare(ctx); err != nil {
		return Status{}, err
	}
	path := i.launchdPlistPath()
	changed, err := writeIfChanged(path, LaunchdPlist(u))
	if err != nil {
		return Status{}, err
	}
	domain := i.launchdDomain(ctx)
	loaded, _ := i.launchdLoaded(ctx, domain)
	if loaded && changed {
		if err := i.launchctl(ctx, "bootout", domain+"/"+LaunchdLabel); err != nil {
			return Status{}, err
		}
		loaded = false
	}
	if !loaded {
		if err := i.launchctl(ctx, "bootstrap", domain, path); err != nil {
			return Status{}, err
		}
	}
	return i.launchdStatus(ctx, domain)
}

func (i Installer) uninstallLaunchd(ctx context.Context) (Status, error) {
	// The agent may have been bootstrapped into either domain (user/ before
	// the owner's first console login, gui/ after), so both are unloaded.
	uid := strconv.Itoa(i.UID)
	for _, domain := range []string{"gui/" + uid, "user/" + uid} {
		if loaded, _ := i.launchdLoaded(ctx, domain); loaded {
			if err := i.launchctl(ctx, "bootout", domain+"/"+LaunchdLabel); err != nil {
				return Status{}, err
			}
		}
	}
	if err := removeIfExists(i.launchdPlistPath()); err != nil {
		return Status{}, err
	}
	return i.launchdStatus(ctx, i.launchdDomain(ctx))
}

func (i Installer) statusLaunchd(ctx context.Context) (Status, error) {
	return i.launchdStatus(ctx, i.launchdDomain(ctx))
}

func (i Installer) launchdStatus(ctx context.Context, domain string) (Status, error) {
	installed, err := fileExists(i.launchdPlistPath())
	if err != nil {
		return Status{}, err
	}
	_, running := i.launchdLoaded(ctx, domain)
	return Status{Manager: managerLaunchd, Installed: installed, Running: running}, nil
}
