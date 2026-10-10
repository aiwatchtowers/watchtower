package cmd

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
	"watchtower/internal/devpack"
	"watchtower/internal/workbenchcheck"
)

const (
	// stopHookBudget bounds the Stop hook's git work, well under the hook's
	// own timeout (devpack's stopSpec), so a slow repository never holds a
	// turn's end for long. stopHookStdinWait bounds reading the hook input
	// (a run from a terminal has none).
	stopHookBudget    = 8 * time.Second
	stopHookStdinWait = 2 * time.Second
	// hookStdinLimit caps what a hook reads of Claude Code's input.
	hookStdinLimit = 1 << 20
	// stopHookMaxFindings caps the list handed back to the agent.
	stopHookMaxFindings = 20
)

var workbenchCheckCmd = &cobra.Command{
	Use:   "check",
	Short: "Find board drift: targets whose status disagrees with their git branch or pull request",
	Long: "Mechanical, no AI, reads only: compares each target's branch (and, with gh and\n" +
		"network allowed, its pull request) with the folder's default branch —\n" +
		"  merged_but_open    the branch/PR is merged, the target is still open\n" +
		"  done_but_unmerged  done in the last 14 days, branch not merged / PR open, no open target on it\n" +
		"  branch_missing     an in-progress/in-review target's branch exists nowhere\n" +
		"  pr_closed_unmerged the PR was closed without a merge, the target is still open\n" +
		"  stale              an in-progress target with no movement for --stale-days\n" +
		"--stop-hook is the Claude Code Stop hook installed by `integrate claude-code --workbench N`:\n" +
		"it reads the hook input on stdin, runs offline, and asks the agent to fix the board\n" +
		"(once per stop) when git certainly disagrees with it — never for stale or\n" +
		"done_but_unmerged. In a Desktop terminal it also records that the session waits for\n" +
		"you when it lets the turn end. It always exits 0. The check never runs git fetch.",
	// No root schema/config pre-run: in --stop-hook mode a broken config must
	// not fail the hook (the workbench brief precedent); the DB is opened by
	// the command itself.
	PersistentPreRunE:  func(*cobra.Command, []string) error { return nil },
	Args:               cobra.ArbitraryArgs,
	FParseErrWhitelist: cobra.FParseErrWhitelist{UnknownFlags: true},
	RunE:               runWorkbenchCheck,
}

// workbenchCheckLegacy says the hook passed the pre-rename --project: the
// folder is still on its old install (spec 2026-10-02 §5.2).
var workbenchCheckLegacy func() bool

var (
	workbenchCheckFlagWorkbench string
	workbenchCheckFlagJSON      bool
	workbenchCheckFlagStaleDays int
	workbenchCheckFlagNoNetwork bool
	workbenchCheckFlagStopHook  bool
)

func init() {
	workbenchCheckLegacy = addWorkbenchIDFlag(workbenchCheckCmd, &workbenchCheckFlagWorkbench, "workbench id")
	workbenchCheckCmd.Flags().BoolVar(&workbenchCheckFlagJSON, "json", false, "output JSON")
	workbenchCheckCmd.Flags().IntVar(&workbenchCheckFlagStaleDays, "stale-days", int(workbenchcheck.DefaultStaleAfter/(24*time.Hour)),
		"days without movement before an in-progress target counts as stale")
	workbenchCheckCmd.Flags().BoolVar(&workbenchCheckFlagNoNetwork, "no-network", false, "skip pull request states (no gh call)")
	workbenchCheckCmd.Flags().BoolVar(&workbenchCheckFlagStopHook, "stop-hook", false, "run as the Claude Code Stop hook (stdin input, always exit 0)")
	workbenchCmd.AddCommand(workbenchCheckCmd)
}

func runWorkbenchCheck(cmd *cobra.Command, _ []string) error {
	ctx := cmd.Context()
	if ctx == nil {
		ctx = context.Background()
	}
	flagErr := checkWorkbenchIDFlags(cmd)
	legacy := workbenchCheckLegacy()
	if workbenchCheckFlagStopHook {
		if flagErr != nil {
			// The hook still exits 0; the reason goes to its log only.
			fmt.Fprintf(cmd.ErrOrStderr(), "watchtower: board drift check skipped: %v\n", flagErr)
			return nil
		}
		runStopHook(ctx, cmd.InOrStdin(), cmd.OutOrStdout(), cmd.ErrOrStderr(), workbenchCheckFlagWorkbench, vocabularyFor(legacy))
		return nil
	}
	if flagErr != nil {
		return flagErr
	}
	id, err := parseWorkbenchID(strings.TrimSpace(workbenchCheckFlagWorkbench))
	if err != nil {
		return fmt.Errorf("%s: %w", workbenchFlagName(legacy), err)
	}
	if workbenchCheckFlagStaleDays <= 0 {
		return errors.New("--stale-days must be positive")
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	rep, err := checkWorkbench(ctx, database, id, workbenchcheck.Options{
		StaleAfter: time.Duration(workbenchCheckFlagStaleDays) * 24 * time.Hour,
		Network:    !workbenchCheckFlagNoNetwork,
	})
	if err != nil {
		return err
	}
	if workbenchCheckFlagJSON {
		return writeJSON(cmd.OutOrStdout(), rep)
	}
	printCheckReport(cmd.OutOrStdout(), rep)
	return nil
}

// checkWorkbench loads workbench id's board and checks it in the
// workbench's folder; o.Folder is filled in here.
func checkWorkbench(ctx context.Context, database *db.DB, id int64, o workbenchcheck.Options) (workbenchcheck.Report, error) {
	p, err := workbenchWithFolder(database, id)
	if err != nil {
		return workbenchcheck.Report{}, err
	}
	board, err := database.GetWorkbenchBoard(p.ID)
	if err != nil {
		return workbenchcheck.Report{}, fmt.Errorf("loading board: %w", err)
	}
	o.Folder = p.FolderPath
	return workbenchcheck.Check(ctx, p.ID, board, o), nil
}

// workbenchWithFolder loads workbench id and checks that its folder still
// exists.
func workbenchWithFolder(database *db.DB, id int64) (*db.Workbench, error) {
	p, err := database.GetWorkbench(id)
	if err != nil {
		return nil, fmt.Errorf("workbench %d: %w", id, err)
	}
	if _, err := os.Stat(p.FolderPath); err != nil {
		return nil, fmt.Errorf("workbench %d: folder %s is missing (moved or deleted?)", id, p.FolderPath)
	}
	return p, nil
}

func printCheckReport(w io.Writer, rep workbenchcheck.Report) {
	head := fmt.Sprintf("Workbench %d board drift", rep.WorkbenchID)
	if rep.Base != "" {
		head += " (against " + rep.Base + ")"
	}
	fmt.Fprintln(w, head+":")
	switch {
	case len(rep.Findings) > 0:
	case rep.Incomplete:
		fmt.Fprintln(w, "  No drift found in the part checked before time ran out.")
	case rep.Base == "":
		fmt.Fprintln(w, "  Branch checks did not run (see the notes); no other drift.")
	default:
		fmt.Fprintln(w, "  No drift.")
	}
	for _, f := range rep.Findings {
		fmt.Fprintf(w, "  - [%s] %s\n", f.Kind, f.Line())
	}
	for _, n := range rep.Notes {
		fmt.Fprintf(w, "  note: %s\n", n)
	}
}

// stopHookInput is the part of Claude Code's Stop hook input we read.
type stopHookInput struct {
	SessionID      string `json:"session_id"`
	TranscriptPath string `json:"transcript_path"`
	StopHookActive bool   `json:"stop_hook_active"`
	// BackgroundTasks lists what the session runs in the background as the
	// turn ends (board #411).
	BackgroundTasks backgroundTasks `json:"background_tasks"`
}

// backgroundTask is one entry of a hook input's background_tasks; every
// other field is ignored.
type backgroundTask struct{ ID, Type string }

// backgroundTasks is a hook input's background_tasks, decoded tolerantly so
// a malformed field never fails the whole input: absent, null or not an
// array leaves present false (an older Claude Code, or a shape we do not
// know); an array sets it, and an entry that is no object, or whose id or
// type is no string, is kept with those fields empty.
type backgroundTasks struct {
	present bool
	list    []backgroundTask
}

func (b *backgroundTasks) UnmarshalJSON(data []byte) error {
	var raw []json.RawMessage
	if json.Unmarshal(data, &raw) != nil || raw == nil {
		*b = backgroundTasks{}
		return nil //nolint:nilerr // not an array reads as absent, never a failed input
	}
	list := make([]backgroundTask, len(raw))
	for i, entry := range raw {
		var fields map[string]json.RawMessage
		if json.Unmarshal(entry, &fields) != nil {
			continue
		}
		_ = json.Unmarshal(fields["id"], &list[i].ID)
		_ = json.Unmarshal(fields["type"], &list[i].Type)
	}
	*b = backgroundTasks{present: true, list: list}
	return nil
}

// backgroundSubagents counts the in-flight background subagents and
// workflows of tasks, leaving out the entry whose id is except ("" leaves
// out none). Shells, monitors, teammates and every other type never count.
// No status filter: Claude Code drops a finished task from the list rather
// than changing its status (only "running" was observed, spec A.7). ok is
// false when the field was absent, null or not an array.
func backgroundSubagents(tasks backgroundTasks, except string) (n int64, ok bool) {
	if !tasks.present {
		return 0, false
	}
	for _, task := range tasks.list {
		if (task.Type == "subagent" || task.Type == "workflow") && (except == "" || task.ID != except) {
			n++
		}
	}
	return n, true
}

// stopHookOutput blocks the stop and hands reason back to the agent.
type stopHookOutput struct {
	Decision string `json:"decision"`
	Reason   string `json:"reason"`
}

// runStopHook is the Stop hook: stdout stays empty unless the board
// contradicts git. Every failure — bad input, no config, a deleted workbench
// (a leftover hook of an old install), a missing folder, a slow repository,
// even a panic — lets the turn finish with exit 0; one line on stderr names
// a real failure (Claude Code shows it in its hook log, never to the model).
// stop_hook_active means Claude Code is already continuing because a Stop
// hook blocked this stop, so this one never blocks again: the agent gets one
// chance to fix the board, never an endless loop. vocab names the skill the
// folder's install has (the reason points the agent at it).
//
// In a Desktop terminal (the terminal env var set) and a folder with the
// session state hooks, the hook also records "waiting" on the session's row
// whenever it lets the turn end: Claude Code runs an event's hooks in
// parallel, so only the process that decides the block knows whether the
// turn really ended. That write comes after the
// drift output, never changes stdout, and a failure is one stderr line.
func runStopHook(ctx context.Context, stdin io.Reader, stdout, stderr io.Writer, rawID string, vocab vocabulary) {
	defer func() {
		// A panic would exit 2, which for a Stop hook means "block and feed
		// stderr to the model" — the opposite of this hook's contract.
		if r := recover(); r != nil {
			fmt.Fprintf(stderr, "watchtower: board drift check failed: %v\n", r)
		}
	}()
	at := hookNow()
	inCtx, cancelIn := context.WithTimeout(ctx, stopHookStdinWait)
	// The session state's cap: Stop carries last_assistant_message, and a
	// cut-off input would lose the "waiting" write.
	in, err := readHookInputLimit[stopHookInput](inCtx, stdin, sessionStateStdinLimit)
	cancelIn()
	if err != nil {
		if _, inTerminal := os.LookupEnv(terminalSessionEnv); inTerminal && !errors.Is(err, io.EOF) {
			fmt.Fprintf(stderr, "watchtower: session state not recorded: reading the hook input: %v\n", err)
		}
		return
	}
	id, err := strconv.ParseInt(strings.TrimSpace(rawID), 10, 64)
	if err != nil || id <= 0 {
		stopHookInvalidID(stderr, in, rawID, vocab)
		return
	}
	// database is nil until opened; the state write opens its own then.
	var database *db.DB
	defer func() {
		if database != nil {
			database.Close()
		}
	}()
	if !in.StopHookActive {
		// Not under the hook's own budget: db.Open may be applying a migration,
		// which our deadline must never cut off part-way (Claude Code's hook
		// timeout still bounds the whole run).
		if _, database, err = openJiraCmdDB(); err != nil {
			fmt.Fprintf(stderr, "watchtower: board drift check skipped%s: %v\n", stopStateLost(in.SessionID), err)
			return
		}
		turnEndErr := markStopTurnEnd(database, id, in)
		if blocked := stopHookDrift(ctx, stdout, stderr, database, id, vocab); blocked {
			// No state write follows to record it again and report it.
			if turnEndErr != nil {
				fmt.Fprintf(stderr, "watchtower: turn end not recorded: %v\n", turnEndErr)
			}
			return
		}
	}
	recordStopAgentState(stderr, database, id, in, at)
}

// markStopTurnEnd records the turn end before the drift check, which can
// take seconds: a tool result of the ending turn whose async hook starts in
// the meantime then already finds its call before it (board #368). Only a
// folder with the session state hooks gets it (nothing else reads it). Best
// effort: it returns the write's error, which the caller reports only when
// the check blocks the stop — otherwise the state write after the check
// records it again and reports a failure. Outside a Desktop terminal, or
// in a folder without the hooks, it does nothing.
func markStopTurnEnd(database *db.DB, workbenchID int64, in stopHookInput) error {
	rowID, ok, err := terminalSessionRowID()
	if !ok || (err == nil && in.SessionID == "") {
		return nil
	}
	if err != nil {
		return err
	}
	has, err := workbenchHasStateHooks(database, workbenchID)
	if err != nil || !has {
		return err
	}
	return recordStopTurnEnd(database, rowID, workbenchID, in)
}

// recordStopTurnEnd stores the transcript's size as the row's turn end. Read
// first, under the session record's short lock wait: the sync Stop hook
// holds the owner's turn end, and the common case (the end already stored by
// markStopTurnEnd) must not wait for the write lock. A transcript that cannot
// be read leaves the last turn end.
func recordStopTurnEnd(database *db.DB, rowID, workbenchID int64, in stopHookInput) error {
	end, ok := transcriptSize(in.TranscriptPath)
	if !ok {
		return nil
	}
	row, err := database.GetTerminalSession(rowID)
	if errors.Is(err, db.ErrTerminalSessionNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	if row.TurnEnd.Valid && row.TurnEnd.Int64 == end {
		return nil
	}
	if err := database.SetBusyTimeout(sessionRecordBusyTimeout); err != nil {
		return err
	}
	_, err = setTerminalTurnEnd(database, rowID, workbenchID, in.SessionID, end)
	return err
}

// setTerminalTurnEnd is the turn end's write; a seam for tests.
var setTerminalTurnEnd = (*db.DB).SetTerminalTurnEnd

// stopHookDrift runs the drift check and prints the block JSON when git
// certainly disagrees with the board; true when it blocked the stop.
func stopHookDrift(ctx context.Context, stdout, stderr io.Writer, database *db.DB, id int64, vocab vocabulary) bool {
	ctx, cancel := context.WithTimeout(ctx, stopHookBudget)
	defer cancel()
	rep, err := checkWorkbench(ctx, database, id, workbenchcheck.Options{})
	switch {
	case errors.Is(err, db.ErrWorkbenchNotFound):
		return false // a deleted workbench's leftover hook: nothing to say
	case err != nil:
		fmt.Fprintf(stderr, "watchtower: board drift check skipped: %v\n", err)
		return false
	case rep.Incomplete:
		fmt.Fprintf(stderr, "watchtower: board drift check ran out of time after %s; only part of the board was checked\n", stopHookBudget)
	}
	findings := rep.BlockingFindings()
	if len(findings) == 0 {
		return false
	}
	_ = json.NewEncoder(stdout).Encode(stopHookOutput{Decision: "block", Reason: stopHookReason(id, findings, vocab)})
	return true
}

// stopHookInvalidID reports a bad --workbench: the drift check it skips
// (never on the continued turn, which checks nothing) and the state write it
// loses in a Desktop terminal.
func stopHookInvalidID(stderr io.Writer, in stopHookInput, rawID string, vocab vocabulary) {
	flag := workbenchFlagName(vocab.Legacy)
	switch {
	case !in.StopHookActive:
		fmt.Fprintf(stderr, "watchtower: board drift check skipped%s: invalid %s %q\n", stopStateLost(in.SessionID), flag, rawID)
	case stopStateExpected(in.SessionID):
		fmt.Fprintf(stderr, "watchtower: session state not recorded: invalid %s %q\n", flag, rawID)
	}
}

// stopStateLost is the drift-skipped line's suffix when the state write is
// lost with it.
func stopStateLost(sessionID string) string {
	if stopStateExpected(sessionID) {
		return " and session state not recorded"
	}
	return ""
}

// stopStateExpected: the Stop hook would record the session state (a
// Desktop terminal and a payload naming its conversation), so a failure
// before the write says the state was lost too.
func stopStateExpected(sessionID string) bool {
	_, inTerminal := os.LookupEnv(terminalSessionEnv)
	return inTerminal && sessionID != ""
}

// recordStopAgentState records "waiting" for a turn the Stop hook let end.
// Outside a Desktop terminal it does nothing and opens nothing; database is
// the hook's own handle, or nil to open one.
func recordStopAgentState(stderr io.Writer, database *db.DB, workbenchID int64, in stopHookInput, at time.Time) {
	rowID, ok, err := terminalSessionRowID()
	if !ok || (err == nil && in.SessionID == "") {
		return
	}
	if err == nil {
		err = writeStopAgentState(stderr, database, rowID, workbenchID, in, at)
	}
	if err != nil {
		fmt.Fprintf(stderr, "watchtower: session state not recorded: %v\n", err)
	}
}

// writeStopAgentState is recordStopAgentState's write, opening a handle when
// database is nil. Only a folder with the session state hooks gets it:
// without them nothing records "working", so "waiting" would stick after the
// first turn until Repair (board #340). The turn end goes first, also when
// the state write is a repeat (a turn without a prompt over a stored
// "waiting"). It only orders late tool results (board #368, limit (a)): its
// failure is reported on stderr and never costs the state write.
func writeStopAgentState(stderr io.Writer, database *db.DB, rowID, workbenchID int64, in stopHookInput, at time.Time) error {
	if database == nil {
		_, opened, err := openJiraCmdDB()
		if err != nil {
			return err
		}
		defer opened.Close()
		database = opened
	}
	if has, err := workbenchHasStateHooks(database, workbenchID); err != nil || !has {
		return err
	}
	if err := recordStopTurnEnd(database, rowID, workbenchID, in); err != nil {
		fmt.Fprintf(stderr, "watchtower: turn end not recorded: %v\n", err)
	}
	state, onlyFrom, _ := agentStateFor("Stop", "")
	turn := hookTurn{stop: true}
	if n, ok := backgroundSubagents(in.BackgroundTasks, ""); ok && n > 0 {
		turn.background = sql.NullInt64{Int64: n, Valid: true}
	}
	return recordAgentState(database, rowID, workbenchID, in.SessionID, state, onlyFrom, nil, false, at, turn)
}

// workbenchHasStateHooks reports whether workbench id's folder has its core
// session state hooks (devpack.HasCoreStateHooks): a folder installed before
// the SubagentStop entry keeps its Stop state and run mark until repaired.
// A gone workbench has none, and so does a settings file that cannot be
// read: that is a normal state the Desktop already offers to repair, so the
// hook stays silent about it.
func workbenchHasStateHooks(database *db.DB, id int64) (bool, error) {
	wb, err := database.GetWorkbench(id)
	if errors.Is(err, db.ErrWorkbenchNotFound) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	has, _ := devpack.HasCoreStateHooks(wb.FolderPath, id)
	return has, nil
}

// readHookInput decodes a hook's JSON input from stdin, giving up at ctx's
// deadline (a run from a terminal may never send one).
func readHookInput[T any](ctx context.Context, stdin io.Reader) (T, error) {
	return readHookInputLimit[T](ctx, stdin, hookStdinLimit)
}

// readHookInputLimit is readHookInput reading at most limit bytes.
func readHookInputLimit[T any](ctx context.Context, stdin io.Reader, limit int64) (T, error) {
	type result struct {
		in  T
		err error
	}
	ch := make(chan result, 1)
	go func() {
		var in T
		err := json.NewDecoder(io.LimitReader(stdin, limit)).Decode(&in)
		ch <- result{in, err}
	}()
	select {
	case r := <-ch:
		return r.in, r.err
	case <-ctx.Done():
		var zero T
		return zero, ctx.Err()
	}
}

func stopHookReason(id int64, findings []workbenchcheck.Finding, vocab vocabulary) string {
	lines := []string{fmt.Sprintf("Watchtower: the board of workbench %d disagrees with git. Fix the board before you finish "+
		"(update_target; the %s skill's \"Keeping the board in step with git\"):", id, vocab.SkillName)}
	for i, f := range findings {
		if i == stopHookMaxFindings {
			lines = append(lines, fmt.Sprintf("- … %d more (watchtower workbench check --workbench %d)", len(findings)-i, id))
			break
		}
		lines = append(lines, "- "+briefClip(f.Line(), 400))
	}
	return strings.Join(lines, "\n")
}
