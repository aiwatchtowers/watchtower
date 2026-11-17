package db

import (
	"database/sql"
	"fmt"
)

// wipeLLMStatements are the Desktop's Wipe LLM Data (DatabaseManager.
// wipeLLMData), statement for statement and in its order: every AI-made
// row goes, raw Slack data, config and the owner's profile stay. Targets go
// only when AI-sourced and personal: the owner's own and every project
// board stay (PROJ-02: only a project delete removes its targets).
var wipeLLMStatements = []string{
	`DELETE FROM digests`,
	`DELETE FROM user_analyses`,
	`DELETE FROM period_summaries`,
	`DELETE FROM tracks`,
	`DELETE FROM people_cards`,
	`DELETE FROM people_card_summaries`,
	`DELETE FROM briefings`,
	`DELETE FROM targets
		WHERE source_type IN ('extract','track','digest','briefing','chat','inbox')
		  AND project_id IS NULL`,
	`DELETE FROM inbox_items`,
	`UPDATE workspace SET inbox_last_processed_ts = 0`,
	`DELETE FROM pipeline_steps`,
	`DELETE FROM pipeline_runs`,
	`DELETE FROM feedback`,
	`DELETE FROM decision_reads`,
	`DELETE FROM user_interactions`,
}

// WipeLLMData deletes all AI-generated data in one transaction
// (`watchtower db wipe-llm`, the Go twin of DatabaseManager.wipeLLMData; the
// app runs it with the daemon stopped). Any failure rolls every statement
// back.
func (db *DB) WipeLLMData() error {
	return db.WithTx(func(tx *sql.Tx) error {
		for i, q := range wipeLLMStatements {
			if _, err := tx.Exec(q); err != nil {
				return fmt.Errorf("wiping LLM data (statement %d): %w", i+1, err)
			}
			if err := fault("wipe_llm"); err != nil {
				return err
			}
		}
		return nil
	})
}
