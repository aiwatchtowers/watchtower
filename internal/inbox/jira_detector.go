package inbox

import (
	"context"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
)

// DetectJira scans jira_issues for signals targeting currentUserID since sinceTS
// and inserts new inbox_items. Returns the count of items created.
//
// Implemented signals:
//   - jira_assigned: issues where assignee_account_id = currentUserID and updated_at > sinceTS
//   - jira_comment_mention: comments in jira_comments (migration 00050) whose body
//     [~mentions] one of currentUserID's mapped Atlassian account ids (jira_user_map).
//     A jira_comments table absence, or currentUserID having no mapped Atlassian id,
//     is a graceful no-op rather than an error.
//
// No-op signals (schema not available — follow-up required):
//   - jira_status_change: requires jira_issue_history table (not in current schema)
//   - jira_priority_change: requires jira_issue_history table (not in current schema)
//   - jira_comment_watching: requires jira_watchers table (not in current schema)
//
// TODO(inbox-pulse v2): add status/priority change detection once jira_issue_history is added.
// TODO(inbox-pulse v2): add watching detection once jira_watchers is added.
func DetectJira(ctx context.Context, database *db.DB, currentUserID string, sinceTS time.Time) (int, error) {
	if currentUserID == "" {
		return 0, nil
	}
	created := 0
	sinceISO := sinceTS.UTC().Format(time.RFC3339)

	// --- jira_assigned: issues assigned to me updated since sinceTS ---
	// Collect all candidates first; the loop below fully drains rows (Next
	// returns false), which auto-closes it before the dedup queries below run.
	// This avoids a deadlock on in-memory SQLite with MaxOpenConns(1). The
	// deferred Close is just a safety net for the scan/rows-error paths, which
	// return immediately without issuing further queries.
	type jiraCandidate struct {
		key, summary, updatedAt string
	}
	var assignedCandidates []jiraCandidate
	rows, err := database.Query(`
		SELECT key, summary, updated_at
		FROM jira_issues
		WHERE assignee_account_id = ?
		  AND updated_at > ?
		  AND is_deleted = 0`,
		currentUserID, sinceISO)
	if err != nil {
		return created, fmt.Errorf("jira detector: query jira_issues: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var c jiraCandidate
		if err := rows.Scan(&c.key, &c.summary, &c.updatedAt); err != nil {
			return created, fmt.Errorf("jira detector: scan jira_issues: %w", err)
		}
		assignedCandidates = append(assignedCandidates, c)
	}
	if err := rows.Err(); err != nil {
		return created, fmt.Errorf("jira detector: rows error: %w", err)
	}

	for _, c := range assignedCandidates {
		if jiraInboxExists(database, c.key, c.updatedAt, "jira_assigned") {
			continue
		}
		item := db.InboxItem{
			ChannelID:    c.key,
			MessageTS:    c.updatedAt,
			SenderUserID: c.key, // Jira issue key used as "sender" for routing/display
			TriggerType:  "jira_assigned",
			Snippet:      c.summary,
			ItemClass:    DefaultItemClass("jira_assigned"),
			Status:       "pending",
			Priority:     "medium",
		}
		if _, err := database.CreateInboxItem(item); err == nil {
			created++
		}
	}

	// --- jira_comment_mention: detect when jira_comments table is available ---
	// jira_comments is part of the core schema since migration 00050; the
	// existence check is now a defensive no-op that only matters for a
	// mid-migration or otherwise unusual database state.
	if jiraCommentsTableExists(database) {
		// A Jira [~mention] embeds the mentioned user's ATLASSIAN account id,
		// not their Slack id — resolve every account id mapped to
		// currentUserID (a user can be unmapped, mapped once, or in theory
		// mapped from more than one namespaced Slack id) and match any of
		// them. Zero mapped ids means we cannot recognize a mention at all,
		// so the detector skips comment mentions gracefully, same as before.
		atlassianIDs := atlassianIDsForUser(database, currentUserID)
		commentCandidates := collectJiraCommentCandidates(database, atlassianIDs, sinceISO)
		for _, c := range commentCandidates {
			if jiraInboxExists(database, c.issueKey, c.createdAt, "jira_comment_mention") {
				continue
			}
			item := db.InboxItem{
				ChannelID:    c.issueKey,
				MessageTS:    c.createdAt,
				SenderUserID: c.issueKey,
				TriggerType:  "jira_comment_mention",
				Snippet:      c.body,
				ItemClass:    DefaultItemClass("jira_comment_mention"),
				Status:       "pending",
				Priority:     "medium",
			}
			if _, err := database.CreateInboxItem(item); err == nil {
				created++
			}
		}
	}

	// --- jira_status_change: no-op until jira_issue_history table is added ---
	// TODO(inbox-pulse v2): detect status changes on issues assigned to currentUserID
	// using jira_issue_history once that table is added to the schema.

	// --- jira_priority_change: no-op until jira_issue_history table is added ---
	// TODO(inbox-pulse v2): detect priority changes analogous to status_change.

	// --- jira_comment_watching: no-op until jira_watchers table is added ---
	// TODO(inbox-pulse v2): detect new comments on issues where currentUserID is a watcher
	// using jira_watchers once that table is added to the schema.

	return created, nil
}

// jiraCommentsTableExists returns true if the jira_comments table is present
// in the SQLite database. Part of the core schema since migration 00050; this
// is now a defensive check rather than a real conditional.
func jiraCommentsTableExists(d *db.DB) bool {
	var n int
	d.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='jira_comments'`).Scan(&n) //nolint:errcheck
	return n > 0
}

type commentCandidate struct {
	issueKey, commentID, body, createdAt string
}

// collectJiraCommentCandidates queries jira_comments for a [~mention] of any
// of the given Atlassian account ids and returns fully-scanned candidates,
// best-effort (query or scan errors just yield fewer/no candidates rather
// than failing the detector). An empty atlassianIDs list — the user has no
// known Jira identity — is a graceful no-op, same as an absent table. The
// rows are closed via defer scoped to this helper, so they are released
// before the caller issues any further queries — required to avoid a
// deadlock on the MaxOpenConns(1) SQLite pool.
func collectJiraCommentCandidates(database *db.DB, atlassianIDs []string, sinceISO string) []commentCandidate {
	if len(atlassianIDs) == 0 {
		return nil
	}

	whereParts := make([]string, len(atlassianIDs))
	args := make([]any, 0, len(atlassianIDs)+1)
	for i, id := range atlassianIDs {
		whereParts[i] = "body_text LIKE ?"
		args = append(args, "%[~"+id+"]%")
	}
	args = append(args, sinceISO)

	query := fmt.Sprintf(`
		SELECT issue_key, id, body_text, created_at
		FROM jira_comments
		WHERE (%s)
		  AND created_at > ?`, strings.Join(whereParts, " OR "))
	cRows, err := database.Query(query, args...)
	if err != nil {
		return nil
	}
	defer cRows.Close()

	var candidates []commentCandidate
	for cRows.Next() {
		var c commentCandidate
		if scanErr := cRows.Scan(&c.issueKey, &c.commentID, &c.body, &c.createdAt); scanErr != nil {
			break
		}
		candidates = append(candidates, c)
	}
	return candidates
}

// atlassianIDsForUser returns every Atlassian account id mapped to a Slack
// user id in jira_user_map, matching both the raw id and its "1:"-namespaced
// form. jira_user_map.slack_user_id was namespaced by the Slack
// multi-account migration (00048: `'1:' || slack_user_id`), but this
// dormant Jira code predates that migration and its callers (tests, and any
// pre-migration data) may still carry the bare id — matching both forms
// keeps identity resolution honest either way. Returns nil (not an error)
// on an unmapped user or a query failure — the caller treats that as "skip
// comment-mention detection gracefully".
func atlassianIDsForUser(database *db.DB, slackUserID string) []string {
	if slackUserID == "" {
		return nil
	}
	candidates := []string{slackUserID}
	if trimmed, ok := strings.CutPrefix(slackUserID, "1:"); ok {
		candidates = append(candidates, trimmed)
	} else {
		candidates = append(candidates, "1:"+slackUserID)
	}

	placeholders := make([]string, len(candidates))
	args := make([]any, len(candidates))
	for i, c := range candidates {
		placeholders[i] = "?"
		args[i] = c
	}
	rows, err := database.Query(fmt.Sprintf(`SELECT jira_account_id FROM jira_user_map WHERE slack_user_id IN (%s)`,
		strings.Join(placeholders, ",")), args...)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var ids []string
	for rows.Next() {
		var id string
		if scanErr := rows.Scan(&id); scanErr != nil {
			break
		}
		ids = append(ids, id)
	}
	return ids
}

// jiraInboxExists returns true if an inbox_item already exists for the given
// Jira issue key (channel_id), timestamp (message_ts), and trigger_type.
// This prevents duplicate inbox items on repeated detector runs.
func jiraInboxExists(d *db.DB, channelID, messageTS, triggerType string) bool {
	var n int
	d.QueryRow(`SELECT COUNT(*) FROM inbox_items
		WHERE channel_id = ? AND message_ts = ? AND trigger_type = ?`,
		channelID, messageTS, triggerType).Scan(&n) //nolint:errcheck
	return n > 0
}
