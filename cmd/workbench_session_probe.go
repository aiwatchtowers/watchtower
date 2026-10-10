package cmd

import (
	"errors"
	"fmt"
	"io"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/claudesession"
	"watchtower/internal/db"
)

// probeStaleAfter is how long a background agent count may go without a
// report before the probe reads the registry (spec §10).
const probeStaleAfter = 30 * time.Minute

// Probe outcomes. busy and waiting leave the row alone; idle, shell,
// unknown and gone end the count.
const (
	probeNotStale = "not_stale" // no counted `waiting`, or its last report is under probeStaleAfter old
	probeBusy     = "busy"      // the registry reads busy: the agents still work
	probeWaiting  = "waiting"   // the registry reads waiting: a prompt or a held message
	probeIdle     = "idle"
	probeShell    = "shell"   // only background shells run, which the count does not track
	probeUnknown  = "unknown" // no status, or one this version does not know
	probeGone     = "gone"    // no registry entry, or its process is dead or its pid reused
)

// probeProcs is the process table the probe checks a registry entry's pid
// against. A var for tests.
var probeProcs claudesession.ProcInfo = claudesession.SystemProcs{}

var workbenchSessionProbeCmd = &cobra.Command{
	Use:   "session-probe",
	Short: "Check a terminal session's stale background agent count against Claude Code's session registry",
	Long: "--session S --workbench N: when the claude row S reads waiting with background subagents\n" +
		"and no report for 30 minutes, reads Claude Code's session registry entry of its\n" +
		"conversation (~/.claude/sessions/<pid>.json, matched by sessionId). busy or\n" +
		"waiting leave the row alone; idle, shell, a missing or unknown status, no entry or a\n" +
		"dead process end the count, unless a report or Stop landed since the probe read the row.\n" +
		"It never starts a count and never changes the row's state. Prints one JSON object\n" +
		"{\"ok\": true, \"outcome\", \"ended\", \"agent_background_at\"} or {\"ok\": false, \"error\"}\n" +
		"and exits 0 either way; an ending outcome also logs one stderr line with the registry's\n" +
		"raw status. Only arguments cobra cannot parse (an unknown flag, a positional argument)\n" +
		"exit non-zero, with no JSON.",
	// No root schema/config pre-run: a broken config answers ok: false like
	// any other failure; the DB is opened by the command.
	PersistentPreRunE: func(*cobra.Command, []string) error { return nil },
	Args:              cobra.NoArgs,
	RunE: func(cmd *cobra.Command, _ []string) error {
		if err := checkWorkbenchIDFlags(cmd); err != nil {
			return writeJSON(cmd.OutOrStdout(), sessionProbeFailure{OK: false, Error: err.Error()})
		}
		res, err := probeSession(workbenchSessionProbeFlagWorkbench, workbenchSessionProbeFlagSession, time.Now(),
			cmd.ErrOrStderr())
		if err != nil {
			return writeJSON(cmd.OutOrStdout(), sessionProbeFailure{OK: false, Error: err.Error()})
		}
		return writeJSON(cmd.OutOrStdout(), res)
	},
}

var (
	workbenchSessionProbeFlagWorkbench int64
	workbenchSessionProbeFlagSession   int64
)

func init() {
	c := workbenchSessionProbeCmd
	addWorkbenchIDFlag(c, &workbenchSessionProbeFlagWorkbench, "workbench id")
	c.Flags().Int64Var(&workbenchSessionProbeFlagSession, "session", 0, "terminal session id")
	workbenchCmd.AddCommand(c)
}

type sessionProbeResult struct {
	OK      bool   `json:"ok"`
	Outcome string `json:"outcome"`
	// Ended: this probe cleared the count. false on an ending outcome means
	// a report or Stop landed after the probe read the row.
	Ended bool `json:"ended"`
	// AgentBackgroundAt is the count's report stamp the probe read; "" when
	// the row has none or it does not parse.
	AgentBackgroundAt string `json:"agent_background_at"`
}

type sessionProbeFailure struct {
	OK    bool   `json:"ok"`
	Error string `json:"error"`
}

// probeSession reads terminal row sessionID of workbench workbenchID and,
// when its background count is stale at now, ends it on the registry's
// verdict. Only EndTerminalBackground writes. An ending outcome logs one line
// to logOut naming the registry's raw status, so a format change that reads
// as unknown or gone leaves a trace.
func probeSession(workbenchID, sessionID int64, now time.Time, logOut io.Writer) (sessionProbeResult, error) {
	if workbenchID <= 0 || sessionID <= 0 {
		return sessionProbeResult{}, errors.New("--workbench and --session take positive ids")
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		return sessionProbeResult{}, err
	}
	defer database.Close()
	row, err := database.GetTerminalSession(sessionID)
	if err != nil {
		return sessionProbeResult{}, err
	}
	if !row.WorkbenchID.Valid || row.WorkbenchID.Int64 != workbenchID {
		return sessionProbeResult{}, fmt.Errorf("terminal session %d is not in workbench %d", sessionID, workbenchID)
	}
	res := sessionProbeResult{OK: true, Outcome: probeNotStale}
	// GetTerminalSession keeps only the parsed time: an unparsable stamp is
	// zero and never reaches the compare-and-clear.
	if row.BackgroundAt.IsZero() {
		return res, nil
	}
	res.AgentBackgroundAt = db.AgentStateStamp(row.BackgroundAt)
	if row.AgentState.String != agentStateWaiting || !row.Background.Valid || row.Background.Int64 <= 0 ||
		now.Sub(row.BackgroundAt) < probeStaleAfter {
		return res, nil
	}
	var rawStatus string
	res.Outcome, rawStatus, err = registryOutcome(row.ClaudeSessionID.String)
	if err != nil {
		return sessionProbeResult{}, err
	}
	if res.Outcome == probeBusy || res.Outcome == probeWaiting {
		return res, nil
	}
	res.Ended, err = database.EndTerminalBackground(row.ID, workbenchID, row.ClaudeSessionID.String, res.AgentBackgroundAt)
	if err != nil {
		return sessionProbeResult{}, err
	}
	_, _ = fmt.Fprintf(logOut, "session-probe: session %d: outcome %s (registry status %q), ended %v\n",
		sessionID, res.Outcome, rawStatus, res.Ended)
	return res, nil
}

// registryOutcome is the registry's verdict on conversation sessionID, with
// the entry's raw status ("" when there is no live entry).
func registryOutcome(sessionID string) (outcome, rawStatus string, err error) {
	// ~/.claude only, never $CLAUDE_CONFIG_DIR: the transcript readers' dual
	// path rule (terminalClaudeDir, ClaudeTranscript.defaultConfigDir).
	configDir := terminalClaudeDir()
	if configDir == "" {
		return "", "", errors.New("claude config dir unknown: no home dir")
	}
	entry, found, err := claudesession.FindSessionWith(configDir, sessionID, probeProcs)
	if err != nil {
		return "", "", fmt.Errorf("reading the claude session registry: %w", err)
	}
	if !found {
		return probeGone, "", nil
	}
	// A process table that cannot answer (a ps timeout or failed fork) is
	// ok: false, never gone: ending a live count cannot be undone.
	alive, err := claudesession.AliveWith(entry, probeProcs)
	if err != nil {
		return "", "", fmt.Errorf("checking claude process %d: %w", entry.PID, err)
	}
	if !alive {
		return probeGone, "", nil
	}
	switch entry.Status {
	case probeBusy, probeWaiting, probeIdle, probeShell:
		return entry.Status, entry.Status, nil
	}
	return probeUnknown, entry.Status, nil
}
