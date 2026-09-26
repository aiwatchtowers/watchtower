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

// jiraSource renders one document per Jira issue (description + comments).
type jiraSource struct{}

func (jiraSource) Name() string { return "jira" }

func (jiraSource) Changed(ctx context.Context, q Queryer, cursor string, _ time.Time) ([]string, string, bool, error) {
	keys, next, err := changedByColumn(ctx, q, cursor,
		`SELECT 'jira:' || account_id || ':' || key, synced_at FROM jira_issues WHERE synced_at >= ?
		 UNION ALL
		 SELECT 'jira:' || account_id || ':' || issue_key, synced_at FROM jira_comments WHERE synced_at >= ?`,
		cursor, cursor)
	return keys, next, true, err
}

func (jiraSource) Keys(ctx context.Context, q Queryer) ([]string, error) {
	return queryStrings(ctx, q, `SELECT 'jira:' || account_id || ':' || key FROM jira_issues WHERE is_deleted = 0`)
}

type jiraComment struct {
	id, author, bodyText, createdAt, updatedAt string
}

func loadJiraComments(ctx context.Context, q Queryer, query string, args ...any) ([]jiraComment, error) {
	rows, err := q.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []jiraComment
	for rows.Next() {
		var c jiraComment
		if err := rows.Scan(&c.id, &c.author, &c.bodyText, &c.createdAt, &c.updatedAt); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func (jiraSource) Build(ctx context.Context, q Queryer, key string) (*Doc, error) {
	rest, ok := splitRef(key, "jira:")
	if !ok {
		return nil, nil //nolint:nilerr // malformed ref: treat as missing doc, not an error
	}
	i := strings.Index(rest, ":")
	if i <= 0 || i == len(rest)-1 {
		return nil, nil //nolint:nilerr // malformed ref: treat as missing doc, not an error
	}
	accountID, issueKey := rest[:i], rest[i+1:]

	var projectKey, summary, description, status, priority, issueType, assignee, reporter, epicKey, sprintName, labelsJSON, updatedAt string
	err := q.QueryRowContext(ctx, `SELECT project_key, summary, description_text, status, priority, issue_type,
		assignee_display_name, reporter_display_name, epic_key, sprint_name, labels, updated_at
		FROM jira_issues WHERE account_id = ? AND key = ? AND is_deleted = 0`, accountID, issueKey).
		Scan(&projectKey, &summary, &description, &status, &priority, &issueType, &assignee, &reporter, &epicKey, &sprintName, &labelsJSON, &updatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("kb jira %s: %w", key, err)
	}

	comments, err := loadJiraComments(ctx, q, `SELECT id, author, body_text, created_at, updated_at FROM jira_comments
		WHERE account_id = ? AND issue_key = ? ORDER BY created_at, id`, accountID, issueKey)
	if err != nil {
		return nil, fmt.Errorf("kb jira %s comments: %w", key, err)
	}

	var siteURL string
	if err := q.QueryRowContext(ctx, `SELECT site_url FROM jira_accounts WHERE id = ?`, accountID).Scan(&siteURL); err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("kb jira %s site: %w", key, err)
	}

	doc := &Doc{
		ID:     key,
		Source: "jira",
		Title:  issueKey + " " + summary,
		Anchor: map[string]string{"account_id": accountID, "key": issueKey},
	}
	// The first section is always the summary + status/assignee line, even
	// when description and comments are both empty (a common real-world
	// shape) — otherwise the issue renders zero sections and writeDoc drops
	// it as if it didn't exist.
	var infoParts []string
	if status != "" {
		infoParts = append(infoParts, "Status: "+status)
	}
	if assignee != "" {
		infoParts = append(infoParts, "Assignee: "+assignee)
	}
	first := summary
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

	if siteURL != "" {
		doc.Link = strings.TrimRight(siteURL, "/") + "/browse/" + issueKey
	}

	var labels []string
	_ = json.Unmarshal([]byte(labelsJSON), &labels)
	metaParts := []string{projectKey, status, priority, issueType, assignee, reporter, epicKey, sprintName}
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

// calendarSource renders one document per calendar event.
type calendarSource struct{}

func (calendarSource) Name() string { return "calendar" }

func (calendarSource) Changed(ctx context.Context, q Queryer, cursor string, _ time.Time) ([]string, string, bool, error) {
	keys, next, err := changedByColumn(ctx, q, cursor,
		`SELECT 'calendar:' || id, synced_at FROM calendar_events WHERE synced_at >= ?`, cursor)
	return keys, next, true, err
}

func (calendarSource) Keys(ctx context.Context, q Queryer) ([]string, error) {
	return queryStrings(ctx, q, `SELECT 'calendar:' || id FROM calendar_events`)
}

func (calendarSource) Build(ctx context.Context, q Queryer, key string) (*Doc, error) {
	id, ok := splitRef(key, "calendar:")
	if !ok {
		return nil, nil //nolint:nilerr // malformed ref: treat as missing doc, not an error
	}

	var title, description, location, start, end, organizer, attendeesJSON, htmlLink string
	err := q.QueryRowContext(ctx, `SELECT title, description, location, start_time, end_time, organizer_email, attendees, html_link
		FROM calendar_events WHERE id = ?`, id).
		Scan(&title, &description, &location, &start, &end, &organizer, &attendeesJSON, &htmlLink)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("kb calendar %s: %w", key, err)
	}

	attendees := parseAttendees(attendeesJSON)

	var lines []string
	if start != "" || end != "" {
		lines = append(lines, fmt.Sprintf("When: %s – %s", start, end))
	}
	if location != "" {
		lines = append(lines, "Where: "+location)
	}
	if organizer != "" {
		lines = append(lines, "Organizer: "+organizer)
	}
	if len(attendees) > 0 {
		lines = append(lines, "Attendees: "+strings.Join(attendees, ", "))
	}
	text := strings.Join(lines, "\n")
	if description != "" {
		if text != "" {
			text += "\n\n"
		}
		text += description
	}

	var meta []string
	if organizer != "" {
		meta = append(meta, organizer)
	}
	meta = append(meta, attendees...)

	return &Doc{
		ID:       key,
		Source:   "calendar",
		Title:    title,
		Meta:     strings.Join(meta, " "),
		Link:     htmlLink,
		Time:     parseTime(start),
		Anchor:   map[string]string{"event_id": id},
		Sections: []Section{{Text: text, Anchor: id}},
	}, nil
}

// parseAttendees reads the calendar_events.attendees JSON, which may be the
// literal null, an array of email strings, or an array of objects carrying
// displayName/display_name/name and email.
func parseAttendees(raw string) []string {
	var items []any
	if err := json.Unmarshal([]byte(raw), &items); err != nil {
		return nil
	}
	var out []string
	for _, item := range items {
		switch v := item.(type) {
		case string:
			if v != "" {
				out = append(out, v)
			}
		case map[string]any:
			label := firstNonEmptyString(v, "displayName", "display_name", "name")
			if label == "" {
				label = firstNonEmptyString(v, "email")
			}
			if label != "" {
				out = append(out, label)
			}
		}
	}
	return out
}

func firstNonEmptyString(m map[string]any, keys ...string) string {
	for _, k := range keys {
		if s, ok := m[k].(string); ok && s != "" {
			return s
		}
	}
	return ""
}
