package db

import (
	"context"
	"fmt"
)

// PurgeStep is one chunked statement of an account purge (board #601,
// PURGE-02). SQL deletes (or updates) at most `limit` rows of Table per run:
// the limit is bound as its last parameter, after Args. Every step is
// idempotent — its predicate reads the current state — so a purge that
// stopped half-way simply runs its list again from the top.
type PurgeStep struct {
	Name  string
	Table string // the driving table, the one the limit applies to
	SQL   string
	Args  []any
}

// Calendar events and calendars of a Google account that a purge (and
// DeleteGoogleAccount) removes: an event a meeting transcript or recap
// references is kept, and so is the calendar row still holding one (the
// DeleteStaleCalendarEvents guard, owner decision 14). The account id is the
// only parameter. accountCalendarEventsWhere is written unaliased against
// calendar_events, accountEmptyCalendarsWhere against calendar_calendars.
const (
	accountCalendarEventsWhere = `calendar_id IN (SELECT id FROM calendar_calendars WHERE account_id = ?)
		   AND NOT EXISTS (SELECT 1 FROM meeting_transcripts t WHERE t.event_id = calendar_events.id)
		   AND NOT EXISTS (SELECT 1 FROM meeting_recaps    r WHERE r.event_id = calendar_events.id)`
	accountEmptyCalendarsWhere = `account_id = ?
		   AND NOT EXISTS (SELECT 1 FROM calendar_events e WHERE e.calendar_id = calendar_calendars.id)`
)

// Inbox trigger types per source.
const (
	slackInboxTriggers    = `('mention','dm','thread_reply','reaction','stream','decision_made','briefing_ready')`
	calendarInboxTriggers = `('calendar_invite','calendar_time_change','calendar_cancelled')`
	jiraInboxTriggers     = `('jira_assigned','jira_comment_mention','jira_comment_watching','jira_status_change','jira_priority_change')`
	linearInboxTriggers   = `('linear_assigned','linear_comment_mention')`
)

// prefixRange returns the half-open key range [prefix, prefix with its final
// ':' bumped to ';') — every key that starts with prefix, matched as an index
// range ("1:" never matches "10:"). prefix must end with ':'.
func prefixRange(prefix string) (lo, hi string) {
	return prefix, prefix[:len(prefix)-1] + ";"
}

// purgeSteps accumulates the step list of one purge.
type purgeSteps []PurgeStep

// del adds a chunked DELETE of table's rows matching where (unaliased,
// against table itself).
func (s *purgeSteps) del(name, table, where string, args ...any) {
	*s = append(*s, PurgeStep{
		Name:  name,
		Table: table,
		SQL:   `DELETE FROM ` + table + ` WHERE rowid IN (SELECT rowid FROM ` + table + ` WHERE ` + where + ` LIMIT ?)`,
		Args:  args,
	})
}

// inbox adds the inbox steps for the items matching scope (written against
// alias i of inbox_items): feedback on the situations whose every signal is
// such an item, those situations, feedback on the items, then the items
// (situation_signals cascade). Situations with any other signal are kept.
func (s *purgeSteps) inbox(scope string, args ...any) {
	twice := append(append([]any{}, args...), args...)
	doomed := `SELECT s.id FROM situations s
		WHERE EXISTS (SELECT 1 FROM situation_signals ss JOIN inbox_items i ON i.id = ss.inbox_item_id
		               WHERE ss.situation_id = s.id AND (` + scope + `))
		  AND NOT EXISTS (SELECT 1 FROM situation_signals ss JOIN inbox_items i ON i.id = ss.inbox_item_id
		               WHERE ss.situation_id = s.id AND NOT (` + scope + `))`
	s.del("situation feedback", "feedback",
		`entity_type = 'situation' AND entity_id IN (SELECT CAST(id AS TEXT) FROM (`+doomed+`))`, twice...)
	s.del("situations", "situations", `id IN (`+doomed+`)`, twice...)
	items := `SELECT i.id FROM inbox_items i WHERE ` + scope
	s.del("inbox feedback", "feedback",
		`entity_type = 'inbox' AND entity_id IN (SELECT CAST(id AS TEXT) FROM (`+items+`))`, args...)
	s.del("inbox items", "inbox_items", `id IN (`+items+`)`, args...)
}

// knowledge adds the steps for the knowledge-index documents under one key
// prefix: the documents (kb_chunks cascade, kb_fts follows kb_chunks_ad),
// pending kb_dirty marks and the doc_links those documents made. Documents
// are deleted directly: messages' kb_dirty trigger fires on UPDATE only
// (00139), so a deleted message would leave its document behind.
func (s *purgeSteps) knowledge(prefix string) {
	lo, hi := prefixRange(prefix)
	s.del("knowledge documents "+prefix, "kb_documents", `id >= ? AND id < ?`, lo, hi)
	s.del("knowledge marks "+prefix, "kb_dirty", `key >= ? AND key < ?`, lo, hi)
	s.del("document links "+prefix, "doc_links", `from_ref >= ? AND from_ref < ?`, lo, hi)
}

// streamDigests adds the steps for one account's stream digests of kind
// (gmail | jira | linear) and their knowledge documents.
func (s *purgeSteps) streamDigests(kind string, accountID int64) {
	s.del("stream digest documents", "kb_documents", `EXISTS (SELECT 1 FROM stream_digests sd
		WHERE sd.source = ? AND sd.account_id = ?
		  AND kb_documents.id >= 'stream_digest:' || sd.id || ':' AND kb_documents.id < 'stream_digest:' || sd.id || ';')`,
		kind, accountID)
	s.del("stream digests", "stream_digests", `source = ? AND account_id = ?`, kind, accountID)
}

// PurgeSteps returns the ordered step list that deletes everything
// attributable to one account without AI (spec Q2 (a)): raw rows, inbox items
// with their situations and learned rules, knowledge documents, and digests,
// tracks and people cards that belong to the account alone. AI text that mixes
// sources (briefings, recaps, ideas, memory, chats, automation outputs,
// transcripts) is kept, and so are cross-account digests and tracks.
// Dependents come before the rows their predicates read.
func PurgeSteps(source string, accountID int64) ([]PurgeStep, error) {
	var s purgeSteps
	switch source {
	case "slack":
		slackSteps(&s, accountID)
	case "google":
		googleSteps(&s, accountID)
	case "jira":
		jiraSteps(&s, accountID)
	case "linear":
		linearSteps(&s, accountID)
	default:
		return nil, fmt.Errorf("purge steps: unknown source %q", source)
	}
	return s, nil
}

func slackSteps(s *purgeSteps, id int64) {
	lo, hi := prefixRange(fmt.Sprintf("%d:", id))
	inRange := func(col string) string { return col + ` >= ? AND ` + col + ` < ?` }

	// Raw rows, heaviest first; FTS follows messages via messages_ad.
	s.del("messages", "messages", inRange("channel_id"), lo, hi)
	s.del("reactions", "reactions", inRange("channel_id"), lo, hi)
	s.del("files", "files", inRange("message_channel_id"), lo, hi)

	// Inbox: Slack trigger types in the account's namespace (memory dispute
	// items, channel_id 'memory', and briefing items are outside it).
	s.inbox(`i.trigger_type IN `+slackInboxTriggers+` AND i.channel_id >= ? AND i.channel_id < ?`, lo, hi)
	chLo, chHi := prefixRange(fmt.Sprintf("channel:%d:", id))
	sdLo, sdHi := prefixRange(fmt.Sprintf("sender:%d:", id))
	s.del("learned rules", "inbox_learned_rules", `(scope_key >= ? AND scope_key < ?) OR (scope_key >= ? AND scope_key < ?)`,
		chLo, chHi, sdLo, sdHi)

	// Channel digests of the account (cross-channel digests have
	// channel_id '' and stay); topics, participants, reads cascade.
	digestsOfAccount := `SELECT id FROM digests WHERE channel_id >= ? AND channel_id < ?`
	s.del("digest documents", "kb_documents", `id IN (SELECT 'digest:' || t.digest_id || ':' || t.idx
		FROM digest_topics t JOIN digests d ON d.id = t.digest_id WHERE d.channel_id >= ? AND d.channel_id < ?)`, lo, hi)
	s.del("digest feedback", "feedback", `(entity_type = 'digest' AND entity_id IN (SELECT CAST(id AS TEXT) FROM (`+digestsOfAccount+`)))
		OR (entity_type = 'decision' AND substr(entity_id, 1, instr(entity_id, ':') - 1) IN (SELECT CAST(id AS TEXT) FROM (`+digestsOfAccount+`)))`,
		lo, hi, lo, hi)
	s.del("digests", "digests", inRange("channel_id"), lo, hi)

	// Tracks whose every channel belongs to the account; events and states
	// cascade. A track spanning two accounts stays.
	tracksOfAccount := `json_valid(channel_ids) AND json_array_length(channel_ids) > 0
		AND NOT EXISTS (SELECT 1 FROM json_each(tracks.channel_ids) j WHERE NOT (j.value >= ? AND j.value < ?))`
	s.del("track feedback", "feedback", `entity_type = 'track' AND entity_id IN (SELECT CAST(id AS TEXT) FROM tracks WHERE `+tracksOfAccount+`)`, lo, hi)
	s.del("tracks", "tracks", tracksOfAccount, lo, hi)

	// People of the account.
	s.del("user analysis feedback", "feedback", `entity_type = 'user_analysis' AND entity_id IN
		(SELECT CAST(id AS TEXT) FROM user_analyses WHERE user_id >= ? AND user_id < ?)`, lo, hi)
	s.del("user analyses", "user_analyses", inRange("user_id"), lo, hi)
	s.del("people cards", "people_cards", inRange("user_id"), lo, hi)
	s.del("user interactions", "user_interactions", `(user_a >= ? AND user_a < ?) OR (user_b >= ? AND user_b < ?)`, lo, hi, lo, hi)

	// Account-keyed ledgers and links.
	s.del("issue links", "issue_slack_links", inRange("channel_id"), lo, hi)
	s.del("reaction commands", "reaction_commands", `account_id = ?`, id)
	s.del("reaction events", "reaction_events", `account_id = ?`, id)
	s.del("reminders", "reminders", `account_id = ?`, id)

	// Sync state and settings, then the directory rows.
	s.del("sync state", "sync_state", inRange("channel_id"), lo, hi)
	s.del("watch list", "watch_list", inRange("entity_id"), lo, hi)
	s.del("channel settings", "channel_settings", inRange("channel_id"), lo, hi)
	s.del("user checkpoints", "user_checkpoints", inRange("id"), lo, hi)
	s.del("users", "users", inRange("id"), lo, hi)
	s.del("channels", "channels", inRange("id"), lo, hi)

	s.knowledge(fmt.Sprintf("slack:thread:%d:", id))
	s.knowledge(fmt.Sprintf("slack:day:%d:", id))
	s.del("history backfill", "history_backfill", `source_kind = 'slack' AND account_id = ?`, id)
}

func googleSteps(s *purgeSteps, id int64) {
	gmailPrefix := GmailChannelPrefix(id) + ":"
	gLo, gHi := prefixRange(gmailPrefix)

	s.del("gmail messages", "gmail_messages", `account_id = ?`, id)

	// Inbox: the account's Gmail threads and the calendar items of the events
	// this purge deletes — before those events go.
	eventsOfAccount := `SELECT id FROM calendar_events WHERE ` + accountCalendarEventsWhere
	s.inbox(`(i.channel_id >= ? AND i.channel_id < ?)
		OR (i.trigger_type IN `+calendarInboxTriggers+` AND i.channel_id IN (`+eventsOfAccount+`))`, gLo, gHi, id)
	rLo, rHi := prefixRange("channel:" + gmailPrefix)
	s.del("learned rules", "inbox_learned_rules", `scope_key >= ? AND scope_key < ?`, rLo, rHi)

	// Calendar: prep cache and knowledge documents of the events first, then
	// the events, the emptied calendars, and the kept calendars detached.
	s.del("meeting prep", "meeting_prep_cache", `event_id IN (`+eventsOfAccount+`)`, id)
	s.del("calendar documents", "kb_documents", `id IN (SELECT 'calendar:' || id FROM calendar_events WHERE `+accountCalendarEventsWhere+`)`, id)
	s.del("calendar events", "calendar_events", accountCalendarEventsWhere, id)
	s.del("calendars", "calendar_calendars", accountEmptyCalendarsWhere, id)
	*s = append(*s, PurgeStep{
		Name:  "detach kept calendars",
		Table: "calendar_calendars",
		SQL: `UPDATE calendar_calendars SET account_id = NULL, is_selected = 0
			WHERE rowid IN (SELECT rowid FROM calendar_calendars WHERE account_id = ? LIMIT ?)`,
		Args: []any{id},
	})

	s.streamDigests("gmail", id)
	s.knowledge(gmailPrefix)
	s.del("history backfill", "history_backfill", `source_kind = 'gmail' AND account_id = ?`, id)
}

func jiraSteps(s *purgeSteps, id int64) {
	// Jira inbox items carry the issue key only: an item is the account's
	// when its key is one of the account's issues and of no other account's.
	// Before the issues go.
	s.inbox(`i.trigger_type IN `+jiraInboxTriggers+`
		AND i.channel_id IN (SELECT key FROM jira_issues WHERE account_id = ?)
		AND i.channel_id NOT IN (SELECT key FROM jira_issues WHERE account_id != ?)`, id, id)

	for _, t := range []string{
		"jira_issue_changelog", "jira_comments", "jira_linked_issues", "jira_issue_links", "jira_issues",
		"jira_sprints", "jira_releases", "jira_board_field_map", "jira_boards", "jira_custom_fields",
		"jira_changelog_sync", "jira_sync_state",
	} {
		s.del(t, t, `account_id = ?`, id)
	}

	// The account's Confluence spaces: documents and comments, their
	// knowledge documents and links, then the source rows themselves.
	extOfAccount := `source_id IN (SELECT id FROM ext_sources WHERE jira_account_id = ?)`
	s.del("confluence comments", "ext_comments", extOfAccount, id)
	s.del("confluence documents", "ext_documents", extOfAccount, id)
	extRef := func(col string) string {
		return `EXISTS (SELECT 1 FROM ext_sources es WHERE es.jira_account_id = ?
			AND ` + col + ` >= es.provider || ':' || es.id || ':' AND ` + col + ` < es.provider || ':' || es.id || ';')`
	}
	s.del("confluence knowledge documents", "kb_documents", extRef("kb_documents.id"), id)
	s.del("confluence knowledge marks", "kb_dirty", extRef("kb_dirty.key"), id)
	s.del("confluence document links", "doc_links", extRef("doc_links.from_ref"), id)
	s.del("confluence spaces", "ext_sources", `jira_account_id = ?`, id)

	s.streamDigests("jira", id)
	s.knowledge(fmt.Sprintf("jira:%d:", id))
	s.del("history backfill", "history_backfill", `source_kind = 'jira' AND account_id = ?`, id)
}

func linearSteps(s *purgeSteps, id int64) {
	s.inbox(`i.trigger_type IN `+linearInboxTriggers+`
		AND i.channel_id IN (SELECT key FROM linear_issues WHERE account_id = ?)
		AND i.channel_id NOT IN (SELECT key FROM linear_issues WHERE account_id != ?)`, id, id)
	for _, t := range []string{
		"linear_issue_history", "linear_comments", "linear_relations", "linear_issues", "linear_cycles",
		"linear_projects", "linear_labels", "linear_workflow_states", "linear_teams", "linear_sync_state",
	} {
		s.del(t, t, `account_id = ?`, id)
	}
	s.streamDigests("linear", id)
	s.knowledge(fmt.Sprintf("linear:%d:", id))
}

// RunPurgeStep runs one chunk of step — one transaction, one statement, at
// most limit rows of the driving table — and returns the rows it affected.
// The caller repeats it until it returns 0.
func (db *DB) RunPurgeStep(ctx context.Context, step PurgeStep, limit int) (int64, error) {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return 0, fmt.Errorf("purge step %s: %w", step.Name, err)
	}
	defer func() { _ = tx.Rollback() }() // no-op once committed
	res, err := tx.ExecContext(ctx, step.SQL, append(append([]any{}, step.Args...), limit)...)
	if err != nil {
		return 0, fmt.Errorf("purge step %s: %w", step.Name, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("purge step %s: %w", step.Name, err)
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("purge step %s: %w", step.Name, err)
	}
	return n, nil
}

// StartAccountPurge moves a scheduled row to running; a row already running
// (a resumed purge) is left as it is.
func (db *DB) StartAccountPurge(id int64) error {
	if _, err := db.Exec(`UPDATE account_purges SET state = 'running', started_at = `+nowSQL+`
		WHERE id = ? AND state = 'scheduled'`, id); err != nil {
		return fmt.Errorf("starting account purge %d: %w", id, err)
	}
	return nil
}

// AddPurgeRows adds n to a purge's deleted-row count.
func (db *DB) AddPurgeRows(id, n int64) error {
	if _, err := db.Exec(`UPDATE account_purges SET rows_deleted = rows_deleted + ? WHERE id = ?`, n, id); err != nil {
		return fmt.Errorf("counting account purge %d rows: %w", id, err)
	}
	return nil
}

// FailAccountPurge records a chunk failure; the row stays running and the
// next cycle resumes it.
func (db *DB) FailAccountPurge(id int64, msg string) error {
	if _, err := db.Exec(`UPDATE account_purges SET error = ? WHERE id = ?`, msg, id); err != nil {
		return fmt.Errorf("recording account purge %d failure: %w", id, err)
	}
	return nil
}

// purgedAccountSQL marks an account row purged and resets its sync clocks,
// so a later login starts over as a first sync. The row itself stays for
// history (labels, permalinks).
var purgedAccountSQL = map[string]string{
	"slack": `UPDATE slack_accounts SET status = 'purged', error = '', enabled = 0, search_last_date = '',
		reaction_commands_seeded_at = '', reaction_events_seeded_at = '', roster_synced_at = '', deletion_sweep_day = ''
		WHERE id = ?`,
	"google": `UPDATE google_accounts SET status = 'purged', error = '', gmail_enabled = 0, calendar_enabled = 0,
		gmail_last_internal_date = 0, memory_gmail_last_extracted_ts = 0, ideas_email_floor = 0, deletions_checked_at = '',
		updated_at = ` + nowSQL + ` WHERE id = ?`,
	"jira": `UPDATE jira_accounts SET status = 'purged', error = '', enabled = 0,
		memory_jira_last_extracted_ts = 0, ideas_jira_floor = '' WHERE id = ?`,
	"linear": `UPDATE linear_accounts SET status = 'purged', error = '', enabled = 0,
		memory_last_extracted_ts = 0, ideas_floor = '', moved_watermark = '' WHERE id = ?`,
}

// FinishAccountPurge closes a purge in one transaction: the ledger row turns
// done and the account row purged.
func (db *DB) FinishAccountPurge(id int64, source string, accountID int64) error {
	accountSQL, ok := purgedAccountSQL[source]
	if !ok {
		return fmt.Errorf("finishing account purge %d: unknown source %q", id, source)
	}
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("finishing account purge %d: %w", id, err)
	}
	defer func() { _ = tx.Rollback() }() // no-op once committed
	if _, err := tx.Exec(`UPDATE account_purges SET state = 'done', error = '', finished_at = `+nowSQL+`
		WHERE id = ?`, id); err != nil {
		return fmt.Errorf("finishing account purge %d: %w", id, err)
	}
	if _, err := tx.Exec(accountSQL, accountID); err != nil {
		return fmt.Errorf("finishing account purge %d: marking %s account %d purged: %w", id, source, accountID, err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("finishing account purge %d: %w", id, err)
	}
	return nil
}
