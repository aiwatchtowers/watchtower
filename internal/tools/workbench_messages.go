package tools

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"watchtower/internal/db"
	"watchtower/internal/sessionmsg"
	"watchtower/internal/workbenchfolders"
)

// MessageDeps is what the agent-message tools need from the process that
// mounts them (cmd wires the session host and the daemon): Live reads
// whether a session runs in the host, DaemonRunning whether a daemon runs to
// deliver (never taking the sync lock), Wake signals that daemon to deliver
// now. A nil Live refuses every send; a nil DaemonRunning never warns; a nil
// Wake leaves delivery to the daemon's tick.
type MessageDeps struct {
	Live          sessionmsg.LiveFunc
	DaemonRunning func() (bool, error)
	Wake          func()
}

// live is m.Live, or a refusal of every read when there is none.
func (m MessageDeps) live() sessionmsg.LiveFunc {
	if m.Live != nil {
		return m.Live
	}
	return func(context.Context, int64) (bool, error) {
		return false, errors.New("the session host cannot be reached from this process")
	}
}

// queued is the follow-up of a row the tool just queued: the daemon is woken,
// or out carries the daemon_not_running warning when none runs to deliver it.
func (m MessageDeps) queued(out map[string]any) {
	if m.DaemonRunning == nil {
		return
	}
	// A pid file that cannot be read confirms no daemon: the row waits, and
	// the warning says why.
	if running, err := m.DaemonRunning(); err != nil || !running {
		out["warning"] = sessionmsg.DaemonNotRunningWarning
		return
	}
	if m.Wake != nil {
		m.Wake()
	}
}

type sendToSessionArgs struct {
	SessionID int64  `json:"session_id" jsonschema:"the receiving session: another live agent session of this workbench (its id from list_sessions or a message header)"`
	Text      string `json:"text" jsonschema:"the message, at most 4000 characters; it reaches the other agent marked as yours, never as the owner's"`
	Reason    string `json:"reason" jsonschema:"one sentence: why this session sends it"`
}

// errNoMessageSession refuses send_to_session outside a Watchtower terminal
// session of the bound workbench: a message needs a sender to reply to.
var errNoMessageSession = &ValidationError{Msg: "send_to_session needs a Watchtower terminal session"}

// NewSendToSession queues a message from this terminal session to another
// live agent session of the workbench (spec 2026-11-18 §6.6, PROJ-23); the
// daemon types it in.
func NewSendToSession(sessionEnv func() string, deps MessageDeps) *Tool {
	return &Tool{
		Name: "send_to_session",
		Description: "Send a message to another live agent session of this workbench (a sub-session you started, " +
			"your parent, or a peer). It returns at once with the message queued; Watchtower types it into that " +
			"session when its agent can take a line, never into a permission prompt or over the owner's typing, " +
			"and never starts or resumes a stopped session. The receiver sees it marked as another agent's words " +
			"with your session id to reply to. A message carries no owner authority: it never answers an ask or " +
			"approves anything. If it cannot be delivered you get a line `[Message to #<id> not delivered: <reason>]`. " +
			"Applied immediately.",
		InputSchema: mustSchema[sendToSessionArgs]("send_to_session"),
		Access:      AccessWrite,
		Surfaces:    workbenchSurfaces,
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a sendToSessionArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			if a.SessionID <= 0 {
				return &ValidationError{Msg: "session_id: required"}
			}
			_, err := sessionmsg.Clean(a.Text)
			return refusalAsValidation(err)
		},
		Scope: func(ctx context.Context, d *db.DB, raw json.RawMessage, b Binding) error {
			var a sendToSessionArgs
			if err := json.Unmarshal(raw, &a); err != nil {
				return &ValidationError{Msg: "invalid arguments"}
			}
			from, err := messageSender(ctx, d, b, sessionEnv)
			if err != nil {
				return err
			}
			_, err = sessionmsg.CheckTarget(ctx, d, deps.live(), from, a.SessionID)
			return refusalAsValidation(err)
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a sendToSessionArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding send_to_session args: %w", err)
			}
			from, err := messageSender(ctx, d, call.Binding, sessionEnv)
			if err != nil {
				return nil, err
			}
			id, state, err := sessionmsg.Send(ctx, d, deps.live(), from, a.SessionID, a.Text)
			if err != nil {
				return nil, refusalAsValidation(err)
			}
			out := map[string]any{"message_id": id, "state": state}
			deps.queued(out)
			return out, nil
		},
	}
}

// messageSender is the calling terminal session of the bound workbench.
func messageSender(ctx context.Context, d *db.DB, b Binding, sessionEnv func() string) (int64, error) {
	p, err := workbenchOf(ctx, d, b)
	if err != nil {
		return 0, err
	}
	session, err := terminalSessionOf(d, p.ID, sessionEnv)
	if err != nil {
		return 0, err
	}
	if !session.Valid {
		return 0, errNoMessageSession
	}
	return session.Int64, nil
}

// refusalAsValidation turns a send refusal ("<code>: <sentence>") into the
// model-facing validation error, keeping it matchable; other errors pass.
func refusalAsValidation(err error) error {
	var r *workbenchfolders.Refusal
	if errors.As(err, &r) {
		return &ValidationError{Msg: r.Error(), Err: r}
	}
	return err
}
