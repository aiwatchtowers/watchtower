package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"

	"watchtower/internal/asks"
	"watchtower/internal/db"
	"watchtower/internal/kb"
)

// TerminalSessionEnv names the terminal_sessions row a Desktop-launched
// claude runs in (TerminalCenter sets it; a dual path with Swift
// `TerminalLaunch.sessionRowEnv`). The MCP server inherits it from claude.
const TerminalSessionEnv = "WATCHTOWER_TERMINAL_SESSION_ID"

// maxListedAsks caps one list_asks call.
const maxListedAsks = 50

// withdrawnTitleWindow is how far back ask_owner refuses a title the agent
// withdrew; seriesHintWindow how far back an open question ask of the same
// session earns the series hint (spec 2026-10-10, Part 8).
const (
	withdrawnTitleWindow = 7 * 24 * time.Hour
	seriesHintWindow     = 10 * time.Minute
)

// processTerminalSession is the terminal session env of this process — the
// getter WorkbenchTools gives the ask tools; tests inject their own.
func processTerminalSession() string { return os.Getenv(TerminalSessionEnv) }

// terminalSessionOf is the session an ask of workbench workbenchID belongs to:
// getenv's id when it parses and names a terminal_sessions row of that
// workbench; otherwise none (an external terminal, a garbage value or a gone
// row), never an error — only a failed lookup is one.
func terminalSessionOf(d *db.DB, workbenchID int64, getenv func() string) (sql.NullInt64, error) {
	s, err := terminalSessionRow(d, workbenchID, getenv)
	if err != nil || s == nil {
		return sql.NullInt64{}, err
	}
	return sql.NullInt64{Int64: s.ID, Valid: true}, nil
}

// terminalSessionRow is terminalSessionOf's row: nil for no session of
// workbench workbenchID, an error only for a failed lookup.
func terminalSessionRow(d *db.DB, workbenchID int64, getenv func() string) (*db.TerminalSession, error) {
	id, ok := parseSessionID(getenv())
	if !ok {
		return nil, nil
	}
	s, err := d.GetTerminalSession(id)
	if errors.Is(err, db.ErrTerminalSessionNotFound) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("loading terminal session %d: %w", id, err)
	}
	if s.WorkbenchID.Int64 != workbenchID {
		return nil, nil
	}
	return s, nil
}

// parseSessionID reads a terminal_sessions id the way the brief's session
// hook does (cmd/workbench_brief_session.go): trimmed, positive.
func parseSessionID(raw string) (int64, bool) {
	id, err := strconv.ParseInt(strings.TrimSpace(raw), 10, 64)
	return id, err == nil && id > 0
}

// fieldRefusal is err as a `field: reason` refusal (spec 2026-10-03 Part 3);
// an error that is not model-facing comes back unchanged.
func fieldRefusal(field string, err error) error {
	var verr *ValidationError
	if !errors.As(err, &verr) {
		return err
	}
	return &ValidationError{Msg: field + ": " + verr.Msg, Err: verr.Err}
}

func noAsk(id int64) error {
	return &ValidationError{Msg: fmt.Sprintf("no ask with id %d", id), Err: db.ErrAskNotFound}
}

// askInWorkbench loads ask id of workbenchID; another workbench's, a missing
// one or an automation run's (its run waits for the answer itself, never a
// session: get_ask, withdraw_ask and previous_ask_id all come through here)
// reads as noAsk.
func askInWorkbench(d *db.DB, workbenchID, id int64) (*db.OwnerAsk, error) {
	a, err := d.GetOwnerAsk(workbenchID, id)
	if errors.Is(err, db.ErrAskNotFound) || (err == nil && a.AutomationRunID.Valid) {
		return nil, noAsk(id)
	}
	return a, err
}

// readReviewDoc resolves a review's doc_path inside folder and reads its text:
// a .md/.markdown/.txt regular file of at most asks.MaxSnapshotBytes, valid
// UTF-8. It only reads. rel is the folder-relative path the ask stores.
func readReviewDoc(folder, path string) (rel, text string, err error) {
	rel, err = ResolveWorkbenchDocumentPath(folder, path)
	if err != nil {
		return "", "", fieldRefusal("doc_path", err)
	}
	data, err := readInsideFolder(folder, rel, asks.MaxSnapshotBytes+1)
	switch {
	case errors.Is(err, errNotRegularFile):
		return "", "", &ValidationError{Msg: fmt.Sprintf("doc_path: %s is not a regular file", rel)}
	case err != nil:
		return "", "", &ValidationError{Msg: fmt.Sprintf("doc_path: cannot read %s: %v", rel, err)}
	case len(data) > asks.MaxSnapshotBytes:
		return "", "", &ValidationError{Msg: fmt.Sprintf("doc_path: %s is larger than 2 MiB", rel)}
	case !utf8.Valid(data):
		return "", "", &ValidationError{Msg: fmt.Sprintf("doc_path: %s is not valid UTF-8 text", rel)}
	}
	return rel, string(data), nil
}

var errNotRegularFile = errors.New("not a regular file")

// readInsideFolder reads at most limit bytes of folder/rel through an
// os.Root on folder: a symlink swapped in after the path was resolved still
// cannot lead the read out of the folder. The open is non-blocking and the
// opened file must be regular (errNotRegularFile), so a FIFO swapped in after
// the check never blocks the call — the same rule as kb's readSetFile.
func readInsideFolder(folder, rel string, limit int64) ([]byte, error) {
	root, err := os.OpenRoot(folder)
	if err != nil {
		return nil, err
	}
	defer func() { _ = root.Close() }()
	f, err := root.OpenFile(filepath.FromSlash(rel), os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if !fi.Mode().IsRegular() {
		return nil, errNotRegularFile
	}
	return io.ReadAll(io.LimitReader(f, limit))
}

func nullID(id int64) sql.NullInt64 {
	return sql.NullInt64{Int64: id, Valid: id != 0}
}

// ---- ask_owner ---------------------------------------------------------

type askOwnerArgs struct {
	Kind          string               `json:"kind" jsonschema:"review (the owner reads a document of this folder and approves or requests changes), check (the owner runs a checklist) or question (the owner picks answers)"`
	Title         string               `json:"title" jsonschema:"what you ask, at most 120 characters"`
	Summary       string               `json:"summary,omitempty" jsonschema:"the context the owner needs, at most 2000 characters"`
	Changes       string               `json:"changes,omitempty" jsonschema:"with previous_ask_id only: what changed since that ask, at most 1000 characters"`
	Focus         []asks.Focus         `json:"focus,omitempty" jsonschema:"up to 5 points to look at; heading and quote (review only) anchor one in the document"`
	Questions     []asks.Question      `json:"questions,omitempty" jsonschema:"up to 4 questions (1-4 for kind question), each with 2-4 options; multi allows several labels"`
	Checklist     []asks.ChecklistItem `json:"checklist,omitempty" jsonschema:"check only: 1-30 steps for the owner to run"`
	DocPath       string               `json:"doc_path,omitempty" jsonschema:"review only, required: the .md/.markdown/.txt file of this folder to review (relative or absolute); its text at this moment is what the owner sees"`
	PreviousAskID int64                `json:"previous_ask_id,omitempty" jsonschema:"an earlier ask of this workbench of the same kind this one follows up; if still open it is withdrawn as superseded"`
	TargetID      int64                `json:"target_id,omitempty" jsonschema:"the workbench target the ask is about"`
	Level         string               `json:"level,omitempty" jsonschema:"quick (one question, 2-3 short options, answered with one tap) or full (the owner opens the ask); default: from its shape. quick on a shape that is not one is stored full with level_note saying why"`
	Reason        string               `json:"reason" jsonschema:"one sentence: why you need the owner now"`
}

func (a askOwnerArgs) input() asks.Input {
	return asks.Input{
		Kind: a.Kind, Title: a.Title, Summary: a.Summary, Changes: a.Changes,
		Focus: a.Focus, Questions: a.Questions, Checklist: a.Checklist,
		DocPath: a.DocPath, PreviousAskID: a.PreviousAskID,
	}
}

// NewAskOwner files an ask of the owner: a document review, a check or
// questions. sessionEnv returns the terminal session env (TerminalSessionEnv).
func NewAskOwner(sessionEnv func() string) *Tool {
	return &Tool{
		Name: "ask_owner",
		Description: "Ask the owner for a document review (kind review, doc_path), a check they run (kind check, " +
			"checklist) or a decision (kind question, questions). Returns at once with the ask id — do not wait: " +
			"the answer reaches this session as a typed line; read it with get_ask. A follow-up round names the " +
			"earlier ask in previous_ask_id (and what changed in changes). Applied immediately.",
		InputSchema: mustSchema[askOwnerArgs]("ask_owner"),
		Access:      AccessWrite,
		Surfaces:    workbenchSurfaces,
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a askOwnerArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			if a.PreviousAskID < 0 {
				return &ValidationError{Msg: "previous_ask_id: must be an ask id"}
			}
			if a.TargetID < 0 {
				return &ValidationError{Msg: "target_id: must be a target id"}
			}
			if a.Level != "" && a.Level != asks.LevelQuick && a.Level != asks.LevelFull {
				return &ValidationError{Msg: "level: must be quick or full"}
			}
			if _, err := asks.Validate(a.input(), asks.OriginAgent); err != nil {
				return &ValidationError{Msg: err.Error()}
			}
			return nil
		},
		Scope: func(ctx context.Context, d *db.DB, raw json.RawMessage, b Binding) error {
			var a askOwnerArgs
			if err := json.Unmarshal(raw, &a); err != nil {
				return &ValidationError{Msg: "invalid arguments"}
			}
			return scopeAskOwner(ctx, d, b, a)
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a askOwnerArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding ask_owner args: %w", err)
			}
			return fileAsk(ctx, d, call.Binding, a, sessionEnv)
		},
	}
}

func scopeAskOwner(ctx context.Context, d *db.DB, b Binding, a askOwnerArgs) error {
	p, err := workbenchOf(ctx, d, b)
	if err != nil {
		return err
	}
	if a.TargetID != 0 {
		if _, err := targetInWorkbench(d, p.ID, a.TargetID); err != nil {
			return fieldRefusal("target_id", err)
		}
	}
	open, err := d.CountOpenOwnerAsks(p.ID)
	if err != nil {
		return err
	}
	if a.PreviousAskID != 0 {
		prev, err := askInWorkbench(d, p.ID, a.PreviousAskID)
		if err != nil {
			return fieldRefusal("previous_ask_id", err)
		}
		if prev.Kind != a.Kind {
			return &ValidationError{Msg: fmt.Sprintf("previous_ask_id: ask %d is a %s ask, not a %s ask", prev.ID, prev.Kind, a.Kind)}
		}
		if prev.Status == "open" {
			open-- // superseded in the same transaction
		}
		if prev.Status == "withdrawn" && strings.TrimSpace(a.Changes) == "" {
			return &ValidationError{Msg: "changes: required when previous_ask_id names a withdrawn ask — say what is new"}
		}
	} else {
		w, err := d.LastWithdrawnByTitle(p.ID, a.Kind, asks.NormalizeTitle(a.Title), time.Now().Add(-withdrawnTitleWindow))
		if err != nil {
			return err
		}
		if w != nil {
			return &ValidationError{Msg: fmt.Sprintf(
				"title: ask #%d with this title was withdrawn; file it as a revision with previous_ask_id %d and changes", w.ID, w.ID)}
		}
	}
	// Refused here, nothing is recorded; InsertOwnerAsk re-checks in its
	// transaction for a race with another session.
	if open >= asks.MaxOpenPerWorkbench {
		return &ValidationError{Msg: db.ErrTooManyOpenAsks.Error(), Err: db.ErrTooManyOpenAsks}
	}
	if a.Kind == asks.KindReview {
		_, _, err = readReviewDoc(p.FolderPath, a.DocPath)
	}
	return err
}

// askLevel is the level ask_owner stores: full when the agent asks for it,
// else the shape's level; note names why a requested quick was not one.
func askLevel(requested, kind string, p asks.Payload) (level, note string) {
	if requested == asks.LevelFull {
		return asks.LevelFull, ""
	}
	note = asks.LevelNote(kind, p, asks.OriginAgent)
	if note == "" {
		return asks.LevelQuick, ""
	}
	if requested != asks.LevelQuick {
		note = ""
	}
	return asks.LevelFull, note
}

// fileAsk inserts the ask (superseding an open previous ask in the same
// transaction) and then indexes a review's document and links its target to
// the ask's session, both best-effort: a failed index is the result's
// index_warning, a failed link its session_link_warning, never a failed ask.
// A question ask of a session that has another open one filed within
// seriesHintWindow carries the series hint.
func fileAsk(ctx context.Context, d *db.DB, b Binding, a askOwnerArgs, sessionEnv func() string) (any, error) {
	p, err := workbenchOf(ctx, d, b)
	if err != nil {
		return nil, err
	}
	payload, err := asks.Validate(a.input(), asks.OriginAgent)
	if err != nil {
		return nil, &ValidationError{Msg: err.Error()}
	}
	payloadJSON, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("encoding ask payload: %w", err)
	}
	level, levelNote := askLevel(a.Level, a.Kind, payload)
	ask := db.OwnerAsk{
		WorkbenchID: p.ID, TargetID: nullID(a.TargetID), PreviousAskID: nullID(a.PreviousAskID),
		Kind: a.Kind, Title: strings.TrimSpace(a.Title), Summary: strings.TrimSpace(a.Summary),
		Changes: strings.TrimSpace(a.Changes), Payload: string(payloadJSON),
		Level: level, Origin: asks.OriginAgent,
	}
	if a.Kind == asks.KindReview {
		// Read before the write transaction opens.
		if ask.DocPath, ask.DocSnapshot, err = readReviewDoc(p.FolderPath, a.DocPath); err != nil {
			return nil, err
		}
	}
	if ask.SessionID, err = terminalSessionOf(d, p.ID, sessionEnv); err != nil {
		return nil, err
	}
	// Read before the insert, which would otherwise find itself.
	series, err := openQuestionSeriesAsk(d, ask, a.PreviousAskID)
	if err != nil {
		return nil, err
	}
	var id, superseded int64
	err = d.WithTx(func(tx *sql.Tx) error {
		id, superseded, err = d.InsertOwnerAsk(tx, ask)
		return err
	})
	switch {
	case errors.Is(err, db.ErrTooManyOpenAsks):
		return nil, &ValidationError{Msg: err.Error(), Err: err}
	case errors.Is(err, db.ErrAskNotFound):
		return nil, fieldRefusal("previous_ask_id", noAsk(a.PreviousAskID))
	case err != nil:
		return nil, err
	}
	out := map[string]any{"ask_id": id, "status": "open", "session_bound": ask.SessionID.Valid, "level": level}
	if levelNote != "" {
		out["level_note"] = levelNote
	}
	if superseded != 0 {
		out["superseded"] = superseded
	}
	if series != nil {
		out["hint"] = fmt.Sprintf("ask #%d of this session is still open — put related decisions in one ask (up to 4 questions)", series.ID)
	}
	indexAndLinkFiledAsk(ctx, d, p, ask, out)
	return out, nil
}

// openQuestionSeriesAsk returns another open question ask of the new ask's
// session filed within seriesHintWindow, or nil (also for a non-question ask
// or one without a session). The ask the new one supersedes is excluded: it
// will not stay open.
func openQuestionSeriesAsk(d *db.DB, ask db.OwnerAsk, previousAskID int64) (*db.OwnerAsk, error) {
	if ask.Kind != asks.KindQuestion || !ask.SessionID.Valid {
		return nil, nil
	}
	since := time.Now().Add(-seriesHintWindow)
	return d.RecentOpenQuestionAsk(ask.SessionID.Int64, since, previousAskID)
}

// indexAndLinkFiledAsk indexes a filed review's document and links the ask's
// target to its session, both best-effort: a failure lands in out as
// index_warning or session_link_warning.
func indexAndLinkFiledAsk(ctx context.Context, d *db.DB, p *db.Workbench, ask db.OwnerAsk, out map[string]any) {
	if ask.DocPath != "" {
		set := kb.FileSet{Source: kb.WorkbenchDocSource, Container: p.ID, Root: p.FolderPath, Files: []string{ask.DocPath}}
		if _, _, err := kb.IndexFileSet(ctx, d, set); err != nil {
			out["index_warning"] = fmt.Sprintf("the ask is filed, but %s is not in search yet: %v", ask.DocPath, err)
		}
	}
	if ask.SessionID.Valid && ask.TargetID.Valid {
		reportLinkFailure(out, linkTargets(d, ask.SessionID.Int64, []int64{ask.TargetID.Int64}))
	}
}

// ---- get_ask -----------------------------------------------------------

type getAskArgs struct {
	AskID int64 `json:"ask_id" jsonschema:"the ask id from ask_owner, list_asks or the answered line"`
}

type askView struct {
	AskID           int64        `json:"ask_id"`
	Kind            string       `json:"kind"`
	Title           string       `json:"title"`
	Status          string       `json:"status"`
	WithdrawnReason string       `json:"withdrawn_reason,omitempty"`
	TargetID        int64        `json:"target_id,omitempty"`
	SessionID       int64        `json:"session_id,omitempty"`
	CreatedAt       string       `json:"created_at"`
	AnsweredAt      string       `json:"answered_at,omitempty"`
	Answer          *asks.Answer `json:"answer,omitempty"`
	AnswerText      string       `json:"answer_text,omitempty"`
	PreviousAskID   int64        `json:"previous_ask_id,omitempty"`
	Level           string       `json:"level"`
	Origin          string       `json:"origin"`
	ChatAskedAt     string       `json:"chat_asked_at,omitempty"`
}

// NewGetAsk reads one ask of this workbench. Reading an answered ask marks
// it delivered — from any session of the workbench.
func NewGetAsk() *Tool {
	return &Tool{
		Name: "get_ask",
		Description: "Read one of this workbench's asks: its status and, once the owner answered, the answer as " +
			"JSON (answer) and as readable text (answer_text). Reading an answer marks the ask delivered.",
		InputSchema: mustSchema[getAskArgs]("get_ask"),
		Access:      AccessRead,
		Surfaces:    workbenchSurfaces,
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a getAskArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			p, err := workbenchOf(ctx, d, call.Binding)
			if err != nil {
				return nil, err
			}
			return readAsk(d, p.ID, a.AskID)
		},
	}
}

// readAsk is get_ask: an answered (or delivered) ask carries its answer,
// checked against the ask before anything is returned — an invalid stored
// answer is an error, never a partial one — and an answered ask then moves
// to delivered.
func readAsk(d *db.DB, workbenchID, id int64) (*askView, error) {
	a, err := askInWorkbench(d, workbenchID, id)
	if err != nil {
		return nil, err
	}
	view := &askView{
		AskID: a.ID, Kind: a.Kind, Title: a.Title, Status: a.Status, WithdrawnReason: a.WithdrawnReason,
		TargetID: a.TargetID.Int64, SessionID: a.SessionID.Int64, PreviousAskID: a.PreviousAskID.Int64,
		CreatedAt: a.CreatedAt, AnsweredAt: a.AnsweredAt,
		Level: a.Level, Origin: a.Origin, ChatAskedAt: a.ChatAskedAt,
	}
	if a.Status != "answered" && a.Status != "delivered" {
		return view, nil
	}
	var payload asks.Payload
	if err := json.Unmarshal([]byte(a.Payload), &payload); err != nil {
		return nil, fmt.Errorf("ask %d: stored payload: %w", id, err)
	}
	answer, err := asks.ParseAnswer([]byte(a.Answer))
	if err == nil {
		err = asks.ValidateAnswer(a.Kind, payload, answer)
	}
	if err != nil {
		return nil, fmt.Errorf("ask %d: stored answer: %w", id, err)
	}
	view.Answer, view.AnswerText = &answer, asks.Render(a.Kind, payload, answer)
	if a.Status == "answered" {
		if _, err := d.MarkOwnerAskDelivered(workbenchID, id); err != nil {
			return nil, err
		}
		// Not marked means another session's get_ask delivered it first:
		// delivered is the one way out of answered.
		view.Status = "delivered"
	}
	return view, nil
}

// ---- list_asks ---------------------------------------------------------

type listAsksArgs struct {
	Status  string `json:"status,omitempty" jsonschema:"open | answered (answered or already read) | all; default: answered and not yet read, then open"`
	Session string `json:"session,omitempty" jsonschema:"mine (this terminal's asks) | all; default all"`
}

type askRow struct {
	AskID       int64  `json:"ask_id"`
	Kind        string `json:"kind"`
	Title       string `json:"title"`
	Status      string `json:"status"`
	SessionID   *int64 `json:"session_id"` // null: an external terminal or a gone session
	CreatedAt   string `json:"created_at"`
	AnsweredAt  string `json:"answered_at"` // "" until answered
	Level       string `json:"level"`
	Origin      string `json:"origin"`
	ChatAskedAt string `json:"chat_asked_at"` // "" unless origin chat
}

// askStatuses maps list_asks' status argument to the statuses it lists.
var askStatuses = map[string][]string{
	"":         nil, // db: answered, then open
	"open":     {"open"},
	"answered": {"answered", "delivered"},
	"all":      {"open", "answered", "delivered", "withdrawn"},
}

// NewListAsks lists this workbench's asks, at most maxListedAsks.
// sessionEnv returns the terminal session env, for session "mine".
func NewListAsks(sessionEnv func() string) *Tool {
	return &Tool{
		Name: "list_asks",
		Description: "List this workbench's asks (at most 50): by default the answered ones you have not read " +
			"yet, then the open ones. Read an answer with get_ask.",
		InputSchema: mustSchema[listAsksArgs]("list_asks"),
		Access:      AccessRead,
		Surfaces:    workbenchSurfaces,
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a listAsksArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			if err := validateEnum("status", a.Status, "open", "answered", "all"); err != nil {
				return nil, err
			}
			if err := validateEnum("session", a.Session, "mine", "all"); err != nil {
				return nil, err
			}
			p, err := workbenchOf(ctx, d, call.Binding)
			if err != nil {
				return nil, err
			}
			f := db.OwnerAskFilter{Statuses: askStatuses[a.Status], Limit: maxListedAsks, ExcludeAutomation: true}
			if a.Session == "mine" {
				s, err := terminalSessionOf(d, p.ID, sessionEnv)
				if err != nil {
					return nil, err
				}
				if !s.Valid {
					return nil, &ValidationError{Msg: `session "mine": this terminal is not a session of this workbench — use session "all"`}
				}
				f.SessionID = s.Int64
			}
			list, err := d.ListOwnerAsks(p.ID, f)
			if err != nil {
				return nil, err
			}
			rows := make([]askRow, 0, len(list))
			for _, x := range list {
				row := askRow{AskID: x.ID, Kind: x.Kind, Title: x.Title, Status: x.Status,
					CreatedAt: x.CreatedAt, AnsweredAt: x.AnsweredAt,
					Level: x.Level, Origin: x.Origin, ChatAskedAt: x.ChatAskedAt}
				if x.SessionID.Valid {
					row.SessionID = &x.SessionID.Int64
				}
				rows = append(rows, row)
			}
			return rows, nil
		},
	}
}

// ---- withdraw_ask ------------------------------------------------------

type withdrawAskArgs struct {
	AskID  int64  `json:"ask_id" jsonschema:"the open ask to withdraw"`
	Reason string `json:"reason" jsonschema:"one sentence: why the owner no longer needs to answer"`
}

// NewWithdrawAsk withdraws an open ask of this workbench.
func NewWithdrawAsk() *Tool {
	return &Tool{
		Name: "withdraw_ask",
		Description: "Withdraw an open ask the owner no longer needs to answer (you found the answer, the work " +
			"moved on). To replace an ask, file the new one with previous_ask_id instead. Applied immediately.",
		InputSchema: mustSchema[withdrawAskArgs]("withdraw_ask"),
		Access:      AccessWrite,
		Surfaces:    workbenchSurfaces,
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a withdrawAskArgs
			return decodeStrict(raw, &a)
		},
		Scope: func(ctx context.Context, d *db.DB, raw json.RawMessage, b Binding) error {
			var a withdrawAskArgs
			if err := json.Unmarshal(raw, &a); err != nil {
				return &ValidationError{Msg: "invalid arguments"}
			}
			return scopeWithdrawAsk(ctx, d, b, a.AskID)
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a withdrawAskArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding withdraw_ask args: %w", err)
			}
			err := d.WithdrawOwnerAsk(call.Binding.WorkbenchID, a.AskID, db.WithdrawnByAgent)
			if errors.Is(err, db.ErrAskNotOpen) || errors.Is(err, db.ErrAskNotFound) {
				// Answered or withdrawn since Scope ran: the same refusal.
				if serr := scopeWithdrawAsk(ctx, d, call.Binding, a.AskID); serr != nil {
					return nil, serr
				}
			}
			if err != nil {
				return nil, err
			}
			return map[string]any{"ask_id": a.AskID, "status": "withdrawn"}, nil
		},
	}
}

// scopeWithdrawAsk refuses an ask that is not this workbench's or not open,
// as `ask N is <status>`.
func scopeWithdrawAsk(ctx context.Context, d *db.DB, b Binding, id int64) error {
	p, err := workbenchOf(ctx, d, b)
	if err != nil {
		return err
	}
	a, err := askInWorkbench(d, p.ID, id)
	if err != nil {
		return err
	}
	if a.Status != "open" {
		return &ValidationError{Msg: fmt.Sprintf("ask %d is %s", id, a.Status), Err: db.ErrAskNotOpen}
	}
	return nil
}
