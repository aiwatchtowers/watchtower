package db

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"time"
)

// The Inbox's writers (spec 2026-11-15-mobile-inbox §4.3). Each is one short
// write in the caller's transaction, ported from its Swift twin in
// WatchtowerCore/Database/Queries with its guard kept; inbox.act
// (internal/inboxfeed) runs them inside tower.Ctx.Write, and the older
// non-Tx forms (MarkTrackRead, ResolveInboxItem, …) wrap them, so each write
// has one implementation. The reminder writes have no Tx form: their
// approval hook runs after their own commit (MarkReminderDone,
// SnoozeReminder; TestApprovalHook_EveryWriterNotifies).

// ErrRowNotFound is a writer's refusal of a row that is not there (Swift's
// requireUpdated / RowNotFoundError).
var ErrRowNotFound = errors.New("row not found")

// ignoreNoRow keeps a non-Tx wrapper's old answer for a missing row: no
// error.
func ignoreNoRow(err error) error {
	if errors.Is(err, ErrRowNotFound) {
		return nil
	}
	return err
}

// faultAfter is the test seam between a writer's statements: a non-nil
// error it returns fails the writer there, so the caller's transaction
// rolls back (TestWriters_FaultSeamRollsBack).
var faultAfter func(step string) error

func fault(step string) error {
	if faultAfter == nil {
		return nil
	}
	return faultAfter(step)
}

// requireRow is requireUpdated: res changed a row, else ErrRowNotFound.
func requireRow(res sql.Result, kind string, id any) error {
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("%s %v: %w", kind, id, err)
	}
	if n == 0 {
		return fmt.Errorf("%s %v: %w", kind, id, ErrRowNotFound)
	}
	return nil
}

// MarkOutputReadTx is the owner opening a card (AutomationQueries.
// markOutputOpened): read_at only, once, on an open card still at
// contentHash. False when nothing changed: the card was rewritten, closed
// or already read.
func MarkOutputReadTx(tx *sql.Tx, id int64, contentHash string, now time.Time) (bool, error) {
	return stampOutputOnce(tx, "read_at", id, contentHash, now, " AND read_at IS NULL")
}

// MarkOutputDoneTx is Done on a card (markOutputDone): done_at, once, at the
// drawn version.
func MarkOutputDoneTx(tx *sql.Tx, id int64, contentHash string, now time.Time) (bool, error) {
	return stampOutputOnce(tx, "done_at", id, contentHash, now, "")
}

// DismissOutputTx is Dismiss on a card (dismissOutput): dismissed_at, once,
// at the drawn version.
func DismissOutputTx(tx *sql.Tx, id int64, contentHash string, now time.Time) (bool, error) {
	return stampOutputOnce(tx, "dismissed_at", id, contentHash, now, "")
}

// stampOutputOnce is AutomationQueries.stampOnce: stamps one state column of
// an open card (neither done nor dismissed) whose content_hash is still the
// drawn one. column and extra are constants of this file.
func stampOutputOnce(tx *sql.Tx, column string, id int64, contentHash string, now time.Time, extra string) (bool, error) {
	//nolint:gosec // G202: column and extra are constants of this file; every value is a bound arg.
	res, err := tx.Exec(`UPDATE automation_outputs SET `+column+` = ?
		WHERE id = ? AND content_hash = ? AND done_at IS NULL AND dismissed_at IS NULL`+extra,
		formatAutomationTime(now), id, contentHash)
	if err != nil {
		return false, fmt.Errorf("stamping %s of inbox card %d: %w", column, id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("stamping %s of inbox card %d: %w", column, id, err)
	}
	if err := fault("output." + column); err != nil {
		return false, err
	}
	return n > 0, nil
}

// MarkBriefingReadTx marks briefings ids read, once (BriefingQueries.markRead).
func MarkBriefingReadTx(tx *sql.Tx, ids []int) error {
	if len(ids) == 0 {
		return nil
	}
	//nolint:gosec // G202: the concatenation is only "?" placeholders; every value is a bound arg.
	if _, err := tx.Exec(`UPDATE briefings SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
		WHERE id IN (`+placeholders(len(ids))+`) AND read_at IS NULL`, intArgs(ids)...); err != nil {
		return fmt.Errorf("marking briefings read: %w", err)
	}
	return fault("briefing.read")
}

// MarkInboxItemReadTx is opening a message card (InboxQueries.markRead):
// read_at only, once.
func MarkInboxItemReadTx(tx *sql.Tx, id int) error {
	if _, err := tx.Exec(`UPDATE inbox_items SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
		WHERE id = ? AND (read_at IS NULL OR read_at = '')`, id); err != nil {
		return fmt.Errorf("marking inbox item %d read: %w", id, err)
	}
	return fault("inbox_item.read")
}

// ResolveInboxItemTx marks inbox item id resolved with reason.
func ResolveInboxItemTx(tx *sql.Tx, id int, reason string) error {
	if _, err := tx.Exec(`UPDATE inbox_items SET status = 'resolved', resolved_reason = ?,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
		WHERE id = ?`, reason, id); err != nil {
		return fmt.Errorf("resolving inbox item %d: %w", id, err)
	}
	return fault("inbox_item.resolve")
}

// DismissInboxItemTx marks inbox item id dismissed.
func DismissInboxItemTx(tx *sql.Tx, id int) error {
	if _, err := tx.Exec(`UPDATE inbox_items SET status = 'dismissed',
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
		WHERE id = ?`, id); err != nil {
		return fmt.Errorf("dismissing inbox item %d: %w", id, err)
	}
	return fault("inbox_item.dismiss")
}

// SnoozeInboxItemTx snoozes inbox item id until the date until.
func SnoozeInboxItemTx(tx *sql.Tx, id int, until string) error {
	if _, err := tx.Exec(`UPDATE inbox_items SET status = 'snoozed', snooze_until = ?,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
		WHERE id = ?`, until, id); err != nil {
		return fmt.Errorf("snoozing inbox item %d: %w", id, err)
	}
	return fault("inbox_item.snooze")
}

// MarkTrackReadTx marks track id read (TrackQueries.markRead, TRACKS-04):
// read_at now, has_updates cleared, and its related digests read with all
// their decisions. A track that is not there has nothing left to read.
func MarkTrackReadTx(tx *sql.Tx, id int) error {
	if _, err := tx.Exec(`UPDATE tracks SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), has_updates = 0
		WHERE id = ?`, id); err != nil {
		return fmt.Errorf("marking track %d read: %w", id, err)
	}
	if err := fault("track.read"); err != nil {
		return err
	}
	var related string
	err := tx.QueryRow(`SELECT related_digest_ids FROM tracks WHERE id = ?`, id).Scan(&related)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("reading track %d's digests: %w", id, err)
	}
	for _, did := range decodeOrNil[[]int](related) {
		if did <= 0 {
			continue
		}
		if err := markDigestReadTx(tx, did); err != nil {
			return err
		}
	}
	return nil
}

// decodeOrNil is Swift's `try? JSONDecoder().decode`: s decoded, or the zero
// value when it does not decode (an unreadable list cascades nothing).
func decodeOrNil[T any](s string) T {
	var v T
	if json.Unmarshal([]byte(s), &v) != nil {
		var zero T
		return zero
	}
	return v
}

// markDigestReadTx is DigestQueries.markDigestRead and markAllDecisionsRead.
func markDigestReadTx(tx *sql.Tx, id int) error {
	if _, err := tx.Exec(`UPDATE digests SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
		WHERE id = ? AND read_at IS NULL`, id); err != nil {
		return fmt.Errorf("marking digest %d read: %w", id, err)
	}
	if err := fault("track.digest"); err != nil {
		return err
	}
	var decisions string
	err := tx.QueryRow(`SELECT decisions FROM digests WHERE id = ?`, id).Scan(&decisions)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("reading digest %d's decisions: %w", id, err)
	}
	for i := range decodeOrNil[[]json.RawMessage](decisions) {
		if _, err := tx.Exec(`INSERT INTO decision_reads (digest_id, decision_idx) VALUES (?, ?)
			ON CONFLICT DO NOTHING`, id, i); err != nil {
			return fmt.Errorf("marking digest %d decision %d read: %w", id, i, err)
		}
	}
	return nil
}

// MarkTrackDoneTx is Done on a track card (ActionStripViewModel.
// markTrackDone): the track read with its cascade (MarkTrackReadTx) and
// every unread event of it read (TrackEventQueries.markAllRead).
func MarkTrackDoneTx(tx *sql.Tx, id int) error {
	if err := MarkTrackReadTx(tx, id); err != nil {
		return err
	}
	if err := fault("track.done"); err != nil {
		return err
	}
	if _, err := tx.Exec(`UPDATE track_events SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE track_id = ? AND (read_at IS NULL OR read_at = '')`, id); err != nil {
		return fmt.Errorf("marking track %d's events read: %w", id, err)
	}
	return nil
}

// StopTrackTx is Stop watching (TrackQueries.dismiss, TRACKS-07) on each of
// ids: dismissed_at now. A track that is not there is ErrRowNotFound.
func StopTrackTx(tx *sql.Tx, ids []int) error {
	for _, id := range ids {
		res, err := tx.Exec(`UPDATE tracks SET dismissed_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = ?`, id)
		if err != nil {
			return fmt.Errorf("dismissing track %d: %w", id, err)
		}
		if err := requireRow(res, "track", id); err != nil {
			return err
		}
		if err := fault("track.stop"); err != nil {
			return err
		}
	}
	return nil
}

// SetTrackEnabledTx turns an unbound custom track's collection on or off
// (TrackQueries.setEnabled).
func SetTrackEnabledTx(tx *sql.Tx, id int, enabled bool) error {
	res, err := tx.Exec(`UPDATE tracks SET enabled = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?`,
		enabled, id)
	if err != nil {
		return fmt.Errorf("setting track %d enabled=%v: %w", id, enabled, err)
	}
	if err := requireRow(res, "track", id); err != nil {
		return err
	}
	return fault("track.enabled")
}

// RestoreTrackTx undoes Stop watching (TrackQueries.restore).
func RestoreTrackTx(tx *sql.Tx, id int) error {
	res, err := tx.Exec(`UPDATE tracks SET dismissed_at = '' WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("restoring track %d: %w", id, err)
	}
	if err := requireRow(res, "track", id); err != nil {
		return err
	}
	return fault("track.restore")
}

// ideaClearReview is IdeaQueries.clearReviewFlag: every owner verdict clears
// the pending review flag (IDEA-04).
const ideaClearReview = `needs_review = 0, review_reason = ''`

// SetIdeaVerdictTx sets idea id's status (IdeaQueries.setStatus), clearing
// its review flag.
func SetIdeaVerdictTx(tx *sql.Tx, id int, status string) error {
	res, err := tx.Exec(`UPDATE ideas SET status = ?, `+ideaClearReview+`,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
		WHERE id = ?`, status, id)
	if err != nil {
		return fmt.Errorf("setting idea %d to %s: %w", id, status, err)
	}
	if err := requireRow(res, "idea", id); err != nil {
		return err
	}
	return fault("idea.verdict")
}

// SnoozeIdeaTx is Not now on idea id (IdeaQueries.snooze): status not_now
// until the date until (nil: no date).
func SnoozeIdeaTx(tx *sql.Tx, id int, until *string) error {
	u := ""
	if until != nil {
		u = *until
	}
	res, err := tx.Exec(`UPDATE ideas SET status = 'not_now', snooze_until = ?, `+ideaClearReview+`,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
		WHERE id = ?`, u, id)
	if err != nil {
		return fmt.Errorf("snoozing idea %d: %w", id, err)
	}
	if err := requireRow(res, "idea", id); err != nil {
		return err
	}
	return fault("idea.snooze")
}

// SetPlanItemStatusTx sets day plan item itemID's status (DayPlanQueries.
// markItemDone/markItemPending). With cascadeToTask, a task-sourced item
// sets its task's status as the owner (cascadeTaskStatus through
// UpdateTargetStatusAsTx, INBOX-02's target_due cascade included): done →
// done, any other → todo. An item that is not there is ErrRowNotFound; a
// task that is not there fails the cascade, so the caller rolls back.
func SetPlanItemStatusTx(tx *sql.Tx, itemID int64, status string, cascadeToTask bool) error {
	res, err := tx.Exec(`UPDATE day_plan_items SET status = ?,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?`, status, itemID)
	if err != nil {
		return fmt.Errorf("setting day plan item %d to %s: %w", itemID, status, err)
	}
	if err := requireRow(res, "day plan item", itemID); err != nil {
		return err
	}
	if err := fault("plan_item.status"); err != nil {
		return err
	}
	if !cascadeToTask {
		return nil
	}
	taskID, ok, err := planItemTaskTx(tx, itemID)
	if err != nil || !ok {
		return err
	}
	taskStatus := "todo"
	if status == "done" {
		taskStatus = "done"
	}
	var one int
	if err := tx.QueryRow(`SELECT 1 FROM targets WHERE id = ?`, taskID).Scan(&one); err != nil {
		return fmt.Errorf("day plan item %d's task %d: %w", itemID, taskID, err)
	}
	return updateTargetStatusOn(tx, taskID, taskStatus, ActorOwner)
}

// planItemTaskTx is the task a day plan item came from: its id when the
// item's source is a task with a numeric source id.
func planItemTaskTx(tx *sql.Tx, itemID int64) (int, bool, error) {
	var sourceType string
	var sourceID sql.NullString
	err := tx.QueryRow(`SELECT source_type, source_id FROM day_plan_items WHERE id = ?`, itemID).Scan(&sourceType, &sourceID)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, fmt.Errorf("reading day plan item %d's source: %w", itemID, err)
	}
	if sourceType != "task" || !sourceID.Valid {
		return 0, false, nil
	}
	id, err := strconv.ParseInt(sourceID.String, 10, 64)
	if err != nil {
		return 0, false, nil //nolint:nilerr // Swift's Int64(String) guard: not a task id, no cascade
	}
	return int(id), true, nil
}
