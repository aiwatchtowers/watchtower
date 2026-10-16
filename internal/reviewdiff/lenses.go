package reviewdiff

import (
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unicode/utf8"
)

// MaxLensFileBytes caps .watchtower/review.md; a larger file is not read.
const MaxLensFileBytes = 65536

const lensFileNotePrefix = ".watchtower/review.md: "

//go:embed lenses.md
var builtinLensesMD []byte

// LensItem is one checklist question; Key is stable across runs.
type LensItem struct {
	Key  string `json:"key"`
	Text string `json:"text"`
}

// Lens is a named review checklist.
type Lens struct {
	ID      string     `json:"id"`
	Name    string     `json:"name"`
	Builtin bool       `json:"builtin"`
	Items   []LensItem `json:"items"`
}

// LensID lowercases name and collapses every run of non [a-z0-9] bytes to
// "_", trimmed of "_". A name with no latin letters or digits gives "".
func LensID(name string) string {
	var b strings.Builder
	pendingSep := false
	for i := 0; i < len(name); i++ {
		c := name[i]
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') {
			if pendingSep && b.Len() > 0 {
				b.WriteByte('_')
			}
			pendingSep = false
			b.WriteByte(c)
		} else {
			pendingSep = true
		}
	}
	return b.String()
}

// ItemKey is the first 16 hex characters of sha256 of the trimmed question.
func ItemKey(question string) string {
	sum := sha256.Sum256([]byte(strings.TrimSpace(question)))
	return hex.EncodeToString(sum[:])[:16]
}

// ParseLenses merges the built-in lenses with the contents of a folder's
// review file (nil = built-ins only). Bad lines are skipped and reported.
func ParseLenses(folderFile []byte) (lenses []Lens, notes []string) {
	lenses, _ = parseLensesInto(nil, builtinLensesMD, true)
	if folderFile == nil {
		return lenses, nil
	}
	return parseLensesInto(lenses, folderFile, false)
}

func parseLensesInto(lenses []Lens, data []byte, builtin bool) ([]Lens, []string) {
	var notes []string
	const (
		noLens      = -1 // before the first heading
		skippedLens = -2 // under a heading that was skipped; its bullets are dropped silently
	)
	cur := noLens // index into lenses, or noLens / skippedLens
	for i, raw := range strings.Split(string(data), "\n") {
		n := i + 1
		line := strings.TrimSpace(raw)
		switch {
		case line == "":
		case strings.HasPrefix(line, "## "):
			name := strings.TrimSpace(line[3:])
			id := LensID(name)
			if id == "" {
				notes = append(notes, fmt.Sprintf("line %d: lens name has no latin letters or digits", n))
				cur = skippedLens
				continue
			}
			cur = noLens
			for j := range lenses {
				if lenses[j].ID == id {
					cur = j
					break
				}
			}
			if cur == noLens {
				lenses = append(lenses, Lens{ID: id, Name: name, Builtin: builtin, Items: []LensItem{}})
				cur = len(lenses) - 1
			}
		case line == "-" || strings.HasPrefix(line, "- "):
			if cur == noLens {
				notes = append(notes, badLensLine(n))
				continue
			}
			if cur == skippedLens {
				continue
			}
			q := strings.TrimSpace(strings.TrimPrefix(line, "-"))
			if q == "" {
				notes = append(notes, fmt.Sprintf("line %d: empty question", n))
				continue
			}
			key := ItemKey(q)
			dup := false
			for _, it := range lenses[cur].Items {
				if it.Key == key {
					dup = true
					break
				}
			}
			if !dup {
				lenses[cur].Items = append(lenses[cur].Items, LensItem{Key: key, Text: q})
			}
		default:
			notes = append(notes, badLensLine(n))
		}
	}
	return lenses, notes
}

func badLensLine(n int) string {
	return fmt.Sprintf(`line %d: not a "## lens" heading or a "- question"`, n)
}

// LoadLenses reads <workbenchFolder>/.watchtower/review.md and merges it with
// the built-ins. The file is read only when .watchtower is a real directory
// and review.md a regular file; any refusal gives the built-ins and one note.
// A missing file is no note.
func LoadLenses(workbenchFolder string) (lenses []Lens, notes []string) {
	data, note := readLensFile(workbenchFolder)
	if note != "" {
		lenses, _ = ParseLenses(nil)
		return lenses, []string{lensFileNotePrefix + note}
	}
	lenses, notes = ParseLenses(data)
	for i := range notes {
		notes[i] = lensFileNotePrefix + notes[i]
	}
	return lenses, notes
}

// readLensFile returns the file bytes (nil when absent) or a refusal note.
func readLensFile(folder string) ([]byte, string) {
	dir := filepath.Join(folder, ".watchtower")
	di, err := os.Lstat(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, ""
	}
	if err != nil {
		return nil, "cannot read: " + err.Error()
	}
	if !di.IsDir() {
		return nil, ".watchtower is not a real directory"
	}
	path := filepath.Join(dir, "review.md")
	before, err := os.Lstat(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, ""
	}
	if err != nil {
		return nil, "cannot read: " + err.Error()
	}
	if !before.Mode().IsRegular() {
		return nil, "not a regular file"
	}
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, "cannot read: " + err.Error()
	}
	defer func() { _ = f.Close() }()
	after, err := f.Stat()
	if err != nil {
		return nil, "cannot read: " + err.Error()
	}
	if !after.Mode().IsRegular() || !os.SameFile(before, after) {
		return nil, "not a regular file (it changed while it was being opened)"
	}
	data, err := io.ReadAll(io.LimitReader(f, MaxLensFileBytes+1))
	if err != nil {
		return nil, "cannot read: " + err.Error()
	}
	if len(data) > MaxLensFileBytes {
		return nil, "larger than 64 KB, not read"
	}
	if !utf8.Valid(data) {
		return nil, "not UTF-8, not read"
	}
	return data, ""
}
