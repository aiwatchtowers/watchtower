package cmd

import (
	"database/sql"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
)

// The owner's instruction for a handed session or target (tuning spec §2,
// #2140): `watchman instruct` sets it, armed or not; `watchman arm
// --instructions-file` sets it with the arming. Both are owner verbs
// (AGENT-07). The twin reads it only for an armed scope and it never lifts
// a hard limit (WATCHMAN-01, -04).

var (
	watchmanInstructFlagSession  int64
	watchmanInstructFlagTarget   int64
	watchmanInstructFlagTextFile string
	watchmanInstructFlagJSON     bool
)

func init() {
	instruct := &cobra.Command{
		Use:   "instruct",
		Short: "Set the instruction Watchman follows for a session or a target",
		Long: "Sets the instruction for --session N or --target N from --text-file F (`-` = stdin), handed to Watchman " +
			"or not: the next hand-over starts from it. An empty file clears it. The text is trimmed and clipped to " +
			"2000 characters; it never lifts a hard limit.",
		Args: cobra.NoArgs,
		RunE: runWatchmanInstruct,
	}
	instruct.Flags().Int64Var(&watchmanInstructFlagSession, "session", 0, "terminal session id")
	instruct.Flags().Int64Var(&watchmanInstructFlagTarget, "target", 0, "target id")
	instruct.Flags().StringVar(&watchmanInstructFlagTextFile, "text-file", "", "file with the instruction (- = stdin; empty = clear)")
	instruct.Flags().BoolVar(&watchmanInstructFlagJSON, "json", false, "print JSON")
	watchmanCmd.AddCommand(instruct)
}

// watchmanInstructJSON is `watchman instruct --json` (keys pinned by
// TestWatchmanInstruct_JSONKeysPinned; the Desktop's sheet reads it).
// Instructions is the stored text after the trim and the clip.
type watchmanInstructJSON struct {
	OK           bool   `json:"ok"`
	Scope        string `json:"scope"`
	RefID        int64  `json:"ref_id"`
	Instructions string `json:"instructions"`
	Error        string `json:"error"`
}

// watchmanInstructionMaxBytes bounds what is read from an instruction file;
// the stored text is clipped to db.WatchmanInstructionMaxRunes anyway.
const watchmanInstructionMaxBytes = 64 << 10

// readWatchmanInstruction reads an instruction file (`-` = stdin), trimmed
// and clipped as it is stored.
func readWatchmanInstruction(cmd *cobra.Command, path string) (string, error) {
	var r io.Reader
	if path == "-" {
		r = cmd.InOrStdin()
	} else {
		f, err := os.Open(path)
		if err != nil {
			return "", fmt.Errorf("reading the instruction: %w", err)
		}
		defer f.Close()
		r = f
	}
	b, err := io.ReadAll(io.LimitReader(r, watchmanInstructionMaxBytes))
	if err != nil {
		return "", fmt.Errorf("reading the instruction: %w", err)
	}
	return db.ClipWatchmanInstruction(string(b)), nil
}

func runWatchmanInstruct(cmd *cobra.Command, _ []string) error {
	out := watchmanInstructJSON{}
	err := watchmanInstruct(cmd, &out)
	out.OK = err == nil
	if err != nil {
		out.Error = err.Error()
	}
	if watchmanInstructFlagJSON {
		if werr := writeJSON(cmd.OutOrStdout(), out); werr != nil && err == nil {
			err = werr
		}
		return err
	}
	if err != nil {
		return err
	}
	if out.Instructions == "" {
		fmt.Fprintf(cmd.OutOrStdout(), "Instruction for %s %d cleared.\n", out.Scope, out.RefID)
	} else {
		fmt.Fprintf(cmd.OutOrStdout(), "Instruction for %s %d saved.\n", out.Scope, out.RefID)
	}
	return nil
}

func watchmanInstruct(cmd *cobra.Command, out *watchmanInstructJSON) error {
	if err := refuseUnderAgent("set a Watchman instruction"); err != nil {
		return err
	}
	if !exactlyOne(watchmanInstructFlagSession != 0, watchmanInstructFlagTarget != 0) {
		return errors.New("name exactly one of --session N or --target N")
	}
	out.Scope, out.RefID = "session", watchmanInstructFlagSession
	if watchmanInstructFlagTarget != 0 {
		out.Scope, out.RefID = "target", watchmanInstructFlagTarget
	}
	if watchmanInstructFlagTextFile == "" {
		return errors.New("--text-file is required (an empty file clears the instruction)")
	}
	text, err := readWatchmanInstruction(cmd, watchmanInstructFlagTextFile)
	if err != nil {
		return err
	}
	cfg, err := workspaceConfigFromFlags()
	if err != nil {
		return err
	}
	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()
	if out.Scope == "session" {
		if _, err := database.GetTerminalSession(out.RefID); errors.Is(err, db.ErrTerminalSessionNotFound) {
			return fmt.Errorf("there is no session %d", out.RefID)
		} else if err != nil {
			return err
		}
	} else if _, err := database.WatchmanTargetWorkbench(out.RefID); errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("there is no target %d", out.RefID)
	} else if err != nil {
		return err
	}
	if err := database.SetWatchmanInstruction(out.Scope, out.RefID, text); err != nil {
		return err
	}
	out.Instructions = text
	return nil
}
