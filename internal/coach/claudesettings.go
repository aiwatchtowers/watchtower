package coach

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
)

// The coach writes one key of the owner's ~/.claude/settings.json:
// permissions.allow. Every other key is kept as the raw JSON it was (its
// meaning byte for byte; the file is re-indented). A symlink, a file that is
// not a JSON object, or a permissions/allow value of another shape is refused
// and the file is left untouched. Errors never quote the file (FILES-01).

var (
	errSettingsNotRegular = errors.New("settings.json is a symlink or not a regular file")
	errSettingsInvalid    = errors.New("settings.json is not a JSON object with a permissions.allow list")
	errSettingsChanged    = errors.New("settings.json changed while it was being written")
)

// settingsErr wraps a file-system error without its path (the owner's home
// folder): a *PathError or *LinkError keeps only its operation and cause, so
// errors.Is still sees the cause (FILES-01).
func settingsErr(what string, err error) error {
	var pe *fs.PathError
	if errors.As(err, &pe) {
		return fmt.Errorf("%s: %s: %w", what, pe.Op, pe.Err)
	}
	var le *os.LinkError
	if errors.As(err, &le) {
		return fmt.Errorf("%s: %s: %w", what, le.Op, le.Err)
	}
	return fmt.Errorf("%s: %w", what, err)
}

// claudeSettingsPath is <home>/.claude/settings.json.
func claudeSettingsPath(home string) string { return filepath.Join(home, ".claude", "settings.json") }

// settingsDoc is a decoded settings file: the top-level keys and the keys of
// permissions as raw JSON, and the allow list.
type settingsDoc struct {
	top, perms map[string]json.RawMessage
	allow      []string
}

// isJSON reports whether raw (trimmed) starts with the given delimiter, so a
// JSON null — which decodes into a nil map without an error — is refused.
func isJSON(raw []byte, open byte) bool {
	t := bytes.TrimSpace(raw)
	return len(t) > 0 && t[0] == open
}

func parseSettings(raw []byte) (settingsDoc, error) {
	var d settingsDoc
	if !isJSON(raw, '{') || json.Unmarshal(raw, &d.top) != nil {
		return settingsDoc{}, errSettingsInvalid
	}
	d.perms = map[string]json.RawMessage{}
	if p, ok := d.top["permissions"]; ok {
		if !isJSON(p, '{') || json.Unmarshal(p, &d.perms) != nil {
			return settingsDoc{}, errSettingsInvalid
		}
	}
	if a, ok := d.perms["allow"]; ok {
		if !isJSON(a, '[') || json.Unmarshal(a, &d.allow) != nil {
			return settingsDoc{}, errSettingsInvalid
		}
	}
	return d, nil
}

// readAllowRules reads permissions.allow of the settings file at path. A
// missing file is an empty list; a symlink, a special file or a file of
// another shape is an error.
func readAllowRules(path string) ([]string, error) {
	raw, _, exists, err := readSettingsFile(path)
	if err != nil || !exists {
		return nil, err
	}
	d, err := parseSettings(raw)
	if err != nil {
		return nil, err
	}
	return d.allow, nil
}

// readSettingsFile returns the file's bytes and permission bits; exists is
// false (and err nil) when there is no file.
func readSettingsFile(path string) (raw []byte, mode fs.FileMode, exists bool, err error) {
	fi, err := os.Lstat(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, 0, false, nil
	}
	if err != nil {
		return nil, 0, false, settingsErr("reading settings.json", err)
	}
	if !fi.Mode().IsRegular() {
		return nil, 0, false, errSettingsNotRegular
	}
	raw, err = os.ReadFile(path)
	if err != nil {
		return nil, 0, false, settingsErr("reading settings.json", err)
	}
	return raw, fi.Mode().Perm(), true, nil
}

// AppendAllowRules adds rules to permissions.allow of the settings file at
// path, skipping those already there (and repeats among rules). A missing file
// is created (0600, its folder 0700) holding only that list. It returns the
// file's bytes before (nil when there was no file) and after; when nothing is
// new the file is not written (nor created) and after equals before.
func AppendAllowRules(path string, rules []string) (before, after []byte, err error) {
	return editAllowRules(path, func(cur []string) []string {
		have := map[string]bool{}
		for _, r := range cur {
			have[r] = true
		}
		out := append([]string{}, cur...)
		for _, r := range rules {
			if !have[r] {
				have[r] = true
				out = append(out, r)
			}
		}
		return out
	})
}

// removeAllowRules drops every occurrence of rules from permissions.allow,
// keeping the rest in order; the rollback of AppendAllowRules.
func removeAllowRules(path string, rules []string) (before, after []byte, err error) {
	return editAllowRules(path, func(cur []string) []string {
		drop := map[string]bool{}
		for _, r := range rules {
			drop[r] = true
		}
		out := []string{}
		for _, r := range cur {
			if !drop[r] {
				out = append(out, r)
			}
		}
		return out
	})
}

func editAllowRules(path string, edit func([]string) []string) (before, after []byte, err error) {
	raw, mode, exists, err := readSettingsFile(path)
	if err != nil {
		return nil, nil, err
	}
	d := settingsDoc{top: map[string]json.RawMessage{}, perms: map[string]json.RawMessage{}}
	if exists {
		if d, err = parseSettings(raw); err != nil {
			return nil, nil, err
		}
	} else {
		mode = 0o600
	}
	next := edit(d.allow)
	if slices.Equal(next, d.allow) {
		return raw, raw, nil // nothing to change (nil, nil when there is no file)
	}
	if d.perms["allow"], err = encodeJSON(next, ""); err != nil {
		return nil, nil, err
	}
	if d.top["permissions"], err = encodeJSON(d.perms, ""); err != nil {
		return nil, nil, err
	}
	out, err := encodeJSON(d.top, "  ")
	if err != nil {
		return nil, nil, err
	}
	out = append(out, '\n')
	if !exists {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			return nil, nil, settingsErr("creating the settings folder", err)
		}
		raw = nil
	}
	if err := writeFileAtomic(path, out, mode, raw, exists); err != nil {
		return nil, nil, err
	}
	return raw, out, nil
}

// RestoreFile puts the settings file at path back to before; nil before (there
// was no file) removes it. A symlink or special file at path is refused.
func RestoreFile(path string, before []byte) error {
	cur, mode, exists, err := readSettingsFile(path)
	if err != nil {
		return err
	}
	if before == nil {
		if !exists {
			return nil
		}
		if err := os.Remove(path); err != nil {
			return settingsErr("removing settings.json", err)
		}
		return nil
	}
	if !exists {
		mode = 0o600
	}
	return writeFileAtomic(path, before, mode, cur, exists)
}

// atomicKind names a file the coach writes atomically: its label for error
// text, its temp-file pattern, how it is read and the error for a file that
// changed under the writer.
type atomicKind struct {
	label   string
	tmp     string
	read    func(path string) ([]byte, fs.FileMode, bool, error)
	changed error
}

var settingsKind = atomicKind{label: "settings.json", tmp: ".settings.json.coach-*",
	read: readSettingsFile, changed: errSettingsChanged}

// writeFileAtomic writes data to the settings file at path (see writeAtomic).
func writeFileAtomic(path string, data []byte, mode fs.FileMode, expect []byte, existed bool) error {
	return writeAtomic(settingsKind, path, data, mode, expect, existed)
}

// writeAtomic writes data to path through a temp file in the same folder
// (fsynced, then renamed over path) with the given mode. Just before the
// rename the file must still be what the caller read (expect, or absent when
// !existed); otherwise nothing is replaced and k.changed is returned.
func writeAtomic(k atomicKind, path string, data []byte, mode fs.FileMode, expect []byte, existed bool) (err error) {
	dir := filepath.Dir(path)
	what := "writing " + k.label
	tmp, err := os.CreateTemp(dir, k.tmp)
	if err != nil {
		return settingsErr(what, err)
	}
	defer func() {
		if err != nil {
			_ = os.Remove(tmp.Name())
		}
	}()
	if err := tmp.Chmod(mode); err != nil {
		_ = tmp.Close()
		return settingsErr(what, err)
	}
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return settingsErr(what, err)
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return settingsErr(what, err)
	}
	if err := tmp.Close(); err != nil {
		return settingsErr(what, err)
	}
	cur, _, exists, err := k.read(path)
	if err != nil {
		return err
	}
	if exists != existed || !bytes.Equal(cur, expect) {
		return k.changed
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		return settingsErr(what, err)
	}
	if d, err := os.Open(dir); err == nil {
		_ = d.Sync() // best effort: the rename is durable once the folder is
		_ = d.Close()
	}
	return nil
}

// encodeJSON marshals v without HTML escaping (so "&" in a kept value stays
// "&"), indented by indent when it is not empty, without a trailing newline.
func encodeJSON(v any, indent string) ([]byte, error) {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if indent != "" {
		enc.SetIndent("", indent)
	}
	if err := enc.Encode(v); err != nil {
		return nil, fmt.Errorf("encoding settings.json: %w", err)
	}
	return bytes.TrimRight(b.Bytes(), "\n"), nil
}
