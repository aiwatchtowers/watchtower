package cmd

import (
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
		instructionsSuggestionAddCmd, instructionsSuggestionDismissCmd} {
		c.Flags().BoolVar(&instructionsFlagJSON, "json", false, "output JSON")
		c.Flags().Int64Var(&instructionsFlagWorkbench, "workbench", 0, "workbench id (default: the global instructions)")
	}
	instructionsSetCmd.Flags().StringVar(&instructionsFlagField, "field", "", "session or procedure")
	instructionsSetCmd.Flags().BoolVar(&instructionsFlagStdin, "stdin", false, "read the text from stdin")
	instructionsSuggestionCmd.AddCommand(instructionsSuggestionAddCmd, instructionsSuggestionDismissCmd)
	instructionsCmd.AddCommand(instructionsShowCmd, instructionsSetCmd, instructionsPreviewCmd, instructionsSuggestionCmd)
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
			_ = writeJSON(cmd.OutOrStdout(), map[string]any{"ok": false, "error": err.Error()})
		}
		return err
	}
	if instructionsFlagJSON {
		return writeJSON(cmd.OutOrStdout(), res)
	}
	printInstructions(cmd.OutOrStdout(), res)
	return nil
}

type instructionsTextsJSON struct {
	Session   string `json:"session"`
	Procedure string `json:"procedure"`
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
}

type instructionsPreviewJSON struct {
	OK        bool   `json:"ok"`
	BriefSlot string `json:"brief_slot"`
	Procedure string `json:"procedure"`
}

func buildInstructionsJSON(d *db.DB, workbench int64) (instructionsJSON, error) {
	res := instructionsJSON{OK: true, Limit: instructions.MaxRunes, Suggestions: []instructionsSuggestionJSON{}}
	g, err := d.GetOwnerInstructions()
	if err != nil {
		return res, err
	}
	res.Global = instructionsTextsJSON{Session: g.Session, Procedure: g.Procedure}
	if workbench > 0 {
		w, err := d.GetWorkbenchInstructions(workbench)
		if err != nil {
			return res, err
		}
		res.Workbench = &instructionsWorkbenchJSON{ID: workbench, Session: w.Session, Procedure: w.Procedure}
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
	if f == db.InstructionProcedure {
		return "target procedure"
	}
	return "session instructions"
}

func parseInstructionsField(s string) (db.InstructionField, error) {
	switch f := db.InstructionField(s); f {
	case db.InstructionSession, db.InstructionProcedure:
		return f, nil
	}
	return "", fmt.Errorf("--field must be session or procedure, not %q", s)
}

func runInstructionsSet(cmd *cobra.Command, d *db.DB) (any, error) {
	f, err := parseInstructionsField(instructionsFlagField)
	if err != nil {
		return nil, err
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
		return nil, fmt.Errorf("%s: %w", instructionsFieldLabel(f), err)
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
		Procedure: strings.ReplaceAll(instructions.Procedure(texts, 0), "#0", "#N")}, nil
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
	existing := cur.Session
	if s.Field == db.InstructionProcedure {
		existing = cur.Procedure
	}
	body, err := instructions.AppendLine(strings.TrimSpace(existing), strings.TrimSpace(s.Text))
	if err != nil {
		return fmt.Errorf("%s: %w", instructionsFieldLabel(s.Field), err)
	}
	return d.AddInstructionSuggestion(s.ID, body, now)
}

func printInstructions(w io.Writer, res any) {
	switch r := res.(type) {
	case instructionsPreviewJSON:
		fmt.Fprintf(w, "Session brief:\n%s\n\nTarget procedure:\n%s\n", r.BriefSlot, r.Procedure)
	case instructionsJSON:
		fmt.Fprintf(w, "Global session instructions:\n%s\n\nGlobal target procedure:\n%s\n", r.Global.Session, r.Global.Procedure)
		if r.Workbench != nil {
			fmt.Fprintf(w, "\nWorkbench %d session instructions:\n%s\n\nWorkbench %d target procedure:\n%s\n",
				r.Workbench.ID, r.Workbench.Session, r.Workbench.ID, r.Workbench.Procedure)
		}
		for _, s := range r.Suggestions {
			fmt.Fprintf(w, "\nSuggestion %d (%s): %s\n", s.ID, s.Field, s.Text)
		}
	}
}
