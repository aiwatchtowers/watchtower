package db

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
)

// GetUserProfile returns the profile for the given Slack user ID, or nil if not found.
func (db *DB) GetUserProfile(slackUserID string) (*UserProfile, error) {
	row := db.QueryRow(`SELECT id, slack_user_id, role, team, responsibilities,
		reports, peers, manager, starred_channels, starred_people,
		pain_points, track_focus, onboarding_done, custom_prompt_context,
		created_at, updated_at
		FROM user_profile WHERE slack_user_id = ?`, slackUserID)

	var p UserProfile
	err := row.Scan(&p.ID, &p.SlackUserID, &p.Role, &p.Team, &p.Responsibilities,
		&p.Reports, &p.Peers, &p.Manager, &p.StarredChannels, &p.StarredPeople,
		&p.PainPoints, &p.TrackFocus, &p.OnboardingDone, &p.CustomPromptContext,
		&p.CreatedAt, &p.UpdatedAt)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		return nil, fmt.Errorf("querying user profile: %w", err)
	}
	return &p, nil
}

// upsertUserProfileSQL is the one user_profile upsert, shared by
// UpsertUserProfile and UpsertOwnerProfile's transaction.
const upsertUserProfileSQL = `INSERT INTO user_profile
		(slack_user_id, role, team, responsibilities, reports, peers, manager,
		 starred_channels, starred_people, pain_points, track_focus,
		 onboarding_done, custom_prompt_context, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
		ON CONFLICT(slack_user_id) DO UPDATE SET
			role = excluded.role,
			team = excluded.team,
			responsibilities = excluded.responsibilities,
			reports = excluded.reports,
			peers = excluded.peers,
			manager = excluded.manager,
			starred_channels = excluded.starred_channels,
			starred_people = excluded.starred_people,
			pain_points = excluded.pain_points,
			track_focus = excluded.track_focus,
			onboarding_done = excluded.onboarding_done,
			custom_prompt_context = excluded.custom_prompt_context,
			updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')`

// upsertUserProfileArgs is upsertUserProfileSQL's argument list for p.
func upsertUserProfileArgs(p UserProfile) []any {
	return []any{p.SlackUserID, p.Role, p.Team, p.Responsibilities, p.Reports, p.Peers, p.Manager,
		p.StarredChannels, p.StarredPeople, p.PainPoints, p.TrackFocus,
		p.OnboardingDone, p.CustomPromptContext}
}

// UpsertUserProfile creates or updates a user profile.
func (db *DB) UpsertUserProfile(p UserProfile) error {
	_, err := db.Exec(upsertUserProfileSQL, upsertUserProfileArgs(p)...)
	if err != nil {
		return fmt.Errorf("upserting user profile: %w", err)
	}
	return nil
}

// GetOwnerProfile returns the owner's profile. user_profile is an owner
// singleton: the row keyed o.ID wins; without one, the most recently updated
// row stands in (the owner switched rungs, e.g. a Google-keyed profile before
// Slack was connected). An unknown owner → nil, nil.
func (db *DB) GetOwnerProfile(o Owner) (*UserProfile, error) {
	if !o.Known() {
		return nil, nil
	}
	p, err := db.GetUserProfile(o.ID)
	if err != nil || p != nil {
		return p, err
	}
	key, err := latestUserProfileKey(db)
	if err != nil || key == "" {
		return nil, err
	}
	return db.GetUserProfile(key)
}

// latestUserProfileKey returns the slack_user_id of the most recently updated
// user_profile row (tie → greatest id), or "" when the table is empty.
func latestUserProfileKey(q interface {
	QueryRow(query string, args ...any) *sql.Row
}) (string, error) {
	var key string
	err := q.QueryRow(`SELECT slack_user_id FROM user_profile ORDER BY updated_at DESC, id DESC LIMIT 1`).Scan(&key)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("querying latest user profile: %w", err)
	}
	return key, nil
}

// UpsertOwnerProfile writes p as the owner's profile under o.ID. When no row
// is keyed o.ID yet but a fallback row exists (the owner switched rungs), that
// row is re-keyed to o.ID first, in the same transaction — the table keeps
// exactly one owner row. An unknown owner → ErrNoOwner.
func (db *DB) UpsertOwnerProfile(o Owner, p UserProfile) error {
	if !o.Known() {
		return ErrNoOwner
	}
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("beginning owner profile upsert: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	if err := rekeyOwnerProfile(tx, o.ID); err != nil {
		return err
	}
	p.SlackUserID = o.ID
	if _, err := tx.Exec(upsertUserProfileSQL, upsertUserProfileArgs(p)...); err != nil {
		return fmt.Errorf("upserting owner profile: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("committing owner profile upsert: %w", err)
	}
	return nil
}

// rekeyOwnerProfile moves the fallback profile row onto ownerID when no row
// is keyed ownerID yet. A no-op when ownerID already has a row or the table
// is empty.
func rekeyOwnerProfile(tx *sql.Tx, ownerID string) error {
	var exists bool
	if err := tx.QueryRow(`SELECT EXISTS(SELECT 1 FROM user_profile WHERE slack_user_id = ?)`, ownerID).Scan(&exists); err != nil {
		return fmt.Errorf("checking owner profile key: %w", err)
	}
	if exists {
		return nil
	}
	key, err := latestUserProfileKey(tx)
	if err != nil || key == "" {
		return err
	}
	if _, err := tx.Exec(`UPDATE user_profile SET slack_user_id = ? WHERE slack_user_id = ?`, ownerID, key); err != nil {
		return fmt.Errorf("re-keying owner profile: %w", err)
	}
	return nil
}

// AddStarredChannel adds a channel to the user's starred channels list.
func (db *DB) AddStarredChannel(slackUserID, channelID string) error {
	profile, err := db.GetUserProfile(slackUserID)
	if err != nil {
		return fmt.Errorf("getting user profile: %w", err)
	}
	if profile == nil {
		return errors.New("user profile not found")
	}

	var channels []string
	if profile.StarredChannels != "" {
		if err := json.Unmarshal([]byte(profile.StarredChannels), &channels); err != nil {
			return fmt.Errorf("unmarshaling starred channels: %w", err)
		}
	}

	// Check if already starred
	for _, ch := range channels {
		if ch == channelID {
			return nil // Already starred, idempotent
		}
	}

	channels = append(channels, channelID)
	data, err := json.Marshal(channels)
	if err != nil {
		return fmt.Errorf("marshaling starred channels: %w", err)
	}

	profile.StarredChannels = string(data)
	return db.UpsertUserProfile(*profile)
}

// RemoveStarredChannel removes a channel from the user's starred channels list.
func (db *DB) RemoveStarredChannel(slackUserID, channelID string) error {
	profile, err := db.GetUserProfile(slackUserID)
	if err != nil {
		return fmt.Errorf("getting user profile: %w", err)
	}
	if profile == nil {
		return errors.New("user profile not found")
	}

	var channels []string
	if profile.StarredChannels != "" {
		if err := json.Unmarshal([]byte(profile.StarredChannels), &channels); err != nil {
			return fmt.Errorf("unmarshaling starred channels: %w", err)
		}
	}

	// Remove the channel
	newChannels := []string{}
	for _, ch := range channels {
		if ch != channelID {
			newChannels = append(newChannels, ch)
		}
	}

	data, err := json.Marshal(newChannels)
	if err != nil {
		return fmt.Errorf("marshaling starred channels: %w", err)
	}

	profile.StarredChannels = string(data)
	return db.UpsertUserProfile(*profile)
}

// AddStarredPerson adds a person to the user's starred people list.
func (db *DB) AddStarredPerson(slackUserID, personUserID string) error {
	profile, err := db.GetUserProfile(slackUserID)
	if err != nil {
		return fmt.Errorf("getting user profile: %w", err)
	}
	if profile == nil {
		return errors.New("user profile not found")
	}

	var people []string
	if profile.StarredPeople != "" {
		if err := json.Unmarshal([]byte(profile.StarredPeople), &people); err != nil {
			return fmt.Errorf("unmarshaling starred people: %w", err)
		}
	}

	// Check if already starred
	for _, p := range people {
		if p == personUserID {
			return nil // Already starred, idempotent
		}
	}

	people = append(people, personUserID)
	data, err := json.Marshal(people)
	if err != nil {
		return fmt.Errorf("marshaling starred people: %w", err)
	}

	profile.StarredPeople = string(data)
	return db.UpsertUserProfile(*profile)
}

// RemoveStarredPerson removes a person from the user's starred people list.
func (db *DB) RemoveStarredPerson(slackUserID, personUserID string) error {
	profile, err := db.GetUserProfile(slackUserID)
	if err != nil {
		return fmt.Errorf("getting user profile: %w", err)
	}
	if profile == nil {
		return errors.New("user profile not found")
	}

	var people []string
	if profile.StarredPeople != "" {
		if err := json.Unmarshal([]byte(profile.StarredPeople), &people); err != nil {
			return fmt.Errorf("unmarshaling starred people: %w", err)
		}
	}

	// Remove the person
	newPeople := []string{}
	for _, p := range people {
		if p != personUserID {
			newPeople = append(newPeople, p)
		}
	}

	data, err := json.Marshal(newPeople)
	if err != nil {
		return fmt.Errorf("marshaling starred people: %w", err)
	}

	profile.StarredPeople = string(data)
	return db.UpsertUserProfile(*profile)
}
