package db

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"time"
)

// The other Mac screens' writers (spec 2026-11-15-mobile-inbox §5.2, plan
// Task 9): Tracks, Ideas and Decisions, Digests, Day plan and Catch-Up. Each
// is one write in the caller's transaction, ported from its Swift twin in
// WatchtowerCore/Database/Queries; the tower's screen commands
// (internal/inboxfeed/screens.go) run them inside tower.Ctx.Write. A writer
// that reports "already" (a bool) found its write in place and wrote
// nothing. ErrRowNotFound is Swift's requireUpdated.

// MarkTracksReadTx marks each of ids read (TrackQueries.markRead(ids:)),
// each with its digest cascade (MarkTrackReadTx). Best-effort, as in Swift:
// a track that is not there has nothing left to read.
func MarkTracksReadTx(tx *sql.Tx, ids []int) error {
	for _, id := range ids {
		if err := MarkTrackReadTx(tx, id); err != nil {
			return err
		}
	}
	return nil
}

// SetTrackPriorityTx is the owner correcting a track's priority
// (TrackQueries.updatePriority): the priority, then a -1 feedback row
// "priority corrected to <priority>" — after the update, so a track that is
// not there leaves no correction behind.
func SetTrackPriorityTx(tx *sql.Tx, id int, priority string) error {
	res, err := tx.Exec(`UPDATE tracks SET priority = ? WHERE id = ?`, priority, id)
	if err != nil {
		return fmt.Errorf("setting track %d priority: %w", id, err)
	}
	if err := requireRow(res, "track", id); err != nil {
		return err
	}
	if err := fault("track.priority"); err != nil {
		return err
	}
	if _, err := tx.Exec(`INSERT INTO feedback (entity_type, entity_id, rating, comment) VALUES ('track', ?, -1, ?)`,
		strconv.Itoa(id), "priority corrected to "+priority); err != nil {
		return fmt.Errorf("recording track %d priority feedback: %w", id, err)
	}
	return nil
}

// SetTrackOwnershipTx sets a track's ownership (TrackQueries.updateOwnership).
func SetTrackOwnershipTx(tx *sql.Tx, id int, ownership string) error {
	res, err := tx.Exec(`UPDATE tracks SET ownership = ? WHERE id = ?`, ownership, id)
	if err != nil {
		return fmt.Errorf("setting track %d ownership: %w", id, err)
	}
	return requireRow(res, "track", id)
}

// trackSubItem is Swift's TrackSubItem, in its encoded key order.
type trackSubItem struct {
	Text   string `json:"text"`
	Status string `json:"status"`
}

// SetTrackSubItemTx sets sub-item index of track id done or open
// (TracksViewModel.toggleSubItem's write over TrackQueries.updateSubItems):
// the list is re-read here, so another item's change landing first is kept.
// An index past the list (or a list that does not decode) writes nothing;
// already reports a sub-item already in that state.
func SetTrackSubItemTx(tx *sql.Tx, id, index int, done bool) (already bool, err error) {
	var raw string
	err = tx.QueryRow(`SELECT sub_items FROM tracks WHERE id = ?`, id).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return false, fmt.Errorf("track %d: %w", id, ErrRowNotFound)
	}
	if err != nil {
		return false, fmt.Errorf("reading track %d sub-items: %w", id, err)
	}
	items := decodeOrNil[[]trackSubItem](raw)
	if index < 0 || index >= len(items) {
		return true, nil
	}
	status := "open"
	if done {
		status = "done"
	}
	if items[index].Status == status {
		return true, nil
	}
	items[index].Status = status
	b, err := json.Marshal(items)
	if err != nil {
		return false, fmt.Errorf("encoding track %d sub-items: %w", id, err)
	}
	if _, err := tx.Exec(`UPDATE tracks SET sub_items = ? WHERE id = ?`, string(b), id); err != nil {
		return false, fmt.Errorf("setting track %d sub-items: %w", id, err)
	}
	return false, nil
}

// SetTrackInstructionTx edits a custom track's watch instruction
// (TrackQueries.updateInstruction); a track that is not custom is
// ErrRowNotFound, as in Swift.
func SetTrackInstructionTx(tx *sql.Tx, id int, instruction string) error {
	res, err := tx.Exec(`UPDATE tracks SET instruction = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = ? AND origin = 'custom'`, instruction, id)
	if err != nil {
		return fmt.Errorf("setting track %d instruction: %w", id, err)
	}
	return requireRow(res, "track", id)
}

// DeleteTrackTx deletes a track with its events (TrackQueries.delete: the
// events go by ON DELETE CASCADE). already: it was not there.
func DeleteTrackTx(tx *sql.Tx, id int) (already bool, err error) {
	res, err := tx.Exec(`DELETE FROM tracks WHERE id = ?`, id)
	if err != nil {
		return false, fmt.Errorf("deleting track %d: %w", id, err)
	}
	return requireRow(res, "track", id) != nil, nil
}

// SetTrackEventStatusTx sets a track event's action status
// (TrackEventQueries.setActionStatus). already: it has that status.
func SetTrackEventStatusTx(tx *sql.Tx, eventID int, status string) (already bool, err error) {
	var cur string
	err = tx.QueryRow(`SELECT action_status FROM track_events WHERE id = ?`, eventID).Scan(&cur)
	if errors.Is(err, sql.ErrNoRows) {
		return false, fmt.Errorf("track event %d: %w", eventID, ErrRowNotFound)
	}
	if err != nil {
		return false, fmt.Errorf("reading track event %d: %w", eventID, err)
	}
	if cur == status {
		return true, nil
	}
	if _, err := tx.Exec(`UPDATE track_events SET action_status = ? WHERE id = ?`, status, eventID); err != nil {
		return false, fmt.Errorf("setting track event %d status: %w", eventID, err)
	}
	return false, nil
}

// MarkTrackEventsReadTx marks one event of track trackID read
// (TrackEventQueries.markRead) or, with eventID 0, every unread event of it
// (markAllRead). Best-effort, as in Swift; an event of another track is
// left alone.
func MarkTrackEventsReadTx(tx *sql.Tx, trackID, eventID int) error {
	q, args := `UPDATE track_events SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE track_id = ? AND (read_at IS NULL OR read_at = '')`, []any{trackID}
	if eventID > 0 {
		q, args = `UPDATE track_events SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = ? AND track_id = ?`, []any{eventID, trackID}
	}
	if _, err := tx.Exec(q, args...); err != nil {
		return fmt.Errorf("marking track %d events read: %w", trackID, err)
	}
	return nil
}

// --- ideas ---

// ideaVerdictState is what an idea verdict guard reads.
func ideaVerdictState(tx *sql.Tx, id int) (status, snooze string, review bool, err error) {
	err = tx.QueryRow(`SELECT status, snooze_until, needs_review != 0 FROM ideas WHERE id = ?`, id).
		Scan(&status, &snooze, &review)
	if errors.Is(err, sql.ErrNoRows) {
		return "", "", false, fmt.Errorf("idea %d: %w", id, ErrRowNotFound)
	}
	if err != nil {
		return "", "", false, fmt.Errorf("reading idea %d: %w", id, err)
	}
	return status, snooze, review, nil
}

// SetIdeaStatusTx is IdeaQueries.setStatus behind its guard: already when
// the idea has status and no review flag pending.
func SetIdeaStatusTx(tx *sql.Tx, id int, status string) (already bool, err error) {
	cur, _, review, err := ideaVerdictState(tx, id)
	if err != nil {
		return false, err
	}
	if cur == status && !review {
		return true, nil
	}
	return false, SetIdeaVerdictTx(tx, id, status)
}

// SnoozeIdeaUntilTx is IdeaQueries.snooze behind its guard ("" = no date):
// already when the idea is not_now until that date with no review flag.
func SnoozeIdeaUntilTx(tx *sql.Tx, id int, until string) (already bool, err error) {
	cur, snooze, review, err := ideaVerdictState(tx, id)
	if err != nil {
		return false, err
	}
	if cur == "not_now" && snooze == until && !review {
		return true, nil
	}
	return false, SnoozeIdeaTx(tx, id, &until)
}

// MergeIdeaTx merges idea id into idea into (IdeaQueries.merge): id merged with
// the link, its mentions re-parented, and what was merged into id earlier
// pointed at into (IDEA-03 follows merged_into_id one hop). Either side
// gone is ErrRowNotFound before anything moves; already: id is already
// merged there with no review flag pending.
func MergeIdeaTx(tx *sql.Tx, id, into int) (already bool, err error) {
	var cur string
	var mergedInto sql.NullInt64
	var review bool
	err = tx.QueryRow(`SELECT status, merged_into_id, needs_review != 0 FROM ideas WHERE id = ?`, id).
		Scan(&cur, &mergedInto, &review)
	if errors.Is(err, sql.ErrNoRows) {
		return false, fmt.Errorf("idea %d: %w", id, ErrRowNotFound)
	}
	if err != nil {
		return false, fmt.Errorf("reading idea %d: %w", id, err)
	}
	var one int
	if err := tx.QueryRow(`SELECT 1 FROM ideas WHERE id = ?`, into).Scan(&one); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return false, fmt.Errorf("idea %d: %w", into, ErrRowNotFound)
		}
		return false, fmt.Errorf("reading idea %d: %w", into, err)
	}
	if cur == "merged" && mergedInto.Valid && mergedInto.Int64 == int64(into) && !review {
		return true, nil
	}
	if _, err := tx.Exec(`UPDATE ideas SET status = 'merged', merged_into_id = ?, `+ideaClearReview+`,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = ?`, into, id); err != nil {
		return false, fmt.Errorf("merging idea %d into %d: %w", id, into, err)
	}
	if err := fault("idea.merge"); err != nil {
		return false, err
	}
	if _, err := tx.Exec(`UPDATE idea_mentions SET idea_id = ? WHERE idea_id = ?`, into, id); err != nil {
		return false, fmt.Errorf("moving idea %d mentions: %w", id, err)
	}
	if _, err := tx.Exec(`UPDATE ideas SET merged_into_id = ? WHERE merged_into_id = ?`, into, id); err != nil {
		return false, fmt.Errorf("re-pointing ideas merged into %d: %w", id, err)
	}
	return false, nil
}

// SupersedeIdeaTx marks idea id superseded (IdeaQueries.supersede), linked
// to by when it is non-nil. already: it is superseded by the same.
func SupersedeIdeaTx(tx *sql.Tx, id int, by *int64) (already bool, err error) {
	var cur string
	var supBy sql.NullInt64
	var review bool
	err = tx.QueryRow(`SELECT status, superseded_by_id, needs_review != 0 FROM ideas WHERE id = ?`, id).
		Scan(&cur, &supBy, &review)
	if errors.Is(err, sql.ErrNoRows) {
		return false, fmt.Errorf("idea %d: %w", id, ErrRowNotFound)
	}
	if err != nil {
		return false, fmt.Errorf("reading idea %d: %w", id, err)
	}
	want := sql.NullInt64{}
	if by != nil {
		want = sql.NullInt64{Int64: *by, Valid: true}
	}
	if cur == "superseded" && supBy == want && !review {
		return true, nil
	}
	if _, err := tx.Exec(`UPDATE ideas SET status = 'superseded', superseded_by_id = ?, `+ideaClearReview+`,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = ?`, want, id); err != nil {
		return false, fmt.Errorf("superseding idea %d: %w", id, err)
	}
	return false, nil
}

// SetIdeaRatingTx sets the owner's rating and comment on idea id
// (IdeaQueries.setRating).
func SetIdeaRatingTx(tx *sql.Tx, id, rating int, comment string) error {
	res, err := tx.Exec(`UPDATE ideas SET owner_rating = ?, rating_comment = ?,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = ?`, rating, comment, id)
	if err != nil {
		return fmt.Errorf("rating idea %d: %w", id, err)
	}
	return requireRow(res, "idea", id)
}

// ConvertIdeaToTargetTx is Convert to Target (IdeasViewModel.convert): a
// personal day target of today from the idea's title and essence
// (TargetQueries.create: todo, progress 0, source idea:<id>), then the idea
// marked converted to it with its review flag cleared (IdeaQueries.
// markConverted: a link, not a delete, IDEA-03), in the caller's
// transaction. A personal target has no status history (PROJ-06) and no
// board parent (PROJ-05). An idea already converted to a target that is
// there answers that target, already; a missing idea is ErrRowNotFound
// before anything is written.
func ConvertIdeaToTargetTx(tx *sql.Tx, id int, today string) (targetID int64, already bool, err error) {
	var title, essence, status string
	var conv sql.NullInt64
	err = tx.QueryRow(`SELECT title, essence, status, converted_target_id FROM ideas WHERE id = ?`, id).
		Scan(&title, &essence, &status, &conv)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, false, fmt.Errorf("idea %d: %w", id, ErrRowNotFound)
	}
	if err != nil {
		return 0, false, fmt.Errorf("reading idea %d: %w", id, err)
	}
	if status == "converted" && conv.Valid {
		var one int
		err := tx.QueryRow(`SELECT 1 FROM targets WHERE id = ?`, conv.Int64).Scan(&one)
		if err == nil {
			return conv.Int64, true, nil
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return 0, false, fmt.Errorf("reading idea %d's target: %w", id, err)
		}
	}
	res, err := tx.Exec(`INSERT INTO targets (text, intent, level, custom_label, period_start, period_end,
			parent_id, status, priority, ownership, ball_on, due_date, snooze_until,
			blocking, tags, sub_items, notes, progress, source_type, source_id, ai_level_confidence)
		VALUES (?, ?, 'day', '', ?, ?, NULL, 'todo', 'medium', 'mine', '', '', '', '', '[]', '[]', '[]', ?, 'idea', ?, NULL)`,
		title, essence, today, today, statusToProgress("todo"), strconv.Itoa(id))
	if err != nil {
		return 0, false, fmt.Errorf("creating idea %d's target: %w", id, err)
	}
	if targetID, err = res.LastInsertId(); err != nil {
		return 0, false, fmt.Errorf("creating idea %d's target: %w", id, err)
	}
	if err := fault("idea.convert"); err != nil {
		return 0, false, err
	}
	if _, err := tx.Exec(`UPDATE ideas SET status = 'converted', converted_target_id = ?, `+ideaClearReview+`,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = ?`, targetID, id); err != nil {
		return 0, false, fmt.Errorf("marking idea %d converted: %w", id, err)
	}
	return targetID, false, nil
}

// knowledgeVisible is IdeaQueries.knowledgeVisibleSQL: a chat-born item
// the owner has not kept is no knowledge.
const knowledgeVisible = `NOT (chat_born = 1 AND status IN ('proposed','not_now','rejected','dropped'))`

// MarkDecisionSeenTx stamps decision id seen (IdeaQueries.markDecisionSeen),
// clearing its review flag (IDEA-04). Best-effort, as in Swift.
func MarkDecisionSeenTx(tx *sql.Tx, id int) error {
	if _, err := tx.Exec(`UPDATE ideas SET seen_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), `+ideaClearReview+`
		WHERE id = ?`, id); err != nil {
		return fmt.Errorf("marking decision %d seen: %w", id, err)
	}
	return nil
}

// MarkAllDecisionsSeenTx stamps every decision not caught up on — never
// seen, or re-flagged since — seen (IdeaQueries.markAllDecisionsSeen).
func MarkAllDecisionsSeenTx(tx *sql.Tx) error {
	if _, err := tx.Exec(`UPDATE ideas SET seen_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), ` + ideaClearReview + `
		WHERE kind = 'decision' AND (seen_at IS NULL OR needs_review = 1) AND ` + knowledgeVisible); err != nil {
		return fmt.Errorf("marking every decision seen: %w", err)
	}
	return nil
}

// CreateManualIdeaTx is CreateManualIdea in the caller's transaction
// (IdeaQueries.createManual): an active owner idea with its owner mention,
// both stamped now.
func (db *DB) CreateManualIdeaTx(tx *sql.Tx, kind, title, essence string, now time.Time) (int64, error) {
	at := now.UTC().Format(time.RFC3339)
	id, err := db.CreateIdeaTx(tx, Idea{
		Kind: kind, Title: title, Essence: essence,
		Status: "active", Source: "owner", LastMentionAt: at,
	})
	if err != nil {
		return 0, err
	}
	if err := db.InsertIdeaMentionTx(tx, IdeaMention{IdeaID: id, Source: "owner", Quote: essence, SaidAt: at}); err != nil {
		return 0, err
	}
	return id, nil
}

// UndoChatIdeaTx is the chat mark's Undo (IdeaQueries.undoChatIdea): the
// chat-born item is deleted (DeleteIdeaTx) only while untouched — active,
// not merged into anything, nothing merged into it, updated_at still
// createdUpdatedAt. False otherwise, nothing written.
func UndoChatIdeaTx(tx *sql.Tx, id int64, createdUpdatedAt string) (bool, error) {
	var untouched bool
	if err := tx.QueryRow(`SELECT EXISTS(
			SELECT 1 FROM ideas
			WHERE id = ? AND chat_born = 1 AND status = 'active' AND merged_into_id IS NULL
			  AND updated_at = ?
			  AND NOT EXISTS (SELECT 1 FROM ideas c WHERE c.merged_into_id = ideas.id))`,
		id, createdUpdatedAt).Scan(&untouched); err != nil {
		return false, fmt.Errorf("reading chat idea %d: %w", id, err)
	}
	if !untouched {
		return false, nil
	}
	if _, err := DeleteIdeaTx(tx, int(id)); err != nil {
		return false, err
	}
	return true, nil
}

// DeleteIdeaTx is the owner's hard delete (IdeaQueries.delete): the idea,
// everything merged into it (recursively), their mentions and each one's
// Discuss chat (its newest idea-context conversation with its messages);
// survivors' similar_to_id and superseded_by_id into the deleted rows are
// cleared. already: the idea was not there.
func DeleteIdeaTx(tx *sql.Tx, id int) (already bool, err error) {
	var one int
	err = tx.QueryRow(`SELECT 1 FROM ideas WHERE id = ?`, id).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return true, nil
	}
	if err != nil {
		return false, fmt.Errorf("reading idea %d: %w", id, err)
	}
	doomed, err := intColumnTx(tx, `WITH RECURSIVE doomed(id) AS (
			SELECT ?
			UNION
			SELECT ideas.id FROM ideas JOIN doomed ON ideas.merged_into_id = doomed.id
		)
		SELECT id FROM doomed`, id)
	if err != nil {
		return false, fmt.Errorf("reading what goes with idea %d: %w", id, err)
	}
	for _, d := range doomed {
		var conv int64
		err := tx.QueryRow(`SELECT id FROM chat_conversations WHERE context_type = 'idea' AND context_id = ?
			ORDER BY updated_at DESC LIMIT 1`, strconv.Itoa(d)).Scan(&conv)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return false, fmt.Errorf("reading idea %d's chat: %w", d, err)
		}
		if err == nil {
			if _, err := tx.Exec(`DELETE FROM chat_messages WHERE conversation_id = ?`, conv); err != nil {
				return false, fmt.Errorf("deleting idea %d's chat messages: %w", d, err)
			}
			if _, err := tx.Exec(`DELETE FROM chat_conversations WHERE id = ?`, conv); err != nil {
				return false, fmt.Errorf("deleting idea %d's chat: %w", d, err)
			}
		}
		if _, err := tx.Exec(`DELETE FROM idea_mentions WHERE idea_id = ?`, d); err != nil {
			return false, fmt.Errorf("deleting idea %d's mentions: %w", d, err)
		}
		if _, err := tx.Exec(`DELETE FROM ideas WHERE id = ?`, d); err != nil {
			return false, fmt.Errorf("deleting idea %d: %w", d, err)
		}
		if err := fault("idea.delete"); err != nil {
			return false, err
		}
	}
	in := placeholders(len(doomed))
	for _, col := range []string{"similar_to_id", "superseded_by_id"} {
		//nolint:gosec // G202: col is one of two constants and in only "?" placeholders; values are bound.
		if _, err := tx.Exec(`UPDATE ideas SET `+col+` = NULL WHERE `+col+` IN (`+in+`)`, intArgs(doomed)...); err != nil {
			return false, fmt.Errorf("clearing links to idea %d: %w", id, err)
		}
	}
	return false, nil
}

// intColumnTx reads one integer column.
func intColumnTx(tx *sql.Tx, query string, args ...any) ([]int, error) {
	rows, err := tx.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []int
	for rows.Next() {
		var v int
		if err := rows.Scan(&v); err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

// --- digests ---

// MarkDigestsReadTx marks digests ids read, once (DigestQueries.markRead;
// no decision cascade, as in Swift).
func MarkDigestsReadTx(tx *sql.Tx, ids []int) error {
	if len(ids) == 0 {
		return nil
	}
	//nolint:gosec // G202: the concatenation is only "?" placeholders; every value is a bound arg.
	if _, err := tx.Exec(`UPDATE digests SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
		WHERE id IN (`+placeholders(len(ids))+`) AND read_at IS NULL`, intArgs(ids)...); err != nil {
		return fmt.Errorf("marking digests read: %w", err)
	}
	return nil
}

// MarkDecisionReadTx marks decision idx of digest digestID read
// (DigestQueries.markDecisionRead).
func MarkDecisionReadTx(tx *sql.Tx, digestID, idx int) error {
	if _, err := tx.Exec(`INSERT INTO decision_reads (digest_id, decision_idx) VALUES (?, ?)
		ON CONFLICT DO NOTHING`, digestID, idx); err != nil {
		return fmt.Errorf("marking digest %d decision %d read: %w", digestID, idx, err)
	}
	return nil
}

// MarkDigestDecisionsReadTx marks every decision of digest digestID read
// (DigestQueries.markAllDecisionsRead).
func MarkDigestDecisionsReadTx(tx *sql.Tx, digestID int) error {
	var decisions string
	err := tx.QueryRow(`SELECT decisions FROM digests WHERE id = ?`, digestID).Scan(&decisions)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("reading digest %d's decisions: %w", digestID, err)
	}
	for i := range decodeOrNil[[]json.RawMessage](decisions) {
		if err := MarkDecisionReadTx(tx, digestID, i); err != nil {
			return err
		}
	}
	return nil
}

// --- day plan ---

// DeleteOwnerPlanItemTx is the owner deleting a day plan item
// (DayPlanQueries.deleteItem): a calendar item is never deleted here (the
// calendar sync owns it). already: nothing was deleted.
func DeleteOwnerPlanItemTx(tx *sql.Tx, itemID int64) (already bool, err error) {
	res, err := tx.Exec(`DELETE FROM day_plan_items WHERE id = ? AND source_type != 'calendar'`, itemID)
	if err != nil {
		return false, fmt.Errorf("deleting day plan item %d: %w", itemID, err)
	}
	return requireRow(res, "day plan item", itemID) != nil, nil
}

// ReorderPlanItemsTx gives each of orderedIDs of plan planID its position
// as order_index (DayPlanQueries.reorderBacklog); an id of another plan is
// left alone.
func ReorderPlanItemsTx(tx *sql.Tx, planID int64, orderedIDs []int64) error {
	for idx, id := range orderedIDs {
		if _, err := tx.Exec(`UPDATE day_plan_items SET order_index = ?,
			updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
			WHERE id = ? AND day_plan_id = ?`, idx, id, planID); err != nil {
			return fmt.Errorf("updating order for item %d: %w", id, err)
		}
		if err := fault("plan.reorder"); err != nil {
			return err
		}
	}
	return nil
}

// ManualPlanItem is a day plan item the owner adds (DayPlanQueries.
// addManualItem): kind and title, and an optional start and end (RFC 3339).
type ManualPlanItem struct {
	Kind, Title        string
	StartTime, EndTime string
}

// AddManualPlanItemTx appends a manual item to plan planID's backlog
// (DayPlanQueries.addManualItem): order_index one past the plan's last, or
// 0. A plan that is not there is ErrRowNotFound.
func AddManualPlanItemTx(tx *sql.Tx, planID int64, it ManualPlanItem) (int64, error) {
	var one int
	if err := tx.QueryRow(`SELECT 1 FROM day_plans WHERE id = ?`, planID).Scan(&one); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return 0, fmt.Errorf("day plan %d: %w", planID, ErrRowNotFound)
		}
		return 0, fmt.Errorf("reading day plan %d: %w", planID, err)
	}
	var next int
	if err := tx.QueryRow(`SELECT COALESCE(MAX(order_index) + 1, 0) FROM day_plan_items WHERE day_plan_id = ?`,
		planID).Scan(&next); err != nil {
		return 0, fmt.Errorf("reading day plan %d order: %w", planID, err)
	}
	res, err := tx.Exec(`INSERT INTO day_plan_items
			(day_plan_id, kind, source_type, title, start_time, end_time, status, order_index, tags)
		VALUES (?, ?, 'manual', ?, ?, ?, 'pending', ?, '[]')`,
		planID, it.Kind, it.Title, nullIfEmpty(it.StartTime), nullIfEmpty(it.EndTime), next)
	if err != nil {
		return 0, fmt.Errorf("adding to day plan %d: %w", planID, err)
	}
	return res.LastInsertId()
}

func nullIfEmpty(s string) sql.NullString { return sql.NullString{String: s, Valid: s != ""} }

// PlanItemTaskGoneTx reports whether day plan item itemID came from a task
// that is no longer there (DayPlanViewModel.setItemStatus's fallback: the
// item is then marked alone).
func PlanItemTaskGoneTx(tx *sql.Tx, itemID int64) (taskID int, gone bool, err error) {
	taskID, ok, err := planItemTaskTx(tx, itemID)
	if err != nil || !ok {
		return 0, false, err
	}
	var one int
	err = tx.QueryRow(`SELECT 1 FROM targets WHERE id = ?`, taskID).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return taskID, true, nil
	}
	if err != nil {
		return 0, false, fmt.Errorf("reading day plan item %d's task: %w", itemID, err)
	}
	return taskID, false, nil
}

// PlanItemStatusTx is a day plan item's status, for its guard.
func PlanItemStatusTx(tx *sql.Tx, itemID int64) (string, error) {
	var status string
	err := tx.QueryRow(`SELECT status FROM day_plan_items WHERE id = ?`, itemID).Scan(&status)
	if errors.Is(err, sql.ErrNoRows) {
		return "", fmt.Errorf("day plan item %d: %w", itemID, ErrRowNotFound)
	}
	if err != nil {
		return "", fmt.Errorf("reading day plan item %d: %w", itemID, err)
	}
	return status, nil
}

// UnreadBriefingIDsTx is which of ids are not read yet (briefing.read's
// guard).
func UnreadBriefingIDsTx(tx *sql.Tx, ids []int) ([]int, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	return intColumnTx(tx, `SELECT id FROM briefings WHERE id IN (`+placeholders(len(ids))+`) AND read_at IS NULL ORDER BY id`,
		intArgs(ids)...)
}

// --- catch-up ---

// ErrRecapNotReady refuses acknowledging a recap that is not ready.
var ErrRecapNotReady = errors.New("catch-up recap is not ready")

// AcknowledgeCatchupTx is "I'm caught up" on recap id (CatchUpQueries.
// acknowledge, CATCHUP-01): its window read on the five read_at surfaces and
// the recap stamped acknowledged (first stamp wins), in the caller's
// transaction. A recap that is not there is ErrRowNotFound; one that is not
// ready, ErrRecapNotReady.
func AcknowledgeCatchupTx(tx *sql.Tx, id int64) error {
	var status string
	var from, to float64
	err := tx.QueryRow(`SELECT status, period_from, period_to FROM catchup_recaps WHERE id = ?`, id).Scan(&status, &from, &to)
	if errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("catch-up recap %d: %w", id, ErrRowNotFound)
	}
	if err != nil {
		return fmt.Errorf("reading catch-up recap %d: %w", id, err)
	}
	if status != "ready" {
		return fmt.Errorf("catch-up recap %d is %s: %w", id, status, ErrRecapNotReady)
	}
	return acknowledgeCatchupWindowTx(tx, id, from, to)
}
