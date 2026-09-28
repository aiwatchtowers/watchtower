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
	return detectJira(ctx, database, owner, newOwnJiraComments(database, owner), sinceTS)
}

// detectJira is DetectJira with the cycle's shared view of the owner's own
// Jira comments (Pipeline.Run builds it once for detection and auto-resolve).
func detectJira(_ context.Context, database *db.DB, owner db.Owner, own *ownJiraComments, sinceTS time.Time) (int, error) {
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

	candidateKeys := make([]string, len(assignedCandidates))
	for i, c := range assignedCandidates {
		candidateKeys[i] = c.key
	}
	ownComments, err := own.latestFor(candidateKeys)
	if err != nil {
		return created, fmt.Errorf("jira detector: %w", err)
	}

	for _, c := range assignedCandidates {
		if isOwnCommentBump(c.updatedAt, ownComments[c.key].touched) {
			continue
		}
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

	// --- jira_comment_mention ---
	// A Jira [~mention] embeds the mentioned user's ATLASSIAN account id, not
	// their Slack id. Zero known ids (or no jira_comments table — own.ids is
	// then empty) means we cannot recognize a mention at all, so the detector
	// skips comment mentions gracefully.
	commentCandidates := collectJiraCommentCandidates(database, own.ids, sinceISO)
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

// ownCommentBumpTolerance is how far an issue's updated_at may trail the
// owner's newest comment on it and still count as that comment's own bump:
// Jira stamps the issue a moment after the comment it just stored.
const ownCommentBumpTolerance = 60 // seconds

// ownJiraComments is one inbox cycle's view of the owner's own Jira
// comments. The identity lookups (jira_comments present, the owner's
// Atlassian ids) run once at construction; latestFor reads only the issue
// keys it is asked about, through an index, and caches them, so each key is
// read at most once per cycle. Detection and auto-resolve ask about
// different keys (issues updated in the window vs. pending items), so a
// cycle can issue a read for each — never a full-table scan.
type ownJiraComments struct {
	database *db.DB
	// ids is every Atlassian id that is the owner — empty when the owner has
	// none or jira_comments does not exist (no comment signal at all).
	ids    []string
	cached map[string]ownComment
	loaded map[string]bool
}

// ownComment is the owner's newest comment activity on one issue, as unix
// seconds (0 = none): created is the newest comment's creation (what
// auto-resolve compares against an item), touched additionally counts an
// edit of any own comment (an edit bumps the issue's updated_at too).
type ownComment struct {
	created, touched int64
}

func newOwnJiraComments(database *db.DB, owner db.Owner) *ownJiraComments {
	o := &ownJiraComments{database: database, cached: map[string]ownComment{}, loaded: map[string]bool{}}
	if jiraCommentsTableExists(database) {
		o.ids = ownerAtlassianIDs(database, owner)
	}
	return o
}

// ownCommentKeyChunk bounds the issue keys bound into one IN (...) list.
const ownCommentKeyChunk = 500

// latestFor returns the owner's comment activity for each of keys that has
// any. Keys already read this cycle are served from the cache; the rest are
// read in one fully-drained query per chunk (the MaxOpenConns(1) SQLite
// deadlock rule). An unparseable timestamp is skipped, matching
// ParseJiraTime's defensive-skip contract. On an error the entries read so
// far are returned alongside it.
func (o *ownJiraComments) latestFor(keys []string) (map[string]ownComment, error) {
	if len(o.ids) == 0 || len(keys) == 0 {
		return nil, nil
	}
	var missing []string
	seen := make(map[string]bool, len(keys))
	for _, k := range keys {
		if !o.loaded[k] && !seen[k] {
			seen[k] = true
			missing = append(missing, k)
		}
	}
	var err error
	for start := 0; start < len(missing) && err == nil; start += ownCommentKeyChunk {
		chunk := missing[start:min(start+ownCommentKeyChunk, len(missing))]
		// A chunk counts as read only once its read succeeded, so a failed
		// read is retried (and fails loudly again) on the next ask instead
		// of being served as "no comments" from the cache.
		if err = o.load(chunk); err == nil {
			for _, k := range chunk {
				o.loaded[k] = true
			}
		}
	}
	out := make(map[string]ownComment, len(keys))
	for _, k := range keys {
		if c, ok := o.cached[k]; ok {
			out[k] = c
		}
	}
	return out, err
}

func (o *ownJiraComments) load(keys []string) error {
	args := make([]any, 0, len(o.ids)+len(keys))
	for _, k := range keys {
		args = append(args, k)
	}
	for _, id := range o.ids {
		args = append(args, id)
	}
	rows, err := o.database.Query(ownCommentsQuery(len(o.ids), len(keys)), args...)
	if err != nil {
		return fmt.Errorf("own comment query: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var issueKey, createdAt, updatedAt string
		if err := rows.Scan(&issueKey, &createdAt, &updatedAt); err != nil {
			return fmt.Errorf("own comment scan: %w", err)
		}
		created, ok := db.ParseJiraTime(createdAt)
		if !ok {
			continue
		}
		touched := created
		if edited, ok := db.ParseJiraTime(updatedAt); ok && edited > touched {
			touched = edited
		}
		cur := o.cached[issueKey]
		o.cached[issueKey] = ownComment{created: max(cur.created, created), touched: max(cur.touched, touched)}
	}
	return rows.Err()
}

// ownCommentsQuery reads the owner's comments on a set of issues: nIDs
// author ids, then nKeys issue keys. The issue_key-first predicate is served
// by idx_jira_comments_issue_author (migration 00079) — pinned by
// TestOwnJiraComments_QueryUsesIndex, since idx_jira_comments_issue leads
// with account_id, which this read does not bind.
func ownCommentsQuery(nIDs, nKeys int) string {
	return fmt.Sprintf(`SELECT issue_key, created_at, updated_at FROM jira_comments
		WHERE issue_key IN (%s) AND author_account_id IN (%s)`,
		placeholders(nKeys), placeholders(nIDs))
}

// placeholders renders n comma-separated SQL bind markers.
func placeholders(n int) string {
	return strings.TrimSuffix(strings.Repeat("?,", n), ",")
}

// isOwnCommentBump reports whether an assigned issue's newest change is the
// owner's own comment activity (ownCommentTS — the newest creation or edit
// of an own comment, 0 when none): its updated_at is not later than that
// plus ownCommentBumpTolerance. The trade-off is deliberate: a change by
// someone else inside that window is taken for the owner's own bump and not
// surfaced until the issue changes again. Such a change is the
// owner answering in the source — the thing that resolves a jira_assigned
// item (INBOX-02) — so it must not mint a fresh one. An unparseable
// updated_at never suppresses.
func isOwnCommentBump(updatedAt string, ownCommentTS int64) bool {
	if ownCommentTS == 0 {
		return false
	}
	updated, ok := db.ParseJiraTime(updatedAt)
	return ok && updated <= ownCommentTS+ownCommentBumpTolerance
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
