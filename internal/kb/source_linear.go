package kb

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

// linearSource renders one document per Linear issue (description +
// comments), the jiraSource twin (spec 2026-10-15-linear-integration-design
// §6 "KB search"). Document key and KB-03 anchor: linear:<account>:<key> with
// anchor {account_id, key}. The key is the issue's current one: a team move
// re-renders the issue under its new key (its synced_at changes) and the old
// key's document builds to nil and leaves the index on the next reconcile.
type linearSource struct{}

func (linearSource) Name() string { return "linear" }

func (linearSource) Changed(ctx context.Context, q Queryer, cursor string, _ time.Time) ([]string, string, bool, error) {
	keys, next, err := changedByColumn(ctx, q, cursor,
		`SELECT 'linear:' || account_id || ':' || key, synced_at FROM linear_issues WHERE synced_at >= ?
		 UNION ALL
		 SELECT 'linear:' || c.account_id || ':' || i.key, c.synced_at FROM linear_comments c
		   JOIN linear_issues i ON i.account_id = c.account_id AND i.id = c.issue_id
		   WHERE c.synced_at >= ?`,
		cursor, cursor)
	return keys, next, true, err
}

func (linearSource) Keys(ctx context.Context, q Queryer) ([]string, error) {
	return queryStrings(ctx, q, `SELECT 'linear:' || account_id || ':' || key FROM linear_issues WHERE is_deleted = 0`)
}

func (linearSource) Build(ctx context.Context, q Queryer, key string) (*Doc, error) {
	rest, ok := splitRef(key, "linear:")
	if !ok {
		return nil, nil // malformed ref: treat as missing doc, not an error
	}
	i := strings.Index(rest, ":")
	if i <= 0 || i == len(rest)-1 {
		return nil, nil // malformed ref: treat as missing doc, not an error
	}
	accountID, issueKey := rest[:i], rest[i+1:]

	var issueID, teamKey, title, description, state, assignee, creator, labelsJSON, url, updatedAt string
	var priority int
	err := q.QueryRowContext(ctx, `SELECT id, team_key, title, description_text, state_name, priority,
		assignee_display_name, creator_display_name, labels, url, updated_at
		FROM linear_issues WHERE account_id = ? AND key = ? AND is_deleted = 0`, accountID, issueKey).
		Scan(&issueID, &teamKey, &title, &description, &state, &priority, &assignee, &creator, &labelsJSON, &url, &updatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("kb linear %s: %w", key, err)
	}

	comments, err := loadJiraComments(ctx, q, `SELECT id, author_display_name, body_text, created_at, updated_at
		FROM linear_comments WHERE account_id = ? AND issue_id = ? ORDER BY created_at, id`, accountID, issueID)
	if err != nil {
		return nil, fmt.Errorf("kb linear %s comments: %w", key, err)
	}

	doc := &Doc{
		ID:     key,
		Source: "linear",
		Title:  issueKey + " " + title,
		Anchor: map[string]string{"account_id": accountID, "key": issueKey},
		Link:   url,
	}
	// The first section is always the title + state/assignee line, so an issue
	// with no description and no comments still renders (jiraSource's rule).
	var infoParts []string
	if state != "" {
		infoParts = append(infoParts, "Status: "+state)
	}
	if assignee != "" {
		infoParts = append(infoParts, "Assignee: "+assignee)
	}
	first := title
	if len(infoParts) > 0 {
		first += "\n" + strings.Join(infoParts, " · ")
	}
	doc.Sections = append(doc.Sections, Section{Text: first, Anchor: issueKey})
	if description != "" {
		doc.Sections = append(doc.Sections, Section{Text: description, Anchor: issueKey})
	}
	for _, c := range comments {
		doc.Sections = append(doc.Sections, Section{Text: c.author + ": " + c.bodyText, Anchor: c.id})
	}

	latest := parseTime(updatedAt)
	for _, c := range comments {
		if t := parseTime(c.updatedAt); t.After(latest) {
			latest = t
		}
	}
	doc.Time = latest

	var labels []string
	_ = json.Unmarshal([]byte(labelsJSON), &labels) // a malformed list simply adds no meta
	metaParts := []string{teamKey, state, linearPriorityName(priority), assignee, creator}
	metaParts = append(metaParts, labels...)
	var meta []string
	for _, p := range metaParts {
		if p != "" {
			meta = append(meta, p)
		}
	}
	doc.Meta = strings.Join(meta, " ")
	return doc, nil
}

// linearPriorityName names Linear's priority number (0 = none).
func linearPriorityName(p int) string {
	switch p {
	case 1:
		return "Urgent"
	case 2:
		return "High"
	case 3:
		return "Medium"
	case 4:
		return "Low"
	}
	return ""
}
