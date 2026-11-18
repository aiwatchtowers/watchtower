// Package sessionmsg is the sending side of agent messages (multi-folder
// workbench spec 2026-11-18 §6.6, PROJ-23): a message from one live agent
// session to another of the same workbench, the finish line a sub-session
// sends its parent, and the failure lines a sender gets back. It validates
// and queues rows in session_messages; the daemon's deliverer
// (sessionmsg/delivery) alone types them into the receiving session. Every
// pasted line carries one of the fixed prefixes below, and a sender's own
// line that starts with one is quoted, so a message can never pass for
// another kind or for the owner.
package sessionmsg

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"

	"watchtower/internal/agentkind"
	"watchtower/internal/db"
	"watchtower/internal/sessionhost"
	"watchtower/internal/workbenchfolders"
)

// The kinds of session_messages rows.
const (
	KindMessage  = "message"
	KindFinished = "finished"
	KindFailure  = "failure"
)

// StateQueued is a row the deliverer has not taken yet: what Send answers.
const StateQueued = "queued"

// MaxTextRunes caps a message's text (after its control characters are
// stripped).
const MaxTextRunes = 4000

// Send's refusal codes ("<code>: <sentence>", spec D42).
const (
	CodeSelf             = "self"
	CodeNotSameWorkbench = "not_same_workbench"
	CodeNotFound         = workbenchfolders.CodeNotFound
	CodeNotRunning       = "not_running"
	CodeTooLong          = "too_long"
	CodeEmpty            = "empty"
)

// The reasons a queued row fails with; the sender reads them in
// FailureLine.
const (
	ReasonNotRunning          = "not_running"
	ReasonNotFound            = "not_found"
	ReasonExpired             = "expired"
	ReasonPromptNotCleared    = "prompt_not_cleared"
	ReasonUnknownAfterRestart = "unknown_after_restart"
	ReasonParentDeleted       = "parent_deleted"
	ReasonCannotType          = "cannot_type"
	ReasonDeliveryUnknown     = "delivery_unknown"
)

// DaemonNotRunningWarning is the warning send_to_session and finish_session
// return when no daemon runs to deliver the row they queued.
const DaemonNotRunningWarning = "daemon_not_running: Watchtower's background sync is stopped; the message is delivered when it runs."

// forgedPrefixes are the line starts only the deliverer writes; a sender's
// line that starts with one gets "> " in front.
var forgedPrefixes = []string{"[Message from", "[Sub-session", "[Message to", "(Reply with"}

// LiveFunc reports whether session sessionID has a run in the session host
// (the agent process exists, whatever its state).
type LiveFunc func(ctx context.Context, sessionID int64) (bool, error)

func refuse(code, format string, args ...any) error {
	return &workbenchfolders.Refusal{Code: code, Detail: fmt.Sprintf(format, args...)}
}

// Clean is text as it is queued: control characters stripped (line breaks
// kept as LF, tabs kept — what the host's paste keeps), surrounding space
// trimmed, at most MaxTextRunes, and every line that starts with a fixed
// prefix quoted. Empty and over-long text are refusals.
func Clean(text string) (string, error) {
	s := strings.TrimSpace(sessionhost.PasteText(text, true, false))
	switch n := utf8.RuneCountInString(s); {
	case n == 0:
		return "", refuse(CodeEmpty, "the message has no text.")
	case n > MaxTextRunes:
		return "", refuse(CodeTooLong, "the message is %d characters; at most %d.", n, MaxTextRunes)
	}
	return quoteForged(s), nil
}

// quoteForged puts "> " before every line of s (already LF-only) that
// starts, after leading blanks, with a fixed prefix.
func quoteForged(s string) string {
	lines := strings.Split(s, "\n")
	for i, l := range lines {
		t := strings.TrimLeft(l, " \t")
		for _, p := range forgedPrefixes {
			if strings.HasPrefix(t, p) {
				lines[i] = "> " + l
				break
			}
		}
	}
	return strings.Join(lines, "\n")
}

// oneLine is s with every control character and line break dropped: a
// title or folder name inside a fixed line.
func oneLine(s string) string { return strings.TrimSpace(sessionhost.PasteText(s, false, false)) }

// Header is the first line of a message from session from, started in
// folder: the one format that marks another agent's words.
func Header(from db.TerminalSession, folder string) string {
	return fmt.Sprintf("[Message from #%d “%s” · %s — another agent of this workbench, not the owner]",
		from.ID, oneLine(from.Title), oneLine(folder))
}

// Body is the pasted text of a message: header, the sender's text, and
// how to reply.
func Body(fromID int64, header, text string) string {
	return header + "\n" + text + "\n" + fmt.Sprintf("(Reply with send_to_session(%d, …))", fromID)
}

// FinishLine is the message a sub-session's finish_session sends its parent.
func FinishLine(id int64, title, folder, summary string) string {
	return fmt.Sprintf("[Sub-session #%d “%s” finished · %s] %s", id, oneLine(title), oneLine(folder),
		quoteForged(strings.TrimSpace(sessionhost.PasteText(summary, true, false))))
}

// FailureLine tells a sender its message to session toID failed; toID 0 is
// a receiver whose row was deleted (its id went with it).
func FailureLine(toID int64, reason string) string {
	if toID == 0 {
		return fmt.Sprintf("[Message to a deleted session not delivered: %s]", reason)
	}
	return fmt.Sprintf("[Message to #%d not delivered: %s]", toID, reason)
}

// TypedLine tells a sender its message was typed into session toID's
// prompt but not submitted.
func TypedLine(toID int64) string {
	return fmt.Sprintf("[Message to #%d was typed into the session but not submitted; it waits in its prompt.]", toID)
}

// StartFailureReason is the FailureLine reason of a sub-session whose launch
// failed after the host answered.
func StartFailureReason(launchError string) string {
	return "the sub-session did not start: " + oneLine(launchError)
}

// Send queues text from session from to session to and returns the row's id
// and its state (queued) at once; the daemon delivers it. The target must be
// another agent session of the same workbench that is live; every refusal
// is a *workbenchfolders.Refusal and writes nothing.
func Send(ctx context.Context, d *db.DB, live LiveFunc, from, to int64, text string) (id int64, state string, err error) {
	body, err := Clean(text)
	if err != nil {
		return 0, "", err
	}
	sender, err := CheckTarget(ctx, d, live, from, to)
	if err != nil {
		return 0, "", err
	}
	folder, err := FolderName(ctx, d, sender)
	if err != nil {
		return 0, "", err
	}
	id, err = d.InsertSessionMessage(ctx, db.SessionMessage{WorkbenchID: sender.WorkbenchID.Int64,
		FromSessionID: validID(from), ToSessionID: validID(to), Kind: KindMessage,
		Text: Body(from, Header(*sender, folder), body)})
	if err != nil {
		return 0, "", err //nolint:wrapcheck // InsertSessionMessage names the write
	}
	return id, StateQueued, nil
}

// CheckTarget is Send's refusals of the pair (from, to) without the text:
// the target must be another agent session of the sender's workbench that
// is live. It returns the sender's row.
func CheckTarget(ctx context.Context, d *db.DB, live LiveFunc, from, to int64) (*db.TerminalSession, error) {
	if from == to {
		return nil, refuse(CodeSelf, "a session cannot message itself.")
	}
	sender, ok, err := LoadSession(ctx, d, from)
	if err != nil {
		return nil, err
	}
	if !ok || !sender.WorkbenchID.Valid {
		return nil, refuse(CodeNotFound, "the sending session #%d is not a session of a workbench.", from)
	}
	target, ok, err := LoadSession(ctx, d, to)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, refuse(CodeNotFound, "there is no session #%d.", to)
	}
	if _, agent := agentkind.Parse(target.Kind); !agent || target.WorkbenchID != sender.WorkbenchID {
		return nil, refuse(CodeNotSameWorkbench, "session #%d is not an agent session of this workbench.", to)
	}
	running, err := live(ctx, to)
	if err != nil {
		return nil, fmt.Errorf("reading whether session %d runs: %w", to, err)
	}
	if !running {
		return nil, refuse(CodeNotRunning, "session #%d is not running; a message never starts or resumes a session.", to)
	}
	return sender, nil
}

// QueueFinished queues child's finish line (summary) to its parent and
// returns its id; queued is false when there is no parent to tell — none,
// or one deleted (a grandchild's finish is never re-routed past it).
func QueueFinished(ctx context.Context, d *db.DB, child *db.TerminalSession, summary string) (id int64, queued bool, err error) {
	parent, ok, err := parentOf(ctx, d, child)
	if err != nil || !ok {
		return 0, false, err
	}
	folder, err := FolderName(ctx, d, child)
	if err != nil {
		return 0, false, err
	}
	id, err = d.InsertSessionMessage(ctx, db.SessionMessage{WorkbenchID: parent.WorkbenchID.Int64,
		FromSessionID: validID(child.ID), ToSessionID: validID(parent.ID), Kind: KindFinished,
		Text: FinishLine(child.ID, child.Title, folder, summary)})
	if err != nil {
		return 0, false, err //nolint:wrapcheck // InsertSessionMessage names the write
	}
	return id, true, nil
}

// QueueStartFailure tells sub-session childID's parent that its launch
// failed with launchError; queued is false when there is no parent to tell.
func QueueStartFailure(ctx context.Context, d *db.DB, childID int64, launchError string) (queued bool, err error) {
	child, ok, err := LoadSession(ctx, d, childID)
	if err != nil || !ok {
		return false, err
	}
	parent, ok, err := parentOf(ctx, d, child)
	if err != nil || !ok {
		return false, err
	}
	if _, err := d.InsertSessionMessage(ctx, db.SessionMessage{WorkbenchID: parent.WorkbenchID.Int64,
		FromSessionID: validID(child.ID), ToSessionID: validID(parent.ID), Kind: KindFailure,
		Text: FailureLine(child.ID, StartFailureReason(launchError))}); err != nil {
		return false, err //nolint:wrapcheck // InsertSessionMessage names the write
	}
	return true, nil
}

// parentOf is child's parent row when it has one that exists, is not being
// deleted and is of child's workbench.
func parentOf(ctx context.Context, d *db.DB, child *db.TerminalSession) (*db.TerminalSession, bool, error) {
	if !child.ParentSessionID.Valid || !child.WorkbenchID.Valid {
		return nil, false, nil
	}
	parent, ok, err := LoadSession(ctx, d, child.ParentSessionID.Int64)
	if err != nil || !ok || parent.WorkbenchID != child.WorkbenchID {
		return nil, false, err
	}
	return parent, true, nil
}

// LoadSession is session id's row; ok is false for a row that is gone or
// whose delete was requested (#1716).
func LoadSession(ctx context.Context, d *db.DB, id int64) (*db.TerminalSession, bool, error) {
	var one int
	err := d.QueryRowContext(ctx, `SELECT 1 FROM terminal_sessions WHERE id = ? AND `+db.NotDeletingSQL, id).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, fmt.Errorf("reading session %d: %w", id, err)
	}
	s, err := d.GetTerminalSession(id)
	if errors.Is(err, db.ErrTerminalSessionNotFound) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err //nolint:wrapcheck // GetTerminalSession names the session
	}
	return s, true, nil
}

// FolderName is the stored name of the bench folder s was started for (the
// home folder for a row with none).
func FolderName(ctx context.Context, d *db.DB, s *db.TerminalSession) (string, error) {
	var f *db.WorkbenchFolder
	var err error
	if s.WorkbenchFolderID.Valid {
		f, err = d.WorkbenchFolderByID(ctx, s.WorkbenchFolderID.Int64)
	} else {
		f, err = d.HomeFolder(ctx, s.WorkbenchID.Int64)
	}
	if err != nil {
		return "", fmt.Errorf("reading session %d's folder: %w", s.ID, err)
	}
	return f.Name, nil
}

func validID(id int64) sql.NullInt64 { return sql.NullInt64{Int64: id, Valid: true} }
