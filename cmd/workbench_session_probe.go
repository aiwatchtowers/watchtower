package cmd

import (
	"errors"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/asks"
	"watchtower/internal/claudesession"
	"watchtower/internal/db"
	"watchtower/internal/sessionagent"
	"watchtower/internal/sessionfeed"
	"watchtower/internal/sessionhost"
)

// probeStaleAfter is how long a background agent count may go without a
// report before the probe reads the registry (spec §10).
const probeStaleAfter = 30 * time.Minute

// Probe outcomes. busy and waiting leave the row alone; idle, shell,
// unknown and gone end the count.
const (
	probeNotStale = "not_stale"               // no counted `waiting`, or its last report is under probeStaleAfter old
	probeBusy     = sessionagent.ProbeBusy    // the registry reads busy: the agents still work
	probeWaiting  = sessionagent.ProbeWaiting // the registry reads waiting: a prompt or a held message
	probeIdle     = sessionagent.ProbeIdle
	probeShell    = sessionagent.ProbeShell   // only background shells run, which the count does not track
	probeUnknown  = sessionagent.ProbeUnknown // no status, or one this version does not know
	probeGone     = sessionagent.ProbeGone    // no registry entry, or its process is dead or its pid reused
	probeFailed   = "failed"                  // a working codex row's last turn failed and this probe stored it (board #959)
	// probeNotWatched: a working codex row's rollout cannot be read
	// (permission, or a compressed one that does not decode) and this probe
	// marked it not watched (spec 2026-11-05 §3.5).
	probeNotWatched = "not_watched"
)

// probeProcs is the process table the probe checks a registry entry's pid
// against. A var for tests.
var probeProcs claudesession.ProcInfo = claudesession.SystemProcs{}

var workbenchSessionProbeCmd = &cobra.Command{
	Use:   "session-probe",
	Short: "Check a terminal session's stale background agent count, or a working codex turn's failure",
	Long: "--session S --workbench N: when the codex row S reads working, reads its rollout and, when\n" +
		"the last turn ended on an error, stores the Error state (outcome \"failed\"; codex has no\n" +
		"StopFailure hook); a rollout it cannot read for its permissions or a compressed one that\n" +
		"does not decode marks the row not watched (outcome \"not_watched\"). This is the app's\n" +
		"bridge for a session the session host does not watch. Otherwise, when the row S reads\n" +
		"waiting with background subagents and no report for 30 minutes, reads Claude Code's\n" +
		"session registry entry of its conversation (~/.claude/sessions/<pid>.json, matched by\n" +
		"sessionId), or a codex row's rollout (its subagents still running). busy or\n" +
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
	c.Flags().Int64Var(&workbenchSessionProbeFlagWorkbench, workbenchFlag, 0, "workbench id")
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

// probeSession reads terminal row sessionID of workbench workbenchID. A
// working codex row gets its rollout read for a failed turn
// (pullCodexTurn, board #959) and nothing else. Otherwise, when its
// background count is stale at now, it ends it on the registry's verdict,
// and only EndTerminalBackground writes. An ending outcome logs one line to
// logOut naming the registry's raw status, so a format change that reads as
// unknown or gone leaves a trace.
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
	if puller, pulls := sessionPuller(row.Kind); pulls && row.AgentState.String == agentStateWorking {
		detail, outcome, err := pullCodexTurn(database, puller, row, now, logOut)
		if err != nil {
			return sessionProbeResult{}, err
		}
		switch outcome {
		case probeFailed:
			res.Outcome = probeFailed
			_, _ = fmt.Fprintf(logOut, "session-probe: session %d: codex turn failed (error %q)\n", sessionID, detail)
		case probeNotWatched:
			res.Outcome = probeNotWatched
			_, _ = fmt.Fprintf(logOut, "session-probe: session %d not watched (%s)\n", sessionID, detail)
		}
		return res, nil
	}
	// GetTerminalSession keeps only the parsed time: an unparsable stamp is
	// zero and never reaches the compare-and-clear.
	if row.BackgroundAt.IsZero() {
		return res, nil
	}
	res.AgentBackgroundAt = db.AgentStateStamp(row.BackgroundAt)
	if !backgroundCountStale(row, now) {
		return res, nil
	}
	var rawStatus string
	res.Outcome, rawStatus, err = sessionOutcome(row, now)
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

// pullCodexTurn is the app's bridge for a working codex row the session
// host does not watch (a local-PTY fallback session, an older host): it
// stores the Error state when the rollout ends its last turn on an error
// (board #959): Codex has no StopFailure hook and its Stop does not fire on
// a failed turn, so the rollout's task_complete is the only signal. The
// write is recordCodexPull's — the session host's watch writes the same
// way, so the two report a turn once — under recordAgentState's guards:
// only over `working`, only for the conversation the row runs, and only
// when the line's time is after the stored state's (a prompt that started a
// new turn wins). The next prompt clears it as it clears Claude's.
//
// When the rollout cannot be read it follows the watch's table (spec
// 2026-11-05 §3.5) without the watch's ticks: a refused read or a
// compressed rollout that does not decode marks the row not watched at
// once; a rollout missing while the row has worked CodexMissingGiveUp, or
// an undecodable tail on a file unchanged for CodexUnreadableGiveUp, marks
// it too. detail is the clipped error of a failure or the class of a
// not-watched mark; outcome is probeFailed or probeNotWatched when this
// probe wrote, "" otherwise.
func pullCodexTurn(database *db.DB, puller sessionagent.Puller, row *db.TerminalSession, now time.Time, logOut io.Writer) (detail, outcome string, err error) {
	sessionID := row.ClaudeSessionID.String
	if sessionID == "" {
		return "", "", nil
	}
	missing := func() (string, string, error) {
		// No stored path yet (before codex's SessionStart) is not armed.
		if row.TranscriptPath.String == "" || row.AgentStateAt.IsZero() ||
			now.Sub(row.AgentStateAt) < sessionhost.CodexMissingGiveUp {
			return "", "", nil
		}
		return markCodexNotWatched(database, row, db.WatchIssueMissing, now)
	}
	path, ok := puller.Locate(terminalCodexHome(), sessionID, row.TranscriptPath.String)
	if !ok {
		return missing()
	}
	turn, err := puller.LastTurn(path)
	var wi *sessionfeed.WatchIssueError
	if errors.As(err, &wi) {
		switch wi.Issue {
		case db.WatchIssuePermission, db.WatchIssueCompressed:
			return markCodexNotWatched(database, row, wi.Issue, now)
		case db.WatchIssueMissing:
			return missing()
		}
		return "", "", err
	}
	if err != nil {
		return "", "", err
	}
	if turn.TailUndecodable {
		if st, statErr := os.Stat(path); statErr == nil && now.Sub(st.ModTime()) >= sessionhost.CodexUnreadableGiveUp {
			return markCodexNotWatched(database, row, db.WatchIssueUnreadable, now)
		}
	}
	if !turn.Failed {
		return "", "", nil
	}
	if turn.At.IsZero() {
		// No time, no ordering against the stored state: never written.
		_, _ = fmt.Fprintf(logOut, "session-probe: session %d: the codex turn failed but its time is unreadable\n", row.ID)
		return "", "", nil
	}
	pull := db.CodexWatchRow{ID: row.ID, WorkbenchID: row.WorkbenchID.Int64, SessionID: sessionID}
	if err := recordCodexPull(database, pull, turn); err != nil {
		return "", "", err
	}
	// recordAgentState does not say whether its guards let the write land:
	// the row read back carries this failure's stamp only when it did.
	after, err := database.GetTerminalSession(row.ID)
	if err != nil {
		return "", "", err
	}
	if after.AgentFailure != nil && after.AgentState.String == agentStateWaiting &&
		after.AgentFailure.At == db.AgentStateStamp(turn.At) {
		return briefClip(asks.OneLine(turn.Error), agentErrorRunes), probeFailed, nil
	}
	return "", "", nil
}

// sessionPuller is the pull signal reader of a stored kind's adapter
// (sessionagent.Adapter.Watch); false for an agent whose hooks report every
// turn end, or no agent.
func sessionPuller(kind string) (sessionagent.Puller, bool) {
	a, ok := sessionagent.Of(kind)
	if !ok || !a.Caps().RolloutWatch() {
		return nil, false
	}
	return a.Watch()
}

// markCodexNotWatched marks row not watched with issue, only while the
// stored row is still the one this probe read (db.SetAgentWatchIssue);
// outcome is probeNotWatched only when this probe wrote it.
func markCodexNotWatched(database *db.DB, row *db.TerminalSession, issue string, now time.Time) (detail, outcome string, err error) {
	seen := db.CodexWatchRow{ID: row.ID, SessionID: row.ClaudeSessionID.String,
		TranscriptPath: row.TranscriptPath.String, StateAt: row.AgentStateAt}
	written, err := database.SetAgentWatchIssue(seen, issue, now)
	if err != nil || !written {
		return "", "", err
	}
	return issue, probeNotWatched, nil
}

// backgroundCountStale says row is waiting on a background count whose last
// report is at least probeStaleAfter old at now: the only rows a probe asks
// the registry about.
func backgroundCountStale(row *db.TerminalSession, now time.Time) bool {
	return row.AgentState.String == agentStateWaiting && row.Background.Valid && row.Background.Int64 > 0 &&
		now.Sub(row.BackgroundAt) >= probeStaleAfter
}

// sessionOutcome is the verdict on row's session from its agent's adapter
// (sessionagent.Adapter.Probe): Claude Code's registry for a claude row, the
// rollout for a codex row (it never reads ~/.claude).
func sessionOutcome(row *db.TerminalSession, now time.Time) (outcome, rawStatus string, err error) {
	a, ok := sessionagent.Of(row.Kind)
	if !ok {
		return probeUnknown, "", nil
	}
	r := sessionagent.Row{SessionID: row.ClaudeSessionID.String, TranscriptPath: row.TranscriptPath.String,
		Home: a.Home(terminalAgentHomes())}
	return a.Probe(r, probeProcs, now)
}
