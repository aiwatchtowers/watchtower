package kb

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
)

// inboundCountsQuery counts the distinct documents per kind that link a
// Confluence page (doc_links, written by internal/doclinks); it seeks
// idx_doc_links_to (TestConfluence_InboundCountQueryPlan).
const inboundCountsQuery = `SELECT from_kind, COUNT(DISTINCT from_ref) FROM doc_links
	WHERE to_kind = 'confluence_page' AND to_ref = ? GROUP BY from_kind`

// discussedIn renders "Discussed in: <n> Slack threads, <m> emails" for the
// page extID of sourceID, "" when nothing links it. Counts only (never the
// linking text), so the page's content hash moves only when a count does;
// doclinks stamps the page when it adds an inbound link, which is what
// brings the page back through Changed. The page is addressed as
// "<cloud_id>:<page_id>" of its source's Jira site; a source without one
// has no inbound links.
func discussedIn(ctx context.Context, q Queryer, sourceID, extID string) (string, error) {
	var cloud string
	err := q.QueryRowContext(ctx, `SELECT a.cloud_id FROM ext_sources s JOIN jira_accounts a ON a.id = s.jira_account_id
		WHERE s.id = ?`, sourceID).Scan(&cloud)
	if errors.Is(err, sql.ErrNoRows) || (err == nil && cloud == "") {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("site of source %s: %w", sourceID, err)
	}
	rows, err := q.QueryContext(ctx, inboundCountsQuery, cloud+":"+extID)
	if err != nil {
		return "", fmt.Errorf("inbound links: %w", err)
	}
	defer rows.Close()
	var slackN, mailN int
	for rows.Next() {
		var kind string
		var n int
		if err := rows.Scan(&kind, &n); err != nil {
			return "", fmt.Errorf("inbound links: %w", err)
		}
		switch kind {
		case "slack":
			slackN += n
		case "gmail", "imap":
			mailN += n
		}
	}
	if err := rows.Err(); err != nil {
		return "", fmt.Errorf("inbound links: %w", err)
	}
	if slackN == 0 && mailN == 0 {
		return "", nil
	}
	return fmt.Sprintf("Discussed in: %d Slack threads, %d emails", slackN, mailN), nil
}
