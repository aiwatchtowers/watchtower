package sessionreport

import (
	"context"
	"database/sql"
	"fmt"
	"slices"
	"strings"

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
// the PR cache only.
func Summaries(ctx context.Context, d *db.DB, workbenchID int64) ([]Summary, error) {
	sessions, err := agentSessions(ctx, d, workbenchID)
	if err != nil {
		return nil, err
	}
	states, err := d.PRStates(workbenchID)
	if err != nil {
		return nil, err
	}
	return summarize(sessions, states, nil), nil
}

// RefreshedSummaries is Summaries after a refresh of the merge verdicts
// every agent session's counts read (board #986): git only — opts.Network
// is ignored, gh never runs — within opts.Budget (0 = SummaryRefreshBudget),
// each cache write waiting at most summaryWriteWait for the write lock (it
// sets d's busy_timeout: d is the caller's own handle). A verdict read but
// not saved still counts in the rows. The board and the cache are each read
// once. The result's note says what could not be refreshed.
func RefreshedSummaries(ctx context.Context, d *db.DB, workbenchID int64, opts RefreshOptions) ([]Summary, RefreshResult, error) {
	sessions, err := agentSessions(ctx, d, workbenchID)
	if err != nil {
		return nil, RefreshResult{}, err
	}
	var refs []string
	for _, as := range sessions {
		refs = append(refs, as.sc.mergeRefs()...)
	}
	opts.Network, opts.writeWait = false, summaryWriteWait
	if opts.Budget <= 0 {
		opts.Budget = SummaryRefreshBudget
	}
	res, states, unchecked := refresh(ctx, d, workbenchID, refs, opts)
	if states == nil {
		if states, err = d.PRStates(workbenchID); err != nil {
			return nil, res, err
		}
		// Nothing was checked.
		unchecked = map[string]bool{}
		for _, ref := range refs {
			unchecked[ref] = true
		}
	}
	return summarize(sessions, states, unchecked), res, nil
}

// summarize is each session's row line from the PR cache states; a
// session whose Merged reads a ref in unchecked has MergedStale.
func summarize(sessions []agentSession, states map[string]db.PRState, unchecked map[string]bool) []Summary {
	out := []Summary{}
	for _, as := range sessions {
		s := as.row
		p := as.sc.counts(states)
		s.Done, s.Total, s.Merged = p.Done, p.Total, p.Merged
		if len(unchecked) > 0 {
			s.MergedStale = slices.ContainsFunc(as.sc.countedMergeRefs(), func(ref string) bool { return unchecked[ref] })
		}
		s.PRLine = as.sc.prLine(as.sc.prs(states))
		out = append(out, s)
	}
	return out
}

// agentSession is one agent session's row fields (no counts yet) and scope.
type agentSession struct {
	row Summary
	sc  scope
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
	rows, err := d.QueryContext(ctx, `SELECT id, target_id, finished_at FROM terminal_sessions
		WHERE project_id = ? AND kind IN `+agentkind.SQLKinds()+` ORDER BY id`, workbenchID)
	if err != nil {
		return nil, fmt.Errorf("listing workbench %d sessions: %w", workbenchID, err)
	}
	defer rows.Close()
	var out []agentSession
	for rows.Next() {
		var s Summary
		var target sql.NullInt64
		var finishedAt sql.NullString
		if err := rows.Scan(&s.SessionID, &target, &finishedAt); err != nil {
			return nil, fmt.Errorf("listing workbench %d sessions: %w", workbenchID, err)
		}
		s.TargetID, s.FinishedAt = nullableInt(target), finishedAt.String
		out = append(out, agentSession{row: s, sc: newScope(b, s.SessionID, target, links[s.SessionID], owners)})
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
