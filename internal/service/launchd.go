package service

import (
	"context"
	"encoding/xml"
	"path/filepath"
	"strconv"
	"strings"
	"time"
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
	for _, arg := range u.daemonArgv() {
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

// bootstrapAttempts and bootstrapRetryWait bound the retry of a bootstrap
// right after a bootout: launchd may still be tearing the old job down and
// answers "5: Input/output error" until it is gone.
const (
	bootstrapAttempts  = 5
	bootstrapRetryWait = 200 * time.Millisecond
)

func (i Installer) launchdDomainNames() (gui, user string) {
	uid := strconv.Itoa(i.UID)
	return "gui/" + uid, "user/" + uid
}

// launchdDomain is the domain a bootstrap goes into: gui/<uid> when the owner
// has a console login, else user/<uid> (a CLI-only Mac reached over SSH with
// nobody logged in).
func (i Installer) launchdDomain(ctx context.Context) string {
	gui, user := i.launchdDomainNames()
	if _, err := i.Run(ctx, "launchctl", "print", gui); err == nil {
		return gui
	}
	return user
}

// launchdLoadedIn finds the domain the agent is loaded in, looking in both
// (an agent bootstrapped into user/ before a login stays there after gui/
// appears); "" when it is loaded in neither.
func (i Installer) launchdLoadedIn(ctx context.Context) (domain string, running bool) {
	gui, user := i.launchdDomainNames()
	for _, d := range []string{gui, user} {
		out, err := i.Run(ctx, "launchctl", "print", d+"/"+LaunchdLabel)
		if err == nil {
			return d, strings.Contains(string(out), "state = running")
		}
	}
	return "", false
}

func (i Installer) launchctl(ctx context.Context, args ...string) error {
	out, err := i.Run(ctx, "launchctl", args...)
	if err != nil {
		return runErr("launchctl "+strings.Join(args, " "), out, err)
	}
	return nil
}

// bootstrap loads the plist into domain. With retry (right after a bootout)
// an I/O-error answer is retried a bounded number of times.
func (i Installer) bootstrap(ctx context.Context, domain, path string, retry bool) error {
	sleep := i.Sleep
	if sleep == nil {
		sleep = time.Sleep
	}
	args := []string{"bootstrap", domain, path}
	for attempt := 1; ; attempt++ {
		out, err := i.Run(ctx, "launchctl", args...)
		if err == nil {
			return nil
		}
		if !retry || attempt >= bootstrapAttempts || !strings.Contains(string(out), "Input/output error") {
			return runErr("launchctl "+strings.Join(args, " "), out, err)
		}
		sleep(bootstrapRetryWait)
	}
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
	loadedIn, _ := i.launchdLoadedIn(ctx)
	switch {
	case loadedIn != "" && !changed:
		// Loaded with this plist already: nothing to do, in whichever domain.
	case loadedIn != "":
		if err := i.launchctl(ctx, "bootout", loadedIn+"/"+LaunchdLabel); err != nil {
			return Status{}, err
		}
		if err := i.bootstrap(ctx, i.launchdDomain(ctx), path, true); err != nil {
			return Status{}, err
		}
	default:
		if err := i.bootstrap(ctx, i.launchdDomain(ctx), path, false); err != nil {
			return Status{}, err
		}
	}
	return i.statusLaunchd(ctx)
}

func (i Installer) uninstallLaunchd(ctx context.Context) (Status, error) {
	// Unloaded from every domain it is loaded in.
	gui, user := i.launchdDomainNames()
	for _, domain := range []string{gui, user} {
		if _, err := i.Run(ctx, "launchctl", "print", domain+"/"+LaunchdLabel); err != nil {
			continue // not loaded there
		}
		if err := i.launchctl(ctx, "bootout", domain+"/"+LaunchdLabel); err != nil {
			return Status{}, err
		}
	}
	if err := removeIfExists(i.launchdPlistPath()); err != nil {
		return Status{}, err
	}
	return i.statusLaunchd(ctx)
}

func (i Installer) statusLaunchd(ctx context.Context) (Status, error) {
	installed, err := fileExists(i.launchdPlistPath())
	if err != nil {
		return Status{}, err
	}
	_, running := i.launchdLoadedIn(ctx)
	return Status{Manager: managerLaunchd, Installed: installed, Running: running}, nil
}
