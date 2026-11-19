// Package hostkind tells a desktop host (a Mac where the Watchtower app runs
// the Swift hub) from a headless one (Linux, a Mac with only the CLI), so a
// live Go hub never runs beside the Swift hub (Go hub spec §7.3, §12.1).
//
// Detect only checks that files exist and reads the app bundle's
// Info.plist; it never creates, opens for writing or lists anything. It
// fails closed: anything it cannot read or make sense of on a Mac reads as
// a desktop host.
package hostkind

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"syscall"
)

// Kind is a host's kind.
type Kind string

// The kinds.
const (
	Desktop  Kind = "desktop"
	Headless Kind = "headless"
)

// The signals Detect names for a desktop host.
const (
	SignalAppBundle     = "app_bundle"
	SignalSwiftHubState = "swift_hub_state"
)

// BundleID is the Watchtower app's bundle identifier.
const BundleID = "com.watchtower.desktop"

// Probe is what Detect looks at: the OS, the home folder, the app support
// folder (config.AppSupportDir) and the two file reads it needs.
type Probe struct {
	GOOS, Home, AppSupport string
	Stat                   func(string) (os.FileInfo, error)
	ReadFile               func(string) ([]byte, error)
}

// Detect classifies the host. Off darwin every host is headless. On darwin
// these make it a desktop host:
//   - app_bundle: a Watchtower.app in /Applications or ~/Applications whose
//     Info.plist names BundleID, or that has no Info.plist, or whose
//     Info.plist cannot be read or parsed (only a plist that parses and
//     names another bundle id is ignored), or whose existence cannot be
//     checked;
//   - swift_hub_state: a MobileHub/ directory in the app support folder
//     (left by an app that ran the Swift hub), or one whose existence
//     cannot be checked.
//
// An empty Home or AppSupport skips the checks that need it.
func Detect(p Probe) (k Kind, signal string) {
	if p.GOOS != "darwin" {
		return Headless, ""
	}
	apps := []string{"/Applications"}
	if p.Home != "" {
		apps = append(apps, filepath.Join(p.Home, "Applications"))
	}
	for _, dir := range apps {
		if appBundleHere(p, filepath.Join(dir, "Watchtower.app")) {
			return Desktop, SignalAppBundle
		}
	}
	if p.AppSupport != "" {
		fi, err := p.Stat(filepath.Join(p.AppSupport, "MobileHub"))
		if (err == nil && fi.IsDir()) || (err != nil && !absent(err)) {
			return Desktop, SignalSwiftHubState
		}
	}
	return Headless, ""
}

// appBundleHere reports whether app is (or may be) the Watchtower app.
func appBundleHere(p Probe, app string) bool {
	raw, err := p.ReadFile(filepath.Join(app, "Contents", "Info.plist"))
	if err == nil {
		id, err := plistBundleID(raw)
		return err != nil || id == BundleID
	}
	if !absent(err) {
		return true
	}
	// No Info.plist: an app dir there is still the app (half-installed or
	// moved in); only its absence is not.
	_, err = p.Stat(app)
	return !absent(err)
}

// absent: err says the path does not exist.
func absent(err error) bool {
	return errors.Is(err, fs.ErrNotExist) || errors.Is(err, syscall.ENOTDIR)
}
