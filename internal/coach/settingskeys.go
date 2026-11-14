package coach

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"

	"watchtower/internal/db"
)

// The settings destinations (spec 2026-11-12 part 2, C5) each own one key of
// one file: claude_plugin_off enabledPlugins["<plugin>"] and
// claude_connectors_off env.ENABLE_CLAUDEAI_MCP_SERVERS of
// ~/.claude/settings.json, claude_mcp_server_off mcpServers["<server>"] of
// ~/.claude.json. A proposal's before_text/after_text hold that key's JSON
// value ("" = absent); a server's hold "present"/"", and the entry itself —
// it may carry secrets — is kept for Rollback in <workspace>/coach-undo/<id>.json
// (0600), never in the row, a log or an error. Accept compares and sets the
// one key only: Claude Code rewriting the file's other keys never makes a
// proposal stale; the whole read bytes still guard the rename itself.

var (
	// errProtected refuses a context proposal that names Watchtower's own
	// server, a plugin a Watchtower skill needs or a pack skill (COACH-01).
	errProtected = errors.New("this belongs to Watchtower and is never turned off")
	// errKeyNotHeld: right after the write the key did not read the value
	// written — another program wrote the file at the same moment.
	errKeyNotHeld = errors.New("the setting did not hold: another program wrote the file at the same time")
	// errUndoGone refuses a server's Rollback without its saved entry.
	errUndoGone = errors.New("saved settings for this server are gone")
	// errUndoUnreadable refuses a server's Rollback whose saved entry is
	// there but not a JSON object (corrupt): distinct from gone.
	errUndoUnreadable = errors.New("saved settings for this server can't be read")
	errNoSource       = errors.New("this proposal names no plugin or server")
	errNoWorkspace    = errors.New("no workspace folder to keep the server's settings in")
	// errKeyChanged: the key no longer holds the value it is set from.
	errKeyChanged = errors.New("the setting changed since it was read")
)

// settingsKeyAfter is the one after-text a settings destination may write.
func settingsKeyAfter(dest string) string {
	switch dest {
	case DestPluginOff:
		return "false"
	case DestConnectorsOff:
		return `"false"`
	}
	return "" // a server is removed
}

// settingsKey is one key of a JSON config file: obj[outer][inner].
type settingsKey struct {
	kind         atomicKind
	path         string
	outer, inner string
	invalid      error
	// presence: the key's text is "present"/"" instead of its value (a
	// server entry).
	presence bool
}

func (a *Applier) settingsKeyOf(p db.CoachProposal) (settingsKey, error) {
	if a.Home == "" {
		return settingsKey{}, errors.New("no home folder")
	}
	switch p.Destination {
	case DestConnectorsOff:
		return settingsKey{kind: settingsKind, path: claudeSettingsPath(a.Home), outer: "env",
			inner: connectorsEnvKey, invalid: errSettingsNotObject}, nil
	case DestPluginOff, DestMCPServerOff:
		if p.SourceKey == "" {
			return settingsKey{}, errNoSource
		}
		if p.Destination == DestPluginOff {
			return settingsKey{kind: settingsKind, path: claudeSettingsPath(a.Home), outer: "enabledPlugins",
				inner: p.SourceKey, invalid: errSettingsNotObject}, nil
		}
		return settingsKey{kind: claudeJSONKind, path: claudeJSONPath(a.Home), outer: "mcpServers",
			inner: p.SourceKey, invalid: errClaudeJSONInvalid, presence: true}, nil
	}
	return settingsKey{}, errNotSupported
}

// keyFile is one read of a key's file.
type keyFile struct {
	raw      []byte
	mode     fs.FileMode
	exists   bool
	top, obj map[string]json.RawMessage
	value    json.RawMessage // obj[inner]; nil when absent
}

func (k settingsKey) read() (keyFile, error) {
	raw, mode, exists, err := k.kind.read(k.path)
	if err != nil {
		return keyFile{}, err
	}
	f := keyFile{raw: raw, mode: mode, exists: exists}
	if f.top, err = objectKeys(raw, k.invalid); err != nil {
		return keyFile{}, err
	}
	if f.obj, err = objectKeys(f.top[k.outer], k.invalid); err != nil {
		return keyFile{}, err
	}
	f.value = f.obj[k.inner]
	return f, nil
}

// textOf is v as a proposal's text: its compact JSON ("present" for a
// presence key), "" when absent.
func (k settingsKey) textOf(v json.RawMessage) string {
	if v == nil {
		return ""
	}
	if k.presence {
		return "present"
	}
	return compactJSON(v)
}

func compactJSON(v json.RawMessage) string {
	var b bytes.Buffer
	if json.Compact(&b, v) != nil {
		return string(v)
	}
	return b.String()
}

// set compare-and-sets the key: while it still reads from (its text), it
// becomes value (nil removes it) and every other key of the file is kept.
// save, when not nil, gets the value being replaced just before the write.
// An atomic-write conflict re-reads and tries once more. After the rename
// (and the test hook after) the file is read again and the key must read
// value, else errKeyNotHeld. A key that no longer reads from is
// errKeyChanged with nothing written.
func (k settingsKey) set(from string, value json.RawMessage, save func(json.RawMessage) error, after func()) error {
	for attempt := 0; ; attempt++ {
		f, err := k.read()
		if err != nil {
			return err
		}
		if k.textOf(f.value) != from {
			return errKeyChanged
		}
		if value == nil {
			delete(f.obj, k.inner)
		} else {
			f.obj[k.inner] = value
		}
		if f.top[k.outer], err = encodeJSON(f.obj, ""); err != nil {
			return err
		}
		out, err := encodeJSON(f.top, "  ")
		if err != nil {
			return err
		}
		out = append(out, '\n')
		if save != nil {
			if err := save(f.value); err != nil {
				return err
			}
		}
		mode := f.mode
		if !f.exists {
			mode = 0o600
			if err := os.MkdirAll(filepath.Dir(k.path), 0o700); err != nil {
				return settingsErr("creating the "+k.kind.label+" folder", err)
			}
		}
		err = writeAtomic(k.kind, k.path, out, mode, f.raw, f.exists)
		if errors.Is(err, k.kind.changed) && attempt == 0 {
			continue
		}
		if err != nil {
			return err
		}
		if after != nil {
			after()
		}
		g, err := k.read()
		if err != nil {
			return err
		}
		if (g.value == nil) != (value == nil) || (value != nil && compactJSON(g.value) != compactJSON(value)) {
			return errKeyNotHeld
		}
		return nil
	}
}

// undoPath is where a server proposal's saved entry lives.
func (a *Applier) undoPath(id int64) (string, error) {
	if a.WorkspaceDir == "" {
		return "", errNoWorkspace
	}
	return filepath.Join(a.WorkspaceDir, "coach-undo", fmt.Sprintf("%d.json", id)), nil
}

// writeUndoFile writes a server entry 0600 (its folder 0700) through a temp
// file renamed into place.
func writeUndoFile(path string, entry json.RawMessage) (err error) {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return settingsErr("creating the coach-undo folder", err)
	}
	tmp, err := os.CreateTemp(dir, ".undo-*")
	if err != nil {
		return settingsErr("saving the server's settings", err)
	}
	defer func() {
		if err != nil {
			_ = os.Remove(tmp.Name())
		}
	}()
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return settingsErr("saving the server's settings", err)
	}
	if _, err := tmp.Write(entry); err != nil {
		_ = tmp.Close()
		return settingsErr("saving the server's settings", err)
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return settingsErr("saving the server's settings", err)
	}
	if err := tmp.Close(); err != nil {
		return settingsErr("saving the server's settings", err)
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		return settingsErr("saving the server's settings", err)
	}
	return nil
}

// readSettingsKey is p's key as a CurrentText (readCurrent).
func (a *Applier) readSettingsKey(p db.CoachProposal, t CurrentText) (CurrentText, error) {
	k, err := a.settingsKeyOf(p)
	if err != nil {
		return CurrentText{}, err
	}
	f, err := k.read()
	if err != nil {
		return CurrentText{}, err
	}
	t.Text = k.textOf(f.value)
	return t, nil
}

// writeSettingsKey sets p's key from cur.Text to after (ValidateAfter has
// checked it is the destination's one after-text); a server's entry is saved
// to its undo file first. A key changed since the read is ErrStale. The undo
// (when the status write fails) sets the key back while it still reads after.
func (a *Applier) writeSettingsKey(p db.CoachProposal, cur CurrentText, after string) (written, error) {
	k, err := a.settingsKeyOf(p)
	if err != nil {
		return written{}, err
	}
	var value json.RawMessage
	if after != "" {
		value = json.RawMessage(after)
	}
	var prev json.RawMessage
	save := func(v json.RawMessage) error { prev = v; return nil }
	undoPath := ""
	if k.presence {
		if undoPath, err = a.undoPath(p.ID); err != nil {
			return written{}, err
		}
		save = func(v json.RawMessage) error { prev = v; return writeUndoFile(undoPath, v) }
	}
	err = k.set(cur.Text, value, save, a.afterSettingsWrite)
	if err != nil {
		if undoPath != "" && !a.serverGone(k) {
			// The server is still there (refused, or put back by another
			// writer): its saved copy is not needed.
			a.removeUndo(p.ID, undoPath)
		}
		if errors.Is(err, errKeyChanged) {
			return written{}, ErrStale
		}
		return written{}, err
	}
	return written{result: after, undo: func() error {
		if err := k.set(after, prev, nil, nil); err != nil {
			return err
		}
		if undoPath != "" {
			a.removeUndo(p.ID, undoPath)
		}
		return nil
	}}, nil
}

// removeUndo removes proposal id's saved server entry (it may hold
// secrets). A failed removal is logged by the proposal id only — never the
// path or the error, which names it — and changes nothing else.
func (a *Applier) removeUndo(id int64, path string) {
	if err := os.Remove(path); err != nil && !errors.Is(err, fs.ErrNotExist) {
		a.logf("coach: proposal %d: the saved server settings could not be removed", id)
	}
}

// serverGone is whether a server key reads absent now; a failed read counts
// as not gone-known, so the saved entry is kept.
func (a *Applier) serverGone(k settingsKey) bool {
	f, err := k.read()
	return err != nil || f.value == nil
}

// restoreSettingsKey puts p's before-value back while the key still reads
// cur.Text (what Rollback read): a plugin or the connectors switch gets its
// before-text (removed when it was absent), a server its saved entry, whose
// file is then removed. A server without its saved entry is refused with
// nothing written.
func (a *Applier) restoreSettingsKey(p db.CoachProposal, cur CurrentText) error {
	k, err := a.settingsKeyOf(p)
	if err != nil {
		return err
	}
	var value json.RawMessage
	undoPath := ""
	if k.presence {
		if undoPath, err = a.undoPath(p.ID); err != nil {
			return err
		}
		b, err := os.ReadFile(undoPath)
		if errors.Is(err, fs.ErrNotExist) {
			return errUndoGone
		}
		if err != nil {
			return settingsErr("reading the server's saved settings", err)
		}
		if !isJSON(b, '{') || !json.Valid(b) {
			return errUndoUnreadable
		}
		value = b
	} else if p.BeforeText != "" {
		value = json.RawMessage(p.BeforeText)
	}
	if err := k.set(cur.Text, value, nil, nil); err != nil {
		if errors.Is(err, errKeyChanged) {
			return ErrChangedSince
		}
		return err
	}
	if undoPath != "" {
		a.removeUndo(p.ID, undoPath)
	}
	return nil
}
