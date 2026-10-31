package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"

	"watchtower/internal/db"
)

type setSessionTargetArgs struct {
	TargetID int64  `json:"target_id" jsonschema:"the workbench target (a group or a task) this session's work now belongs to; 0 clears the binding so the session counts only what it touched"`
	Reason   string `json:"reason" jsonschema:"one sentence: why the session's work moved to this target"`
}

// errNoSessionTargetSession refuses set_session_target outside a Watchtower
// terminal session of the bound workbench.
var errNoSessionTargetSession = &ValidationError{Msg: "set_session_target needs a Watchtower terminal session"}

// NewSetSessionTarget re-points this terminal session at a target (board
// #1352, PROJ-14): the target is the ticket finish_session gates on and the
// scope of the session's progress line. sessionEnv returns the terminal
// session env (TerminalSessionEnv).
func NewSetSessionTarget(sessionEnv func() string) *Tool {
	return &Tool{
		Name: "set_session_target",
		Description: "Re-point this terminal session at a workbench target when the session's work moves to a new " +
			"group or task: the owner's progress line for the session then counts that target's leaves, and " +
			"finish_session gates on its subtree. target_id 0 clears the binding. Refused for a target that is " +
			"archived, dismissed or not in this workbench. Applied immediately.",
		InputSchema: mustSchema[setSessionTargetArgs]("set_session_target"),
		Access:      AccessWrite,
		Surfaces:    workbenchSurfaces,
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a setSessionTargetArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			if a.TargetID < 0 {
				return &ValidationError{Msg: "target_id: must be 0 or a target id"}
			}
			return nil
		},
		Scope: func(ctx context.Context, d *db.DB, raw json.RawMessage, b Binding) error {
			var a setSessionTargetArgs
			if err := json.Unmarshal(raw, &a); err != nil {
				return &ValidationError{Msg: "invalid arguments"}
			}
			_, _, err := planSessionTarget(ctx, d, b, a, sessionEnv)
			return err
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a setSessionTargetArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding set_session_target args: %w", err)
			}
			session, leaves, err := planSessionTarget(ctx, d, call.Binding, a, sessionEnv)
			if err != nil {
				return nil, err
			}
			if err := d.SetSessionTarget(session, sql.NullInt64{Int64: a.TargetID, Valid: a.TargetID > 0}); err != nil {
				return nil, err
			}
			return map[string]any{"session_id": session, "target_id": a.TargetID, "stamped": len(leaves)}, nil
		},
	}
}

// planSessionTarget resolves the calling session and validates the target
// without writing; it returns the session id and the leaves of the target's
// subtree (the leaves the binding stamp takes; none when clearing).
func planSessionTarget(ctx context.Context, d *db.DB, b Binding, a setSessionTargetArgs, sessionEnv func() string) (int64, []int64, error) {
	p, err := workbenchOf(ctx, d, b)
	if err != nil {
		return 0, nil, err
	}
	session, err := terminalSessionRow(d, p.ID, sessionEnv)
	if err != nil {
		return 0, nil, err
	}
	if session == nil {
		return 0, nil, errNoSessionTargetSession
	}
	leaves, err := checkSessionTarget(d, p.ID, session, a.TargetID)
	return session.ID, leaves, err
}

// checkSessionTarget refuses a shell row or another workbench's row, and (for
// a non-zero targetID) a target that is not in the workbench, not on the
// board or dismissed; it returns the leaves of the target's subtree.
func checkSessionTarget(d *db.DB, workbenchID int64, s *db.TerminalSession, targetID int64) ([]int64, error) {
	if s.WorkbenchID.Int64 != workbenchID || (s.Kind != "claude" && s.Kind != "codex") {
		return nil, &ValidationError{Msg: fmt.Sprintf("session %d is not an agent session of this workbench", s.ID)}
	}
	if targetID == 0 {
		return nil, nil
	}
	if _, err := targetInWorkbench(d, workbenchID, targetID); err != nil {
		return nil, err
	}
	board, err := d.GetWorkbenchBoard(workbenchID)
	if err != nil {
		return nil, fmt.Errorf("reading the board of workbench %d: %w", workbenchID, err)
	}
	node := findBoardNode(board, targetID)
	switch {
	case node == nil || node.Archived:
		return nil, &ValidationError{Msg: fmt.Sprintf("target_id: target %d is not on the board (archived)", targetID)}
	case node.Target.Status == "dismissed":
		return nil, &ValidationError{Msg: fmt.Sprintf("target_id: target %d is dismissed", targetID)}
	}
	return boardLeaves(*node, nil), nil
}

func findBoardNode(nodes []db.BoardNode, id int64) *db.BoardNode {
	for i := range nodes {
		if int64(nodes[i].Target.ID) == id {
			return &nodes[i]
		}
		if n := findBoardNode(nodes[i].Children, id); n != nil {
			return n
		}
	}
	return nil
}

// boardLeaves appends the ids of n's leaf descendants (n itself when it has
// no children) to out.
func boardLeaves(n db.BoardNode, out []int64) []int64 {
	if len(n.Children) == 0 {
		return append(out, int64(n.Target.ID))
	}
	for _, c := range n.Children {
		out = boardLeaves(c, out)
	}
	return out
}

// BindSessionTarget is the CLI's twin of set_session_target: it binds session
// sessionID of workbench workbenchID to targetID (0 clears) under the same
// checks and returns "stamped": the number of leaves in the bound target's
// subtree (the target itself when it is a leaf; 0 when clearing). The
// binding stamp on the session takes those leaves; no row is written per
// leaf.
func BindSessionTarget(d *db.DB, workbenchID, sessionID, targetID int64) (int, error) {
	s, err := d.GetTerminalSession(sessionID)
	if errors.Is(err, db.ErrTerminalSessionNotFound) {
		return 0, &ValidationError{Msg: fmt.Sprintf("session %d is not an agent session of this workbench", sessionID)}
	}
	if err != nil {
		return 0, fmt.Errorf("binding session %d: %w", sessionID, err)
	}
	leaves, err := checkSessionTarget(d, workbenchID, s, targetID)
	if err != nil {
		return 0, err
	}
	if err := d.SetSessionTarget(sessionID, sql.NullInt64{Int64: targetID, Valid: targetID > 0}); err != nil {
		return 0, err
	}
	return len(leaves), nil
}
