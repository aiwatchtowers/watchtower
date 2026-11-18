package sessionreport

import (
	"context"
	"database/sql"
	"fmt"
	"slices"
	"strings"
	"time"

	"watchtower/internal/agentkind"
	"watchtower/internal/db"
)

// Summary is one agent session's row line (`session-report --summary`).
// FinishedAt is "" when the session is not finished.
type Summary struct {
	SessionID int64  `json:"session_id"`
	TargetID  *int64 `json:"target_id"`
	Done      int    `json:"done"`
	Total     int    `json:"total"`
	Merged    int    `json:"merged"` // not done, branch merged into its base (Progress.Merged)
	// MergedStale: the merge refresh before these lines could not check a
	// verdict Merged reads — a git call failed, the base did not resolve,
	// the budget ran out or the cache could not be read — so Merged counts
	// the last verdicts known (board #986, ask #525). Always false from
	// Summaries, which refreshes nothing, and in a folder outside a git
	// repository, where git has no verdict to give.
	MergedStale bool   `json:"merged_stale"`
	PRLine      string `json:"pr_line"`
	FinishedAt  string `json:"finished_at"`
}

// Summaries is the row line of every agent session (Claude Code or Codex;
// never a shell) of workbench workbenchID, in session id order, from the DB and
// the PR cache only — each session's from its own folder's cache.
func Summaries(ctx context.Context, d *db.DB, workbenchID int64) ([]Summary, error) {
	sessions, err := agentSessions(ctx, d, workbenchID)
	if err != nil {
		return nil, err
	}
	states := map[int64]map[string]db.PRState{}
	for _, f := range sessionFolders(sessions) {
		if states[f.id], err = folderPRStates(d, workbenchID, f.id); err != nil {
			return nil, err
		}
	}
	return summarize(sessions, states, nil), nil
}

// sessionFolders is the bench folders of sessions, each once, in order of
// first appearance.
func sessionFolders(sessions []agentSession) []benchFolder {
	var out []benchFolder
	seen := map[int64]bool{}
	for _, as := range sessions {
		if !seen[as.folder.id] {
			seen[as.folder.id] = true
			out = append(out, as.folder)
		}
	}
	return out
}

// RefreshedSummaries is Summaries after a refresh of the merge verdicts
// every agent session's counts read (board #986), each in the session's own
// folder (one refresh per folder, in order of first appearance, sharing the
// budget): git only — opts.Network is ignored, gh never runs — within
// opts.Budget (0 = SummaryRefreshBudget), each cache write waiting at most
// summaryWriteWait for the write lock (d's busy_timeout during the writes,
// restored after). A verdict read but not saved still counts in the rows.
// The board and each folder's cache are read once. The result's note says
// what could not be refreshed.
func RefreshedSummaries(ctx context.Context, d *db.DB, workbenchID int64, opts RefreshOptions) ([]Summary, RefreshResult, error) {
	sessions, err := agentSessions(ctx, d, workbenchID)
	if err != nil {
		return nil, RefreshResult{}, err
	}
	refs := map[int64][]string{}
	for _, as := range sessions {
		refs[as.folder.id] = append(refs[as.folder.id], as.sc.mergeRefs()...)
	}
	opts.Network = false
	if opts.Budget <= 0 {
		opts.Budget = SummaryRefreshBudget
	}
	if opts.Now == nil {
		opts.Now = time.Now
	}
	// The short write wait is the handle's busy_timeout while the refresh
	// writes; the caller's own wait comes back after. Without a readable one
	// the writes keep the handle's wait.
	var prevMS int64
	if err := d.QueryRowContext(ctx, "PRAGMA busy_timeout").Scan(&prevMS); err == nil {
		opts.writeWait = summaryWriteWait
		defer func() { _ = d.SetBusyTimeout(time.Duration(prevMS) * time.Millisecond) }()
	}
	deadline := opts.Now().Add(opts.Budget)
	states := map[int64]map[string]db.PRState{}
	unchecked := map[int64]map[string]bool{}
	var notes []string
	for _, f := range sessionFolders(sessions) {
		fo := opts
		fo.Budget = deadline.Sub(opts.Now())
		var res RefreshResult
		var cache map[string]db.PRState
		var left map[string]bool
		if fo.Budget > 0 {
			res, cache, left = refresh(ctx, d, workbenchID, f, refs[f.id], fo)
		} else {
			res.Note = fmt.Sprintf("the %s time budget ran out; %d ref(s) keep their cached state", opts.Budget, len(refs[f.id]))
		}
		if res.Note != "" {
			notes = append(notes, res.Note)
		}
		if cache == nil {
			if cache, err = folderPRStates(d, workbenchID, f.id); err != nil {
				return nil, RefreshResult{Note: strings.Join(notes, "; ")}, err
			}
			// Nothing was checked.
			left = map[string]bool{}
			for _, ref := range refs[f.id] {
				left[ref] = true
			}
		}
		states[f.id], unchecked[f.id] = cache, left
	}
	return summarize(sessions, states, unchecked), RefreshResult{Note: strings.Join(notes, "; ")}, nil
}

// summarize is each session's row line from its folder's PR cache (states,
// by folder id); a session whose Merged reads a ref unchecked in its folder
// (unchecked, by folder id) has MergedStale.
func summarize(sessions []agentSession, states map[int64]map[string]db.PRState, unchecked map[int64]map[string]bool) []Summary {
	out := []Summary{}
	for _, as := range sessions {
		s := as.row
		folderStates := states[as.folder.id]
		p := as.sc.counts(folderStates)
		s.Done, s.Total, s.Merged = p.Done, p.Total, p.Merged
		if left := unchecked[as.folder.id]; len(left) > 0 {
			s.MergedStale = slices.ContainsFunc(as.sc.countedMergeRefs(), func(ref string) bool { return left[ref] })
		}
		s.PRLine = as.sc.prLine(as.sc.prs(folderStates))
		out = append(out, s)
	}
	return out
}

// agentSession is one agent session's row fields (no counts yet), scope and
// bench folder.
type agentSession struct {
	row    Summary
	sc     scope
	folder benchFolder
}

// agentSessions is every agent session of workbench workbenchID with its
// scope, in session id order.
func agentSessions(ctx context.Context, d *db.DB, workbenchID int64) ([]agentSession, error) {
	b, err := loadBoard(d, workbenchID)
	if err != nil {
		return nil, err
	}
	links, err := workbenchLinks(ctx, d, workbenchID)
	if err != nil {
		return nil, err
	}
	owners, err := loadOwners(d, b, workbenchID)
	if err != nil {
		return nil, err
	}
	home, err := homeFolder(ctx, d, workbenchID)
	if err != nil {
		return nil, err
	}
	rows, err := d.QueryContext(ctx, `SELECT s.id, s.target_id, s.finished_at, f.id, f.folder_path
		FROM terminal_sessions s LEFT JOIN workbench_folders f ON f.id = s.workbench_folder_id
		WHERE s.project_id = ? AND s.kind IN `+agentkind.SQLKinds()+` ORDER BY s.id`, workbenchID)
	if err != nil {
		return nil, fmt.Errorf("listing workbench %d sessions: %w", workbenchID, err)
	}
	defer rows.Close()
	var out []agentSession
	for rows.Next() {
		var s Summary
		var target sql.NullInt64
		var finishedAt, folderPath sql.NullString
		var folderID sql.NullInt64
		if err := rows.Scan(&s.SessionID, &target, &finishedAt, &folderID, &folderPath); err != nil {
			return nil, fmt.Errorf("listing workbench %d sessions: %w", workbenchID, err)
		}
		s.TargetID, s.FinishedAt = nullableInt(target), finishedAt.String
		folder := home // a row with no folder reads as the home folder (db.SessionFolderID)
		if folderID.Valid {
			folder = benchFolder{id: folderID.Int64, path: folderPath.String}
		}
		out = append(out, agentSession{row: s, sc: newScope(b, s.SessionID, target, links[s.SessionID], owners), folder: folder})
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing workbench %d sessions: %w", workbenchID, err)
	}
	return out, nil
}

// prLine sums prs up from the cache: "PR #147 open" for one PR, "2 PRs
// merged" (one part per state) for several, "no PR yet" when there is none
// but a branch known to be unmerged carries done work, "not checked" when
// only a never-checked branch does (it may still carry a PR — the Session
// view's PR rows say the same), or "".
func (s scope) prLine(prs []PR) string {
	var withPR []PR
	noPRYet, notChecked := false, false
	for _, pr := range prs {
		if strings.HasPrefix(pr.Ref, "pr:") {
			withPR = append(withPR, pr)
			continue
		}
		if pr.State == "merged" || !s.doneWork(pr.Targets) {
			continue
		}
		if pr.State == "unknown" {
			notChecked = true
		} else {
			noPRYet = true
		}
	}
	switch {
	case len(withPR) == 1 && withPR[0].PRNumber != nil:
		line := fmt.Sprintf("PR #%d", *withPR[0].PRNumber)
		if knownPRState(withPR[0].State) {
			line += " " + withPR[0].State
		}
		return line
	case len(withPR) > 0:
		counts := map[string]int{}
		for _, pr := range withPR {
			if knownPRState(pr.State) {
				counts[pr.State]++
			} else {
				counts["not checked"]++
			}
		}
		var parts []string
		for _, state := range []string{"open", "merged", "closed", "not checked"} {
			if n := counts[state]; n == 1 {
				parts = append(parts, "1 PR "+state)
			} else if n > 1 {
				parts = append(parts, fmt.Sprintf("%d PRs %s", n, state))
			}
		}
		return strings.Join(parts, ", ")
	case noPRYet:
		return "no PR yet"
	case notChecked:
		return "not checked"
	}
	return ""
}

// doneWork reports whether one of targets is done or has a done leaf.
func (s scope) doneWork(targets []int64) bool {
	for _, id := range targets {
		if e, ok := s.b.byID[id]; ok && s.b.hasDoneWork(e) {
			return true
		}
	}
	return false
}

func knownPRState(state string) bool {
	return state == "open" || state == "merged" || state == "closed"
}
