package db

import (
	"database/sql"
	"errors"
	"fmt"
	"log"
	"strings"
)

// CreateTargetFromJiraIssue creates a target from a Jira issue with dedup.
// If a target with source_type='jira' and source_id=issue.Key already exists,
// it returns the existing target without creating a duplicate.
func (db *DB) CreateTargetFromJiraIssue(issue JiraIssue) (*Target, error) {
	return db.createIssueTarget(TrackerJira, issue.Key, issue.Summary, jiraPriorityToTargetPriority(issue.Priority), issue.DueDate)
}

// CreateTargetFromTrackerIssue creates a target from a Jira or Linear issue
// with the same dedup: an existing target with source_type = the issue's
// tracker and source_id = its key is returned instead of a duplicate.
func (db *DB) CreateTargetFromTrackerIssue(issue TrackerIssue) (*Target, error) {
	if issue.Tracker != TrackerJira && issue.Tracker != TrackerLinear {
		return nil, fmt.Errorf("creating target from %s issue %s: unknown tracker", issue.Tracker, issue.Key)
	}
	return db.createIssueTarget(issue.Tracker, issue.Key, issue.Title, rankToTargetPriority(issue.PriorityRank), issue.DueDate)
}

// createIssueTarget is the shared body: a day-level, mine, todo target whose
// source is the issue (sourceType 'jira' or 'linear', source_id the key).
func (db *DB) createIssueTarget(sourceType, key, title, priority, dueDate string) (*Target, error) {
	tx, err := db.Begin()
	if err != nil {
		return nil, fmt.Errorf("beginning %s target tx: %w", sourceType, err)
	}
	defer tx.Rollback()

	row := tx.QueryRow(`SELECT `+targetSelectCols+` FROM targets WHERE source_type = ? AND source_id = ?`, sourceType, key)
	existing, err := scanTarget(row)
	if err == nil {
		return existing, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("checking existing %s target %s: %w", sourceType, key, err)
	}

	res, err := tx.Exec(`INSERT INTO targets
		(text, intent, level, custom_label, period_start, period_end,
		 status, priority, ownership, ball_on, due_date, snooze_until, blocking,
		 tags, sub_items, notes, progress, source_type, source_id)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		title, "", "day", "", dueDate, dueDate,
		"todo", priority, "mine", "", dueDate, "", "",
		"[]", "[]", "[]", 0.0, sourceType, key,
	)
	if err != nil {
		return nil, fmt.Errorf("creating target from %s issue %s: %w", sourceType, key, err)
	}

	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("committing %s target tx: %w", sourceType, err)
	}

	id, _ := res.LastInsertId()
	created, err := db.GetTargetByID(int(id))
	if err != nil {
		return &Target{
			ID: int(id), Text: title, Status: "todo",
			Priority: priority, Ownership: "mine", DueDate: dueDate,
			SourceType: sourceType, SourceID: key, Tags: "[]", SubItems: "[]",
		}, err
	}
	return created, nil
}

// jiraPriorityToTargetPriority maps Jira priority names to target priority levels.
func jiraPriorityToTargetPriority(jiraPriority string) string {
	switch strings.ToLower(jiraPriority) {
	case "highest", "high":
		return "high"
	case "medium":
		return "medium"
	case "low", "lowest":
		return "low"
	default:
		return "medium"
	}
}

// rankToTargetPriority maps tracker_issues.priority_rank (1 highest … 5
// lowest, 0 none) to a target priority — for Jira's standard names the same
// levels jiraPriorityToTargetPriority gives.
func rankToTargetPriority(rank int) string {
	switch rank {
	case 1, 2:
		return "high"
	case 4, 5:
		return "low"
	default:
		return "medium"
	}
}

// SyncJiraTargetStatuses synchronizes target statuses from linked Jira issues.
func (db *DB) SyncJiraTargetStatuses() (int, error) {
	return db.syncIssueTargetStatuses(TrackerJira)
}

// SyncLinearTargetStatuses synchronizes target statuses from linked Linear
// issues, with the Jira rules.
func (db *DB) SyncLinearTargetStatuses() (int, error) {
	return db.syncIssueTargetStatuses(TrackerLinear)
}

// syncIssueTargetStatuses moves the open targets whose source is a tracker
// issue: done when the issue is done, in_progress when a todo target's issue
// started. The issue is read from tracker_issues and must be unambiguous:
// `targets.source_id` holds a bare key with no account dimension, and this
// WRITE path flips a user-authored target, so a key two connected accounts
// share leaves the target alone rather than guessing (UnambiguousTrackerIssue).
func (db *DB) syncIssueTargetStatuses(tracker string) (int, error) {
	rows, err := db.Query(`SELECT `+targetSelectCols+` FROM targets WHERE source_type = ? AND status NOT IN ('done', 'dismissed')`, tracker)
	if err != nil {
		return 0, fmt.Errorf("querying %s targets: %w", tracker, err)
	}
	defer rows.Close()

	var targets []Target
	for rows.Next() {
		t, err := scanTarget(rows)
		if err != nil {
			return 0, fmt.Errorf("scanning %s target: %w", tracker, err)
		}
		targets = append(targets, *t)
	}
	if err := rows.Err(); err != nil {
		return 0, err
	}

	synced := 0
	for _, t := range targets {
		issue, err := db.UnambiguousTrackerIssue(tracker, t.SourceID)
		if err != nil {
			log.Printf("%s-targets: error fetching issue %s: %v", tracker, t.SourceID, err)
			continue
		}
		if issue == nil {
			continue
		}

		cat := strings.ToLower(issue.StatusCategory)
		var newStatus string
		switch {
		case cat == "done":
			newStatus = "done"
		case cat == "in_progress" && t.Status == "todo":
			newStatus = "in_progress"
		default:
			continue
		}

		// A sync write: recorded as the system's in a project target's
		// status history (PROJ-06).
		if err := updateTargetStatusOn(db, t.ID, newStatus, ActorSystem); err != nil {
			log.Printf("%s-targets: error updating target %d status to %s: %v", tracker, t.ID, newStatus, err)
			continue
		}
		synced++
	}
	return synced, nil
}
