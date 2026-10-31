package handlers

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"slices"
	"strings"
	"unicode/utf8"

	"watchtower/internal/db"
	"watchtower/internal/hub/actions"
)

// Board limits (spec §5.2, BoardHandlers): the title counts runes as Go's
// `target add` does; comment bodies and the intent count characters.
const (
	bodyLimit   = 4000
	titleLimit  = 200
	intentLimit = 4000
)

// boardTimeoutMessage is BoardHandlers.timeoutMessage, verbatim.
const boardTimeoutMessage = "The Mac did not finish this board change in time — check the board on the Mac"

// The values the phone may set (WorkbenchBoardCard.editableStatuses and
// editablePriorities).
var (
	editableStatuses   = []string{"todo", "in_progress", "in_review", "blocked", "done", "dismissed"}
	editablePriorities = []string{"high", "medium", "low"}
)

// board is the board writes from the phone (mobile POC spec §5.2, §6.3), each
// through the owner's writer (status_actor owner, PROJ-06). Before any write
// each kind re-checks the board scope: a workbench or row that is gone is
// not_found, a row of another workbench not_on_board. Status and priority
// carry the value the phone showed (from_*): a different current value is a
// conflict with result.current, one already equal to the request is applied
// with no write. The checks and the write share one transaction.
func (h *Handlers) board(ctx context.Context, r actions.Request) actions.Outcome {
	return h.withTimeout(ctx, "board", boardTimeoutMessage, func(context.Context) actions.Outcome {
		o, err := h.applyBoard(r)
		var ref *refusal
		switch {
		case errors.As(err, &ref):
			return failed(ref.reason, ref.message)
		case err != nil:
			return failed(reasonWriteFailed, err.Error())
		}
		return o
	})
}

func (h *Handlers) applyBoard(r actions.Request) (actions.Outcome, error) {
	workbenchID, ok := intParam(r, "workbench_id")
	if !ok {
		return actions.Outcome{}, invalid(r.Action.Kind + " needs a workbench_id")
	}
	entity, hasEntity := entityID(r)
	switch r.Action.Kind {
	case "board_target_status":
		return h.editField(r, "status", editableStatuses, entity, hasEntity, workbenchID)
	case "board_target_priority":
		return h.editField(r, "priority", editablePriorities, entity, hasEntity, workbenchID)
	case "board_comment_add":
		return h.addComment(r, entity, hasEntity, workbenchID)
	case "board_comment_reply":
		return h.reply(r, entity, hasEntity, workbenchID)
	case "board_target_create":
		return h.createTarget(r, workbenchID)
	}
	return failed("unsupported_in_poc", ""), nil
}

// editField is board_target_status / board_target_priority.
func (h *Handlers) editField(r actions.Request, field string, allowed []string, targetID int64, hasTarget bool,
	workbenchID int64) (actions.Outcome, error) {
	value, okValue := stringParam(r, field)
	shown, okShown := stringParam(r, "from_"+field)
	if !hasTarget || !okValue || !okShown {
		return actions.Outcome{}, invalid(fmt.Sprintf("board_target_%s needs a target id, %s and from_%s", field, field, field))
	}
	if !slices.Contains(allowed, value) {
		return actions.Outcome{}, invalid(fmt.Sprintf("%s must be one of %s", field, strings.Join(allowed, ", ")))
	}
	var current string
	conflict := false
	err := h.d.DB.WithTx(func(tx *sql.Tx) error {
		t, err := boardTarget(tx, targetID, workbenchID)
		if err != nil {
			return err
		}
		if field == "status" {
			// PROJ-05: a group's status follows its sub-tasks.
			var group bool
			if err := tx.QueryRow(`SELECT EXISTS(SELECT 1 FROM targets WHERE parent_id = ? AND project_id = ?)`,
				targetID, workbenchID).Scan(&group); err != nil {
				return err
			}
			if group {
				return invalid("A group's status follows its sub-tasks")
			}
			current = t.status
		} else {
			current = t.priority
		}
		switch {
		case current == value:
			return nil
		case current != shown:
			conflict = true
			return nil
		case field == "status":
			return h.d.DB.UpdateTargetStatusAsTx(tx, int(targetID), value, db.ActorOwner)
		default:
			return h.d.DB.UpdateTargetPriorityTx(tx, int(targetID), value)
		}
	})
	if err != nil {
		return actions.Outcome{}, err
	}
	if conflict {
		o := failed(reasonConflict, "Changed on the Mac to "+current)
		o.Result = map[string]any{"current": current}
		return o, nil
	}
	return applied(map[string]any{field: value}), nil
}

// addComment is board_comment_add: a new owner thread on a target.
func (h *Handlers) addComment(r actions.Request, targetID int64, hasTarget bool, workbenchID int64) (actions.Outcome, error) {
	raw, ok := stringParam(r, "body")
	if !hasTarget || !ok {
		return actions.Outcome{}, invalid("board_comment_add needs a target id and a body")
	}
	body, err := boardText(raw, "body", bodyLimit)
	if err != nil {
		return actions.Outcome{}, err
	}
	var id int64
	err = h.d.DB.WithTx(func(tx *sql.Tx) error {
		if _, err := boardTarget(tx, targetID, workbenchID); err != nil {
			return err
		}
		id, err = h.d.DB.AddWorkbenchCommentTx(tx, db.WorkbenchComment{
			WorkbenchID: workbenchID, TargetID: sql.NullInt64{Int64: targetID, Valid: true}, Author: "owner", Body: body,
		})
		return err
	})
	if err != nil {
		return actions.Outcome{}, err
	}
	return applied(map[string]any{"comment_id": id}), nil
}

// reply is board_comment_reply: an owner reply under a thread's first
// comment; a resolved or outdated root reopens.
func (h *Handlers) reply(r actions.Request, rootID int64, hasRoot bool, workbenchID int64) (actions.Outcome, error) {
	raw, ok := stringParam(r, "body")
	if !hasRoot || !ok {
		return actions.Outcome{}, invalid("board_comment_reply needs a comment id and a body")
	}
	body, err := boardText(raw, "body", bodyLimit)
	if err != nil {
		return actions.Outcome{}, err
	}
	var id int64
	err = h.d.DB.WithTx(func(tx *sql.Tx) error {
		if err := requireWorkbench(tx, workbenchID); err != nil {
			return err
		}
		var project int64
		var parent sql.NullInt64
		err := tx.QueryRow(`SELECT project_id, parent_id FROM project_comments WHERE id = ?`, rootID).Scan(&project, &parent)
		if errors.Is(err, sql.ErrNoRows) {
			return &refusal{reasonNotFound, "This comment no longer exists on the Mac"}
		}
		if err != nil {
			return err
		}
		if project != workbenchID {
			return &refusal{reasonNotOnBoard, "That comment is not on this workbench's board"}
		}
		if parent.Valid {
			return invalid("A reply goes under a thread's first comment")
		}
		id, err = h.d.DB.AddWorkbenchCommentTx(tx, db.WorkbenchComment{
			WorkbenchID: workbenchID, ParentID: sql.NullInt64{Int64: rootID, Valid: true}, Author: "owner", Body: body,
		})
		return err
	})
	if err != nil {
		return actions.Outcome{}, err
	}
	return applied(map[string]any{"comment_id": id}), nil
}

// createTarget is board_target_create: `workbench target add`'s writer with
// the owner as actor, in one transaction with the scope checks.
func (h *Handlers) createTarget(r actions.Request, workbenchID int64) (actions.Outcome, error) {
	rawTitle, okTitle := stringParam(r, "text")
	priority, okPriority := stringParam(r, "priority")
	if !okTitle || !okPriority {
		return actions.Outcome{}, invalid("board_target_create needs a text and a priority")
	}
	title, err := boardText(rawTitle, "text", titleLimit)
	if err != nil {
		return actions.Outcome{}, err
	}
	intent := ""
	if !isNull(r, "intent") {
		raw, ok := stringParam(r, "intent")
		if !ok {
			return actions.Outcome{}, invalid("intent must be text")
		}
		intent = strings.TrimSpace(raw)
		if utf8.RuneCountInString(intent) > intentLimit {
			return actions.Outcome{}, invalid(fmt.Sprintf("intent is longer than %d characters", intentLimit))
		}
	}
	var parent sql.NullInt64
	if !isNull(r, "parent_id") {
		id, ok := intParam(r, "parent_id")
		if !ok {
			return actions.Outcome{}, invalid("parent_id must be a target id")
		}
		parent = sql.NullInt64{Int64: id, Valid: true}
	}
	if !slices.Contains(editablePriorities, priority) {
		return actions.Outcome{}, invalid("priority must be one of " + strings.Join(editablePriorities, ", "))
	}
	var ids []int64
	err = h.d.DB.WithTx(func(tx *sql.Tx) error {
		if parent.Valid {
			if _, err := boardTarget(tx, parent.Int64, workbenchID); err != nil {
				return err
			}
		} else if err := requireWorkbench(tx, workbenchID); err != nil {
			return err
		}
		var err error
		ids, err = h.d.DB.CreateWorkbenchTargetsTx(tx, workbenchID, db.ActorOwner, []db.WorkbenchTargetInput{
			{Title: title, Intent: intent, Priority: priority, ParentID: parent},
		})
		return err
	})
	if err != nil {
		return actions.Outcome{}, err
	}
	return applied(map[string]any{"target_id": ids[0]}), nil
}

// boardText is trimmed, non-empty and at most limit runes.
func boardText(raw, name string, limit int) (string, error) {
	text := strings.TrimSpace(raw)
	if text == "" {
		return "", invalid(name + " is empty")
	}
	if utf8.RuneCountInString(text) > limit {
		return "", invalid(fmt.Sprintf("%s is longer than %d characters", name, limit))
	}
	return text, nil
}

func requireWorkbench(tx *sql.Tx, workbenchID int64) error {
	var one int
	err := tx.QueryRow(`SELECT 1 FROM projects WHERE id = ?`, workbenchID).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return &refusal{reasonNotFound, "This workbench no longer exists on the Mac"}
	}
	return err
}

type boardRow struct{ status, priority string }

// boardTarget is the target when it is on workbenchID's board (§5.2 rule 3).
func boardTarget(tx *sql.Tx, targetID, workbenchID int64) (boardRow, error) {
	if err := requireWorkbench(tx, workbenchID); err != nil {
		return boardRow{}, err
	}
	var t boardRow
	var project sql.NullInt64
	err := tx.QueryRow(`SELECT project_id, status, priority FROM targets WHERE id = ?`, targetID).Scan(&project, &t.status, &t.priority)
	if errors.Is(err, sql.ErrNoRows) {
		return boardRow{}, &refusal{reasonNotFound, "This target no longer exists on the Mac"}
	}
	if err != nil {
		return boardRow{}, err
	}
	if !project.Valid || project.Int64 != workbenchID {
		return boardRow{}, &refusal{reasonNotOnBoard, "That target is not on this workbench's board"}
	}
	return t, nil
}
