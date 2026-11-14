package coach

import (
	"os"
	"time"

	"watchtower/internal/db"
)

// The daemon's measure check (spec 2026-11-12 C3, C8, C10) reads what an
// accepted context change left behind through these: the settings key a
// running Claude Code may have written back, and the memory index the
// cleanup session wrote. Both only read; the daemon writes the row.

// IsSettingsDestination reports whether destination is one key of the
// owner's Claude Code settings (plugin, server, connectors), applied by
// Accept and turned off again by Reapply.
func IsSettingsDestination(destination string) bool {
	switch destination {
	case DestPluginOff, DestMCPServerOff, DestConnectorsOff:
		return true
	}
	return false
}

// SettingsReverted reports whether accepted settings proposal p's own key
// reads "on" again (someone turned it back on outside Watchtower,
// settingsBackOn). Other keys of the file never matter. An unreadable file
// is an error that names the file's label, never a path or a value.
func (a *Applier) SettingsReverted(p db.CoachProposal) (bool, error) {
	k, err := a.settingsKeyOf(p)
	if err != nil {
		return false, err
	}
	f, err := k.read()
	if err != nil {
		return false, err
	}
	return settingsBackOn(p.Destination, k.textOf(f.value)), nil
}

// settingsBackOn is whether a settings key's text (compact JSON, "" when
// absent, "present" for a server) reads "on", in any form Claude Code takes
// as on: a plugin only at true (a key that disappeared from enabledPlugins
// — the plugin uninstalled — is not turned back on); the connectors switch
// at anything but "false" or "0", absent included (on by default); a
// server whenever it is present.
func settingsBackOn(dest, text string) bool {
	switch dest {
	case DestPluginOff:
		return text == "true"
	case DestConnectorsOff:
		switch text {
		case `"false"`, `"0"`, "false", "0":
			return false
		}
		return true
	case DestMCPServerOff:
		return text == "present"
	}
	return false
}

// MemoryIndexNow reads memory proposal p's MEMORY.md (its workbench folder's
// project, the same safe read Accept and Rollback use) and when it was last
// written.
func (a *Applier) MemoryIndexNow(p db.CoachProposal) (text string, modified time.Time, err error) {
	if p.Destination != DestMemoryIndex {
		return "", time.Time{}, errNotSupported
	}
	u, err := a.memoryIndex(p)
	if err != nil {
		return "", time.Time{}, err
	}
	if text, err = u.readText(); err != nil {
		return "", time.Time{}, err
	}
	fi, err := os.Lstat(u.path)
	if err != nil {
		return "", time.Time{}, settingsErr("reading MEMORY.md", err) // no path in the error
	}
	return text, fi.ModTime(), nil
}
