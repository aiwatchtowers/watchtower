package sources

import (
	"context"
	"database/sql"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/agentkind"
	"watchtower/internal/db"
	"watchtower/internal/hub/slices"
	"watchtower/internal/hub/wire"
)

// Caps of the workbench slice (WorkbenchSlice).
const (
	maxWorkbenches  = 100
	maxAutomations  = 50
	maxWorkbenchTxt = 200
	maxDescription  = 1000
	maxFolder       = 300
	maxBranch       = 120
)

// GitSnapshot is a workbench's last good git status (the Swift
// WorkbenchGitSnapshot): the branch ("" when detached), detached HEAD and
// the count of changed files.
type GitSnapshot struct {
	Branch   string
	Detached bool
	Changes  int
}

// WorkbenchOptions wires the workbench source. Home is the folder
// folder_display abbreviates to "~"; GitStatus (nil = none yet) the git
// refresher's last good status; Sessions (nil = every count 0) the
// terminal_session source whose published states the session counts are
// over; DefaultAgent (nil = Claude) the `workbench.default_agent` a phone
// start runs; Now (nil = time.Now) the clock of the archive window.
type WorkbenchOptions struct {
	Home         string
	GitStatus    func(workbenchID int64) (GitSnapshot, bool)
	Sessions     *TerminalSessionSource
	DefaultAgent func() agentkind.Kind
	Now          func() time.Time
}

// Workbench is the `workbench` slice (mobile POC spec §4.2), record
// `workbench-<projects.id>`: the ≤ 100 workbenches with the latest session
// activity, resolved and capped for the phone's Workbench list. The raw
// folder_path is never published, only folder_display. Wire shape: the Kit
// mirror WatchtowerKit.Workbench.
func Workbench(d *db.DB, o WorkbenchOptions) slices.Source {
	if o.Now == nil {
		o.Now = time.Now
	}
	if o.DefaultAgent == nil {
		o.DefaultAgent = func() agentkind.Kind { return agentkind.Claude }
	}
	return &workbenchSource{d: d, o: o}
}

type workbenchSource struct {
	d *db.DB
	o WorkbenchOptions
}

func (s *workbenchSource) Kind() slices.Kind { return "workbench" }

// sessionCounts is the workbench's `session_counts`.
type sessionCounts struct {
	Working       int `json:"working"`
	Waiting       int `json:"waiting"`
	NeedsApproval int `json:"needs_approval"`
	Finished      int `json:"finished"`
	Failed        int `json:"failed"`
	Stopped       int `json:"stopped"`
	NotRunning    int `json:"not_running"`
}

type workbenchAutomation struct {
	ID            int64      `json:"id"`
	Name          string     `json:"name"`
	NameClipped   *bool      `json:"name_clipped,omitempty"`
	Kind          string     `json:"kind"`
	AsksFirst     bool       `json:"asks_first"`
	State         string     `json:"state"`
	LastRunStatus *string    `json:"last_run_status,omitempty"`
	LastRunAt     *wire.Time `json:"last_run_at,omitempty"`
}

type workbenchPayload struct {
	ID                   int64                 `json:"id"`
	Name                 string                `json:"name"`
	NameClipped          *bool                 `json:"name_clipped,omitempty"`
	Description          string                `json:"description"`
	DescriptionClipped   *bool                 `json:"description_clipped,omitempty"`
	FolderDisplay        string                `json:"folder_display"`
	FolderDisplayClipped *bool                 `json:"folder_display_clipped,omitempty"`
	Branch               string                `json:"branch"`
	BranchClipped        *bool                 `json:"branch_clipped,omitempty"`
	Detached             bool                  `json:"detached"`
	Changes              int                   `json:"changes"`
	OpenAsks             int                   `json:"open_asks"`
	OpenTargets          int                   `json:"open_targets"`
	InProgressTargets    int                   `json:"in_progress_targets"`
	BlockedTargets       int                   `json:"blocked_targets"`
	DoneTargets          int                   `json:"done_targets"`
	SessionCounts        sessionCounts         `json:"session_counts"`
	LastSessionActivity  *wire.Time            `json:"last_session_activity,omitempty"`
	ArchiveAfterDays     int                   `json:"archive_after_days"`
	TargetsMore          *int                  `json:"targets_more,omitempty"`
	DefaultAgent         string                `json:"default_agent"`
	Automations          []workbenchAutomation `json:"automations,omitempty"`
}

// workbenchRow is one projects row with the switcher's counts.
type workbenchRow struct {
	ref
	description, folder        string
	archiveAfterDays           int
	openAsks, open, inProgress int
	blocked                    int
	lastActivity               string
}

func (s *workbenchSource) Items(ctx context.Context) ([]slices.Item, error) {
	var items []slices.Item
	err := readTx(ctx, s.d, func(tx *sql.Tx) error {
		rows, err := workbenchRows(ctx, tx)
		if err != nil || len(rows) == 0 {
			return err
		}
		now := s.o.Now()
		window, err := loadTargetWindow(ctx, tx, now)
		if err != nil {
			return err
		}
		counts := map[int64]sessionCounts{}
		if s.o.Sessions != nil {
			if counts, err = s.o.Sessions.counts(ctx, tx); err != nil {
				return err
			}
		}
		autos, err := workbenchAutomations(ctx, tx)
		if err != nil {
			return err
		}
		agent := wireAgent(s.o.DefaultAgent())
		for _, r := range rows {
			p := s.payload(r, window, counts[r.id], agent)
			p.Automations = autos[r.id]
			b, err := wire.Marshal(p)
			if err != nil {
				return err
			}
			items = append(items, slices.Item{ID: strconv.FormatInt(r.id, 10), Payload: b})
		}
		return nil
	})
	return items, err
}

func (s *workbenchSource) payload(r workbenchRow, w targetWindow, sessions sessionCounts, agent string) workbenchPayload {
	name, nameClipped := clipText(r.name, maxWorkbenchTxt)
	desc, descClipped := clipText(r.description, maxDescription)
	folder, folderClipped := clipText(displayPath(r.folder, s.o.Home), maxFolder)
	var git GitSnapshot
	if s.o.GitStatus != nil {
		git, _ = s.o.GitStatus(r.id)
	}
	branch, branchClipped := clipText(git.Branch, maxBranch)
	var more *int
	if n := w.more[r.id]; n > 0 {
		more = &n
	}
	return workbenchPayload{
		ID: r.id, Name: name, NameClipped: nameClipped,
		Description: desc, DescriptionClipped: descClipped,
		FolderDisplay: folder, FolderDisplayClipped: folderClipped,
		Branch: branch, BranchClipped: branchClipped,
		Detached: git.Detached, Changes: git.Changes,
		OpenAsks: r.openAsks, OpenTargets: r.open, InProgressTargets: r.inProgress, BlockedTargets: r.blocked,
		DoneTargets:         w.doneUnarchived[r.id],
		SessionCounts:       sessions,
		LastSessionActivity: parseDate(r.lastActivity),
		ArchiveAfterDays:    r.archiveAfterDays,
		TargetsMore:         more,
		DefaultAgent:        agent,
	}
}

// displayPath is WorkbenchBranchPresentation.displayPath: a folder under
// home shown with "~", anything else as is.
func displayPath(path, home string) string {
	root := strings.TrimSuffix(home, "/")
	switch {
	case root == "":
		return path
	case path == root:
		return "~"
	case strings.HasPrefix(path, root+"/"):
		return "~" + path[len(root):]
	}
	return path
}

// wireAgent is TerminalSessionSlice.wireAgent: the Kit's agent raw value.
func wireAgent(k agentkind.Kind) string {
	if k == agentkind.Codex {
		return "codex_cli"
	}
	return "claude_code"
}

// ref is a published workbench's id and name.
type ref struct {
	id   int64
	name string
}

// workbenchRows is WorkbenchSlice.publishedWorkbenches: every workbench with
// the switcher's counts, ranked by rankWorkbenches.
func workbenchRows(ctx context.Context, tx *sql.Tx) ([]workbenchRow, error) {
	rows, err := tx.QueryContext(ctx, `
SELECT p.id, p.name, p.description, p.folder_path, p.archive_after_days,
       (SELECT COUNT(*) FROM owner_asks a WHERE a.project_id = p.id AND a.status = 'open' AND `+askVisible+`),
       (SELECT COUNT(*) FROM targets t WHERE t.project_id = p.id AND t.status IN ('todo','in_progress','in_review','blocked')),
       (SELECT COUNT(*) FROM targets t WHERE t.project_id = p.id AND t.status = 'in_progress'),
       (SELECT COUNT(*) FROM targets t WHERE t.project_id = p.id AND t.status = 'blocked'),
       COALESCE((SELECT MAX(s.last_active_at) FROM terminal_sessions s WHERE s.project_id = p.id), '')
FROM projects p
ORDER BY p.name COLLATE NOCASE, p.id`)
	if err != nil {
		return nil, fmt.Errorf("reading the workbenches: %w", err)
	}
	defer rows.Close()
	var out []workbenchRow
	for rows.Next() {
		var r workbenchRow
		if err := rows.Scan(&r.id, &r.name, &r.description, &r.folder, &r.archiveAfterDays,
			&r.openAsks, &r.open, &r.inProgress, &r.blocked, &r.lastActivity); err != nil {
			return nil, fmt.Errorf("reading the workbenches: %w", err)
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading the workbenches: %w", err)
	}
	return rankWorkbenches(out, func(r workbenchRow) string { return r.lastActivity }), nil
}

// publishedRefs is WorkbenchSlice.publishedWorkbenchRefs: workbenchRows'
// set in its order from one light query, for the sources that need only
// which workbenches are published.
func publishedRefs(ctx context.Context, tx *sql.Tx) ([]ref, error) {
	rows, err := tx.QueryContext(ctx, `
SELECT p.id, p.name, COALESCE(s.last, '')
FROM projects p
LEFT JOIN (
    SELECT project_id, MAX(last_active_at) AS last FROM terminal_sessions
    WHERE project_id IS NOT NULL GROUP BY project_id
) s ON s.project_id = p.id
ORDER BY p.name COLLATE NOCASE, p.id`)
	if err != nil {
		return nil, fmt.Errorf("reading the workbenches: %w", err)
	}
	defer rows.Close()
	type row struct {
		ref
		last string
	}
	var all []row
	for rows.Next() {
		var r row
		if err := rows.Scan(&r.id, &r.name, &r.last); err != nil {
			return nil, fmt.Errorf("reading the workbenches: %w", err)
		}
		all = append(all, r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading the workbenches: %w", err)
	}
	ranked := rankWorkbenches(all, func(r row) string { return r.last })
	out := make([]ref, len(ranked))
	for i, r := range ranked {
		out[i] = r.ref
	}
	return out, nil
}

// rankWorkbenches is WorkbenchSlice.ranked: the latest parsed session
// activity first, none (or an unparsable stamp) last, ties in the given
// (name) order; at most maxWorkbenches.
func rankWorkbenches[T any](items []T, activity func(T) string) []T {
	at := make([]*wire.Time, len(items))
	idx := make([]int, len(items))
	for i, it := range items {
		at[i] = parseDate(activity(it))
		idx[i] = i
	}
	sort.SliceStable(idx, func(a, b int) bool {
		l, r := at[idx[a]], at[idx[b]]
		switch {
		case l != nil && r != nil:
			return l.After(r.Time)
		default:
			return l != nil && r == nil
		}
	})
	n := min(len(idx), maxWorkbenches)
	out := make([]T, n)
	for i := range n {
		out[i] = items[idx[i]]
	}
	return out
}

// readTx runs fn in one read-only transaction, so a source's queries see
// one snapshot and never block a writer.
func readTx(ctx context.Context, d *db.DB, fn func(*sql.Tx) error) error {
	tx, err := d.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return fmt.Errorf("hub slices: opening a read: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	return fn(tx)
}

// workbenchAutomations is WorkbenchSlice.automations (ask #692): quick
// run's rows (QuickRunCatalog: removed recipes left out) of workbench
// recipes only, by workbench, manual and button recipes first, then the
// scheduled and event ones, each by name; at most maxAutomations each.
func workbenchAutomations(ctx context.Context, tx *sql.Tx) (map[int64][]workbenchAutomation, error) {
	rows, err := tx.QueryContext(ctx, `
SELECT a.id, a.project_id, a.slug, a.name, a.trigger_kind,
       COALESCE(json_extract(CASE WHEN json_valid(a.trigger_spec) THEN a.trigger_spec END, '$.button.confirm'), 0),
       a.parse_error, a.enabled, a.approval_hash, a.confirmed_hash,
       EXISTS (SELECT 1 FROM automation_runs r WHERE r.automation_id = a.id AND r.status IN ('queued','running','waiting')),
       l.status, l.finished_at, l.started_at, l.queued_at
FROM automations a
LEFT JOIN automation_runs l ON l.id = (
    SELECT MAX(r.id) FROM automation_runs r
    WHERE r.automation_id = a.id AND r.status NOT IN ('queued','running','waiting'))
WHERE a.removed_at IS NULL AND a.scope = 'workbench' AND a.project_id IS NOT NULL`)
	if err != nil {
		return nil, fmt.Errorf("reading the automations: %w", err)
	}
	defer rows.Close()
	type row struct {
		a         workbenchAutomation
		project   int64
		scheduled bool
	}
	var all []row
	for rows.Next() {
		var (
			r                                   row
			slug, name, trigger                 string
			confirm                             any
			parseError, approval, confirmedHash string
			enabled, active                     bool
			status, finished, started           sql.NullString
			queued                              sql.NullString
		)
		if err := rows.Scan(&r.a.ID, &r.project, &slug, &name, &trigger, &confirm, &parseError, &enabled,
			&approval, &confirmedHash, &active, &status, &finished, &started, &queued); err != nil {
			return nil, fmt.Errorf("reading the automations: %w", err)
		}
		if name == "" {
			name = slug
		}
		r.a.Name, r.a.NameClipped = clipText(name, maxWorkbenchTxt)
		switch trigger {
		case "schedule", "event":
			r.a.Kind, r.scheduled = "scheduled", true
		case "button":
			r.a.Kind = "button"
			r.a.AsksFirst = isTrue(confirm)
		default:
			r.a.Kind = "manual"
		}
		confirmed := confirmedHash != "" && confirmedHash == approval
		switch {
		case parseError != "":
			r.a.State = "parse_error"
		case active:
			r.a.State = "running"
		case enabled && confirmed:
			r.a.State = "runnable"
		case confirmed:
			r.a.State = "disabled"
		default:
			r.a.State = "needs_confirmation"
		}
		if status.Valid {
			s := status.String
			r.a.LastRunStatus = &s
			for _, at := range []sql.NullString{finished, started, queued} {
				if t := parseDate(at.String); at.Valid && t != nil {
					r.a.LastRunAt = t
					break
				}
			}
		}
		all = append(all, r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading the automations: %w", err)
	}
	sort.SliceStable(all, func(i, j int) bool {
		l, r := all[i], all[j]
		if l.scheduled != r.scheduled {
			return !l.scheduled
		}
		if ln, rn := strings.ToLower(l.a.Name), strings.ToLower(r.a.Name); ln != rn {
			return ln < rn
		}
		return l.a.ID < r.a.ID
	})
	out := map[int64][]workbenchAutomation{}
	for _, r := range all {
		if len(out[r.project]) < maxAutomations {
			out[r.project] = append(out[r.project], r.a)
		}
	}
	return out, nil
}

// isTrue reads a JSON true as SQLite's json_extract returns it (1).
func isTrue(v any) bool {
	switch x := v.(type) {
	case int64:
		return x == 1
	case bool:
		return x
	}
	return false
}
