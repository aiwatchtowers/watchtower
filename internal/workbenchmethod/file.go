// Package workbenchmethod resolves a workbench's methodology (spec
// 2026-10-15-workbench-configurable-methodology-design.md): the preset skill,
// the ask guard mode and the finish check, from the owner's personal
// overrides (projects.*, migration 00116), the folder's
// .watchtower/workflow.md and the built-in defaults, in that order.
package workbenchmethod

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"unicode/utf8"

	"gopkg.in/yaml.v3"
)

// The values each setting takes (spec §5, §8).
const (
	PresetFlow = "watchtower-flow"
	PresetNone = "none"

	AskGuardStrict = "strict"
	AskGuardSoft   = "soft"
	AskGuardOff    = "off"

	FinishOn  = "on"
	FinishOff = "off"
)

const (
	// FileRel is the folder file, relative to the folder.
	FileRel = ".watchtower/workflow.md"
	// MaxFileBytes is how much of the file is read; a longer file is cut.
	MaxFileBytes = 64 << 10
)

// allowed is each frontmatter key and the values it accepts.
var allowed = map[string][]string{
	"preset":       {PresetFlow, PresetNone},
	"ask_guard":    {AskGuardStrict, AskGuardSoft, AskGuardOff},
	"finish_check": {FinishOn, FinishOff},
}

// Valid reports whether value is one key ("preset", "ask_guard",
// "finish_check") accepts.
func Valid(key, value string) bool { return slices.Contains(allowed[key], value) }

// Values lists what key accepts, in the documented order.
func Values(key string) []string { return slices.Clone(allowed[key]) }

// errSpecialFile refuses a symlink or a special file in the file's place.
var errSpecialFile = errors.New("symlinks and special files are not read")

// File is the folder file as read. Present: something is at FileRel (a
// refused file too). Err: the file was refused as a whole — a symlink or
// special file, unreadable, not UTF-8, or a frontmatter error — so none of
// its keys or body apply. Truncated: only the first MaxFileBytes were read.
// A key left out of the frontmatter is "".
type File struct {
	Present     bool
	Preset      string
	AskGuard    string
	FinishCheck string
	Body        string // trimmed
	BodyChars   int    // runes in Body
	Truncated   bool
	Err         error
}

// ReadFile reads folder's FileRel with lstat semantics: neither .watchtower
// nor the file itself may be a symlink or a special file. Nothing there is
// the zero File.
func ReadFile(folder string) File {
	dir := filepath.Join(folder, filepath.Dir(FileRel))
	fi, err := os.Lstat(dir)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return File{}
	case err != nil:
		return File{Present: true, Err: err}
	case !fi.IsDir():
		return File{Present: true, Err: fmt.Errorf("%s: %w", filepath.Dir(FileRel), errSpecialFile)}
	}
	data, truncated, err := readRegular(filepath.Join(folder, FileRel))
	if errors.Is(err, fs.ErrNotExist) {
		return File{}
	}
	if err != nil {
		return File{Present: true, Err: err}
	}
	f, err := Parse(data, truncated)
	if err != nil {
		return File{Present: true, Truncated: truncated, Err: err}
	}
	f.Present = true
	return f
}

// readRegular reads at most MaxFileBytes of p, a regular file that is not a
// symlink: lstat, open without following and without blocking (a FIFO
// swapped in cannot hang a hook), then fstat must still show the same
// regular file — internal/automations' readRecipeFile.
func readRegular(p string) ([]byte, bool, error) {
	before, err := os.Lstat(p)
	if err != nil {
		return nil, false, err
	}
	if !before.Mode().IsRegular() {
		return nil, false, fmt.Errorf("%s: %w", FileRel, errSpecialFile)
	}
	f, err := os.OpenFile(p, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, false, err
	}
	defer func() { _ = f.Close() }()
	after, err := f.Stat()
	if err != nil {
		return nil, false, err
	}
	if !after.Mode().IsRegular() || !os.SameFile(before, after) {
		return nil, false, errors.New("the file changed while it was being opened")
	}
	data, err := io.ReadAll(io.LimitReader(f, MaxFileBytes+1))
	if err != nil {
		return nil, false, err
	}
	if len(data) > MaxFileBytes {
		return data[:MaxFileBytes], true, nil
	}
	return data, false, nil
}

// Parse reads a workflow.md: an optional "---" frontmatter of the three keys
// (strict: a duplicate or unknown key, or a value outside the key's set,
// refuses the whole file) and the body after it. A file cut at MaxFileBytes
// (truncated) may end inside a character; that partial character is
// dropped. A file without a frontmatter is all body; a BOM and CRLF line
// ends are accepted.
func Parse(data []byte, truncated bool) (File, error) {
	if truncated {
		data = dropPartialRune(data)
	}
	if !utf8.Valid(data) {
		return File{}, errors.New("the file is not valid UTF-8")
	}
	text := strings.TrimPrefix(strings.ReplaceAll(string(data), "\r\n", "\n"), "\ufeff")
	head, body, hasHead, err := splitFrontmatter(text)
	if err != nil {
		return File{}, err
	}
	f := File{Truncated: truncated}
	if hasHead {
		if err := parseFrontmatter(head, &f); err != nil {
			return File{}, err
		}
	}
	f.Body = strings.TrimSpace(body)
	f.BodyChars = utf8.RuneCountInString(f.Body)
	return f, nil
}

// dropPartialRune drops the bytes after the last rune start when they do
// not form a whole rune (the cut split a character).
func dropPartialRune(b []byte) []byte {
	for i := len(b) - 1; i >= 0 && i >= len(b)-utf8.UTFMax; i-- {
		if utf8.RuneStart(b[i]) {
			if !utf8.FullRune(b[i:]) {
				return b[:i]
			}
			return b
		}
	}
	return b
}

// splitFrontmatter: a first line "---" opens a frontmatter the next "---"
// line closes; an unclosed one is an error. Without one, all is body.
func splitFrontmatter(text string) (head, body string, ok bool, err error) {
	first, rest, _ := strings.Cut(text, "\n")
	if strings.TrimRight(first, " \t") != "---" {
		return "", text, false, nil
	}
	lines := strings.Split(rest, "\n")
	for i, line := range lines {
		if strings.TrimRight(line, " \t") == "---" {
			return strings.Join(lines[:i], "\n"), strings.Join(lines[i+1:], "\n"), true, nil
		}
	}
	return "", "", false, errors.New(`the frontmatter is not closed by a "---" line`)
}

// parseFrontmatter applies the keys of src to f. Line numbers in errors are
// the file's (the frontmatter starts on line 2). Only comments = no keys.
func parseFrontmatter(src string, f *File) error {
	var doc yaml.Node
	if err := yaml.Unmarshal([]byte(src), &doc); err != nil {
		return fmt.Errorf("invalid frontmatter: %w", err)
	}
	if len(doc.Content) == 0 {
		return nil
	}
	m := doc.Content[0]
	if m.Kind != yaml.MappingNode {
		return errors.New("the frontmatter must be a mapping of keys")
	}
	seen := map[string]bool{}
	for i := 0; i+1 < len(m.Content); i += 2 {
		k, v := m.Content[i], m.Content[i+1]
		key := k.Value
		if seen[key] {
			return fmt.Errorf("line %d: duplicate key %q", k.Line+1, key)
		}
		seen[key] = true
		if _, ok := allowed[key]; !ok {
			return fmt.Errorf("line %d: unknown key %q (preset, ask_guard and finish_check are allowed)", k.Line+1, key)
		}
		if v.Kind != yaml.ScalarNode || !Valid(key, v.Value) {
			return fmt.Errorf("line %d: %s must be one of %s", v.Line+1, key, strings.Join(allowed[key], ", "))
		}
		switch key {
		case "preset":
			f.Preset = v.Value
		case "ask_guard":
			f.AskGuard = v.Value
		case "finish_check":
			f.FinishCheck = v.Value
		}
	}
	return nil
}
