// Package hostkind tells a desktop host (a Mac where the Watchtower app runs
// the Swift hub) from a headless one (Linux, a Mac with only the CLI), so a
// live Go hub never runs beside the Swift hub (Go hub spec §7.3, §12.1).
//
// Detect only checks that files exist and reads the app bundle's
// Info.plist; it never creates, opens for writing or lists anything.
package hostkind

import (
	"bytes"
	"os"
	"path/filepath"
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
// a Watchtower.app in /Applications or ~/Applications whose Info.plist holds
// BundleID (signal app_bundle), or a MobileHub/ directory in the app support
// folder (swift_hub_state, left by an app that ran the Swift hub), makes it
// a desktop host. An empty Home or AppSupport skips the checks that need it.
func Detect(p Probe) (k Kind, signal string) {
	if p.GOOS != "darwin" {
		return Headless, ""
	}
	apps := []string{"/Applications"}
	if p.Home != "" {
		apps = append(apps, filepath.Join(p.Home, "Applications"))
	}
	for _, dir := range apps {
		raw, err := p.ReadFile(filepath.Join(dir, "Watchtower.app", "Contents", "Info.plist"))
		if err == nil && plistHasBundleID(raw, BundleID) {
			return Desktop, SignalAppBundle
		}
	}
	if p.AppSupport != "" {
		if fi, err := p.Stat(filepath.Join(p.AppSupport, "MobileHub")); err == nil && fi.IsDir() {
			return Desktop, SignalSwiftHubState
		}
	}
	return Headless, ""
}

// plistHasBundleID reports whether an Info.plist names id as its
// CFBundleIdentifier: in an XML plist the key followed by <string>id</string>;
// in a binary plist (bplist00) id stored as its own ASCII string object
// (marker 0x5F, int marker 0x10, length byte), so a longer identifier that
// starts with id does not match.
func plistHasBundleID(raw []byte, id string) bool {
	if bytes.HasPrefix(raw, []byte("bplist00")) {
		if len(id) < 15 || len(id) > 255 {
			return false
		}
		obj := append([]byte{0x5F, 0x10, byte(len(id))}, id...)
		return bytes.Contains(raw, obj)
	}
	const key = "<key>CFBundleIdentifier</key>"
	for rest := raw; ; {
		i := bytes.Index(rest, []byte(key))
		if i < 0 {
			return false
		}
		rest = bytes.TrimLeft(rest[i+len(key):], " \t\r\n")
		if bytes.HasPrefix(rest, []byte("<string>"+id+"</string>")) {
			return true
		}
	}
}
