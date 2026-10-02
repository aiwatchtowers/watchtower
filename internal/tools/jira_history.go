package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strings"
	"time"

	"watchtower/internal/db"
)

// timeInStatusNote is attached to every time-in-status answer: the numbers
// are elapsed time, and nothing in Jira says anyone worked on the issue.
const timeInStatusNote = "time in status: wall-clock time an issue spent in a status while assigned to that person " +
	"(nights and weekends included) — not hours worked; the company keeps no worklogs."

const (
	maxHistoryKeys            = 50
	defaultTimeInStatusDays   = 30
	defaultTimeInStatusLimit  = 300
	maxTimeInStatusIntervals  = 2000
	maxIssuesListed           = 100
	historyStateSynced        = "synced"
	historyStateStale         = "stale"
	historyStateMissing       = "missing"
	statusCategoryDone        = "done"
	timeInStatusHoursDecimals = 100
)

// statusInterval is one stretch of an issue's life in one status under one
// assignee.
type statusInterval struct {
	Key               string    `json:"key"`
	Status            string    `json:"status"`
	StatusCategory    string    `json:"status_category,omitempty"`
	AssigneeAccountID string    `json:"assignee_account_id,omitempty"`
	Assignee          string    `json:"assignee,omitempty"`
	Start             time.Time `json:"start"`
	End               time.Time `json:"end"`
	Hours             float64   `json:"hours"`
}

func roundHours(d time.Duration) float64 {
	return math.Round(d.Hours()*timeInStatusHoursDecimals) / timeInStatusHoursDecimals
}

func parseStored(s string) (time.Time, bool) {
	unix, ok := db.ParseJiraTime(s)
	if !ok {
		return time.Time{}, false
	}
	return time.Unix(unix, 0).UTC(), true
}

// buildStatusIntervals reconstructs an issue's (status, assignee) timeline
// from its creation to end. The status before the first status change is
// that change's "from" (no change: the current status); the same for the
// assignee. Changes are applied in stored order (oldest first); a change
// before creation, at the same instant as the previous one, or with an
// unreadable time only updates the state. ok is false when the issue's own
// creation time is unreadable: there is no timeline to build.
func buildStatusIntervals(is db.JiraHistoryIssue, items []db.JiraChangelogItem, end time.Time) (_ []statusInterval, ok bool) {
	start, ok := parseStored(is.CreatedAt)
	if !ok {
		return nil, false
	}
	status, assigneeID, assignee := is.Status, is.AssigneeAccountID, is.AssigneeDisplayName
	seenStatus, seenAssignee := false, false
	for _, it := range items {
		switch {
		case it.Field == "status" && !seenStatus:
			status, seenStatus = it.FromString, true
		case it.Field == "assignee" && !seenAssignee:
			assigneeID, assignee, seenAssignee = it.FromValue, it.FromString, true
		}
	}

	var out []statusInterval
	emit := func(to time.Time) {
		if to.After(start) {
			out = append(out, statusInterval{
				Key: is.Key, Status: status, AssigneeAccountID: assigneeID, Assignee: assignee,
				Start: start, End: to, Hours: roundHours(to.Sub(start)),
			})
			start = to
		}
	}
	for _, it := range items {
		if at, ok := parseStored(it.ChangedAt); ok {
			if at.After(end) {
				break
			}
			emit(at)
		}
		switch it.Field {
		case "status":
			status = it.ToString
		case "assignee":
			assigneeID, assignee = it.ToValue, it.ToString
		}
	}
	emit(end)
	return out, true
}

// clipInterval cuts iv to [since, until); ok is false when nothing is left.
func clipInterval(iv statusInterval, since, until time.Time) (statusInterval, bool) {
	if iv.Start.Before(since) {
		iv.Start = since
	}
	if iv.End.After(until) {
		iv.End = until
	}
	if !iv.End.After(iv.Start) {
		return iv, false
	}
	iv.Hours = roundHours(iv.End.Sub(iv.Start))
	return iv, true
}

func historyState(is db.JiraHistoryIssue) string {
	switch is.ChangelogUpdatedAt {
	case "":
		return historyStateMissing
	case is.UpdatedAt:
		return historyStateSynced
	default:
		return historyStateStale
	}
}

// changelogByAccount loads the stored changelog of issues, per account.
func changelogByAccount(d *db.DB, issues []db.JiraHistoryIssue) (map[int64]map[string][]db.JiraChangelogItem, error) {
	keys := map[int64][]string{}
	for _, is := range issues {
		keys[is.AccountID] = append(keys[is.AccountID], is.Key)
	}
	out := map[int64]map[string][]db.JiraChangelogItem{}
	for accountID, ks := range keys {
		m, err := d.ListJiraIssueChangelog(accountID, ks)
		if err != nil {
			return nil, err
		}
		out[accountID] = m
	}
	return out, nil
}

// --- get_jira_status_history ---

type getJiraStatusHistoryArgs struct {
	Keys      []string `json:"keys" jsonschema:"Jira issue keys, e.g. [\"ABC-123\"], at most 50"`
	AccountID int64    `json:"account_id,omitempty" jsonschema:"connected Jira account id; only needed when two sites share a key"`
}

type historyEvent struct {
	At              string `json:"at"`
	Field           string `json:"field"`
	From            string `json:"from,omitempty"`
	To              string `json:"to,omitempty"`
	FromAccountID   string `json:"from_account_id,omitempty"`
	ToAccountID     string `json:"to_account_id,omitempty"`
	Author          string `json:"author,omitempty"`
	AuthorAccountID string `json:"author_account_id,omitempty"`
}

type issueHistoryView struct {
	Key               string           `json:"key"`
	AccountID         int64            `json:"account_id"`
	Source            string           `json:"source"`
	Summary           string           `json:"summary"`
	Status            string           `json:"status"`
	StatusCategory    string           `json:"status_category"`
	Assignee          string           `json:"assignee,omitempty"`
	AssigneeAccountID string           `json:"assignee_account_id,omitempty"`
	CreatedAt         string           `json:"created_at"`
	History           string           `json:"history"`
	Events            []historyEvent   `json:"events"`
	StatusIntervals   []statusInterval `json:"status_intervals"`
}

type statusHistoryResult struct {
	Note     string             `json:"note"`
	Issues   []issueHistoryView `json:"issues"`
	NotFound []string           `json:"not_found,omitempty"`
}

// NewGetJiraStatusHistory returns the synced status/assignee history of
// Jira issues (board issues and linked issues from other boards).
func NewGetJiraStatusHistory() *Tool {
	return &Tool{
		Name: "get_jira_status_history",
		Description: "Get the status and assignee change history of Jira issues (who changed what, when) plus the derived " +
			"time-in-status intervals over each issue's life. Covers the synced boards and the issues they link to on " +
			"other boards. Intervals are wall-clock time in a status, NOT hours worked. history=missing means the " +
			"history has not been synced yet; stale means the issue changed after it was synced.",
		InputSchema: mustSchema[getJiraStatusHistoryArgs]("get_jira_status_history"),
		Access:      AccessRead,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a getJiraStatusHistoryArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			keys := normalizeKeys(a.Keys)
			if len(keys) == 0 {
				return nil, &ValidationError{Msg: "keys is required"}
			}
			if len(keys) > maxHistoryKeys {
				return nil, &ValidationError{Msg: fmt.Sprintf("at most %d keys per call", maxHistoryKeys)}
			}
			issues, err := d.ListJiraHistoryIssues(db.JiraHistoryFilter{AccountID: a.AccountID, Keys: keys})
			if err != nil {
				return nil, fmt.Errorf("listing jira issues: %w", err)
			}
			changelogs, err := changelogByAccount(d, issues)
			if err != nil {
				return nil, fmt.Errorf("reading jira history: %w", err)
			}
			cats, err := d.JiraStatusCategories()
			if err != nil {
				return nil, fmt.Errorf("reading jira status categories: %w", err)
			}
			now := time.Now().UTC()
			res := statusHistoryResult{Note: timeInStatusNote, Issues: []issueHistoryView{}}
			found := map[string]bool{}
			for _, is := range issues {
				found[is.Key] = true
				items := changelogs[is.AccountID][is.Key]
				view := issueHistoryView{
					Key: is.Key, AccountID: is.AccountID, Source: is.Source, Summary: is.Summary,
					Status: is.Status, StatusCategory: is.StatusCategory,
					Assignee: is.AssigneeDisplayName, AssigneeAccountID: is.AssigneeAccountID,
					CreatedAt: is.CreatedAt, History: historyState(is),
					Events: make([]historyEvent, 0, len(items)), StatusIntervals: []statusInterval{},
				}
				for _, it := range items {
					ev := historyEvent{At: it.ChangedAt, Field: it.Field, From: it.FromString, To: it.ToString,
						Author: it.AuthorDisplayName, AuthorAccountID: it.AuthorAccountID}
					if it.Field == "assignee" {
						ev.FromAccountID, ev.ToAccountID = it.FromValue, it.ToValue
					}
					view.Events = append(view.Events, ev)
				}
				if view.History != historyStateMissing {
					intervals, _ := buildStatusIntervals(is, items, now) // an unreadable created_at leaves the list empty
					for _, iv := range intervals {
						iv.StatusCategory = cats[iv.Status]
						view.StatusIntervals = append(view.StatusIntervals, iv)
					}
				}
				res.Issues = append(res.Issues, view)
			}
			for _, k := range keys {
				if !found[k] {
					res.NotFound = append(res.NotFound, k)
				}
			}
			return res, nil
		},
	}
}

// normalizeKeys trims, upper-cases and de-duplicates issue keys.
func normalizeKeys(in []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, k := range in {
		k = strings.ToUpper(strings.TrimSpace(k))
		if k != "" && !seen[k] {
			seen[k] = true
			out = append(out, k)
		}
	}
	return out
}

// --- get_jira_time_in_status ---

type jiraTimeInStatusArgs struct {
	BoardID       int      `json:"board_id,omitempty" jsonschema:"synced Jira board id; narrows to that board's issues"`
	Project       string   `json:"project,omitempty" jsonschema:"Jira project key, e.g. ABC"`
	IssueKeys     []string `json:"issue_keys,omitempty" jsonschema:"explicit issue keys (board or linked issues)"`
	IncludeLinked *bool    `json:"include_linked,omitempty" jsonschema:"also count issues linked from the selected ones, on any board (default true)"`
	Assignee      string   `json:"assignee,omitempty" jsonschema:"only intervals with this assignee: Jira account id, or a case-insensitive part of the display name"`
	Statuses      []string `json:"statuses,omitempty" jsonschema:"only these exact status names, e.g. [\"In Progress\",\"Code Review\"]"`
	IncludeDone   bool     `json:"include_done,omitempty" jsonschema:"keep statuses of the done category (left out by default unless named in statuses)"`
	Since         string   `json:"since,omitempty" jsonschema:"period start, YYYY-MM-DD or RFC3339 (default 30 days before until)"`
	Until         string   `json:"until,omitempty" jsonschema:"period end, YYYY-MM-DD (inclusive day) or RFC3339 (default now)"`
	AccountID     int64    `json:"account_id,omitempty" jsonschema:"connected Jira account id (default: every account)"`
	Limit         int      `json:"limit,omitempty" jsonschema:"max raw intervals returned, default 300, capped at 2000; totals always cover everything"`
}

type timeInStatusTotal struct {
	AssigneeAccountID string  `json:"assignee_account_id,omitempty"`
	Assignee          string  `json:"assignee"`
	Status            string  `json:"status,omitempty"`
	Hours             float64 `json:"hours"`
	Issues            int     `json:"issues"`
}

type timeInStatusResult struct {
	Note             string              `json:"note"`
	Since            time.Time           `json:"since"`
	Until            time.Time           `json:"until"`
	IssuesConsidered int                 `json:"issues_considered"`
	Totals           []timeInStatusTotal `json:"totals"`
	PerAssignee      []timeInStatusTotal `json:"per_assignee"`
	Intervals        []statusInterval    `json:"intervals"`
	Truncated        bool                `json:"truncated"`
	// IssuesWithoutHistoryCount issues are left out of every total (history
	// not synced yet, or an unreadable creation time); the list names at most
	// maxIssuesListed of them. Stale issues are counted in.
	IssuesWithoutHistoryCount   int      `json:"issues_without_history_count"`
	IssuesWithoutHistory        []string `json:"issues_without_history,omitempty"`
	IssuesWithStaleHistoryCount int      `json:"issues_with_stale_history_count"`
	IssuesWithStaleHistory      []string `json:"issues_with_stale_history,omitempty"`
	// StatusesWithoutCategory are counted statuses no synced issue holds now,
	// so their category (and whether they are "done") is unknown.
	StatusesWithoutCategory []string          `json:"statuses_without_category,omitempty"`
	StatusCategories        map[string]string `json:"status_categories"`
}

// timeInStatusPeriod resolves since/until: a date-only until covers that
// whole day; defaults are the last defaultTimeInStatusDays days up to now.
func timeInStatusPeriod(sinceArg, untilArg string, now time.Time) (time.Time, time.Time, error) {
	until := now
	if s := strings.TrimSpace(untilArg); s != "" {
		if t, err := time.ParseInLocation("2006-01-02", s, time.Local); err == nil {
			until = t.AddDate(0, 0, 1)
		} else if t, err := time.Parse(time.RFC3339, s); err == nil {
			until = t
		} else {
			return time.Time{}, time.Time{}, &ValidationError{Msg: "until must be YYYY-MM-DD or RFC3339"}
		}
	}
	if until.After(now) {
		until = now
	}
	since := until.AddDate(0, 0, -defaultTimeInStatusDays)
	if s := strings.TrimSpace(sinceArg); s != "" {
		t, err := parseSince(s)
		if err != nil {
			return time.Time{}, time.Time{}, &ValidationError{Msg: "since must be YYYY-MM-DD or RFC3339"}
		}
		since = t
	}
	if !until.After(since) {
		return time.Time{}, time.Time{}, &ValidationError{Msg: "since must be before until (and before now)"}
	}
	return since.UTC(), until.UTC(), nil
}

// NewGetJiraTimeInStatus sums time in status per assignee over a period for a
// board / project / key set, including linked issues on other boards.
func NewGetJiraTimeInStatus() *Tool {
	return &Tool{
		Name: "get_jira_time_in_status",
		Description: "Time in status per assignee over a period, reconstructed from the synced Jira status/assignee " +
			"history: for a board, project or issue keys, by default including the issues they link to on other " +
			"boards. Returns totals per (assignee, status), per-assignee totals and the raw intervals clipped to the " +
			"period. This is wall-clock time in a status, NOT hours worked (no worklogs exist) — say so when you " +
			"answer. Done-category statuses are left out unless include_done or named in statuses.",
		InputSchema: mustSchema[jiraTimeInStatusArgs]("get_jira_time_in_status"),
		Access:      AccessRead,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a jiraTimeInStatusArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			now := time.Now().UTC()
			since, until, err := timeInStatusPeriod(a.Since, a.Until, now)
			if err != nil {
				return nil, err
			}
			includeLinked := a.IncludeLinked == nil || *a.IncludeLinked
			issues, err := d.ListJiraHistoryIssues(db.JiraHistoryFilter{
				AccountID: a.AccountID, Keys: normalizeKeys(a.IssueKeys), BoardID: a.BoardID,
				ProjectKey: strings.ToUpper(strings.TrimSpace(a.Project)), IncludeLinked: includeLinked,
				ActiveSince: activeSince(a, since),
			})
			if err != nil {
				return nil, fmt.Errorf("listing jira issues: %w", err)
			}
			cats, err := d.JiraStatusCategories()
			if err != nil {
				return nil, fmt.Errorf("reading jira status categories: %w", err)
			}
			changelogs, err := changelogByAccount(d, issues)
			if err != nil {
				return nil, fmt.Errorf("reading jira history: %w", err)
			}
			return timeInStatus(a, issues, changelogs, cats, since, until), nil
		},
	}
}

// activeSince is the done-issue pre-filter: an issue already done before the
// period only adds done-category time, so it is skipped unless the caller
// asked for done time (include_done, or any explicit statuses).
func activeSince(a jiraTimeInStatusArgs, since time.Time) string {
	if a.IncludeDone || len(a.Statuses) > 0 {
		return ""
	}
	return db.FormatJiraTime(since)
}

// timeInStatus is the tool's pure part: reconstruct, clip, filter, sum.
func timeInStatus(a jiraTimeInStatusArgs, issues []db.JiraHistoryIssue, changelogs map[int64]map[string][]db.JiraChangelogItem,
	cats map[string]string, since, until time.Time) timeInStatusResult {
	limit := a.Limit
	if limit <= 0 {
		limit = defaultTimeInStatusLimit
	}
	if limit > maxTimeInStatusIntervals {
		limit = maxTimeInStatusIntervals
	}
	wantStatus := map[string]bool{}
	for _, s := range a.Statuses {
		wantStatus[strings.TrimSpace(s)] = true
	}
	assignee := strings.TrimSpace(a.Assignee)
	keep := func(iv statusInterval) bool {
		if len(wantStatus) > 0 {
			if !wantStatus[iv.Status] {
				return false
			}
		} else if !a.IncludeDone && iv.StatusCategory == statusCategoryDone {
			return false
		}
		if assignee == "" {
			return true
		}
		return iv.AssigneeAccountID == assignee ||
			(iv.Assignee != "" && strings.Contains(strings.ToLower(iv.Assignee), strings.ToLower(assignee)))
	}

	res := timeInStatusResult{Note: timeInStatusNote, Since: since, Until: until, IssuesConsidered: len(issues),
		Intervals: []statusInterval{}, StatusCategories: cats}
	// A person is keyed by account id (their display name can differ between
	// the issue row and the changelog); a name stands in only without one.
	type totalKey struct{ person, status string }
	totals := map[totalKey]*timeInStatusTotal{}
	totalIssues := map[totalKey]map[string]bool{}
	type shownName struct {
		name string
		at   time.Time
	}
	names := map[string]shownName{} // person → their latest display name
	uncategorized := map[string]bool{}
	var all []statusInterval
	for _, is := range issues {
		state := historyState(is)
		intervals, ok := buildStatusIntervals(is, changelogs[is.AccountID][is.Key], until)
		if state == historyStateMissing || !ok {
			res.IssuesWithoutHistoryCount++
			if len(res.IssuesWithoutHistory) < maxIssuesListed {
				res.IssuesWithoutHistory = append(res.IssuesWithoutHistory, is.Key)
			}
			continue
		}
		if state == historyStateStale {
			res.IssuesWithStaleHistoryCount++
			if len(res.IssuesWithStaleHistory) < maxIssuesListed {
				res.IssuesWithStaleHistory = append(res.IssuesWithStaleHistory, is.Key)
			}
		}
		issueID := fmt.Sprintf("%d/%s", is.AccountID, is.Key)
		for _, iv := range intervals {
			iv.StatusCategory = cats[iv.Status]
			iv, ok := clipInterval(iv, since, until)
			if !ok || !keep(iv) {
				continue
			}
			all = append(all, iv)
			if iv.StatusCategory == "" {
				uncategorized[iv.Status] = true
			}
			person := iv.AssigneeAccountID
			if person == "" {
				person = "name:" + iv.Assignee
			}
			for _, k := range []totalKey{{person, iv.Status}, {person, ""}} {
				t := totals[k]
				if t == nil {
					t = &timeInStatusTotal{AssigneeAccountID: iv.AssigneeAccountID, Status: k.status}
					totals[k] = t
					totalIssues[k] = map[string]bool{}
				}
				t.Hours += iv.End.Sub(iv.Start).Hours()
				totalIssues[k][issueID] = true
			}
			if iv.Assignee != "" && !iv.End.Before(names[person].at) {
				names[person] = shownName{iv.Assignee, iv.End}
			}
		}
	}
	for st := range uncategorized {
		res.StatusesWithoutCategory = append(res.StatusesWithoutCategory, st)
	}
	sort.Strings(res.StatusesWithoutCategory)
	for k, t := range totals {
		t.Assignee = names[k.person].name
		t.Hours = math.Round(t.Hours*timeInStatusHoursDecimals) / timeInStatusHoursDecimals
		t.Issues = len(totalIssues[k])
		if t.Assignee == "" && t.AssigneeAccountID == "" {
			t.Assignee = "(unassigned)"
		}
		if k.status == "" {
			res.PerAssignee = append(res.PerAssignee, *t)
		} else {
			res.Totals = append(res.Totals, *t)
		}
	}
	byHours := func(s []timeInStatusTotal) {
		sort.Slice(s, func(i, j int) bool {
			if s[i].Hours != s[j].Hours {
				return s[i].Hours > s[j].Hours
			}
			return s[i].Assignee+s[i].Status < s[j].Assignee+s[j].Status
		})
	}
	byHours(res.Totals)
	byHours(res.PerAssignee)
	if res.Totals == nil {
		res.Totals = []timeInStatusTotal{}
		res.PerAssignee = []timeInStatusTotal{}
	}
	sort.SliceStable(all, func(i, j int) bool { return all[i].Start.Before(all[j].Start) })
	if len(all) > limit {
		all, res.Truncated = all[:limit], true
	}
	res.Intervals = append(res.Intervals, all...)
	return res
}
