// Package company keeps the confirmed company bundles of this install
// (<workspace>/company/<slug>.json) and compares an incoming bundle with a
// stored one. The bundle format itself is internal/companybundle.
package company

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"slices"
	"strings"
	"time"
	"unicode"

	"watchtower/internal/companybundle"
	"watchtower/internal/fsutil"
)

// forcedSource is LoadError.File for a forced MDM bundle that fails to parse.
const forcedSource = "CompanyBundle (managed preference)"

// draftSlug is the wizard draft's stem (draft.json), never a company.
const draftSlug = "draft"

// maxFileBytes caps a stored file; a bundle is a few hundred bytes.
const maxFileBytes = 64 << 10

// saveLockWait bounds how long Save waits for another writer of the file.
const saveLockWait = 30 * time.Second

// slugRE is a stored file's stem: what companybundle.Slug makes, plus the
// store's numeric clash suffix.
var slugRE = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)

// clashSuffixRE is the store's numeric clash suffix (-2, -3…).
var clashSuffixRE = regexp.MustCompile(`^-[0-9]+$`)

// ErrStoredChanged is SaveIfUnchanged finding the file changed since the
// caller read it (another confirm wrote first).
var ErrStoredChanged = errors.New("company file changed since it was read")

// ErrSlugTaken is Save over a file that holds another company (or that is
// damaged): the store never overwrites a company it cannot read as the same.
var ErrSlugTaken = errors.New("company file belongs to another company")

// Entry is one effective company: its stored file, or the forced MDM bundle
// (Forced) that wins over the stored file of the same company name.
type Entry struct {
	Slug   string
	Bundle companybundle.Bundle
	Forced bool
}

// LoadError is a company file (or the forced bundle) that failed to read; the
// other companies still load.
type LoadError struct {
	File string
	Err  string
}

// Store is the company directory of one workspace.
type Store struct{ Dir string }

// NewStore returns the store under <workspaceDir>/company.
func NewStore(workspaceDir string) Store {
	return Store{Dir: filepath.Join(workspaceDir, "company")}
}

// CleanCode drops every whitespace character (spaces, tabs, line breaks)
// from a pasted connect code: a mail client wraps a long code. The wire form
// is base64url, which never contains one.
func CleanCode(s string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsSpace(r) {
			return -1
		}
		return r
	}, s)
}

// diskState is what one read of the directory found.
type diskState struct {
	entries []Entry         // readable files, by slug
	errs    []LoadError     // damaged files
	taken   map[string]bool // every stem in use, damaged ones included
	// seen maps a forced company to the slug its .forced-<slug>.seen pins
	// (ApplyForcedChanges); seenSlugs is every slug such a file holds.
	seen      map[string]string
	seenSlugs map[string]bool
	// damagedSeen are the slugs of unreadable records, in name order.
	damagedSeen []string
}

// damagedPin is the slug of an unreadable .seen record that company's name
// slugs to (its base slug, or the base with a clash suffix) and that no file
// holds: the record was most likely that company's, so its slug — the one
// its accounts carry — stays put.
func (st *diskState) damagedPin(company string) (string, bool) {
	base := companybundle.Slug(company)
	for _, slug := range st.damagedSeen {
		if st.taken[slug] {
			continue
		}
		if suffix, ok := strings.CutPrefix(slug, base); ok && (suffix == "" || clashSuffixRE.MatchString(suffix)) {
			return slug, true
		}
	}
	return "", false
}

// inUse reports whether slug is a file's, the draft's or a forced
// company's pinned one.
func (st *diskState) inUse(slug string) bool { return st.taken[slug] || st.seenSlugs[slug] }

// read lists the company files. A missing directory is no company.
func (s Store) read() (diskState, error) {
	st := diskState{taken: map[string]bool{draftSlug: true}, seen: map[string]string{}, seenSlugs: map[string]bool{}}
	des, err := os.ReadDir(s.Dir)
	if errors.Is(err, fs.ErrNotExist) {
		return st, nil
	}
	if err != nil {
		return st, fmt.Errorf("reading company directory: %w", err)
	}
	for _, de := range des {
		name := de.Name()
		if slug, ok := seenSlug(name); ok {
			st.addSeen(s.Dir, slug)
			continue
		}
		slug, ok := strings.CutSuffix(name, ".json")
		if !ok || slug == draftSlug || strings.HasPrefix(name, ".") {
			continue
		}
		st.taken[slug] = true
		b, err := readFile(filepath.Join(s.Dir, name), slug)
		if err != nil {
			st.errs = append(st.errs, LoadError{File: name, Err: err.Error()})
			continue
		}
		st.entries = append(st.entries, Entry{Slug: slug, Bundle: b})
	}
	return st, nil
}

// addSeen records the forced company slug pins (the first file of a company,
// in name order, wins). A damaged .seen is a LoadError and keeps its slug in
// use; overlay still gives it to a forced company whose name slugs to it.
func (st *diskState) addSeen(dir, slug string) {
	st.seenSlugs[slug] = true
	b, err := readSeen(dir, slug)
	if err != nil {
		st.errs = append(st.errs, LoadError{File: seenPrefix + slug + seenSuffix, Err: err.Error()})
		st.damagedSeen = append(st.damagedSeen, slug)
		return
	}
	if _, dup := st.seen[b.Company]; !dup {
		st.seen[b.Company] = slug
	}
}

// readFile reads and validates one stored bundle.
func readFile(path, slug string) (companybundle.Bundle, error) {
	if !slugRE.MatchString(slug) {
		return companybundle.Bundle{}, errors.New("not a company file name")
	}
	fi, err := os.Lstat(path)
	if err != nil {
		return companybundle.Bundle{}, err
	}
	if !fi.Mode().IsRegular() {
		return companybundle.Bundle{}, errors.New("not a regular file")
	}
	if fi.Size() > maxFileBytes {
		return companybundle.Bundle{}, errors.New("file too large")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return companybundle.Bundle{}, err
	}
	return companybundle.ParseJSON(raw, companybundle.OriginLocal)
}

// overlay applies the forced bundle: it replaces the stored entry of the
// same company name, or joins as a new entry under a free slug. A forced
// bundle that fails to parse is a LoadError and overlays nothing.
func overlay(st *diskState, forcedWire string) {
	if strings.TrimSpace(forcedWire) == "" {
		return
	}
	fb, err := companybundle.Parse(forcedWire, companybundle.OriginMDM)
	if err != nil {
		st.errs = append(st.errs, LoadError{File: forcedSource, Err: err.Error()})
		return
	}
	matched := false
	for i := range st.entries {
		if st.entries[i].Bundle.Company == fb.Company {
			st.entries[i].Bundle, st.entries[i].Forced = fb, true
			matched = true
		}
	}
	if matched {
		return
	}
	// A forced company with no file of its own keeps the slug its
	// .forced-<slug>.seen pins (its accounts carry it), unless a file of
	// another company holds it now; else it takes a free one.
	slug, pinned := st.seen[fb.Company]
	if pinned && st.taken[slug] {
		pinned = false
	}
	if !pinned {
		slug, pinned = st.damagedPin(fb.Company)
	}
	if !pinned {
		slug = freeSlug(fb.Company, st.inUse)
	}
	st.taken[slug] = true
	st.entries = append(st.entries, Entry{Slug: slug, Bundle: fb, Forced: true})
}

// freeSlug is companybundle.Slug(company), with -2, -3… while taken.
func freeSlug(company string, taken func(string) bool) string {
	base := companybundle.Slug(company)
	if !taken(base) {
		return base
	}
	for n := 2; ; n++ {
		if s := fmt.Sprintf("%s-%d", base, n); !taken(s) {
			return s
		}
	}
}

// LoadAll returns every company, the forced MDM bundle (forcedWire, "" for
// none) winning over the stored file of the same company name. It is a pure
// read: it never creates, changes or deletes a file. A damaged file is a
// LoadError; the other companies still load. Entries are in slug order.
func (s Store) LoadAll(forcedWire string) ([]Entry, []LoadError, error) {
	st, err := s.read()
	if err != nil {
		return nil, nil, err
	}
	overlay(&st, forcedWire)
	slices.SortFunc(st.entries, func(a, b Entry) int { return strings.Compare(a.Slug, b.Slug) })
	return st.entries, st.errs, nil
}

// Get returns the company stored (or forced) under slug. A damaged file under
// slug is an error.
func (s Store) Get(slug, forcedWire string) (Entry, bool, error) {
	entries, errs, err := s.LoadAll(forcedWire)
	if err != nil {
		return Entry{}, false, err
	}
	for _, e := range entries {
		if e.Slug == slug {
			return e, true, nil
		}
	}
	for _, le := range errs {
		if le.File == slug+".json" {
			return Entry{}, false, fmt.Errorf("company file %s: %s", le.File, le.Err)
		}
	}
	return Entry{}, false, nil
}

// SlugFor returns the slug of company: the one it is stored (or forced)
// under, else the slug pinned when it was last forced, else a free one —
// never the slug of another company, of a damaged file, or of the forced
// bundle (pinned or current) of another company.
func (s Store) SlugFor(company, forcedWire string) (string, error) {
	st, err := s.read()
	if err != nil {
		return "", err
	}
	overlay(&st, forcedWire)
	for _, e := range st.entries {
		if e.Bundle.Company == company {
			return e.Slug, nil
		}
	}
	// A company forced before (no longer, or not yet stored) keeps its
	// pinned slug: its accounts carry it.
	if slug, ok := st.seen[company]; ok && !st.taken[slug] {
		return slug, nil
	}
	if slug, ok := st.damagedPin(company); ok {
		return slug, nil
	}
	return freeSlug(company, st.inUse), nil
}

// Save writes b as <slug>.json (0600, directory 0700) under the file's flock,
// through a temp file and a rename. It refuses a file that holds another
// company or that it cannot read (ErrSlugTaken): the slug of a different
// company comes from SlugFor.
func (s Store) Save(slug string, b companybundle.Bundle) error {
	return s.save(slug, b, nil, false)
}

// SaveIfUnchanged is Save that writes only while the file still holds prev
// (absent when prev is nil), checked under the flock: a decision taken on a
// read (needs Replace or not) never lands over a newer write. Otherwise it
// returns ErrStoredChanged and writes nothing.
func (s Store) SaveIfUnchanged(slug string, prev *companybundle.Bundle, b companybundle.Bundle) error {
	return s.save(slug, b, prev, true)
}

// save validates b the way a stored file is read (Save is also the bridge's
// and the wizard's writer, whose bundles do not all come out of Parse), so
// nothing unreadable lands on disk.
func (s Store) save(slug string, b companybundle.Bundle, prev *companybundle.Bundle, check bool) error {
	if !slugRE.MatchString(slug) || slug == draftSlug {
		return fmt.Errorf("invalid company slug %q", slug)
	}
	raw, err := json.Marshal(b)
	if err != nil {
		return fmt.Errorf("encoding company bundle: %w", err)
	}
	n, err := companybundle.ParseJSON(raw, companybundle.OriginLocal)
	if err != nil {
		return fmt.Errorf("company bundle: %w", err)
	}
	data, err := json.MarshalIndent(n, "", "  ")
	if err != nil {
		return fmt.Errorf("encoding company bundle: %w", err)
	}
	if len(data) >= maxFileBytes {
		return fmt.Errorf("company bundle too large to store (%d bytes)", len(data))
	}
	if err := fsutil.MakePrivateDir(s.Dir); err != nil {
		return fmt.Errorf("creating company directory: %w", err)
	}
	path := filepath.Join(s.Dir, slug+".json")
	ctx, cancel := context.WithTimeout(context.Background(), saveLockWait)
	defer cancel()
	unlock, err := fsutil.LockFile(ctx, path+".lock")
	if err != nil {
		return fmt.Errorf("locking company file %s: %w", slug, err)
	}
	defer unlock()
	_, err = os.Lstat(path)
	exists := err == nil
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("company file %s: %w", slug, err)
	}
	var cur companybundle.Bundle
	if exists {
		if cur, err = readFile(path, slug); err != nil {
			return fmt.Errorf("%w: %s.json is unreadable (%v)", ErrSlugTaken, slug, err)
		}
		if cur.Company != n.Company {
			return fmt.Errorf("%w: %s.json holds %q", ErrSlugTaken, slug, cur.Company)
		}
	}
	if check && (exists != (prev != nil) || (exists && !reflect.DeepEqual(cur, *prev))) {
		return fmt.Errorf("%w: %s.json", ErrStoredChanged, slug)
	}
	return fsutil.WriteFileAtomic(path, append(data, '\n'), 0o600)
}
