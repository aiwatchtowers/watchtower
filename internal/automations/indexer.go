package automations

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"watchtower/internal/db"
)

// recipeExt is the extension of a recipe file; any other file is ignored.
const recipeExt = ".md"

// PersonalDir is the personal recipe folder, <workspaceDir>/automations (§20 D8).
func PersonalDir(workspaceDir string) string {
	return filepath.Join(workspaceDir, "automations")
}

// WorkbenchDir is a workbench's recipe folder, <folder>/.watchtower/automations.
func WorkbenchDir(folder string) string {
	return filepath.Join(folder, ".watchtower", "automations")
}

// SkipNote is a file in a recipe folder the indexer did not index, and why.
type SkipNote struct {
	Path, Reason string
}

// RescanReport is what one folder rescan did. Indexed counts rows written (new
// or changed), Unchanged rows left as they were, Removed rows newly stamped
// removed_at. NeedConfirmation lists, in id order, every parsed recipe of the
// folder whose approval_hash the owner has not confirmed — new or changed in
// this scan or still waiting from an earlier one.
type RescanReport struct {
	Indexed, Unchanged, Removed int
	Skipped                     []SkipNote
	NeedConfirmation            []int64
}

// Indexer turns recipe folders into automations index rows (spec §2.5).
//
// Path policy: a folder is made absolute and its symlinks are resolved
// (filepath.EvalSymlinks on the deepest existing ancestor, so a folder that
// does not exist yet keys the same once it does); a recipe's path is that
// canonical folder joined with the file's own name. Entries inside the
// folder are never followed: only a regular file named *.md is a recipe; a
// symlink or a special file (FIFO, socket, device) named *.md is skipped
// with a note and never opened.
type Indexer struct {
	db           *db.DB
	workspaceDir string
	clock        Clock

	mu   sync.Mutex
	seen map[string]folderState // canonical folder → its state at the last scan
	big  map[string]bigFileHash // oversized recipe path → its hash at the last read
}

// bigFileHash remembers the whole-file hash of an oversized recipe, so a
// rescan does not re-read a huge file whose lstat size and mtime are as before.
type bigFileHash struct {
	size, mtime int64
	hash        string
}

// folderState is what Changed compares: the folder's entries and the DB
// generation of the scope it was scanned under.
type folderState struct {
	fingerprint string
	scope       Scope
	generation  string
}

// NewIndexer returns an indexer over d; workspaceDir locates the personal folder.
func NewIndexer(d *db.DB, workspaceDir string, clock Clock) *Indexer {
	return &Indexer{db: d, workspaceDir: workspaceDir, clock: clock, seen: map[string]folderState{}, big: map[string]bigFileHash{}}
}

// RescanPersonal rescans the personal folder.
func (ix *Indexer) RescanPersonal(ctx context.Context) (RescanReport, error) {
	return ix.RescanFolder(ctx, Scope{Kind: ScopePersonal}, PersonalDir(ix.workspaceDir))
}

// Changed reports whether dir looks different from its last rescan: never
// scanned, appeared or vanished, an entry added, removed, renamed, resized,
// touched or its inode changed (mtime/ctime), or the scope's rows changed in
// the database (e.g. a CLI delete freed a slug). It is the scheduler's cheap
// check; when dir or the database cannot be inspected it answers true, so the
// rescan reports the real error.
func (ix *Indexer) Changed(dir string) bool {
	canon, err := canonicalDir(dir)
	if err != nil {
		return true
	}
	ix.mu.Lock()
	last, ok := ix.seen[canon]
	ix.mu.Unlock()
	if !ok {
		return true
	}
	fp, err := folderFingerprint(canon)
	if err != nil || fp != last.fingerprint {
		return true
	}
	gen, err := ix.db.AutomationScopeGeneration(string(last.scope.Kind), last.scope.WorkbenchID)
	return err != nil || gen != last.generation
}

// RescanFolder indexes every recipe in dir under scope. A missing folder is
// empty. A file whose stem is not a valid slug, or whose slug another row of
// the scope holds at a different path, is skipped and reported; other
// extensions are ignored. A recipe that fails to parse is indexed with
// parse_error set (never runnable). Rows of the scope whose file is gone get
// removed_at.
func (ix *Indexer) RescanFolder(ctx context.Context, scope Scope, dir string) (RescanReport, error) {
	if err := validateScope(scope); err != nil {
		return RescanReport{}, fmt.Errorf("rescanning %s: %w", dir, err)
	}
	canon, err := canonicalDir(dir)
	if err != nil {
		return RescanReport{}, fmt.Errorf("rescanning %s: %w", dir, err)
	}
	// The fingerprint is taken before reading, so a change made during the
	// scan shows up as Changed next time.
	fp, err := folderFingerprint(canon)
	if err != nil {
		return RescanReport{}, fmt.Errorf("rescanning %s: %w", canon, err)
	}
	scan := &folderScan{ix: ix, scope: scope, dir: canon, now: ix.clock.Now()}
	if err := scan.run(ctx); err != nil {
		return RescanReport{}, fmt.Errorf("rescanning %s: %w", canon, err)
	}
	// The generation is read after the scan's own writes, so only a later
	// change shows up as Changed.
	gen, err := ix.db.AutomationScopeGeneration(string(scope.Kind), scope.WorkbenchID)
	if err != nil {
		return RescanReport{}, fmt.Errorf("rescanning %s: %w", canon, err)
	}
	ix.mu.Lock()
	ix.seen[canon] = folderState{fingerprint: fp, scope: scope, generation: gen}
	ix.mu.Unlock()
	return scan.report, nil
}

// folderScan is the state of one RescanFolder call.
type folderScan struct {
	ix     *Indexer
	scope  Scope
	dir    string
	now    time.Time
	byPath map[string]db.Automation
	bySlug map[string]db.Automation
	keep   []string
	report RescanReport
}

func (s *folderScan) scopeName() string { return string(s.scope.Kind) }

func (s *folderScan) run(ctx context.Context) error {
	existing, err := s.ix.db.ListAutomations(db.AutomationFilter{
		Scope: s.scopeName(), ProjectID: s.scope.WorkbenchID, IncludeRemoved: true,
	})
	if err != nil {
		return err
	}
	s.byPath = make(map[string]db.Automation, len(existing))
	s.bySlug = make(map[string]db.Automation, len(existing))
	for _, a := range existing {
		s.byPath[a.Path] = a
		s.bySlug[a.Slug] = a
	}
	names, notes, err := listRecipeEntries(s.dir)
	if err != nil {
		return err
	}
	s.report.Skipped = append(s.report.Skipped, notes...)
	for _, name := range names {
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := s.indexEntry(name); err != nil {
			return err
		}
	}
	n, err := s.ix.db.MarkAutomationsRemovedExcept(s.scopeName(), s.scope.WorkbenchID, s.keep, s.now)
	if err != nil {
		return err
	}
	s.report.Removed = n
	slices.Sort(s.report.NeedConfirmation)
	return nil
}

func (s *folderScan) skip(path, reason string) {
	s.report.Skipped = append(s.report.Skipped, SkipNote{Path: path, Reason: reason})
}

// indexEntry indexes one *.md entry of the folder.
func (s *folderScan) indexEntry(name string) error {
	path := filepath.Join(s.dir, name)
	slug := strings.TrimSuffix(name, recipeExt)
	if !ValidSlug(slug) {
		s.skip(path, fmt.Sprintf("file name %q is not a valid automation slug (want %s%s)", name, slugPattern.String(), recipeExt))
		return nil
	}
	if other, ok := s.bySlug[slug]; ok && other.Path != path {
		s.skip(path, slugTakenReason(slug, other))
		return nil
	}
	data, contentHash, err := s.ix.readRecipe(path)
	if err != nil {
		// An unreadable file keeps its row (not removed): what was indexed
		// stays what runs until the file can be read again.
		s.keep = append(s.keep, path)
		s.skip(path, fmt.Sprintf("cannot read the recipe: %v", err))
		return nil
	}
	s.keep = append(s.keep, path)
	cand, err := s.candidate(slug, path, data, contentHash)
	if err != nil {
		return err
	}
	prev, exists := s.byPath[path]
	if exists {
		return s.update(prev, cand)
	}
	return s.insert(cand)
}

func slugTakenReason(slug string, other db.Automation) string {
	state := "indexed"
	if other.RemovedAt != nil {
		state = "removed, its file gone"
	}
	return fmt.Sprintf("slug %q is already used in this scope by automation %d at %s (%s); "+
		"rename this file, or delete that automation with `watchtower automations delete %d`",
		slug, other.ID, other.Path, state, other.ID)
}

// candidate is the index row the file's bytes produce.
// contentHash is over the whole file even when data holds only its first
// MaxRecipeBytes+1 bytes.
func (s *folderScan) candidate(slug, path string, data []byte, contentHash string) (db.Automation, error) {
	a := db.Automation{
		Slug: slug, Scope: s.scopeName(), ProjectID: s.scope.WorkbenchID, Path: path,
		RecipeText: string(data), ContentHash: contentHash,
	}
	r, perr := ParseRecipe(slug, data, s.scope)
	if perr != nil {
		return withParseErrorDefaults(a, perr.Error()), nil
	}
	spec, err := triggerSpecJSON(r.Trigger)
	if err != nil {
		return db.Automation{}, err
	}
	perms, err := json.Marshal(normalizedPermissions(r.Permissions))
	if err != nil {
		return db.Automation{}, fmt.Errorf("encoding permissions of %s: %w", path, err)
	}
	outs, err := json.Marshal(sortedCopy(r.Outputs))
	if err != nil {
		return db.Automation{}, fmt.Errorf("encoding outputs of %s: %w", path, err)
	}
	a.Name, a.TriggerKind, a.TriggerSpec, a.MissedPolicy = r.Name, string(r.Trigger.Kind), spec, string(r.Missed)
	a.Concurrency, a.BudgetTokens, a.BudgetMinutes = r.Concurrency, r.Budget.Tokens, r.Budget.Minutes
	a.PauseTimeoutHours, a.PermissionsJSON, a.OutputsJSON = r.PauseTimeoutHours, string(perms), string(outs)
	a.ApprovalHash = ApprovalHash(r)
	return a, nil
}

// withParseErrorDefaults fills an unparsable recipe's row with the column
// defaults, so a rescan of the same broken file compares equal to its row.
func withParseErrorDefaults(a db.Automation, msg string) db.Automation {
	a.ParseError = msg
	a.TriggerSpec, a.MissedPolicy = "{}", string(MissedRunOnce)
	a.Concurrency, a.BudgetTokens, a.BudgetMinutes = DefaultConcurrency, DefaultBudgetTokens, DefaultBudgetMinutes
	a.PauseTimeoutHours, a.PermissionsJSON, a.OutputsJSON = DefaultPauseTimeoutHours, "[]", "[]"
	return a
}

func (s *folderScan) noteConfirmation(id int64, a db.Automation) {
	if a.ParseError == "" && a.ConfirmedHash != a.ApprovalHash {
		s.report.NeedConfirmation = append(s.report.NeedConfirmation, id)
	}
}

// insert indexes a recipe new to the index: unconfirmed and disabled; a
// schedule recipe starts its schedule now (no back-fill).
func (s *folderScan) insert(cand db.Automation) error {
	id, err := s.ix.db.UpsertAutomationIndex(cand)
	if err != nil {
		return err
	}
	if cand.TriggerKind == string(TriggerSchedule) {
		if _, err := s.ix.db.PrimeAutomationSchedule(id, s.now); err != nil {
			return err
		}
	}
	s.report.Indexed++
	s.noteConfirmation(id, cand)
	return nil
}

// update re-indexes an existing row. A row this rescan makes runnable as a
// schedule automation when it was not one before (its approval_hash reverted
// to the confirmed one, its file came back, its parse error is fixed, or its
// trigger became a schedule) gets last_scheduled_for = now first, so the
// scheduler never catches up on the window it spent not runnable. Priming
// before the upsert is race-free: the scheduler ignores the row until the
// upsert makes it runnable, and PrimeAutomationSchedule writes only while
// the row is still not a runnable schedule, so an indexer working from a
// stale snapshot cannot rewind a schedule point the scheduler advanced.
func (s *folderScan) update(prev, cand db.Automation) error {
	if sameIndexFields(prev, cand) && prev.RemovedAt == nil {
		s.report.Unchanged++
		s.noteConfirmation(prev.ID, prev)
		return nil
	}
	// next is the row after the upsert: the file's fields, the owner's columns.
	next := cand
	next.ID, next.ConfirmedHash, next.Enabled = prev.ID, prev.ConfirmedHash, prev.Enabled
	next.LastScheduledFor, next.NextRunAt = prev.LastScheduledFor, prev.NextRunAt
	if becameRunnableSchedule(prev, next) {
		if _, err := s.ix.db.PrimeAutomationSchedule(prev.ID, s.now); err != nil {
			return err
		}
	}
	if _, err := s.ix.db.UpsertAutomationIndex(next); err != nil {
		return err
	}
	s.report.Indexed++
	s.noteConfirmation(prev.ID, next)
	return nil
}

func becameRunnableSchedule(prev, next db.Automation) bool {
	isSchedule := func(a db.Automation) bool { return a.Runnable() && a.TriggerKind == string(TriggerSchedule) }
	return isSchedule(next) && !isSchedule(prev)
}

// indexFields is the part of a row the recipe file determines.
type indexFields struct {
	Slug, Scope                                            string
	ProjectID                                              int64
	Path, Name, TriggerKind, TriggerSpec, MissedPolicy     string
	Concurrency, BudgetTokens, BudgetMinutes, PauseTimeout int
	PermissionsJSON, OutputsJSON, RecipeText, ContentHash  string
	ApprovalHash, ParseError                               string
}

func fieldsOf(a db.Automation) indexFields {
	return indexFields{
		a.Slug, a.Scope, a.ProjectID, a.Path, a.Name, a.TriggerKind, a.TriggerSpec, a.MissedPolicy,
		a.Concurrency, a.BudgetTokens, a.BudgetMinutes, a.PauseTimeoutHours,
		a.PermissionsJSON, a.OutputsJSON, a.RecipeText, a.ContentHash, a.ApprovalHash, a.ParseError,
	}
}

func sameIndexFields(a, b db.Automation) bool { return fieldsOf(a) == fieldsOf(b) }

// triggerSpec is trigger_spec: the recipe's trigger map in its own shape,
// e.g. {"schedule":"0 9 * * *"} or {"manual":true}.
type triggerSpec struct {
	Schedule string             `json:"schedule,omitempty"`
	Button   *triggerSpecButton `json:"button,omitempty"`
	Event    *triggerSpecEvent  `json:"event,omitempty"`
	Manual   bool               `json:"manual,omitempty"`
}

type triggerSpecButton struct {
	Label   string `json:"label"`
	Confirm bool   `json:"confirm"`
}

type triggerSpecEvent struct {
	Type  string            `json:"type"`
	Where map[string]string `json:"where,omitempty"`
}

func triggerSpecJSON(t Trigger) (string, error) {
	var spec triggerSpec
	switch t.Kind {
	case TriggerSchedule:
		spec.Schedule = t.Schedule
	case TriggerButton:
		spec.Button = &triggerSpecButton{Label: t.Button.Label, Confirm: t.Button.Confirm}
	case TriggerEvent:
		spec.Event = &triggerSpecEvent{Type: t.Event.Type, Where: t.Event.Where}
	case TriggerManual:
		spec.Manual = true
	default:
		return "", fmt.Errorf("encoding trigger: unknown kind %q", t.Kind)
	}
	b, err := json.Marshal(spec)
	if err != nil {
		return "", fmt.Errorf("encoding trigger: %w", err)
	}
	return string(b), nil
}

// CanonicalDir is the indexer's folder path policy (see Indexer), exported so
// the CLI can tell whether a path lies in a recipe folder and key a file the
// way its index row does: filepath.Join(CanonicalDir(filepath.Dir(f)),
// filepath.Base(f)).
func CanonicalDir(dir string) (string, error) { return canonicalDir(dir) }

// canonicalDir makes dir absolute and resolves symlinks through its deepest
// existing ancestor; the part that does not exist yet is appended as is.
func canonicalDir(dir string) (string, error) {
	abs, err := filepath.Abs(dir)
	if err != nil {
		return "", err
	}
	missing := ""
	for cur := abs; ; {
		resolved, err := filepath.EvalSymlinks(cur)
		if err == nil {
			return filepath.Join(resolved, missing), nil
		}
		if !errors.Is(err, fs.ErrNotExist) {
			return "", err
		}
		parent := filepath.Dir(cur)
		if parent == cur {
			return abs, nil
		}
		missing = filepath.Join(filepath.Base(cur), missing)
		cur = parent
	}
}

// specialEntryReason is the skip note of a *.md entry that is not a regular file.
const specialEntryReason = "symlinks and special files are not read; put the recipe file itself in the folder"

// listRecipeEntries lists, in name order, the entries of dir named *.md that
// are regular files, without following any of them (lstat semantics). A
// symlink or special file named *.md is returned as a skip note; a directory
// and any other name are ignored. A missing dir has none.
func listRecipeEntries(dir string) ([]string, []SkipNote, error) {
	entries, err := os.ReadDir(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil, nil
	}
	if err != nil {
		return nil, nil, err
	}
	var (
		names []string
		notes []SkipNote
	)
	for _, e := range entries {
		switch {
		case filepath.Ext(e.Name()) != recipeExt || e.IsDir():
		case e.Type().IsRegular():
			names = append(names, e.Name())
		default:
			notes = append(notes, SkipNote{Path: filepath.Join(dir, e.Name()), Reason: specialEntryReason})
		}
	}
	return names, notes, nil
}

// readRecipe is readRecipeFile with the oversized-file hash cache.
func (ix *Indexer) readRecipe(path string) ([]byte, string, error) {
	ix.mu.Lock()
	known := ix.big[path]
	ix.mu.Unlock()
	data, hash, fi, err := readRecipeFile(path, known)
	ix.mu.Lock()
	defer ix.mu.Unlock()
	if err != nil || fi.Size() <= MaxRecipeBytes {
		delete(ix.big, path)
	} else {
		ix.big[path] = bigFileHash{size: fi.Size(), mtime: fi.ModTime().UnixNano(), hash: hash}
	}
	return data, hash, err
}

// ReadRecipeFile reads a recipe file the way the indexer does (see
// readRecipeFile: a regular file only, never through a symlink): its first
// MaxRecipeBytes+1 bytes and the ContentHash of the whole file. The CLI's
// validate and save read their input through it.
func ReadRecipeFile(path string) ([]byte, string, error) {
	data, hash, _, err := readRecipeFile(path, bigFileHash{})
	if err != nil {
		return nil, "", fmt.Errorf("reading recipe %s: %w", path, err)
	}
	return data, hash, nil
}

// readRecipeFile reads a regular file that is not a symlink: lstat, open
// without following and without blocking (a FIFO swapped in cannot hang the
// scan), then fstat must still show a regular file with the same inode. It
// returns the first MaxRecipeBytes+1 bytes — enough for ParseRecipe to refuse
// an oversized file without holding it whole — and the ContentHash of the
// whole file, streamed — or known.hash, without reading past the head, for
// an oversized file whose size and mtime match known. It also returns the
// file's fstat info (nil on error).
func readRecipeFile(path string, known bigFileHash) ([]byte, string, os.FileInfo, error) {
	before, err := os.Lstat(path)
	if err != nil {
		return nil, "", nil, err
	}
	if !before.Mode().IsRegular() {
		return nil, "", nil, errors.New(specialEntryReason)
	}
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, "", nil, err
	}
	defer func() { _ = f.Close() }()
	after, err := f.Stat()
	if err != nil {
		return nil, "", nil, err
	}
	if !after.Mode().IsRegular() || !os.SameFile(before, after) {
		return nil, "", nil, errors.New("the file changed while it was being opened")
	}
	reuse := after.Size() > MaxRecipeBytes && known.hash != "" &&
		known.size == after.Size() && known.mtime == after.ModTime().UnixNano()
	h := sha256.New()
	var head bytes.Buffer
	if _, err := io.Copy(h, io.TeeReader(io.LimitReader(f, MaxRecipeBytes+1), &head)); err != nil {
		return nil, "", nil, err
	}
	if reuse {
		return head.Bytes(), known.hash, after, nil
	}
	if _, err := io.Copy(h, f); err != nil {
		return nil, "", nil, err
	}
	return head.Bytes(), hex.EncodeToString(h.Sum(nil)), after, nil
}

// folderFingerprint summarises dir for Changed: its mtime plus every entry's
// name, size, mtime and ctime, read with lstat (nothing is followed). A
// missing dir has a fixed one.
func folderFingerprint(dir string) (string, error) {
	fi, err := os.Stat(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return "missing", nil
	}
	if err != nil {
		return "", err
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", err
	}
	var b strings.Builder
	b.WriteString(strconv.FormatInt(fi.ModTime().UnixNano(), 10))
	for _, e := range entries {
		efi, err := e.Info()
		if err != nil {
			fmt.Fprintf(&b, "\x00%s:?", e.Name())
			continue
		}
		fmt.Fprintf(&b, "\x00%s:%s:%d:%d:%d", e.Name(), efi.Mode().Type(), efi.Size(), efi.ModTime().UnixNano(), changeTimeNanos(efi))
	}
	return b.String(), nil
}
