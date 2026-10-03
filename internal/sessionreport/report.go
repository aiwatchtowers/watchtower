// Package sessionreport builds a workbench terminal session's report: what
// the session's agent worked on, how far it got, which PRs carry the work and
// what waits on the owner (spec 2026-10-03-workbench-session-report Part 6).
// Build and Summaries only read the DB and the PR cache; they never write a
// target, a status or a comment (PROJ-14).
package sessionreport

import (
	"context"
	"database/sql"
	"slices"
	"strconv"
	"strings"

	"watchtower/internal/db"
)

// maxNext caps Report.Next.
const maxNext = 3

// Options tunes Build.
type Options struct {
	// PRNote says why PR state may be incomplete (the refresh's note); it is
	// the report's pr_note.
	PRNote string
}

// Report is one session's report, also the `session-report --json` output.
type Report struct {
	Session  Session   `json:"session"`
	Progress Progress  `json:"progress"`
	OnYou    []Ask     `json:"on_you"`
	Now      []NowItem `json:"now"`
	Next     []Item    `json:"next"`
	Phases   []Phase   `json:"phases"`
	PRs      []PR      `json:"prs"`
	PRNote   string    `json:"pr_note"`
}

// Session is the terminal_sessions row the report is about. A NULL text
// column reads as "".
type Session struct {
	ID            int64  `json:"id"`
	Title         string `json:"title"`
	TargetID      *int64 `json:"target_id"`
	Kind          string `json:"kind"`
	CreatedAt     string `json:"created_at"`
	LastActiveAt  string `json:"last_active_at"`
	AgentState    string `json:"agent_state"`
	AgentStateAt  string `json:"agent_state_at"`
	FinishedAt    string `json:"finished_at"`
	FinishSummary string `json:"finish_summary"`
}

// Progress counts the in-scope leaves: Done are done, Total leaves out
// dismissed ones.
type Progress struct {
	Done  int `json:"done"`
	Total int `json:"total"`
}

// Ask is one of the session's open asks.
type Ask struct {
	ID        int64  `json:"id"`
	Kind      string `json:"kind"`
	Title     string `json:"title"`
	TargetID  *int64 `json:"target_id"`
	CreatedAt string `json:"created_at"`
}

// Item is one leaf target.
type Item struct {
	ID     int64  `json:"id"`
	Text   string `json:"text"`
	Status string `json:"status"`
}

// NowItem is an in-scope leaf being worked on, in review or blocked. Since is
// when it entered its status (its latest history row), "" when unknown.
type NowItem struct {
	Item
	Branch string `json:"branch"`
	Since  string `json:"since"`
}

// Phase is a parent of in-scope leaves. Done and Total count all its
// non-dismissed leaf descendants; StartedAt is the earliest move of one of
// them to in_progress, FinishedAt the latest move to done, set only when all
// are done.
type Phase struct {
	TargetID   int64  `json:"target_id"`
	Text       string `json:"text"`
	Done       int    `json:"done"`
	Total      int    `json:"total"`
	StartedAt  string `json:"started_at"`
	FinishedAt string `json:"finished_at"`
	Items      []Item `json:"items"`
}

// PR is a pull request or a branch of in-scope targets with its cached state.
// A branch whose PR is known is folded into that PR's entry. A ref never
// cached has State "unknown" and an empty CheckedAt.
type PR struct {
	Ref       string  `json:"ref"`
	PRNumber  *int64  `json:"pr_number"`
	Title     string  `json:"title"`
	State     string  `json:"state"`
	Additions *int64  `json:"additions"`
	Deletions *int64  `json:"deletions"`
	MergedAt  string  `json:"merged_at"`
	CheckedAt string  `json:"checked_at"`
	Targets   []int64 `json:"targets"`
}

// Build reads session sessionID's report from the DB and the PR cache of
// workbench projectID. A missing session, or one of another workbench, is
// db.ErrTerminalSessionNotFound.
func Build(ctx context.Context, d *db.DB, projectID, sessionID int64, opts Options) (Report, error) {
	sess, sc, err := loadScope(ctx, d, projectID, sessionID)
	if err != nil {
		return Report{}, err
	}
	states, err := d.PRStates(projectID)
	if err != nil {
		return Report{}, err
	}
	spans, err := statusSpans(ctx, d, projectID)
	if err != nil {
		return Report{}, err
	}
	asks, err := d.ListOwnerAsks(projectID, db.OwnerAskFilter{Statuses: []string{"open"}, SessionID: sessionID})
	if err != nil {
		return Report{}, err
	}
	r := Report{Session: sess, Progress: sc.progress(), OnYou: []Ask{}, Now: []NowItem{}, Next: []Item{},
		Phases: sc.phases(spans), PRs: sc.prs(states), PRNote: opts.PRNote}
	for _, a := range asks {
		r.OnYou = append(r.OnYou, Ask{ID: a.ID, Kind: a.Kind, Title: a.Title, TargetID: nullableInt(a.TargetID),
			CreatedAt: a.CreatedAt})
	}
	for _, e := range sc.leaves() {
		switch e.target.Status {
		case "in_progress", "in_review", "blocked":
			r.Now = append(r.Now, NowItem{Item: itemOf(e), Branch: e.target.Branch, Since: e.since})
		case "todo":
			if len(r.Next) < maxNext {
				r.Next = append(r.Next, itemOf(e))
			}
		}
	}
	return r, nil
}

func itemOf(e *boardEntry) Item {
	return Item{ID: e.id(), Text: e.target.Text, Status: e.target.Status}
}

// prs is the distinct PRs and branches of the in-scope targets, in board
// order of first appearance. A branch whose cached row names its PR joins
// that PR's entry, whose state comes from the PR's own row when cached and
// from the branch's row otherwise.
func (s scope) prs(states map[string]db.PRState) []PR {
	type entry struct {
		number  sql.NullInt64
		via     *db.PRState // the branch row that named this PR
		targets []int64
	}
	var keys []string
	byKey := map[string]*entry{}
	add := func(key string, number sql.NullInt64, via *db.PRState, target int64) {
		e, ok := byKey[key]
		if !ok {
			e = &entry{number: number}
			byKey[key] = e
			keys = append(keys, key)
		}
		if e.via == nil {
			e.via = via
		}
		if !slices.Contains(e.targets, target) {
			e.targets = append(e.targets, target)
		}
	}
	for _, t := range s.targets() {
		if p := strings.TrimSpace(t.target.PR); p != "" {
			key, number := prRef(p)
			add(key, number, nil, t.id())
		}
		br := strings.TrimSpace(t.target.Branch)
		if br == "" {
			continue
		}
		if row, ok := states[branchRef(br)]; ok && row.PRNumber.Valid {
			add("pr:"+strconv.FormatInt(row.PRNumber.Int64, 10), row.PRNumber, &row, t.id())
			continue
		}
		add(branchRef(br), sql.NullInt64{}, nil, t.id())
	}
	out := make([]PR, 0, len(keys))
	for _, key := range keys {
		e := byKey[key]
		pr := PR{Ref: key, State: "unknown", Targets: e.targets}
		row, ok := states[key]
		if !ok && e.via != nil {
			row, ok = *e.via, true
		}
		if ok {
			pr.Title, pr.State, pr.MergedAt, pr.CheckedAt = row.Title, row.State, row.MergedAt, row.CheckedAt
			pr.Additions, pr.Deletions = nullableInt(row.Additions), nullableInt(row.Deletions)
			if !e.number.Valid {
				e.number = row.PRNumber
			}
		}
		pr.PRNumber = nullableInt(e.number)
		out = append(out, pr)
	}
	return out
}
