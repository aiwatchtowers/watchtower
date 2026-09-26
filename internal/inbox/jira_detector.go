package inbox

import (
	"context"
	"fmt"
	"slices"
	"strings"
	"time"

	"watchtower/internal/db"
)

// DetectJira scans jira_issues for signals targeting the owner since sinceTS
// and inserts new inbox_items. Returns the count of items created. An owner
// with neither a Jira nor a Slack id is a graceful no-op, not an error
// (INBOX-09: a skip for missing identity never freezes the watermark).
//
// Implemented signals:
//   - jira_assigned: issues where assignee_account_id = ownerAssigneeID(owner) and updated_at > sinceTS
//   - jira_comment_mention: comments in jira_comments (migration 00050) whose body
//     [~mentions] one of ownerAtlassianIDs(owner).
//     A jira_comments table absence, or the owner having no known Atlassian id,
//     is a graceful no-op rather than an error.
//
// No-op signals (schema not available — follow-up required):
//   - jira_status_change: requires jira_issue_history table (not in current schema)
//   - jira_priority_change: requires jira_issue_history table (not in current schema)
//   - jira_comment_watching: requires jira_watchers table (not in current schema)
//
// TODO(inbox-pulse v2): add status/priority change detection once jira_issue_history is added.
// TODO(inbox-pulse v2): add watching detection once jira_watchers is added.
func DetectJira(ctx context.Context, database *db.DB, owner db.Owner, sinceTS time.Time) (int, error) {
	assigneeID := ownerAssigneeID(owner)
	if assigneeID == "" {
		return 0, nil
	}
	created := 0
	// Both comparisons below are plain SQL string compares against columns
	// holding Jira Cloud's own dotted-millisecond format, so the bound has to
	// be rendered the same way — an RFC3339 bound sorts above every Jira
	// timestamp in the same second and hides it (see db.FormatJiraTime).
	sinceISO := db.FormatJiraTime(sinceTS.UTC())

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
		assigneeID, sinceISO)
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
		// Every edit of an assigned issue — the owner's own included — bumps
		// updated_at, so the (key, updated_at) check alone would mint a fresh
		// item per update. One pending item per issue is enough; a resolved or
		// dismissed one does not block a later update from surfacing again.
		if jiraInboxExists(database, c.key, c.updatedAt, "jira_assigned") ||
			jiraPendingExists(database, c.key, "jira_assigned") {
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
		// not their Slack id. Zero known ids means we cannot recognize a
		// mention at all, so the detector skips comment mentions gracefully.
		atlassianIDs := ownerAtlassianIDs(database, owner)
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
	// TODO(inbox-pulse v2): detect status changes on issues assigned to the owner
	// using jira_issue_history once that table is added to the schema.

	// --- jira_priority_change: no-op until jira_issue_history table is added ---
	// TODO(inbox-pulse v2): detect priority changes analogous to status_change.

	// --- jira_comment_watching: no-op until jira_watchers table is added ---
	// TODO(inbox-pulse v2): detect new comments on issues where the owner is a watcher
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

// ownerAssigneeID is the id jira_assigned matches against
// jira_issues.assignee_account_id: the owner's Atlassian id, else — the
// pre-resolver path, kept as the fallback — the owner's Slack id. "" when the
// owner has neither, so no `= ?` ever runs with an empty id (an unassigned
// issue's assignee_account_id is empty).
func ownerAssigneeID(owner db.Owner) string {
	if owner.JiraAccountID != "" {
		return owner.JiraAccountID
	}
	return owner.SlackUserID
}

// ownerAtlassianIDs are every Atlassian id that is the owner, for both
// comment-mention detection and auto-resolve (INBOX-02): Owner.JiraAccountID
// (GET /myself, else the resolver's first jira_user_map match) plus EVERY id
// jira_user_map maps to the owner's Slack id, deduplicated. The resolver keeps
// only one id, so using it alone would drop mentions of — and answers from —
// every other mapped id the pre-resolver inbox matched. An empty Slack id is
// never queried (atlassianIDsForUser returns nil for it).
func ownerAtlassianIDs(database *db.DB, owner db.Owner) []string {
	ids := atlassianIDsForUser(database, owner.SlackUserID)
	if owner.JiraAccountID != "" && !slices.Contains(ids, owner.JiraAccountID) {
		ids = append([]string{owner.JiraAccountID}, ids...)
	}
	return ids
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

// jiraPendingExists returns true if a pending, unarchived inbox_item already
// exists for the given Jira issue key (channel_id) and trigger_type, whatever
// its message_ts. An archived item keeps status='pending'
// (db.ArchiveStaleActionable), so without the archived_at check it would
// block the issue forever.
func jiraPendingExists(d *db.DB, channelID, triggerType string) bool {
	var n int
	d.QueryRow(`SELECT COUNT(*) FROM inbox_items
		WHERE channel_id = ? AND trigger_type = ? AND status = 'pending' AND archived_at IS NULL`,
		channelID, triggerType).Scan(&n) //nolint:errcheck
	return n > 0
}
