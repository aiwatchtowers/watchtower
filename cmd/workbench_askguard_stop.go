package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/devpack"
	"watchtower/internal/digest"
)

// The Stop ask guard (spec 2026-10-10-owner-asks-v2 Part 4, PROJ-13): a Stop
// command hook that classifies the turn's final message with the light-tier
// model and decides by a fixed table, with the owner's presence.

// askGuardSource is the classifier call's source tag: TierForSource routes
// it to the light tier on every provider.
const askGuardSource = "workbench.ask_guard"

// askGuardModelBudget bounds the model call inside the hook's 30 s timeout;
// on the budget the turn ends (pass). A var for tests.
var askGuardModelBudget = 20 * time.Second

// askGuardRecordBusyTimeout bounds the record or clear, which runs after the
// model call and its reads (askGuardBusyTimeout).
const askGuardRecordBusyTimeout = time.Second

// askGuardMessageLimit is how much of the turn's final message the
// classifier reads: its last 32 KiB, where a closing request sits.
const askGuardMessageLimit = 32 << 10

// askGuardCutMarker opens a message cut to its last askGuardMessageLimit
// bytes.
const askGuardCutMarker = "[earlier text cut]\n"

// Clip bounds of the model's question and option labels (Part 4.3).
const (
	askGuardQuestionRunes = 300
	askGuardLabelRunes    = 40
	askGuardMaxOptions    = 4
)

// The fixed reasons a blocked Stop hands the agent (Part 4.5); the model
// never writes them.
const (
	askGuardReasonFull = "You asked the owner for a review, a check or several decisions in plain text. File it with " +
		"ask_owner (kind review, check or question with up to 4 questions), name it as 'ask #<id>' in your text, then stop."
	askGuardReasonAway = "The owner is not in this session, so a question in the terminal would wait unseen. File it " +
		"with ask_owner (kind question; one decision with 2-3 short options shows as a one-tap Quick ask), name it as " +
		"'ask #<id>' in your text, then stop."
	askGuardReasonFinish = "Your work in this session looks complete. Call finish_session with a 2-3 line summary for " +
		"the owner (what was done, the PRs, what is left on them), say 'session finished', then stop."
	askGuardReasonFinishAsk = "Your work in this session looks complete, and your message still asks the owner " +
		"something. File the open question with ask_owner and name it as 'ask #<id>', then call finish_session with a " +
		"2-3 line summary for the owner (what was done, the PRs, what is left on them), say 'session finished', then stop."
)

// The classifier's request values.
const (
	askRequestNone = "none"
	askRequestChat = "chat"
	askRequestFull = "full"
)

// askGuardStopInput is the part of Claude Code's Stop hook input the guard
// reads.
type askGuardStopInput struct {
	SessionID            string `json:"session_id"`
	StopHookActive       bool   `json:"stop_hook_active"`
	LastAssistantMessage string `json:"last_assistant_message"`
}

// askGuardVerdict is the classifier's answer after normalisation (Part 4.3).
type askGuardVerdict struct {
	Request            string
	NamesAsk           bool
	RequestOutsideAsk  bool
	ClosingSummary     bool
	CompleteUnreported bool
	Question           string
	Options            []db.ChatQuestionOption
}

// covered: the request is the named ask itself.
func (v askGuardVerdict) covered() bool { return v.NamesAsk && !v.RequestOutsideAsk }

// askGuardModelOutput is the JSON object the classifier returns.
type askGuardModelOutput struct {
	Request            *string `json:"request"`
	NamesAsk           bool    `json:"names_ask"`
	RequestOutsideAsk  bool    `json:"request_outside_ask"`
	ClosingSummary     bool    `json:"closing_summary"`
	CompleteUnreported bool    `json:"complete_unreported"`
	Question           string  `json:"question"`
	Options            []struct {
		Label       string `json:"label"`
		Recommended bool   `json:"recommended"`
	} `json:"options"`
}

// decodeAskGuardVerdict reads the model's reply: one JSON object (a code
// fence around it is tolerated) with a string request; anything else is a
// malformed reply, never a verdict.
func decodeAskGuardVerdict(reply string) (askGuardVerdict, error) {
	s := strings.TrimSpace(reply)
	if body, ok := strings.CutPrefix(s, "```"); ok {
		body = strings.TrimPrefix(body, "json")
		s = strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(body), "```"))
	}
	var out askGuardModelOutput
	if err := json.Unmarshal([]byte(s), &out); err != nil {
		return askGuardVerdict{}, fmt.Errorf("the classifier reply is not the verdict object: %w", err)
	}
	if out.Request == nil {
		return askGuardVerdict{}, errors.New("the classifier reply has no request")
	}
	v := askGuardVerdict{
		Request:            *out.Request,
		NamesAsk:           out.NamesAsk,
		RequestOutsideAsk:  out.RequestOutsideAsk,
		ClosingSummary:     out.ClosingSummary,
		CompleteUnreported: out.CompleteUnreported,
		Question:           out.Question,
	}
	for _, o := range out.Options {
		v.Options = append(v.Options, db.ChatQuestionOption{Label: o.Label, Recommended: o.Recommended})
	}
	return normaliseAskGuardVerdict(v), nil
}

// normaliseAskGuardVerdict applies Part 4.3 (F3) in order: the question on
// one line, clipped; each label trimmed, clipped, empty ones dropped;
// duplicates (case-folded, after the clip) dropped, keeping the first and
// OR-ing its recommended; the first 4 kept; a single remaining option
// becomes none. An unknown request reads as none, and a chat request whose
// question is empty as full. The options therefore number 0 or 2-4.
func normaliseAskGuardVerdict(v askGuardVerdict) askGuardVerdict {
	v.Question = clipRunes(oneLine(v.Question), askGuardQuestionRunes)
	var opts []db.ChatQuestionOption
	seen := map[string]int{}
	for _, o := range v.Options {
		label := clipRunes(oneLine(o.Label), askGuardLabelRunes)
		if label == "" {
			continue
		}
		key := strings.ToLower(label)
		if i, dup := seen[key]; dup {
			opts[i].Recommended = opts[i].Recommended || o.Recommended
			continue
		}
		seen[key] = len(opts)
		opts = append(opts, db.ChatQuestionOption{Label: label, Recommended: o.Recommended})
	}
	if len(opts) > askGuardMaxOptions {
		opts = opts[:askGuardMaxOptions]
	}
	if len(opts) == 1 {
		opts = nil
	}
	v.Options = opts
	switch v.Request {
	case askRequestChat:
		if v.Question == "" {
			v.Request = askRequestFull
		}
	case askRequestFull:
	default:
		v.Request = askRequestNone
	}
	return v
}

// askGuardMessageTail keeps message's last askGuardMessageLimit bytes, cut on
// a rune boundary and opened by askGuardCutMarker; a shorter message is kept
// whole.
func askGuardMessageTail(message string) string {
	if len(message) <= askGuardMessageLimit {
		return message
	}
	tail := message[len(message)-askGuardMessageLimit:]
	for tail != "" && !utf8.RuneStart(tail[0]) {
		tail = tail[1:]
	}
	return askGuardCutMarker + tail
}

// oneLine collapses every run of whitespace, line breaks included, to one
// space.
func oneLine(s string) string { return strings.Join(strings.Fields(s), " ") }

// clipRunes cuts s to at most n runes.
func clipRunes(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return strings.TrimSpace(string([]rune(s)[:n]))
}

// askGuardResolution is what the guard knows about the session after the
// model call (Part 4.6).
type askGuardResolution struct {
	// Matched: the hook runs in a Desktop terminal row of this workbench
	// running the payload's conversation, so its chat question can be
	// cleared.
	Matched bool
	// Recordable: Matched, and the folder has the core state hooks.
	Recordable bool
	// Present: the owner is in this session. False on any database failure.
	Present bool
}

// stopDecision is decideStop's outcome: Reason is the block reason ("" =
// pass); Record asks to record the verdict's question; Clear asks to clear
// the session's older question.
type stopDecision struct {
	Reason string
	Record bool
	Clear  bool
}

// decideStop is the Part 4.5 table. verdict nil is a model failure (pass,
// nothing recorded or cleared); empty is an empty message (pass, then the
// clear). Two phases, the first failure winning: the request phase (a named
// ask covers only itself; a full request is sent back; a chat request is a
// candidate only with the owner present and a recordable session, otherwise
// sent back), then the finish phase (a complete message that did not report
// finish_session is sent back, with the candidate R-finish-ask and nothing
// recorded). On stop_hook_active nothing is ever sent back, and a chat
// request is recorded whatever the presence. Every outcome that records no
// question clears the older one (4.2 step 6).
func decideStop(stopHookActive, empty bool, verdict *askGuardVerdict, r askGuardResolution) stopDecision {
	switch {
	case empty:
		return stopDecision{Clear: true}
	case verdict == nil:
		return stopDecision{}
	case stopHookActive:
		if verdict.chatAsk() && r.Recordable {
			return stopDecision{Record: true}
		}
		return stopDecision{Clear: true}
	}
	reason, candidate := stopRequestPhase(*verdict, r)
	if reason != "" {
		return stopDecision{Reason: reason, Clear: true}
	}
	return stopFinishPhase(*verdict, candidate)
}

// chatAsk: a chat request that is neither the named ask itself nor a closing
// summary's list.
func (v askGuardVerdict) chatAsk() bool {
	return v.Request == askRequestChat && !v.covered() && !v.ClosingSummary
}

// stopRequestPhase is rows 3-6: the block reason ("" = no request failure)
// and whether the message is a Chat candidate.
func stopRequestPhase(v askGuardVerdict, r askGuardResolution) (reason string, candidate bool) {
	switch {
	case v.ClosingSummary || v.covered():
		return "", false
	case v.Request == askRequestFull:
		return askGuardReasonFull, false
	case v.Request != askRequestChat:
		return "", false
	case r.Present && r.Recordable:
		return "", true
	}
	return askGuardReasonAway, false
}

// stopFinishPhase is rows 7-10.
func stopFinishPhase(v askGuardVerdict, candidate bool) stopDecision {
	switch {
	case v.CompleteUnreported && candidate:
		return stopDecision{Reason: askGuardReasonFinishAsk, Clear: true}
	case v.CompleteUnreported:
		return stopDecision{Reason: askGuardReasonFinish, Clear: true}
	case candidate:
		return stopDecision{Record: true}
	}
	return stopDecision{Clear: true}
}

// askGuardGeneratorFactory builds the classifier's model client; the seam
// tests replace (no test calls a real model). The child gets its own process
// group (killed whole on the budget or a signal) and never the Desktop
// terminal's session variable, and the message travels on stdin.
var askGuardGeneratorFactory = func(cfg *config.Config) digest.Generator {
	gen := cliGenerator(cfg)
	if s, ok := gen.(interface{ SetStdinOnly(bool) }); ok {
		s.SetStdinOnly(true)
	}
	if s, ok := gen.(interface{ SetIsolatedChild(...string) }); ok {
		s.SetIsolatedChild(terminalSessionEnv)
	}
	return gen
}

// classifyAskGuard asks the light-tier model for the verdict on message,
// within askGuardModelBudget. The system prompt is the embedded v4 text, not
// a prompt-store entry: PROJ-13 pins it (a documented exception to the
// DB-backed prompts rule, docs/features/workbench.md).
func classifyAskGuard(ctx context.Context, gen digest.Generator, message string) (askGuardVerdict, error) {
	ctx, cancel := context.WithTimeout(ctx, askGuardModelBudget)
	defer cancel()
	reply, _, _, err := gen.Generate(digest.WithSource(ctx, askGuardSource), devpack.AskGuardClassifier, message, "")
	if err != nil {
		return askGuardVerdict{}, fmt.Errorf("the classifier call failed: %w", err)
	}
	return decodeAskGuardVerdict(reply)
}

// runAskGuardStop is `workbench ask-guard --workbench N --stop`. Its stdout
// is Claude Code's decision: nothing (the turn ends) or one block JSON, and
// it always exits 0. An input or model failure, a bad id, a broken config or
// a panic prints nothing on stdout (a real failure is one stderr line, which
// Claude Code keeps in its hook log); a database failure reads as the owner
// being away. SIGINT, SIGTERM (Claude Code's hook timeout) and SIGHUP (its
// terminal gone) cancel the model call, whose process group is killed and
// reaped before the hook returns; a signal at any point before the output
// writes nothing more and prints nothing on stdout.
func runAskGuardStop(parent context.Context, stdin io.Reader, stdout, stderr io.Writer, rawID string) {
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(stderr, "watchtower: ask guard skipped: %v\n", r)
		}
	}()
	ctx, stop := signal.NotifyContext(parent, os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer stop()
	at := hookNow().Truncate(time.Millisecond)
	in, workbenchID, cfg, ok := askGuardStopSetup(ctx, stdin, stderr, rawID)
	if !ok {
		return
	}
	rowID, inSession := askGuardSessionRow(stderr, in.SessionID)
	if in.StopHookActive && !inSession {
		return // a continued turn with nothing to record or clear: no model call
	}
	empty := strings.TrimSpace(in.LastAssistantMessage) == ""
	verdict, ok := askGuardVerdictFor(ctx, stderr, cfg, in, empty)
	if !ok || askGuardCancelled(ctx, stderr) {
		return
	}

	g := openAskGuardSession(stderr, cfg.DBPath(), workbenchID, in.SessionID, rowID, inSession)
	defer g.close()
	r, gone := g.resolution(stderr, hookNow())
	if gone {
		return // a deleted workbench's leftover hook: nothing to say
	}
	d := decideStop(in.StopHookActive, empty, verdict, r)
	if askGuardCancelled(ctx, stderr) {
		return
	}
	reason := g.apply(stderr, d, verdict, at, in.StopHookActive)
	if askGuardCancelled(ctx, stderr) || reason == "" {
		return
	}
	_ = json.NewEncoder(stdout).Encode(stopHookOutput{Decision: "block", Reason: reason})
}

// askGuardVerdictFor classifies the Stop's message (nil verdict for an
// empty one, which calls no model); false after a model failure, reported in
// one stderr line.
func askGuardVerdictFor(ctx context.Context, stderr io.Writer, cfg *config.Config, in askGuardStopInput, empty bool) (*askGuardVerdict, bool) {
	if empty {
		return nil, true
	}
	v, err := classifyAskGuard(ctx, askGuardGeneratorFactory(cfg), askGuardMessageTail(in.LastAssistantMessage))
	if err != nil {
		fmt.Fprintf(stderr, "watchtower: ask guard skipped: %v\n", err)
		return nil, false
	}
	return &v, true
}

// askGuardCancelled reports a signal that cancelled the hook, in one stderr
// line: the turn ends, and nothing more is written or printed.
func askGuardCancelled(ctx context.Context, stderr io.Writer) bool {
	if ctx.Err() == nil {
		return false
	}
	fmt.Fprintln(stderr, "watchtower: ask guard skipped: cancelled")
	return true
}

// askGuardStopSetup reads the hook input (at most askGuardInputWait), the
// workbench id and the config; false when any of them fails, which ends the
// turn (a config failure is one stderr line; a bad input or id is silent).
func askGuardStopSetup(ctx context.Context, stdin io.Reader, stderr io.Writer, rawID string) (askGuardStopInput, int64, *config.Config, bool) {
	inCtx, cancel := context.WithTimeout(ctx, askGuardInputWait)
	in, err := readHookInputLimit[askGuardStopInput](inCtx, stdin, sessionStateStdinLimit)
	cancel()
	if err != nil {
		return in, 0, nil, false
	}
	workbenchID, err := strconv.ParseInt(strings.TrimSpace(rawID), 10, 64)
	if err != nil || workbenchID <= 0 {
		return in, 0, nil, false
	}
	cfg, err := askGuardConfig()
	if err != nil {
		fmt.Fprintf(stderr, "watchtower: ask guard skipped: %v\n", err)
		return in, 0, nil, false
	}
	return in, workbenchID, cfg, true
}

// askGuardConfig loads the config for the active workspace (or --workspace).
func askGuardConfig() (*config.Config, error) {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return nil, err
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	if err := cfg.ValidateWorkspace(); err != nil {
		return nil, err
	}
	return cfg, nil
}

// askGuardSession is the guard's handle on its session row: rowID, of
// workbench workbenchID, running conversation claudeID. database is nil when
// the hook runs outside a Desktop terminal, or opening the database or its
// schema check failed: nothing is read or written then. readFailed is a read
// failure after that (the owner reads as away): it blocks the record only,
// so a matched session's older question is still cleared (4.2 step 6).
type askGuardSession struct {
	database           *db.DB
	readFailed         bool
	rowID, workbenchID int64
	claudeID           string
	matched            bool
}

// askGuardSessionRow is the Desktop terminal row the hook runs in; false
// outside one, without the payload's conversation id, or with an unreadable
// variable (one stderr line: the owner reads as away).
func askGuardSessionRow(stderr io.Writer, claudeID string) (int64, bool) {
	rowID, ok, err := terminalSessionRowID()
	if err != nil {
		fmt.Fprintf(stderr, "watchtower: ask guard reads the owner as away: %v\n", err)
		return 0, false
	}
	return rowID, ok && claudeID != ""
}

// openAskGuardSession opens the database (never creating or migrating it,
// reads under askGuardBusyTimeout) when the hook runs in Desktop terminal
// row rowID (inSession), and checks the columns the guard needs by schema
// lookup. A failure is one stderr line and reads as absent.
func openAskGuardSession(stderr io.Writer, dbPath string, workbenchID int64, claudeID string, rowID int64, inSession bool) *askGuardSession {
	g := &askGuardSession{workbenchID: workbenchID, claudeID: claudeID, rowID: rowID}
	if !inSession {
		return g
	}
	database, err := db.OpenExistingRW(dbPath, askGuardBusyTimeout)
	if err == nil {
		err = askGuardSchemaReady(database)
		if err != nil {
			database.Close()
		}
	}
	if err != nil {
		fmt.Fprintf(stderr, "watchtower: ask guard reads the owner as away: %v\n", err)
		return g
	}
	g.database = database
	return g
}

// askGuardSchemaReady checks the chat question columns and owner_presence
// exist (a crossed migration line is possible, so never by goose version).
func askGuardSchemaReady(database *db.DB) error {
	for _, need := range []struct {
		table string
		cols  []string
	}{
		{"terminal_sessions", []string{"chat_question", "chat_question_at"}},
		{"owner_presence", []string{"session_id", "seen_at"}},
	} {
		has, err := database.HasColumns(need.table, need.cols...)
		if err != nil {
			return err
		}
		if !has {
			return fmt.Errorf("the database lacks %s %v (an older schema)", need.table, need.cols)
		}
	}
	return nil
}

func (g *askGuardSession) close() {
	if g.database != nil {
		g.database.Close()
	}
}

// resolution resolves the session (a claude row of the workbench running
// this conversation: the PROJ-11 nested-session rule), the core state hooks
// and the presence at now. gone: the workbench no longer exists (a leftover
// hook), so the guard has nothing to say. A read failure is one stderr line,
// and the owner reads as away.
func (g *askGuardSession) resolution(stderr io.Writer, now time.Time) (r askGuardResolution, gone bool) {
	if g.database == nil {
		return askGuardResolution{}, false
	}
	r, err := g.resolve(now)
	if errors.Is(err, db.ErrWorkbenchNotFound) {
		return askGuardResolution{}, true
	}
	if err != nil {
		fmt.Fprintf(stderr, "watchtower: ask guard reads the owner as away: %v\n", err)
		g.readFailed = true
		return askGuardResolution{Matched: g.matched}, false
	}
	return r, false
}

func (g *askGuardSession) resolve(now time.Time) (askGuardResolution, error) {
	if _, err := g.database.GetWorkbench(g.workbenchID); err != nil {
		return askGuardResolution{}, err
	}
	row, err := g.database.GetTerminalSession(g.rowID)
	if errors.Is(err, db.ErrTerminalSessionNotFound) {
		return askGuardResolution{}, nil
	}
	if err != nil {
		return askGuardResolution{}, err
	}
	if !row.WorkbenchID.Valid || row.WorkbenchID.Int64 != g.workbenchID || row.Kind != "claude" ||
		row.ClaudeSessionID.String != g.claudeID {
		return askGuardResolution{}, nil
	}
	g.matched = true
	hooks, err := workbenchHasStateHooks(g.database, g.workbenchID)
	if err != nil {
		return askGuardResolution{Matched: true}, err
	}
	present, err := g.database.OwnerPresentIn(g.rowID, now)
	if err != nil {
		return askGuardResolution{Matched: true}, err
	}
	return askGuardResolution{Matched: true, Recordable: hooks, Present: present}, nil
}

// apply carries out d for the Stop of time at and returns the block reason
// to print ("" = pass). A record that fails is a failure of row 9: the
// question is sent back (R-away; never on a continued turn) and the older
// one cleared. A failed clear is one stderr line.
func (g *askGuardSession) apply(stderr io.Writer, d stopDecision, v *askGuardVerdict, at time.Time, stopHookActive bool) string {
	if d.Record {
		if err := g.record(v, at); err != nil {
			fmt.Fprintf(stderr, "watchtower: chat question not recorded: %v\n", err)
			d = stopDecision{Clear: true}
			if !stopHookActive {
				d.Reason = askGuardReasonAway
			}
		}
	}
	if d.Clear {
		if err := g.clear(at); err != nil {
			fmt.Fprintf(stderr, "watchtower: chat question not cleared: %v\n", err)
		}
	}
	return d.Reason
}

// record stores the verdict's question, asked at the Stop's time at.
func (g *askGuardSession) record(v *askGuardVerdict, at time.Time) error {
	if g.database == nil || g.readFailed || !g.matched {
		return errors.New("no session to record on")
	}
	if err := g.database.SetBusyTimeout(askGuardRecordBusyTimeout); err != nil {
		return err
	}
	return g.database.SetChatQuestion(g.rowID, g.workbenchID, g.claudeID,
		db.ChatQuestion{Question: v.Question, Options: v.Options}, at)
}

// clear drops the session's chat question recorded before at; outside a
// matched session, or without a database, there is nothing to clear.
func (g *askGuardSession) clear(at time.Time) error {
	if g.database == nil || !g.matched {
		return nil
	}
	if err := g.database.SetBusyTimeout(askGuardRecordBusyTimeout); err != nil {
		return err
	}
	return g.database.ClearChatQuestionBefore(g.rowID, g.workbenchID, g.claudeID, at)
}
