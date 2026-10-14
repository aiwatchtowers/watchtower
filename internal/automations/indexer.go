package automations

import (
	"context"
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
// canonical folder joined with the file's own name. A symlinked file is
// followed for reading but keeps the in-folder name — its stem is the slug.
type Indexer struct {
	db           *db.DB
	workspaceDir string
	clock        Clock

	mu   sync.Mutex
	seen map[string]string // canonical folder → fingerprint at its last scan
}

// NewIndexer returns an indexer over d; workspaceDir locates the personal folder.
func NewIndexer(d *db.DB, workspaceDir string, clock Clock) *Indexer {
	return &Indexer{db: d, workspaceDir: workspaceDir, clock: clock, seen: map[string]string{}}
}

// RescanPersonal rescans the personal folder.
func (ix *Indexer) RescanPersonal(ctx context.Context) (RescanReport, error) {
	return ix.RescanFolder(ctx, Scope{Kind: ScopePersonal}, PersonalDir(ix.workspaceDir))
}

// Changed reports whether dir looks different from its last rescan: never
// scanned, appeared or vanished, or an entry added, removed, renamed, resized
// or touched. It is the scheduler's cheap check; when dir cannot be inspected
// it answers true, so the rescan reports the real error.
func (ix *Indexer) Changed(dir string) bool {
	canon, err := canonicalDir(dir)
	if err != nil {
		return true
	}
	fp, err := folderFingerprint(canon)
	if err != nil {
		return true
	}
	ix.mu.Lock()
	defer ix.mu.Unlock()
	last, ok := ix.seen[canon]
	return !ok || last != fp
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
	ix.mu.Lock()
	ix.seen[canon] = fp
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
	names, err := recipeDirNames(s.dir)
	if err != nil {
		return err
	}
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
	data, err := readRecipeFile(path)
	if err != nil {
		// An unreadable file keeps its row (not removed): what was indexed
		// stays what runs until the file can be read again.
		s.keep = append(s.keep, path)
		s.skip(path, fmt.Sprintf("cannot read the recipe: %v", err))
		return nil
	}
	s.keep = append(s.keep, path)
	cand, err := s.candidate(slug, path, data)
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
func (s *folderScan) candidate(slug, path string, data []byte) (db.Automation, error) {
	a := db.Automation{
		Slug: slug, Scope: s.scopeName(), ProjectID: s.scope.WorkbenchID, Path: path,
		RecipeText: string(data), ContentHash: ContentHash(data),
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
		if err := s.ix.db.SetAutomationSchedule(id, &s.now, nil); err != nil {
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
// upsert makes it runnable.
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
		if err := s.ix.db.SetAutomationSchedule(prev.ID, &s.now, prev.NextRunAt); err != nil {
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

// recipeDirNames lists the *.md entries of dir in name order that are files
// (a symlink counts when it points at a regular file); a missing dir has none.
func recipeDirNames(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var names []string
	for _, e := range entries {
		if filepath.Ext(e.Name()) != recipeExt || e.IsDir() {
			continue
		}
		if e.Type()&fs.ModeSymlink != 0 {
			if fi, err := os.Stat(filepath.Join(dir, e.Name())); err == nil && fi.IsDir() {
				continue
			}
		}
		names = append(names, e.Name())
	}
	return names, nil
}

// readRecipeFile reads at most MaxRecipeBytes+1 bytes of a regular file:
// enough for ParseRecipe to refuse an oversized one without loading it whole.
func readRecipeFile(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }()
	fi, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if !fi.Mode().IsRegular() {
		return nil, fmt.Errorf("not a regular file (%s)", fi.Mode().Type())
	}
	return io.ReadAll(io.LimitReader(f, MaxRecipeBytes+1))
}

// folderFingerprint summarises dir for Changed: its mtime plus every entry's
// name, size and mtime (symlinks followed). A missing dir has a fixed one.
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
		efi, err := os.Stat(filepath.Join(dir, e.Name()))
		if err != nil {
			fmt.Fprintf(&b, "\x00%s:?", e.Name())
			continue
		}
		fmt.Fprintf(&b, "\x00%s:%d:%d", e.Name(), efi.Size(), efi.ModTime().UnixNano())
	}
	return b.String(), nil
}
