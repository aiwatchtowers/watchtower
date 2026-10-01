package kb

import (
	"context"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
)

// Scope names the sources one project works in: Slack channels (namespaced
// ids, "1:C123"), Jira project keys ("PROJ") and Confluence space keys. A
// document is in scope when it is a thread or channel-day of one of the
// channels, an issue of one of the projects, or a page, blog post or
// attachment of one of the spaces. Keys compare case-insensitively. Derived
// documents (a channel's digest topics, stream digests) are deliberately
// out of scope: the scope points at the sources' own text.
type Scope struct {
	SlackChannels    []string
	JiraProjects     []string
	ConfluenceSpaces []string
}

// Empty reports whether the scope names no source at all.
func (s Scope) Empty() bool {
	return len(s.SlackChannels) == 0 && len(s.JiraProjects) == 0 && len(s.ConfluenceSpaces) == 0
}

// predicate is the SQL condition (over kb_documents aliased d) matching the
// scope's documents, with its arguments. It is the one definition of "in
// scope": the ranking boost, ScopeOnly, Hit.InScope and Recent all use it.
func (s Scope) predicate() (string, []any) {
	var parts []string
	var args []any
	add := func(cond string, values []string, upper bool) {
		if len(values) == 0 {
			return
		}
		parts = append(parts, cond+` IN (?`+strings.Repeat(`, ?`, len(values)-1)+`))`)
		for _, v := range values {
			if upper {
				v = strings.ToUpper(v)
			}
			args = append(args, v)
		}
	}
	add(`(d.source = 'slack' AND json_extract(d.anchor_json, '$.channel_id')`, s.SlackChannels, false)
	add(`(d.source = 'jira' AND upper(substr(json_extract(d.anchor_json, '$.key'), 1, instr(json_extract(d.anchor_json, '$.key'), '-') - 1))`, s.JiraProjects, true)
	add(`(d.source = 'confluence' AND upper(json_extract(d.anchor_json, '$.space'))`, s.ConfluenceSpaces, true)
	return "(" + strings.Join(parts, " OR ") + ")", args
}

// Recent lists the scope's documents active on or after since, newest
// first, at most limit. Hits carry no snippets (nothing was searched).
func Recent(ctx context.Context, d *db.DB, scope Scope, since time.Time, limit int) ([]Hit, error) {
	if scope.Empty() || limit <= 0 {
		return nil, nil
	}
	pred, args := scope.predicate()
	args = append(args, float64(since.Unix()), limit)
	rows, err := d.QueryContext(ctx, `SELECT d.id, d.source, d.title, d.doc_time, d.link, d.anchor_json
		FROM kb_documents d WHERE `+pred+` AND d.doc_time_unix >= ?
		ORDER BY d.doc_time_unix DESC, d.id LIMIT ?`, args...)
	if err != nil {
		return nil, fmt.Errorf("kb: recent in scope: %w", err)
	}
	defer rows.Close()
	var out []Hit
	for rows.Next() {
		h := Hit{Snippets: []string{}, InScope: true}
		var anchorJS string
		if err := rows.Scan(&h.Ref, &h.Source, &h.Title, &h.When, &h.Link, &anchorJS); err != nil {
			return nil, fmt.Errorf("kb: recent in scope: %w", err)
		}
		if h.Anchor, err = parseAnchor(anchorJS); err != nil {
			return nil, fmt.Errorf("kb: anchor of %s: %w", h.Ref, err)
		}
		out = append(out, h)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("kb: recent in scope: %w", err)
	}
	return out, nil
}
