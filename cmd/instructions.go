package cmd

import (
	"database/sql"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
	"watchtower/internal/instructions"
)

// maxSuggestionsPerScope caps the open suggestions listed per (field, workbench).
const maxSuggestionsPerScope = 5

var instructionsCmd = &cobra.Command{
	Use:   "instructions",
	Short: "Show and edit the owner's agent instructions (session and target procedure)",
	Long: "The owner's own instructions for the agents working in a workbench: session instructions (in\n" +
		"every session brief) and a target procedure (returned when a target goes in_progress), global or\n" +
		"per workbench. Text comes on stdin (--stdin), never on the command line. --json prints a pinned\n" +
		"shape; a failure prints {\"ok\":false,\"error\":…} and exits non-zero.",
}

var (
	instructionsFlagJSON      bool
	instructionsFlagWorkbench int64
	instructionsFlagField     string
	instructionsFlagStdin     bool
	instructionsFlagConv      int64
	instructionsFlagMessage   int64
)

var instructionsShowCmd = &cobra.Command{
	Use:   "show",
	Short: "Print the instructions and the open suggestions",
	Args:  cobra.NoArgs,
	RunE:  func(cmd *cobra.Command, _ []string) error { return instructionsRun(cmd, runInstructionsShow) },
}

var instructionsSetCmd = &cobra.Command{
	Use:   "set --field session|procedure [--workbench N] --stdin",
	Short: "Set one instruction text from stdin (empty clears it)",
	Args:  cobra.NoArgs,
	RunE:  func(cmd *cobra.Command, _ []string) error { return instructionsRun(cmd, runInstructionsSet) },
}

var instructionsRememberCmd = &cobra.Command{
	Use:   "remember --conversation C --message M --stdin",
	Short: "Append the owner's \"remember:\" chat message to the chat instructions (stdin = the whole message)",
	Args:  cobra.NoArgs,
	RunE:  func(cmd *cobra.Command, _ []string) error { return instructionsRun(cmd, runInstructionsRemember) },
}

var instructionsForgetCmd = &cobra.Command{
	Use:   "forget <line-id>",
	Short: "Remove a remembered chat line (the line the ledger row names)",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		return instructionsRun(cmd, func(_ *cobra.Command, d *db.DB) (any, error) {
			return runInstructionsForget(d, args[0])
		})
	},
}

var instructionsPreviewCmd = &cobra.Command{
	Use:   "preview [--workbench N]",
	Short: "Print what the session brief and the target procedure will say",
	Args:  cobra.NoArgs,
	RunE:  func(cmd *cobra.Command, _ []string) error { return instructionsRun(cmd, runInstructionsPreview) },
}

var instructionsSuggestionCmd = &cobra.Command{
	Use:   "suggestion",
	Short: "Add or dismiss a suggested instruction line",
}

var instructionsSuggestionAddCmd = &cobra.Command{
	Use:   "add <id>",
	Short: "Append the suggestion to the instruction it names and mark it added",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		return instructionsRun(cmd, func(cmd *cobra.Command, d *db.DB) (any, error) {
			return runInstructionsSuggestion(d, args[0], true)
		})
	},
}

var instructionsSuggestionDismissCmd = &cobra.Command{
	Use:   "dismiss <id>",
	Short: "Dismiss the suggestion",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		return instructionsRun(cmd, func(cmd *cobra.Command, d *db.DB) (any, error) {
			return runInstructionsSuggestion(d, args[0], false)
		})
	},
}

func init() {
	for _, c := range []*cobra.Command{instructionsShowCmd, instructionsSetCmd, instructionsPreviewCmd,
		instructionsRememberCmd, instructionsForgetCmd, instructionsSuggestionAddCmd, instructionsSuggestionDismissCmd} {
		c.Flags().BoolVar(&instructionsFlagJSON, "json", false, "output JSON")
		c.Flags().Int64Var(&instructionsFlagWorkbench, "workbench", 0, "workbench id (default: the global instructions)")
	}
	instructionsSetCmd.Flags().StringVar(&instructionsFlagField, "field", "", "session, procedure or chat")
	instructionsSetCmd.Flags().BoolVar(&instructionsFlagStdin, "stdin", false, "read the text from stdin")
	instructionsRememberCmd.Flags().BoolVar(&instructionsFlagStdin, "stdin", false, "read the owner's message from stdin")
	instructionsRememberCmd.Flags().Int64Var(&instructionsFlagConv, "conversation", 0, "chat conversation id")
	instructionsRememberCmd.Flags().Int64Var(&instructionsFlagMessage, "message", 0, "chat message id")
	instructionsSuggestionCmd.AddCommand(instructionsSuggestionAddCmd, instructionsSuggestionDismissCmd)
	instructionsCmd.AddCommand(instructionsShowCmd, instructionsSetCmd, instructionsPreviewCmd, instructionsRememberCmd, instructionsForgetCmd, instructionsSuggestionCmd)
	rootCmd.AddCommand(instructionsCmd)
}

// instructionsRun opens the database, runs fn and prints its result; with
// --json a failure is {"ok":false,"error":…} on stdout plus the error exit.
func instructionsRun(cmd *cobra.Command, fn func(*cobra.Command, *db.DB) (any, error)) error {
	var res any
	_, database, err := openJiraCmdDB()
	if err == nil {
		defer database.Close()
		res, err = fn(cmd, database)
	}
	if err != nil {
		if instructionsFlagJSON {
			fail := map[string]any{"ok": false, "error": err.Error()}
			var ce *instructionsCodedError
			if errors.As(err, &ce) {
				fail["code"] = ce.code
			}
			_ = writeJSON(cmd.OutOrStdout(), fail)
		}
		return err
	}
	if instructionsFlagJSON {
		return writeJSON(cmd.OutOrStdout(), res)
	}
	printInstructions(cmd.OutOrStdout(), res)
	return nil
}

// instructionsCodedError carries the machine-readable "code" of a failure
// object (too_long, empty, not_found, not_a_command).
type instructionsCodedError struct {
	code string
	err  error
}

func (e *instructionsCodedError) Error() string { return e.err.Error() }
func (e *instructionsCodedError) Unwrap() error { return e.err }

func codedInstructionsErr(code string, err error) error {
	return &instructionsCodedError{code: code, err: err}
}

type instructionsTextsJSON struct {
	Session   string `json:"session"`
	Procedure string `json:"procedure"`
	Chat      string `json:"chat"`
}

type instructionsChatLineJSON struct {
	ID             int64  `json:"id"`
	Line           string `json:"line"`
	ConversationID *int64 `json:"conversation_id"`
	MessageID      *int64 `json:"message_id"`
	AddedAt        string `json:"added_at"`
}

type instructionsWorkbenchJSON struct {
	ID        int64  `json:"id"`
	Session   string `json:"session"`
	Procedure string `json:"procedure"`
}

type instructionsSuggestionJSON struct {
	ID             int64  `json:"id"`
	Text           string `json:"text"`
	Field          string `json:"field"`
	WorkbenchID    *int64 `json:"workbench_id"`
	SessionCount   int    `json:"session_count"`
	WorkbenchCount int    `json:"workbench_count"`
	FirstSeenAt    string `json:"first_seen_at"`
	LastSeenAt     string `json:"last_seen_at"`
}

// instructionsJSON is the pinned shape of show, set and suggestion add/dismiss;
// the Desktop decodes it. Keys are only added.
type instructionsJSON struct {
	OK          bool                         `json:"ok"`
	Limit       int                          `json:"limit"`
	Global      instructionsTextsJSON        `json:"global"`
	Workbench   *instructionsWorkbenchJSON   `json:"workbench"`
	Suggestions []instructionsSuggestionJSON `json:"suggestions"`
	ChatLines   []instructionsChatLineJSON   `json:"chat_lines"`
}

// instructionsActionJSON is the show shape plus the outcome of remember or
// forget; nil fields are omitted.
type instructionsActionJSON struct {
	instructionsJSON
	Outcome string `json:"outcome,omitempty"`
	LineID  *int64 `json:"line_id,omitempty"`
	Removed *bool  `json:"removed,omitempty"`
}

type instructionsPreviewJSON struct {
	OK        bool   `json:"ok"`
	BriefSlot string `json:"brief_slot"`
	Procedure string `json:"procedure"`
	ChatSlot  string `json:"chat_slot"`
}

func nullInt64Ptr(n sql.NullInt64) *int64 {
	if !n.Valid {
		return nil
	}
	v := n.Int64
	return &v
}

func buildInstructionsJSON(d *db.DB, workbench int64) (instructionsJSON, error) {
	res := instructionsJSON{OK: true, Limit: instructions.MaxRunes, Suggestions: []instructionsSuggestionJSON{}, ChatLines: []instructionsChatLineJSON{}}
	g, err := d.GetOwnerInstructions()
	if err != nil {
		return res, err
	}
	res.Global = instructionsTextsJSON{Session: g.Session, Procedure: g.Procedure, Chat: g.Chat}
	if workbench > 0 {
		w, err := d.GetWorkbenchInstructions(workbench)
		if err != nil {
			return res, err
		}
		res.Workbench = &instructionsWorkbenchJSON{ID: workbench, Session: w.Session, Procedure: w.Procedure}
	}
	lines, err := d.ListPresentChatLines()
	if err != nil {
		return res, err
	}
	for _, l := range lines {
		res.ChatLines = append(res.ChatLines, instructionsChatLineJSON{ID: l.ID, Line: l.Line,
			ConversationID: nullInt64Ptr(l.ConversationID), MessageID: nullInt64Ptr(l.MessageID), AddedAt: l.AddedAt})
	}
	open, err := d.ListOpenInstructionSuggestions()
	if err != nil {
		return res, err
	}
	type scope struct {
		field db.InstructionField
		wb    int64
	}
	seen := map[scope]int{}
	for _, s := range open {
		k := scope{s.Field, s.WorkbenchID.Int64}
		if seen[k] >= maxSuggestionsPerScope {
			continue
		}
		seen[k]++
		item := instructionsSuggestionJSON{ID: s.ID, Text: s.Text, Field: string(s.Field),
			SessionCount: s.SessionCount, WorkbenchCount: s.WorkbenchCount,
			FirstSeenAt: s.FirstSeenAt, LastSeenAt: s.LastSeenAt}
		if s.WorkbenchID.Valid {
			id := s.WorkbenchID.Int64
			item.WorkbenchID = &id
		}
		res.Suggestions = append(res.Suggestions, item)
	}
	return res, nil
}

func runInstructionsShow(_ *cobra.Command, d *db.DB) (any, error) {
	return buildInstructionsJSON(d, instructionsFlagWorkbench)
}

// instructionsFieldLabel names a field in errors so the Desktop shows which
// one is too long.
func instructionsFieldLabel(f db.InstructionField) string {
	switch f {
	case db.InstructionProcedure:
		return "target procedure"
	case db.InstructionChat:
		return "chat instructions"
	case db.InstructionSession:
	}
	return "session instructions"
}

func parseInstructionsField(s string) (db.InstructionField, error) {
	switch f := db.InstructionField(s); f {
	case db.InstructionSession, db.InstructionProcedure, db.InstructionChat:
		return f, nil
	}
	return "", fmt.Errorf("--field must be session, procedure or chat, not %q", s)
}

func runInstructionsSet(cmd *cobra.Command, d *db.DB) (any, error) {
	f, err := parseInstructionsField(instructionsFlagField)
	if err != nil {
		return nil, err
	}
	if f == db.InstructionChat && instructionsFlagWorkbench > 0 {
		return nil, errors.New("chat instructions are global: --field chat cannot be combined with --workbench")
	}
	if !instructionsFlagStdin {
		return nil, errors.New("the text is read from stdin: pass --stdin")
	}
	raw, err := io.ReadAll(cmd.InOrStdin())
	if err != nil {
		return nil, fmt.Errorf("reading stdin: %w", err)
	}
	body := strings.TrimSpace(string(raw))
	if err := instructions.Validate(body); err != nil {
		return nil, codedInstructionsErr("too_long", fmt.Errorf("%s: %w", instructionsFieldLabel(f), err))
	}
	if instructionsFlagWorkbench > 0 {
		err = d.SetWorkbenchInstruction(instructionsFlagWorkbench, f, body)
	} else {
		err = d.SetOwnerInstruction(f, body)
	}
	if err != nil {
		return nil, err
	}
	return buildInstructionsJSON(d, instructionsFlagWorkbench)
}

func runInstructionsRemember(cmd *cobra.Command, d *db.DB) (any, error) {
	if instructionsFlagConv <= 0 || instructionsFlagMessage <= 0 {
		return nil, errors.New("--conversation and --message are required positive ids")
	}
	if !instructionsFlagStdin {
		return nil, errors.New("the message is read from stdin: pass --stdin")
	}
	raw, err := io.ReadAll(cmd.InOrStdin())
	if err != nil {
		return nil, fmt.Errorf("reading stdin: %w", err)
	}
	line, ok := instructions.ParseRemember(string(raw))
	if !ok {
		return nil, codedInstructionsErr("not_a_command", errors.New("the message does not start with a remember prefix"))
	}
	if line == "" {
		return nil, codedInstructionsErr("empty", errors.New("nothing to remember after the prefix"))
	}
	row, outcome, err := d.RememberChatLine(line, instructionsFlagConv, instructionsFlagMessage, time.Now(), instructions.MaxRunes)
	if err != nil {
		return nil, err
	}
	if outcome == db.RememberTooLong {
		return nil, codedInstructionsErr("too_long", fmt.Errorf("%s: adding this line would go over the %d-character limit — shorten the text first",
			instructionsFieldLabel(db.InstructionChat), instructions.MaxRunes))
	}
	base, err := buildInstructionsJSON(d, 0)
	if err != nil {
		return nil, err
	}
	res := instructionsActionJSON{instructionsJSON: base, Outcome: string(outcome)}
	if outcome == db.RememberAdded {
		res.LineID = &row.ID
	}
	return res, nil
}

func runInstructionsForget(d *db.DB, arg string) (any, error) {
	id, err := strconv.ParseInt(arg, 10, 64)
	if err != nil || id <= 0 {
		return nil, fmt.Errorf("invalid line id %q", arg)
	}
	removed, err := d.ForgetChatLine(id, time.Now())
	if errors.Is(err, sql.ErrNoRows) {
		return nil, codedInstructionsErr("not_found", fmt.Errorf("no remembered line %d", id))
	}
	if err != nil {
		return nil, err
	}
	base, err := buildInstructionsJSON(d, 0)
	if err != nil {
		return nil, err
	}
	return instructionsActionJSON{instructionsJSON: base, Removed: &removed}, nil
}

func runInstructionsPreview(_ *cobra.Command, d *db.DB) (any, error) {
	var texts instructions.Texts
	var err error
	if instructionsFlagWorkbench > 0 {
		texts, err = instructions.Load(d, instructionsFlagWorkbench)
	} else {
		texts.Global, err = d.GetOwnerInstructions()
	}
	if err != nil {
		return nil, err
	}
	return instructionsPreviewJSON{OK: true, BriefSlot: instructions.BriefSlot(texts),
		Procedure: instructions.ProcedureFor(texts, "N"), ChatSlot: instructions.ChatSlot(texts.Global)}, nil
}

func runInstructionsSuggestion(d *db.DB, arg string, add bool) (any, error) {
	id, err := strconv.ParseInt(arg, 10, 64)
	if err != nil || id <= 0 {
		return nil, fmt.Errorf("invalid suggestion id %q", arg)
	}
	s, err := d.GetInstructionSuggestion(id)
	if err != nil {
		return nil, err
	}
	if add {
		err = addInstructionSuggestion(d, s, time.Now())
	} else {
		err = d.DecideInstructionSuggestion(id, "dismissed", time.Now())
	}
	if err != nil {
		return nil, err
	}
	wb := instructionsFlagWorkbench
	if wb == 0 && s.WorkbenchID.Valid {
		wb = s.WorkbenchID.Int64
	}
	return buildInstructionsJSON(d, wb)
}

// addInstructionSuggestion appends the suggestion to the current text of its
// field and scope and marks it added in one transaction; over the limit it
// errors and the suggestion stays open.
func addInstructionSuggestion(d *db.DB, s db.InstructionSuggestion, now time.Time) error {
	var cur db.OwnerInstructions
	var err error
	if s.WorkbenchID.Valid {
		cur, err = d.GetWorkbenchInstructions(s.WorkbenchID.Int64)
	} else {
		cur, err = d.GetOwnerInstructions()
	}
	if err != nil {
		return err
	}
	var existing string
	switch s.Field {
	case db.InstructionSession:
		existing = cur.Session
	case db.InstructionProcedure:
		existing = cur.Procedure
	case db.InstructionChat:
		if s.WorkbenchID.Valid { // chat text is global only; never write a workbench text
			return fmt.Errorf("instruction suggestion %d: a chat suggestion cannot belong to a workbench", s.ID)
		}
		existing = cur.Chat
	}
	body, err := instructions.AppendLine(strings.TrimSpace(existing), strings.TrimSpace(s.Text))
	if err != nil { // AppendLine fails only over the limit
		return fmt.Errorf("%s: adding this line would go over the %d-character limit — shorten the text first",
			instructionsFieldLabel(s.Field), instructions.MaxRunes)
	}
	return d.AddInstructionSuggestion(s.ID, body, now)
}

func printInstructions(w io.Writer, res any) {
	switch r := res.(type) {
	case instructionsPreviewJSON:
		fmt.Fprintf(w, "Session brief:\n%s\n\nTarget procedure:\n%s\n\nChat slot:\n%s\n", r.BriefSlot, r.Procedure, r.ChatSlot)
	case instructionsActionJSON:
		printInstructions(w, r.instructionsJSON)
	case instructionsJSON:
		fmt.Fprintf(w, "Global session instructions:\n%s\n\nGlobal target procedure:\n%s\n", r.Global.Session, r.Global.Procedure)
		fmt.Fprintf(w, "\nGlobal chat instructions:\n%s\n", r.Global.Chat)
		if r.Workbench != nil {
			fmt.Fprintf(w, "\nWorkbench %d session instructions:\n%s\n\nWorkbench %d target procedure:\n%s\n",
				r.Workbench.ID, r.Workbench.Session, r.Workbench.ID, r.Workbench.Procedure)
		}
		for _, s := range r.Suggestions {
			fmt.Fprintf(w, "\nSuggestion %d (%s): %s\n", s.ID, s.Field, s.Text)
		}
	}
}
