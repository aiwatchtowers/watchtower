package db

import (
	"errors"
	"fmt"
)

// ErrPersonNotFound is returned by ExcludePerson and IncludePerson for an id
// that names no Slack user.
var ErrPersonNotFound = errors.New("user not found")

// ErrPersonExcluded is returned by UpsertPeopleCard for a person the owner
// stopped cards for: nothing is written.
var ErrPersonExcluded = errors.New("the owner stopped cards for this person")

// ExcludePerson stops people cards for a Slack user (Stop card for this
// person, spec 2026-11-17 §5.3, A14): it records the namespaced id in
// people_card_exclusions and deletes the person's cards in the same
// transaction, so no window keeps one. Excluding an excluded person again is
// a no-op. An id with no users row is ErrPersonNotFound.
func (db *DB) ExcludePerson(userID string) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("beginning exclude person tx: %w", err)
	}
	defer tx.Rollback()
	var known int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM users WHERE id = ?`, userID).Scan(&known); err != nil {
		return fmt.Errorf("looking up user %s: %w", userID, err)
	}
	if known == 0 {
		return fmt.Errorf("%w: %s", ErrPersonNotFound, userID)
	}
	if _, err := tx.Exec(`INSERT INTO people_card_exclusions (user_id) VALUES (?) ON CONFLICT(user_id) DO NOTHING`, userID); err != nil {
		return fmt.Errorf("excluding %s: %w", userID, err)
	}
	if _, err := tx.Exec(`DELETE FROM people_cards WHERE user_id = ?`, userID); err != nil {
		return fmt.Errorf("deleting cards of %s: %w", userID, err)
	}
	return tx.Commit()
}

// IncludePerson undoes ExcludePerson (Make cards again): the next people run
// may make a card for the person again. Including a person who is not
// excluded is a no-op; an id that is neither excluded nor a Slack user is
// ErrPersonNotFound.
func (db *DB) IncludePerson(userID string) error {
	res, err := db.Exec(`DELETE FROM people_card_exclusions WHERE user_id = ?`, userID)
	if err != nil {
		return fmt.Errorf("including %s: %w", userID, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("including %s: %w", userID, err)
	}
	if n > 0 {
		return nil
	}
	var known int
	if err := db.QueryRow(`SELECT COUNT(*) FROM users WHERE id = ?`, userID).Scan(&known); err != nil {
		return fmt.Errorf("looking up user %s: %w", userID, err)
	}
	if known == 0 {
		return fmt.Errorf("%w: %s", ErrPersonNotFound, userID)
	}
	return nil
}

// PeopleExclusions returns the namespaced ids the owner stopped cards for.
func (db *DB) PeopleExclusions() (map[string]bool, error) {
	rows, err := db.Query(`SELECT user_id FROM people_card_exclusions`)
	if err != nil {
		return nil, fmt.Errorf("listing people exclusions: %w", err)
	}
	defer rows.Close()
	out := map[string]bool{}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scanning people exclusion: %w", err)
		}
		out[id] = true
	}
	return out, rows.Err()
}
