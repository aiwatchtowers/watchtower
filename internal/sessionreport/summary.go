package sessionreport

import (
	"context"
	"database/sql"
	"fmt"
	"strings"

	"watchtower/internal/db"
)

// Summary is one claude session's row line (`session-report --summary`).
// FinishedAt is "" when the session is not finished.
type Summary struct {
	SessionID  int64  `json:"session_id"`
	TargetID   *int64 `json:"target_id"`
	Done       int    `json:"done"`
	Total      int    `json:"total"`
	PRLine     string `json:"pr_line"`
	FinishedAt string `json:"finished_at"`
}

// Summaries is the row line of every claude session of workbench projectID,
// in session id order, from the DB and the PR cache only.
func Summaries(ctx context.Context, d *db.DB, projectID int64) ([]Summary, error) {
	b, err := loadBoard(d, projectID)
	if err != nil {
		return nil, err
	}
	states, err := d.PRStates(projectID)
	if err != nil {
		return nil, err
	}
	links, err := workbenchLinks(ctx, d, projectID)
	if err != nil {
		return nil, err
	}
	rows, err := d.QueryContext(ctx, `SELECT id, target_id, finished_at FROM terminal_sessions
		WHERE project_id = ? AND kind = 'claude' ORDER BY id`, projectID)
	if err != nil {
		return nil, fmt.Errorf("listing workbench %d sessions: %w", projectID, err)
	}
	defer rows.Close()
	out := []Summary{}
	for rows.Next() {
		var s Summary
		var target sql.NullInt64
		var finishedAt sql.NullString
		if err := rows.Scan(&s.SessionID, &target, &finishedAt); err != nil {
			return nil, fmt.Errorf("listing workbench %d sessions: %w", projectID, err)
		}
		sc := newScope(b, target, links[s.SessionID])
		p := sc.progress()
		s.TargetID, s.Done, s.Total, s.FinishedAt = nullableInt(target), p.Done, p.Total, finishedAt.String
		s.PRLine = sc.prLine(sc.prs(states))
		out = append(out, s)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing workbench %d sessions: %w", projectID, err)
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
