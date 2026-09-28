package db

import "fmt"

// GetTrackRetryDigests returns the channel digests whose track-extraction batch
// failed in an earlier run and that are still owed a retry.
func (db *DB) GetTrackRetryDigests() ([]Digest, error) {
	rows, err := db.Query(`SELECT d.id, d.channel_id, d.period_from, d.period_to, d.type, d.summary, d.topics, d.decisions, d.action_items, d.people_signals, d.situations, d.running_summary, d.message_count, d.model, d.input_tokens, d.output_tokens, d.cost_usd, d.created_at, d.read_at
		FROM track_retry_digests r JOIN digests d ON d.id = r.digest_id
		WHERE d.type = 'channel'
		ORDER BY d.created_at DESC`)
	if err != nil {
		return nil, fmt.Errorf("querying track retry digests: %w", err)
	}
	defer rows.Close()
	var digests []Digest
	for rows.Next() {
		var d Digest
		if err := rows.Scan(&d.ID, &d.ChannelID, &d.PeriodFrom, &d.PeriodTo, &d.Type,
			&d.Summary, &d.Topics, &d.Decisions, &d.ActionItems, &d.PeopleSignals, &d.Situations, &d.RunningSummary,
			&d.MessageCount, &d.Model, &d.InputTokens, &d.OutputTokens, &d.CostUSD, &d.CreatedAt, &d.ReadAt); err != nil {
			return nil, fmt.Errorf("scanning track retry digest: %w", err)
		}
		digests = append(digests, d)
	}
	return digests, rows.Err()
}

// SettleTrackRetryDigests records one tracks run's outcome in the retry set, in
// one transaction: every id in done leaves the set, every id in failed gains an
// attempt, and a failed id that reaches maxAttempts leaves the set too (the run
// gives up on it). Returns how many digests were given up on.
func (db *DB) SettleTrackRetryDigests(done, failed []int, maxAttempts int) (int, error) {
	if len(done) == 0 && len(failed) == 0 {
		return 0, nil
	}
	tx, err := db.Begin()
	if err != nil {
		return 0, fmt.Errorf("settling track retry digests: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	for _, id := range done {
		if _, err := tx.Exec(`DELETE FROM track_retry_digests WHERE digest_id = ?`, id); err != nil {
			return 0, fmt.Errorf("clearing track retry digest %d: %w", id, err)
		}
	}
	gaveUp := 0
	for _, id := range failed {
		var attempts int
		if err := tx.QueryRow(`INSERT INTO track_retry_digests (digest_id, attempts) VALUES (?, 1)
			ON CONFLICT(digest_id) DO UPDATE SET attempts = attempts + 1,
				updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
			RETURNING attempts`, id).Scan(&attempts); err != nil {
			return 0, fmt.Errorf("recording track retry digest %d: %w", id, err)
		}
		if attempts >= maxAttempts {
			if _, err := tx.Exec(`DELETE FROM track_retry_digests WHERE digest_id = ?`, id); err != nil {
				return 0, fmt.Errorf("dropping track retry digest %d: %w", id, err)
			}
			gaveUp++
		}
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("settling track retry digests: %w", err)
	}
	return gaveUp, nil
}
