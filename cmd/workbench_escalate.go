package cmd

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/asks"
	"watchtower/internal/db"
)

// The escalation's reasons (spec 2026-10-10-owner-asks-v2 Part 5.2), each
// with the summary line the raised ask carries.
const (
	escalateReasonTimeout = "timeout"
	escalateReasonLeft    = "left"
	escalateReasonAway    = "away"
)

// Outcomes and error codes of `workbench escalate-question` (Part 5.3). The
// Desktop retries busy and open_cap only.
const (
	escalateFiled = "filed"
	escalateGone  = "gone"

	escalateErrBusy     = "busy"
	escalateErrOpenCap  = "open_cap"
	escalateErrNotFound = "not_found"
	escalateErrBadArgs  = "bad_args"
	escalateErrSchema   = "schema"
	escalateErrInternal = "internal"
)

// escalateTitleRunes bounds the raised ask's title (asks.Validate's cap).
const escalateTitleRunes = 120

var workbenchEscalateCmd = &cobra.Command{
	Use:   "escalate-question",
	Short: "Raise a terminal session's unanswered chat question to an owner ask",
	Long: "--workbench N --session S --at <chat_question_at> --reason timeout|left|away: files the chat\n" +
		"question the Stop ask guard recorded on session S as a question ask raised from chat (origin\n" +
		"chat), in one transaction and only while it is still the stored one (chat_question_at equals\n" +
		"--at) and the session still waits on that turn end (agent_state waiting, stamped at most 30 s\n" +
		"after the question); the question is cleared as it is filed. Prints one JSON object:\n" +
		"{\"ok\": true, \"outcome\": \"filed\", \"ask_id\", \"level\"}, {\"ok\": true, \"outcome\": \"gone\"} when\n" +
		"the question is no longer there to raise, or {\"ok\": false, \"error_code\", \"error\"} with\n" +
		"error_code busy, open_cap, not_found, bad_args, schema or internal, nothing written. Always\n" +
		"exits 0. The Desktop runs it; nothing is typed into the terminal.",
	// No root schema/config pre-run: a broken config answers ok: false like
	// any other failure; the DB is opened by the command. Skipping
	// ensureSchemaFormat is safe, as for session-state: the Desktop runs this
	// only over a chat_question_at it read, which only a goose-era database
	// past that legacy upgrade holds.
	PersistentPreRunE: func(*cobra.Command, []string) error { return nil },
	Args:              cobra.ArbitraryArgs,
	RunE: func(cmd *cobra.Command, args []string) (err error) {
		defer func() {
			if r := recover(); r != nil {
				err = writeEscalateResult(cmd.OutOrStdout(), escalateFailure(escalateErrInternal, fmt.Errorf("panic: %v", r)))
			}
		}()
		return writeEscalateResult(cmd.OutOrStdout(), runEscalateQuestion(cmd, args))
	},
}

var (
	workbenchEscalateFlagWorkbench int64
	workbenchEscalateFlagSession   int64
	workbenchEscalateFlagAt        string
	workbenchEscalateFlagReason    string
)

func init() {
	c := workbenchEscalateCmd
	addWorkbenchIDFlag(c, &workbenchEscalateFlagWorkbench, "workbench id")
	c.Flags().Int64Var(&workbenchEscalateFlagSession, "session", 0, "terminal session id")
	c.Flags().StringVar(&workbenchEscalateFlagAt, "at", "", "the chat_question_at the Desktop read, verbatim")
	c.Flags().StringVar(&workbenchEscalateFlagReason, "reason", "", "timeout, left or away")
	// A flag cobra cannot parse is a bad_args envelope with exit 0, never a
	// usage error: the Desktop reads the envelope.
	c.SetFlagErrorFunc(func(cmd *cobra.Command, err error) error {
		return writeEscalateResult(cmd.OutOrStdout(), escalateFailure(escalateErrBadArgs, err))
	})
	workbenchCmd.AddCommand(c)
}

// escalateResult is the verb's one JSON object.
type escalateResult struct {
	OK        bool   `json:"ok"`
	Outcome   string `json:"outcome,omitempty"`
	AskID     int64  `json:"ask_id,omitempty"`
	Level     string `json:"level,omitempty"`
	ErrorCode string `json:"error_code,omitempty"`
	Error     string `json:"error,omitempty"`
}

func escalateFailure(code string, err error) escalateResult {
	return escalateResult{OK: false, ErrorCode: code, Error: err.Error()}
}

// writeEscalateResult prints res and never fails the command: the exit code
// stays 0 whatever happened (an unwritable stdout has no reader anyway, so
// its error is dropped on purpose).
func writeEscalateResult(w io.Writer, res escalateResult) error {
	_ = writeJSON(w, res)
	return nil
}

// escalateArgs is the parsed command line.
type escalateArgs struct {
	workbenchID, sessionID int64
	at                     string
	asked                  time.Time
	reason                 string
}

func parseEscalateArgs(cmd *cobra.Command, positional []string) (escalateArgs, error) {
	var a escalateArgs
	if err := checkWorkbenchIDFlags(cmd); err != nil {
		return a, err
	}
	if len(positional) > 0 {
		return a, fmt.Errorf("unexpected argument %q", briefClip(positional[0], 40))
	}
	if a.workbenchID = workbenchEscalateFlagWorkbench; a.workbenchID <= 0 {
		return a, errors.New("--workbench takes a positive id")
	}
	if a.sessionID = workbenchEscalateFlagSession; a.sessionID <= 0 {
		return a, errors.New("--session takes a positive id")
	}
	a.at = workbenchEscalateFlagAt
	var ok bool
	if a.asked, ok = db.ParseAgentStateStamp(a.at); !ok {
		return a, fmt.Errorf("--at %q is not a chat_question_at stamp", briefClip(a.at, 40))
	}
	switch a.reason = workbenchEscalateFlagReason; a.reason {
	case escalateReasonTimeout, escalateReasonLeft, escalateReasonAway:
	default:
		return a, fmt.Errorf("--reason must be timeout, left or away, not %q", briefClip(a.reason, 20))
	}
	return a, nil
}

// errEscalateOpenCap is open_cap's fixed text (spec Part 5.3).
var errEscalateOpenCap = errors.New("too many open asks")

// runEscalateQuestion parses, opens the database (migrating it, as every
// writer CLI) and raises the question.
func runEscalateQuestion(cmd *cobra.Command, positional []string) escalateResult {
	a, err := parseEscalateArgs(cmd, positional)
	if err != nil {
		return escalateFailure(escalateErrBadArgs, err)
	}
	cfg, err := askGuardConfig()
	if err != nil {
		return escalateFailure(escalateErrInternal, fmt.Errorf("loading config: %w", err))
	}
	database, err := db.Open(cfg.DBPath())
	switch {
	case db.IsBusy(err):
		return escalateFailure(escalateErrBusy, fmt.Errorf("opening database: %w", err))
	case err != nil:
		return escalateFailure(escalateErrSchema, fmt.Errorf("opening database: %w", err))
	}
	defer database.Close()
	res, err := escalateQuestion(database, a, hookNow())
	switch {
	case err == nil:
		return res
	case db.IsBusy(err):
		return escalateFailure(escalateErrBusy, err)
	case errors.Is(err, db.ErrTooManyOpenAsks):
		return escalateFailure(escalateErrOpenCap, errEscalateOpenCap)
	case errors.Is(err, db.ErrNotInWorkbench), errors.Is(err, db.ErrTerminalSessionNotFound):
		return escalateFailure(escalateErrNotFound, err)
	}
	return escalateFailure(escalateErrInternal, err)
}

// escalateQuestion is Part 5.3's compare-and-take: in one write transaction
// it takes session a.sessionID's chat question only while it is still the
// one stored at a.at and the session waits on that turn end
// (db.TakeChatQuestion), and files it as a question ask of origin chat; at
// the open-ask cap the transaction rolls back, so the question stays.
func escalateQuestion(database *db.DB, a escalateArgs, now time.Time) (escalateResult, error) {
	res := escalateResult{OK: true, Outcome: escalateGone}
	err := database.WithTx(func(tx *sql.Tx) error {
		q, err := database.TakeChatQuestion(tx, a.sessionID, a.workbenchID, a.at)
		if err != nil || q == nil {
			return err
		}
		ask, level, err := escalatedAsk(database, tx, a, *q, now)
		if err != nil {
			return err
		}
		id, _, err := database.InsertOwnerAsk(tx, ask)
		if err != nil {
			return err
		}
		res = escalateResult{OK: true, Outcome: escalateFiled, AskID: id, Level: level}
		return nil
	})
	if err != nil {
		return escalateResult{}, err
	}
	return res, nil
}

// escalatedAsk builds the raised ask (Part 5.3 step 2): one question q1 with
// the stored options, the question clipped to the title on one line, the
// full question then the reason's line as the summary, the session's single
// linked target (none for none or several), origin chat asked at a.at; validated with origin chat, its
// level classified.
func escalatedAsk(database *db.DB, tx *sql.Tx, a escalateArgs, q db.ChatQuestion, now time.Time) (db.OwnerAsk, string, error) {
	opts := make([]asks.Option, 0, len(q.Options))
	for _, o := range q.Options {
		opts = append(opts, asks.Option{Label: o.Label, Recommended: o.Recommended})
	}
	in := asks.Input{
		Kind:      asks.KindQuestion,
		Title:     clipRunes(oneLine(q.Question), escalateTitleRunes),
		Summary:   q.Question + "\n" + escalateReasonLine(a.reason, now.Sub(a.asked)),
		Questions: []asks.Question{{ID: "q1", Question: q.Question, Options: opts}},
	}
	payload, err := asks.Validate(in, asks.OriginChat)
	if err != nil {
		return db.OwnerAsk{}, "", fmt.Errorf("the stored chat question is no valid ask: %w", err)
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return db.OwnerAsk{}, "", fmt.Errorf("encoding the ask: %w", err)
	}
	var target sql.NullInt64
	linked, err := database.SessionLinkedTargetsTx(tx, a.sessionID)
	if err != nil {
		return db.OwnerAsk{}, "", err
	}
	if len(linked) == 1 {
		target = sql.NullInt64{Int64: linked[0], Valid: true}
	}
	level := asks.Level(asks.KindQuestion, payload, asks.OriginChat)
	return db.OwnerAsk{
		WorkbenchID: a.workbenchID,
		SessionID:   sql.NullInt64{Int64: a.sessionID, Valid: true},
		TargetID:    target,
		Kind:        asks.KindQuestion,
		Title:       strings.TrimSpace(in.Title),
		Summary:     in.Summary,
		Payload:     string(body),
		Level:       level,
		Origin:      asks.OriginChat,
		ChatAskedAt: a.at,
	}, level, nil
}

// escalateReasonLine is the summary's last line for reason, waited being how
// long the question has gone unanswered.
func escalateReasonLine(reason string, waited time.Duration) string {
	switch reason {
	case escalateReasonLeft:
		return "Asked in the terminal; you left the session."
	case escalateReasonAway:
		return "Asked in the terminal while you were away."
	}
	return fmt.Sprintf("Asked in the terminal; no answer for %d min.", max(int(waited/time.Minute), 0))
}
