package automations

import (
	"cmp"
	"context"
	"fmt"
	"slices"

	"watchtower/internal/db"
)

const jiraIssueChanged = "jira.issue_changed"

// JiraSource is phaseJiraSync's event source: per issue the phase changed,
// one jira.issue_changed per changed field — status, assignee, priority,
// comment (its comment count grew) in that order — or one "other" when only
// updated_at moved. An issue new to a project that already had issues is
// "other"; a project with no issues before the phase (a first sync) publishes
// nothing. Deleted issues are neither news nor tracked.
func JiraSource(d *db.DB) EventSource { return jiraSource{d: d} }

type jiraSource struct{ d *db.DB }

func (jiraSource) Type() string { return jiraIssueChanged }

func (s jiraSource) Before(context.Context) (EventDiff, error) {
	marks, err := s.d.JiraIssueMarks()
	if err != nil {
		return nil, fmt.Errorf("snapshotting jira issues: %w", err)
	}
	projects := map[jiraProject]bool{}
	for ref, m := range marks {
		projects[jiraProject{ref.AccountID, m.Project}] = true
	}
	return jiraDiff{d: s.d, before: marks, projects: projects}, nil
}

// jiraProject is one account's project.
type jiraProject struct {
	account int64
	key     string
}

type jiraDiff struct {
	d        *db.DB
	before   map[db.JiraIssueRef]db.JiraIssueMark
	projects map[jiraProject]bool
}

func (s jiraDiff) After(ctx context.Context) ([]Event, error) {
	after, err := s.d.JiraIssueMarks()
	if err != nil {
		return nil, fmt.Errorf("reading jira issues: %w", err)
	}
	labels := map[int64]string{}
	var events []Event
	for _, ref := range sortedIssueRefs(after) {
		if err := ctx.Err(); err != nil {
			return nil, fmt.Errorf("diffing jira issues: %w", err)
		}
		fields := s.changedFields(ref, after[ref])
		if len(fields) == 0 {
			continue
		}
		account, err := s.accountLabel(ref.AccountID, labels)
		if err != nil {
			return nil, err
		}
		for _, f := range fields {
			events = append(events, Event{Type: jiraIssueChanged, Fields: map[string]any{
				"account": account, "key": ref.Key, "project": after[ref].Project, "field": f,
			}})
		}
	}
	return events, nil
}

// changedFields returns the event fields one issue's change produces.
func (s jiraDiff) changedFields(ref db.JiraIssueRef, a db.JiraIssueMark) []string {
	b, ok := s.before[ref]
	if !ok {
		if s.projects[jiraProject{ref.AccountID, a.Project}] {
			return []string{"other"}
		}
		return nil
	}
	var fields []string
	for _, c := range []struct {
		field   string
		changed bool
	}{
		{"status", a.Status != b.Status},
		{"assignee", a.Assignee != b.Assignee},
		{"priority", a.Priority != b.Priority},
		{"comment", a.Comments > b.Comments},
	} {
		if c.changed {
			fields = append(fields, c.field)
		}
	}
	if len(fields) == 0 && a.UpdatedAt != b.UpdatedAt {
		fields = append(fields, "other")
	}
	return fields
}

// sortedIssueRefs returns marks' issues ordered by account, then key.
func sortedIssueRefs(marks map[db.JiraIssueRef]db.JiraIssueMark) []db.JiraIssueRef {
	refs := make([]db.JiraIssueRef, 0, len(marks))
	for ref := range marks {
		refs = append(refs, ref)
	}
	slices.SortFunc(refs, func(x, y db.JiraIssueRef) int {
		return cmp.Or(cmp.Compare(x.AccountID, y.AccountID), cmp.Compare(x.Key, y.Key))
	})
	return refs
}

// accountLabel reads an account's label once per diff.
func (s jiraDiff) accountLabel(acct int64, cache map[int64]string) (string, error) {
	if l, ok := cache[acct]; ok {
		return l, nil
	}
	l, err := s.d.JiraEventLabel(acct)
	if err != nil {
		return "", fmt.Errorf("labelling jira events: %w", err)
	}
	cache[acct] = l
	return l, nil
}
