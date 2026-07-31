package db

import "fmt"

// ClearSlackData removes all Slack-sourced rows and the AI products built on
// them (used on Slack disconnect): raw sync data, digests, tracks, people
// analytics, briefings, Slack inbox items together with the situations and
// feed rows they composed, and the Slack sync watermarks. Data from other
// sources (Gmail, Calendar, Jira), targets, day plans, and the user's own
// profiles are preserved.
func (db *DB) ClearSlackData() error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("beginning slack purge: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	stmts := []string{
		// Learned rules keyed to Slack channels/senders — resolved against the
		// channels/users tables, so this must run before those are wiped.
		`DELETE FROM inbox_learned_rules WHERE scope_key IN (
			SELECT 'channel:' || id FROM channels
			UNION SELECT 'sender:' || id FROM users)`,

		// Feedback on Slack-derived entities. Target feedback survives because
		// targets themselves survive as user-managed work items.
		`DELETE FROM feedback WHERE entity_type IN
			('digest','track','decision','user_analysis','briefing','inbox','catchup_theme')`,

		// Slack inbox signals (jira_*/calendar_*/email_*/target_due survive).
		// inbox_feedback and situation_signals rows cascade via FK. Memory dispute
		// items (channel_id='memory', trigger_type='decision_made') are NOT
		// Slack-derived — they surface belief conflicts from the memory vault — so
		// they are excluded and survive a Slack disconnect.
		`DELETE FROM inbox_items WHERE trigger_type IN
			('mention','dm','thread_reply','reaction','stream','decision_made','briefing_ready')
			AND channel_id != 'memory'`,

		// Situations left with no signals, then feed rows whose source is gone.
		`DELETE FROM situations WHERE id NOT IN
			(SELECT situation_id FROM situation_signals)`,
		`DELETE FROM feed_items WHERE item_type = 'situation'
			AND source_id NOT IN (SELECT CAST(id AS TEXT) FROM situations)`,
		`DELETE FROM feed_items WHERE item_type = 'briefing'`,

		// AI products computed from Slack messages.
		`DELETE FROM digest_participants`,
		`DELETE FROM digest_topics`,
		`DELETE FROM decision_reads`,
		`DELETE FROM digests`,
		`DELETE FROM user_analyses`,
		`DELETE FROM period_summaries`,
		`DELETE FROM track_events`,
		`DELETE FROM track_states`,
		`DELETE FROM tracks`,
		`DELETE FROM guide_summaries`,
		`DELETE FROM communication_guides`,
		`DELETE FROM people_card_summaries`,
		`DELETE FROM people_cards`,
		`DELETE FROM briefings`,
		`DELETE FROM catchup_themes`,
		`DELETE FROM catchup_sessions`,
		`DELETE FROM decision_importance_corrections`,
		`DELETE FROM user_interactions`,

		// Raw Slack sync data. Deleting messages also clears the FTS index
		// via the messages_ad trigger.
		`DELETE FROM reactions`,
		`DELETE FROM files`,
		`DELETE FROM messages`,
		`DELETE FROM users`,
		`DELETE FROM channels`,
		`DELETE FROM sync_state`,
		`DELETE FROM watch_list`,
		`DELETE FROM user_checkpoints`,
		`DELETE FROM custom_emojis`,
		`DELETE FROM channel_settings`,

		// Slack linkage caches.
		`DELETE FROM jira_slack_links`,
		`DELETE FROM jira_user_map`,
		`DELETE FROM meeting_prep_cache`,

		// Slack sync watermarks; the Gmail watermark stays. Per-account
		// search_last_date now lives on slack_accounts — untouched here (see
		// docs/superpowers/plans/2026-07-31-slack-multi-account.md).
		`UPDATE workspace SET synced_at = NULL,
			inbox_last_processed_ts = 0, compose_last_run_ts = 0`,
	}
	for _, stmt := range stmts {
		if _, err := tx.Exec(stmt); err != nil {
			return fmt.Errorf("slack purge: %w", err)
		}
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("committing slack purge: %w", err)
	}
	return nil
}
