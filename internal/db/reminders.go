package db

import (
	"database/sql"
	"fmt"
)

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
	id, err := res.LastInsertId()
	if err != nil {
		return 0, fmt.Errorf("inserting reminder: %w", err)
	}
	db.approvalChanged(ReminderRef(id))
	return id, nil
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

// MarkReminderDone marks reminder id done. changed is false when it was
// already done or does not exist: nothing was written and the approval hook
// is not called.
func (db *DB) MarkReminderDone(id int64) (changed bool, err error) {
	res, err := db.Exec(`UPDATE reminders SET status='done', done_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = ? AND status != 'done'`, id)
	return db.reminderChanged(id, res, err, "marking reminder done")
}

// SnoozeReminder moves reminder id to until and makes it pending again.
// changed is false for an unknown id.
func (db *DB) SnoozeReminder(id int64, until string) (changed bool, err error) {
	res, err := db.Exec(`UPDATE reminders SET remind_at=?, status='pending' WHERE id=?`, until, id)
	return db.reminderChanged(id, res, err, "snoozing reminder")
}

// reminderChanged reads an autocommit reminder UPDATE's result and calls the
// approval hook when it changed a row.
func (db *DB) reminderChanged(id int64, res sql.Result, err error, what string) (bool, error) {
	if err != nil {
		return false, fmt.Errorf("%s: %w", what, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("%s: %w", what, err)
	}
	if n == 0 {
		return false, nil
	}
	db.approvalChanged(ReminderRef(id))
	return true, nil
}
