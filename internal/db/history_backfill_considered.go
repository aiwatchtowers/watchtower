package db

// HistoryBackfillConsidered reads chunk-local completion marks. Unlike the
// channels' forward mark these cannot move any live source window.
func (db *DB) HistoryBackfillConsidered(account int64, from, to float64) (map[string]float64, error) {
	rows, err := db.Query(`SELECT channel_id,reached_ts FROM history_backfill_considered WHERE account_id=? AND from_ts=? AND to_ts=?`, account, from, to)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	marks := map[string]float64{}
	for rows.Next() {
		var id string
		var reached float64
		if err := rows.Scan(&id, &reached); err != nil {
			return nil, err
		}
		marks[id] = reached
	}
	return marks, rows.Err()
}
func (db *DB) SetHistoryBackfillConsidered(account int64, channel string, from, to, reached float64) error {
	_, err := db.Exec(`INSERT INTO history_backfill_considered(account_id,channel_id,from_ts,to_ts,reached_ts) VALUES(?,?,?,?,?) ON CONFLICT(account_id,channel_id,from_ts,to_ts) DO UPDATE SET reached_ts=MAX(reached_ts,excluded.reached_ts)`, account, channel, from, to, reached)
	return err
}

// HistoryBackfillDailyCompleted is exact completion, independent of newly
// arrived channel data and separate from the scheduled daily attempt token.
func (db *DB) HistoryBackfillDailyCompleted(account int64, from, to, day float64) (bool, error) {
	var done bool
	err := db.QueryRow(`SELECT EXISTS(SELECT 1 FROM history_backfill_daily WHERE account_id=? AND chunk_from=? AND chunk_to=? AND day_from=?)`, account, from, to, day).Scan(&done)
	return done, err
}

func (db *DB) UpsertHistoryBackfillDaily(d Digest, account int64, from, to float64) (int64, error) {
	tx, err := db.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	id, err := upsertDigestRow(tx, d, "")
	if err != nil {
		return 0, err
	}
	_, err = tx.Exec(`INSERT INTO history_backfill_daily(account_id,chunk_from,chunk_to,day_from,digest_id) VALUES(?,?,?,?,?) ON CONFLICT DO NOTHING`, account, from, to, d.PeriodFrom, id)
	if err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	if d.Situations != "" && d.Situations != "[]" {
		db.populateDigestParticipants(id, d.Situations)
	}
	return id, nil
}

// MarkHistoryBackfillDailyExisting binds an already fresh output to this
// historical step. New channel data later belongs to another ordinary rollup.
func (db *DB) MarkHistoryBackfillDailyExisting(account int64, from, to, day, dayEnd float64) error {
	_, err := db.Exec(`INSERT INTO history_backfill_daily(account_id,chunk_from,chunk_to,day_from,digest_id) SELECT ?,?,?,?,id FROM digests WHERE channel_id='' AND type='daily' AND period_from=? AND period_to=? ON CONFLICT DO NOTHING`, account, from, to, day, day, dayEnd)
	return err
}
