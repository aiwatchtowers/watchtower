package coach

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"unicode/utf8"
)

// The coach may edit the owner's ~/.claude/CLAUDE.md, a file the owner also
// edits by hand, so it is read only when it is a plain regular file of sane
// size (a symlink or special file is refused, never followed) and written
// only as an exact-text replace through an atomic write that re-reads the
// file just before the rename. Errors never quote the file or its path
// (FILES-01).

const (
	// claudeMDGrowth is how many runes one edit may add to the file.
	claudeMDGrowth = 400
	// claudeMDMaxRunes is the ceiling the coach's edits never push the file
	// past (owner, ask #659): a file at or over it may only stay the same size
	// or shrink, so the coach can only cut there.
	claudeMDMaxRunes = 4000
	// claudeMDMaxBytes is the largest file the coach will read or write.
	claudeMDMaxBytes = 256 * 1024
)

var (
	errClaudeMDNotRegular = errors.New("CLAUDE.md is a symlink or not a regular file")
	errClaudeMDTooBig     = errors.New("CLAUDE.md is too large or not text")
	errClaudeMDChanged    = errors.New("CLAUDE.md changed while it was being written")
)

var claudeMDKind = atomicKind{label: "CLAUDE.md", tmp: ".CLAUDE.md.coach-*",
	read: readClaudeMDFile, changed: errClaudeMDChanged}

// claudeMDPath is <home>/.claude/CLAUDE.md.
func claudeMDPath(home string) string { return filepath.Join(home, ".claude", "CLAUDE.md") }

// readClaudeMDFile returns the file's bytes and permission bits; exists is
// false (and err nil) when there is no file.
func readClaudeMDFile(path string) (raw []byte, mode fs.FileMode, exists bool, err error) {
	fi, err := os.Lstat(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, 0, false, nil
	}
	if err != nil {
		return nil, 0, false, settingsErr("reading CLAUDE.md", err)
	}
	if !fi.Mode().IsRegular() {
		return nil, 0, false, errClaudeMDNotRegular
	}
	if fi.Size() > claudeMDMaxBytes {
		return nil, 0, false, errClaudeMDTooBig
	}
	raw, err = os.ReadFile(path)
	if err != nil {
		return nil, 0, false, settingsErr("reading CLAUDE.md", err)
	}
	if len(raw) > claudeMDMaxBytes || !utf8.Valid(raw) {
		return nil, 0, false, errClaudeMDTooBig
	}
	return raw, fi.Mode().Perm(), true, nil
}

// readClaudeMD is the file's text as a CurrentText: a missing file is an empty
// text the coach may append to; the budget is claudeMDBudget.
func readClaudeMD(path string) (CurrentText, error) {
	raw, _, _, err := readClaudeMDFile(path)
	if err != nil {
		return CurrentText{}, err
	}
	return CurrentText{Destination: DestClaudeMDUser, Text: string(raw),
		Budget: BudgetOf(DestClaudeMDUser, string(raw))}, nil
}

// claudeMDBudget is the most runes an edit may leave in a file of n runes:
// n + claudeMDGrowth, capped at claudeMDMaxRunes; a file already at or over
// the ceiling keeps n (an edit may not grow it).
func claudeMDBudget(n int) int {
	if n >= claudeMDMaxRunes {
		return n
	}
	return min(n+claudeMDGrowth, claudeMDMaxRunes)
}

// replaceClaudeMD makes the file hold to, only while it still holds from (an
// empty from also matches a missing file); otherwise errClaudeMDChanged. A
// missing file and its folder are created (0600, 0700); an existing file keeps
// its mode. It returns whether the file existed.
func replaceClaudeMD(path, from, to string) (existed bool, err error) {
	raw, mode, exists, err := readClaudeMDFile(path)
	if err != nil {
		return false, err
	}
	if string(raw) != from {
		return exists, errClaudeMDChanged
	}
	if !exists {
		mode = 0o600
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			return false, settingsErr("creating the CLAUDE.md folder", err)
		}
	}
	return exists, writeAtomic(claudeMDKind, path, []byte(to), mode, raw, exists)
}
