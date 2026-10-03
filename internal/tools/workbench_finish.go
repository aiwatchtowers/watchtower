package tools

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"
	"unicode/utf8"

	"watchtower/internal/db"
)

// ---- session links -----------------------------------------------------

// linkSession records that this terminal session's agent wrote to targetIDs
// (spec 2026-10-03-workbench-session-report Part 3, PROJ-14): the session is
// the one terminalSessionOf resolves for the binding's workbench, and with no
// session nothing is recorded. Called only after the tool's own write
// succeeded; a failure never fails or undoes it — see reportLinkFailure.
func linkSession(d *db.DB, b Binding, sessionEnv func() string, out map[string]any, targetIDs ...int64) {
	if len(targetIDs) == 0 {
		return
	}
	session, err := terminalSessionOf(d, b.WorkbenchID, sessionEnv)
	if err == nil && session.Valid {
		err = linkTargets(d, session.Int64, targetIDs)
	}
	reportLinkFailure(out, err)
}

// linkTargets upserts one (session, target) link per target, stopping at the
// first failure.
func linkTargets(d *db.DB, sessionID int64, targetIDs []int64) error {
	for _, id := range targetIDs {
		if err := d.LinkSessionTarget(sessionID, id); err != nil {
			return err
		}
	}
	return nil
}

// reportLinkFailure turns a failed link write into one stderr line and the
// result's session_link_warning; a nil err changes nothing.
func reportLinkFailure(out map[string]any, err error) {
	if err == nil {
		return
	}
	fmt.Fprintf(os.Stderr, "watchtower: recording the session's target link: %v\n", err)
	out["session_link_warning"] = "the write is done, but this session's report may not list its target: " + err.Error()
}

// ---- finish_session ----------------------------------------------------

const (
	maxFinishSummaryRunes = 600
	maxFinishSummaryLines = 4
	// finishedAtLayout is db's agent_state_at form, the one finished_at is
	// stored in.
	finishedAtLayout = "2006-01-02T15:04:05.000Z"
)

type finishSessionArgs struct {
	Summary  string `json:"summary" jsonschema:"your last word to the owner, 2-3 lines and at most 4 (600 characters): what was done, the PRs and their state, what is left"`
	TargetID int64  `json:"target_id,omitempty" jsonschema:"the workbench target this session worked on, if one"`
	Reason   string `json:"reason" jsonschema:"one sentence: why the session is finished"`
}

// errNoTerminalSession refuses finish_session outside a Watchtower terminal
// session: an external terminal has no session to mark.
var errNoTerminalSession = &ValidationError{Msg: "finish_session needs a Watchtower terminal session"}

// NewFinishSession marks this terminal session finished with the agent's
// summary. sessionEnv returns the terminal session env (TerminalSessionEnv).
func NewFinishSession(sessionEnv func() string) *Tool {
	return &Tool{
		Name: "finish_session",
		Description: "Mark this terminal session finished once the work it was started for is done or handed to the " +
			"owner, with a short summary the owner reads in the Watchtower app (what was done, the PRs, what is " +
			"left). Open asks may stay open. Calling it again replaces the summary. Applied immediately.",
		InputSchema: mustSchema[finishSessionArgs]("finish_session"),
		Access:      AccessWrite,
		Surfaces:    workbenchSurfaces,
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a finishSessionArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			_, err := finishSummary(a.Summary)
			return err
		},
		Scope: func(ctx context.Context, d *db.DB, raw json.RawMessage, b Binding) error {
			var a finishSessionArgs
			if err := json.Unmarshal(raw, &a); err != nil {
				return &ValidationError{Msg: "invalid arguments"}
			}
			_, err := scopeFinishSession(ctx, d, b, a, sessionEnv)
			return err
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a finishSessionArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding finish_session args: %w", err)
			}
			return finishSession(ctx, d, call.Binding, a, sessionEnv)
		},
	}
}

// finishSummary is summary trimmed: 1-600 runes, at most 4 lines.
func finishSummary(summary string) (string, error) {
	s := strings.TrimSpace(summary)
	switch {
	case s == "":
		return "", &ValidationError{Msg: "summary: required"}
	case utf8.RuneCountInString(s) > maxFinishSummaryRunes:
		return "", &ValidationError{Msg: fmt.Sprintf("summary: at most %d characters", maxFinishSummaryRunes)}
	case strings.Count(s, "\n") >= maxFinishSummaryLines:
		return "", &ValidationError{Msg: fmt.Sprintf("summary: at most %d lines", maxFinishSummaryLines)}
	}
	return s, nil
}

// scopeFinishSession refuses a target_id outside the workbench and a call
// from no terminal session of it; otherwise it returns the session id.
func scopeFinishSession(ctx context.Context, d *db.DB, b Binding, a finishSessionArgs, sessionEnv func() string) (int64, error) {
	p, err := workbenchOf(ctx, d, b)
	if err != nil {
		return 0, err
	}
	if a.TargetID != 0 {
		_, err := targetInWorkbench(d, p.ID, a.TargetID)
		if errors.Is(err, db.ErrNotInWorkbench) {
			return 0, &ValidationError{Msg: fmt.Sprintf("target_id: no target with id %d in this workbench", a.TargetID),
				Err: db.ErrNotInWorkbench}
		}
		if err != nil {
			return 0, err
		}
	}
	session, err := terminalSessionOf(d, p.ID, sessionEnv)
	if err != nil {
		return 0, err
	}
	if !session.Valid {
		return 0, errNoTerminalSession
	}
	return session.Int64, nil
}

// finishSession stores finished_at and the summary on the session (a repeat
// call overwrites both), then links target_id best-effort, and reports the
// session's open asks — a finished session may still wait on the owner. A
// failed count after the write is an error; the agent's retry rewrites the
// same finish.
func finishSession(ctx context.Context, d *db.DB, b Binding, a finishSessionArgs, sessionEnv func() string) (any, error) {
	summary, err := finishSummary(a.Summary)
	if err != nil {
		return nil, err
	}
	sessionID, err := scopeFinishSession(ctx, d, b, a, sessionEnv)
	if err != nil {
		return nil, err
	}
	at := time.Now().UTC()
	err = d.FinishTerminalSession(sessionID, summary, at)
	if errors.Is(err, db.ErrTerminalSessionNotFound) {
		return nil, errNoTerminalSession // the session row went since Scope ran
	}
	if err != nil {
		return nil, err
	}
	out := map[string]any{"session_id": sessionID, "finished_at": at.Format(finishedAtLayout)}
	if a.TargetID != 0 {
		reportLinkFailure(out, linkTargets(d, sessionID, []int64{a.TargetID}))
	}
	open, err := d.ListOwnerAsks(b.WorkbenchID, db.OwnerAskFilter{Statuses: []string{"open"}, SessionID: sessionID})
	if err != nil {
		return nil, err
	}
	out["open_asks"] = len(open)
	return out, nil
}
