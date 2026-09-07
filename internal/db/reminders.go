package db

import "fmt"

// Reminder is one parked message the owner asked to resurface (remind_me tool).
type Reminder struct {
	ID         int64
	AccountID  int64
	MessageRef string
	Note       string
	RemindAt   string
	Status     string
	CreatedAt  string
	DoneAt     string
}

func (db *DB) InsertReminder(r Reminder) (int64, error) {
	res, err := db.Exec(`INSERT INTO reminders (account_id, message_ref, note, remind_at)
		VALUES (?, ?, ?, ?)`, r.AccountID, r.MessageRef, r.Note, r.RemindAt)
	if err != nil {
		return 0, fmt.Errorf("inserting reminder: %w", err)
	}
	return res.LastInsertId()
}

func (db *DB) ListDueReminders(nowUTC string) ([]Reminder, error) {
	rows, err := db.Query(`SELECT id, account_id, message_ref, note, remind_at, status, created_at, done_at
		FROM reminders WHERE status = 'pending' AND remind_at <= ? ORDER BY remind_at ASC`, nowUTC)
	if err != nil {
		return nil, fmt.Errorf("listing due reminders: %w", err)
	}
	defer rows.Close()
	var out []Reminder
	for rows.Next() {
		var r Reminder
		if err := rows.Scan(&r.ID, &r.AccountID, &r.MessageRef, &r.Note, &r.RemindAt, &r.Status, &r.CreatedAt, &r.DoneAt); err != nil {
			return nil, fmt.Errorf("scanning reminder: %w", err)
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func (db *DB) MarkReminderDone(id int64) error {
	_, err := db.Exec(`UPDATE reminders SET status='done', done_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id=?`, id)
	if err != nil {
		return fmt.Errorf("marking reminder done: %w", err)
	}
	return nil
}

func (db *DB) SnoozeReminder(id int64, until string) error {
	_, err := db.Exec(`UPDATE reminders SET remind_at=?, status='pending' WHERE id=?`, until, id)
	if err != nil {
		return fmt.Errorf("snoozing reminder: %w", err)
	}
	return nil
}
