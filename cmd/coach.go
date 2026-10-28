package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/agentlogdb"
	"watchtower/internal/coach"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/fsutil"
	"watchtower/internal/instructions"
	"watchtower/internal/sessionfeed"
)

// coachDefaultDays is the default length of the period `coach status`
// measures; the previous period is the same length right before it.
const (
	coachDefaultDays = 14
	coachMaxDays     = 90
)

var coachCmd = &cobra.Command{
	Use:   "coach",
	Short: "The agent coach: metrics and proposals for the owner's setup",
	Long: "The weekly coach proposes edits to the owner's own setup (session instructions, target procedure,\n" +
		"chat instructions, prompt additions, the Claude allow list, ~/.claude/CLAUDE.md). `status` and\n" +
		"`proposals` read; `accept`, `decline`, `rollback` and `run` are the owner's own decisions and are\n" +
		"refused under an AI agent. --json prints a pinned shape; a failure prints {\"ok\":false,\"error\":…}\n" +
		"and exits non-zero.",
}

var (
	coachFlagJSON      bool
	coachFlagWorkbench int64
	coachFlagStatus    string
	coachFlagStdin     bool
	coachFlagForce     bool
	coachFlagDryRun    bool
	coachFlagDays      int
)

// coachGeneratorFactory is the seam tests override. The prompt carries the
// owner's own text, so the CLI generator is switched to stdin-only mode
// (CHAT-04), like the daemon's instruction miner.
var coachGeneratorFactory = func(cfg *config.Config) digest.Generator {
	gen := cliGenerator(cfg)
	if s, ok := gen.(interface{ SetStdinOnly(bool) }); ok {
		s.SetStdinOnly(true)
	}
	return digest.WithCallTimeout(gen, digest.DaemonAICallTimeout)
}

// coachJudge is the verdict step of `coach run` (a seam for tests).
var coachJudge = coach.Judge

// coachHome is the home folder ~/.claude lives in (a seam for tests).
var coachHome = os.UserHomeDir

func init() {
	statusCmd := &cobra.Command{Use: "status", Short: "Metrics of the last N days (default 14) against the N before",
		Args: cobra.NoArgs, RunE: func(c *cobra.Command, _ []string) error { return coachRun(c, runCoachStatus) }}
	statusCmd.Flags().Int64Var(&coachFlagWorkbench, "workbench", 0, "workbench id (default: every workbench with analytics on)")
	statusCmd.Flags().IntVar(&coachFlagDays, "days", coachDefaultDays, "length of the period in days (1 to 90)")
	proposalsCmd := &cobra.Command{Use: "proposals", Short: "List the coach's proposals",
		Args: cobra.NoArgs, RunE: func(c *cobra.Command, _ []string) error { return coachRun(c, runCoachProposals) }}
	proposalsCmd.Flags().StringVar(&coachFlagStatus, "status", "open", "open, accepted, declined or all")
	acceptCmd := &cobra.Command{Use: "accept <id> [--stdin]", Short: "Apply an open proposal (the owner's edited text on stdin)",
		Args: cobra.ExactArgs(1), RunE: func(c *cobra.Command, a []string) error {
			if err := coachRefuseUnderAgent(c, "accept a coach proposal"); err != nil {
				return err
			}
			return coachRun(c, func(c *cobra.Command, e *coachEnv) (any, error) { return runCoachAccept(c, e, a[0]) })
		}}
	acceptCmd.Flags().BoolVar(&coachFlagStdin, "stdin", false, "read the owner's edited whole text from stdin")
	declineCmd := &cobra.Command{Use: "decline <id>", Short: "Decline an open proposal for good",
		Args: cobra.ExactArgs(1), RunE: func(c *cobra.Command, a []string) error {
			if err := coachRefuseUnderAgent(c, "decline a coach proposal"); err != nil {
				return err
			}
			return coachRun(c, func(c *cobra.Command, e *coachEnv) (any, error) { return runCoachDecline(e, a[0]) })
		}}
	rollbackCmd := &cobra.Command{Use: "rollback <id> [--force]", Short: "Undo an accepted proposal",
		Args: cobra.ExactArgs(1), RunE: func(c *cobra.Command, a []string) error {
			if err := coachRefuseUnderAgent(c, "roll back a coach proposal"); err != nil {
				return err
			}
			return coachRun(c, func(c *cobra.Command, e *coachEnv) (any, error) { return runCoachRollback(e, a[0]) })
		}}
	rollbackCmd.Flags().BoolVar(&coachFlagForce, "force", false, "roll back although the destination changed since the accept")
	runCmd := &cobra.Command{Use: "run [--dry-run]", Short: "Judge, collect and propose now (ignores the weekly stamp)",
		Args: cobra.NoArgs, RunE: func(c *cobra.Command, _ []string) error {
			// run writes proposals (and verdicts): the owner's call, like the weekly phase it replaces.
			if err := coachRefuseUnderAgent(c, "run the coach"); err != nil {
				return err
			}
			return coachRun(c, runCoachNow)
		}}
	runCmd.Flags().BoolVar(&coachFlagDryRun, "dry-run", false, "print the validated proposals, write nothing")
	for _, c := range []*cobra.Command{statusCmd, proposalsCmd, acceptCmd, declineCmd, rollbackCmd, runCmd} {
		c.Flags().BoolVar(&coachFlagJSON, "json", false, "output JSON")
	}
	coachCmd.AddCommand(statusCmd, proposalsCmd, acceptCmd, declineCmd, rollbackCmd, runCmd)
	rootCmd.AddCommand(coachCmd)
}

// coachRefuseUnderAgent is AGENT-07's refusal of an owner verb; with --json
// it prints the failure object like every other coach error.
func coachRefuseUnderAgent(cmd *cobra.Command, action string) error {
	err := refuseUnderAgent(action)
	if err != nil && coachFlagJSON {
		coachWriteFailure(cmd, map[string]any{"ok": false, "error": err.Error()})
	}
	return err
}

// coachWriteFailure prints a --json failure object on stdout and again as one
// line on stderr (its last line), so a caller that only keeps stderr of a
// failed run still reads the reason.
func coachWriteFailure(cmd *cobra.Command, fail map[string]any) {
	_ = writeJSON(cmd.OutOrStdout(), fail)
	if b, err := json.Marshal(fail); err == nil {
		fmt.Fprintln(cmd.ErrOrStderr(), string(b))
	}
}

// coachEnv is what a coach verb works on.
type coachEnv struct {
	cfg *config.Config
	db  *db.DB
	al  *agentlogdb.DB
}

func (e *coachEnv) applier() *coach.Applier {
	home, _ := coachHome() // empty: only a settings.json destination fails, with its own error
	return &coach.Applier{DB: e.db, AgentLog: e.al, Home: home}
}

// coachCodedError carries the machine-readable "code" (and a diff) of a failure object.
type coachCodedError struct {
	code, diff string
	err        error
}

func (e *coachCodedError) Error() string { return e.err.Error() }
func (e *coachCodedError) Unwrap() error { return e.err }

// coachRun opens both databases, runs fn and prints its result; with --json a
// failure is {"ok":false,"error":…} on stdout plus the error exit.
func coachRun(cmd *cobra.Command, fn func(*cobra.Command, *coachEnv) (any, error)) error {
	var res any
	cfg, err := workspaceConfigFromFlags()
	if err == nil {
		var database *db.DB
		var al *agentlogdb.DB
		database, al, _, err = openAgentsDBs(cfg)
		if err == nil {
			defer database.Close()
			defer al.Close()
			res, err = fn(cmd, &coachEnv{cfg: cfg, db: database, al: al})
		}
	}
	if err != nil {
		var ce *coachCodedError
		if errors.As(err, &ce) {
			if !coachFlagJSON && ce.diff != "" {
				fmt.Fprint(cmd.OutOrStdout(), ce.diff)
				return fmt.Errorf("%w; the destination changed since the accept (diff above): pass --force to roll back anyway", err)
			}
		}
		if coachFlagJSON {
			fail := map[string]any{"ok": false, "error": err.Error()}
			if ce != nil {
				fail["code"] = ce.code
				if ce.diff != "" {
					fail["diff"] = ce.diff
				}
			}
			coachWriteFailure(cmd, fail)
		}
		return err
	}
	if coachFlagJSON {
		return writeJSON(cmd.OutOrStdout(), res)
	}
	printCoach(cmd.OutOrStdout(), res)
	return nil
}

// ---- status ----

type coachPeriodJSON struct {
	Since string `json:"since"`
	Until string `json:"until"`
}

type coachMetricJSON struct {
	Value    *float64 `json:"value"`
	N        int      `json:"n"`
	Known    bool     `json:"known"`
	Previous *float64 `json:"previous"`
}

type coachMetricsJSON struct {
	Corrections    coachMetricJSON `json:"corrections"`
	TaskHours      coachMetricJSON `json:"task_hours"`
	TaskCostUSD    coachMetricJSON `json:"task_cost_usd"`
	OwnerLoop      coachMetricJSON `json:"owner_loop"`
	SpecFindings   coachMetricJSON `json:"spec_findings"`
	ReviewComments coachMetricJSON `json:"review_comments"`
}

// coachStatusJSON is the pinned shape of `coach status --json`; keys are only added.
type coachStatusJSON struct {
	OK      bool             `json:"ok"`
	Period  coachPeriodJSON  `json:"period"`
	Metrics coachMetricsJSON `json:"metrics"`
	Open    int              `json:"open"`
	LastRun string           `json:"last_run"`
}

func metricJSON(cur, prev coach.Value) coachMetricJSON {
	m := coachMetricJSON{N: cur.N, Known: cur.Known}
	if cur.Known {
		v := cur.V
		m.Value = &v
	}
	if prev.Known {
		v := prev.V
		m.Previous = &v
	}
	return m
}

func runCoachStatus(_ *cobra.Command, e *coachEnv) (any, error) {
	if coachFlagDays < 1 || coachFlagDays > coachMaxDays {
		return nil, fmt.Errorf("--days must be between 1 and %d, not %d", coachMaxDays, coachFlagDays)
	}
	period := time.Duration(coachFlagDays) * 24 * time.Hour
	now := time.Now().UTC()
	since := now.Add(-period)
	cur, err := coach.Measure(e.db, e.al, coachFlagWorkbench, since, now)
	if err != nil {
		return nil, err
	}
	prev, err := coach.Measure(e.db, e.al, coachFlagWorkbench, since.Add(-period), since)
	if err != nil {
		return nil, err
	}
	open, err := e.db.CountOpenCoachProposals()
	if err != nil {
		return nil, err
	}
	return coachStatusJSON{OK: true,
		Period: coachPeriodJSON{Since: since.Format(time.RFC3339), Until: now.Format(time.RFC3339)},
		Metrics: coachMetricsJSON{
			Corrections:    metricJSON(cur.Corrections, prev.Corrections),
			TaskHours:      metricJSON(cur.TaskHours, prev.TaskHours),
			TaskCostUSD:    metricJSON(cur.TaskCostUSD, prev.TaskCostUSD),
			OwnerLoop:      metricJSON(cur.OwnerLoop, prev.OwnerLoop),
			SpecFindings:   metricJSON(cur.SpecFindings, prev.SpecFindings),
			ReviewComments: metricJSON(cur.ReviewComments, prev.ReviewComments),
		},
		Open: open, LastRun: lastCoachRun(e.cfg)}, nil
}

// lastCoachRun reads the daemon's weekly stamp (<workspace>/last_coach.txt,
// unix seconds); "" when missing or unreadable.
func lastCoachRun(cfg *config.Config) string {
	data, err := os.ReadFile(filepath.Join(cfg.WorkspaceDir(), "last_coach.txt"))
	if err != nil {
		return ""
	}
	unix, err := strconv.ParseInt(strings.TrimSpace(string(data)), 10, 64)
	if err != nil {
		return ""
	}
	return time.Unix(unix, 0).UTC().Format(time.RFC3339)
}

// ---- proposals ----

type coachEvidenceJSON struct {
	Kind string `json:"kind"`
	Ref  string `json:"ref"`
}

// coachProposalJSON is the pinned shape of one proposal; keys are only added.
type coachProposalJSON struct {
	ID           int64               `json:"id"`
	Title        string              `json:"title"`
	Why          string              `json:"why"`
	Destination  string              `json:"destination"`
	WorkbenchID  int64               `json:"workbench_id"`
	PromptID     string              `json:"prompt_id"`
	Kind         string              `json:"kind"`
	Metric       string              `json:"metric"`
	Before       string              `json:"before"`
	After        string              `json:"after"`
	Evidence     []coachEvidenceJSON `json:"evidence"`
	Sources      int                 `json:"sources"`
	Status       string              `json:"status"`
	CreatedAt    string              `json:"created_at"`
	DecidedAt    *string             `json:"decided_at"`
	Baseline     *float64            `json:"baseline"`
	Verdict      string              `json:"verdict"`
	VerdictValue *float64            `json:"verdict_value"`
	VerdictAt    *string             `json:"verdict_at"`
	RevertsID    int64               `json:"reverts_id"`
	// Budget is the destination's rune budget (0: none), the same number Validate uses.
	Budget int `json:"budget"`
}

type coachProposalsJSON struct {
	OK        bool                `json:"ok"`
	Proposals []coachProposalJSON `json:"proposals"`
}

func stampPtr(t time.Time) *string {
	if t.IsZero() {
		return nil
	}
	s := t.UTC().Format(time.RFC3339)
	return &s
}

func proposalJSON(p db.CoachProposal) coachProposalJSON {
	ev := make([]coachEvidenceJSON, 0, len(p.Evidence))
	for _, e := range p.Evidence {
		ev = append(ev, coachEvidenceJSON{Kind: e.Kind, Ref: e.Ref})
	}
	return coachProposalJSON{ID: p.ID, Title: p.Title, Why: p.Why, Destination: p.Destination,
		WorkbenchID: p.WorkbenchID, PromptID: p.PromptID, Kind: p.Kind, Metric: p.Metric,
		Before: p.BeforeText, After: p.AfterText, Evidence: ev, Sources: p.Sources, Status: p.Status,
		CreatedAt: p.CreatedAt.UTC().Format(time.RFC3339), DecidedAt: stampPtr(p.DecidedAt),
		Baseline: p.Baseline, Verdict: p.Verdict, VerdictValue: p.VerdictValue, VerdictAt: stampPtr(p.VerdictAt),
		RevertsID: p.RevertsID, Budget: coach.BudgetOf(p.Destination, p.BeforeText)}
}

func proposalsOf(ps []db.CoachProposal) coachProposalsJSON {
	out := coachProposalsJSON{OK: true, Proposals: make([]coachProposalJSON, 0, len(ps))}
	for _, p := range ps {
		out.Proposals = append(out.Proposals, proposalJSON(p))
	}
	return out
}

func runCoachProposals(_ *cobra.Command, e *coachEnv) (any, error) {
	var statuses []string
	switch coachFlagStatus {
	case "all":
	case "open", "accepted", "declined":
		statuses = []string{coachFlagStatus}
	default:
		return nil, fmt.Errorf("--status must be open, accepted, declined or all, not %q", coachFlagStatus)
	}
	ps, err := e.db.ListCoachProposals(statuses...)
	if err != nil {
		return nil, err
	}
	return proposalsOf(ps), nil
}

// ---- accept, decline, rollback ----

type coachDecisionJSON struct {
	OK     bool   `json:"ok"`
	ID     int64  `json:"id"`
	Status string `json:"status"`
}

func parseCoachID(s string) (int64, error) {
	id, err := strconv.ParseInt(s, 10, 64)
	if err != nil || id <= 0 {
		return 0, fmt.Errorf("%q is not a proposal id", s)
	}
	return id, nil
}

func runCoachAccept(cmd *cobra.Command, e *coachEnv, arg string) (any, error) {
	id, err := parseCoachID(arg)
	if err != nil {
		return nil, err
	}
	edited := ""
	if coachFlagStdin {
		b, err := io.ReadAll(cmd.InOrStdin())
		if err != nil {
			return nil, fmt.Errorf("reading the edited text: %w", err)
		}
		edited = string(b)
		if strings.TrimSpace(edited) == "" {
			// An empty Accept text means "the proposed text": never apply that
			// when the owner meant to pass an edit.
			return nil, errors.New("--stdin read no text: pipe the edited whole text, or accept without --stdin")
		}
	}
	if err := coachConfirm(e, "accept a coach proposal", id, edited); err != nil {
		return nil, err
	}
	if err := e.applier().Accept(id, edited); err != nil {
		return nil, codedCoachErr(err)
	}
	return coachDecisionJSON{OK: true, ID: id, Status: "accepted"}, nil
}

func runCoachDecline(e *coachEnv, arg string) (any, error) {
	id, err := parseCoachID(arg)
	if err != nil {
		return nil, err
	}
	if err := coachConfirm(e, "decline a coach proposal", id, ""); err != nil {
		return nil, err
	}
	if err := e.applier().Decline(id); err != nil {
		return nil, codedCoachErr(err)
	}
	return coachDecisionJSON{OK: true, ID: id, Status: "declined"}, nil
}

func runCoachRollback(e *coachEnv, arg string) (any, error) {
	id, err := parseCoachID(arg)
	if err != nil {
		return nil, err
	}
	if err := coachConfirm(e, "roll back a coach proposal", id, ""); err != nil {
		return nil, err
	}
	diff, err := e.applier().Rollback(id, coachFlagForce)
	if err != nil {
		ce := codedCoachErr(err)
		ce.diff = diff
		return nil, ce
	}
	return coachDecisionJSON{OK: true, ID: id, Status: "rolled_back"}, nil
}

// coachConfirm is AGENT-07's second step for a decision on proposal id (the
// marker refusal ran first, in RunE): the owner confirms it in the running
// Desktop, whose window shows the proposal, its change and, for an edited
// accept, the owner's text.
func coachConfirm(e *coachEnv, verb string, id int64, edited string) error {
	return confirmWithOwner(verb, coachConfirmDetail(e, id, edited))
}

func coachConfirmDetail(e *coachEnv, id int64, edited string) string {
	p, err := e.db.GetCoachProposal(id)
	if err != nil {
		return detailUnavailable(err)
	}
	var b strings.Builder
	printCoachProposals(&b, []coachProposalJSON{proposalJSON(p)})
	if edited != "" {
		b.WriteString("With your text:\n" + edited)
	}
	return b.String()
}

func codedCoachErr(err error) *coachCodedError {
	code := "failed"
	switch {
	case errors.Is(err, coach.ErrStale):
		code = "stale"
	case errors.Is(err, coach.ErrChangedSince):
		code = "changed_since"
	case errors.Is(err, db.ErrCoachStateChanged):
		code = "state_changed"
	}
	return &coachCodedError{code: code, err: err}
}

// ---- run ----

type coachRunJSON struct {
	OK        bool                `json:"ok"`
	DryRun    bool                `json:"dry_run"`
	Judged    int                 `json:"judged"`
	Cuts      int                 `json:"cuts"`
	Written   int                 `json:"written"`
	Skipped   string              `json:"skipped"`
	Proposals []coachProposalJSON `json:"proposals"`
	// JudgeError is why judging failed ("" when it did not); proposing goes
	// on, as in the daemon.
	JudgeError string `json:"judge_error"`
}

func coachSessionDirs() sessionfeed.Dirs {
	return sessionfeed.Dirs{ClaudeProjects: filepath.Join(agentsClaudeDir(), "projects"), CodexHome: terminalCodexHome()}
}

// runCoachNow is the weekly pass on demand: judge, collect, propose. It
// ignores the daemon's stamp and does not write it. No plan-limit gate (ask
// #655). --dry-run judges nothing and writes nothing: it prints what the
// model would have proposed.
func runCoachNow(cmd *cobra.Command, e *coachEnv) (any, error) {
	ctx := cmd.Context()
	if ctx == nil {
		ctx = context.Background()
	}
	if !coachFlagDryRun { // a dry run writes nothing: the marker refusal is enough
		detail := "Judge the accepted proposals, read the last weeks' signals and ask the model for new proposals (nothing is applied)."
		if err := confirmWithOwner("run the coach", detail); err != nil {
			return nil, err
		}
		unlock, ok, err := fsutil.TryLockFile(coach.LockPath(e.cfg.WorkspaceDir()))
		if err != nil {
			return nil, fmt.Errorf("locking the coach: %w", err)
		}
		if !ok {
			return nil, &coachCodedError{code: "busy", err: errors.New("the coach is already running")}
		}
		defer unlock()
	}
	now := time.Now()
	res := coachRunJSON{OK: true, DryRun: coachFlagDryRun, Proposals: []coachProposalJSON{}}
	if !coachFlagDryRun {
		judged, cuts, err := coachJudge(e.db, e.al, now)
		if err != nil {
			res.JudgeError = err.Error()
		}
		res.Judged, res.Cuts = judged, cuts
	}
	in, err := coach.Collect(ctx, e.db, e.al, instructions.NewFeedReader(ctx, e.db, coachSessionDirs()), now)
	if err != nil {
		return nil, fmt.Errorf("collecting signals: %w", err)
	}
	p := &coach.Proposer{DB: e.db, Gen: coachGeneratorFactory(e.cfg), Now: func() time.Time { return now },
		Lang: e.cfg.Digest.Language}
	if coachFlagDryRun {
		props, _, err := p.Preview(ctx, in)
		if err != nil {
			return nil, err
		}
		res.Proposals = proposalsOf(props).Proposals
		return res, nil
	}
	n, _, err := p.Run(ctx, in)
	if err != nil {
		return nil, err
	}
	res.Written = n
	open, err := e.db.ListCoachProposals("open")
	if err != nil {
		return nil, err
	}
	res.Proposals = proposalsOf(open).Proposals
	return res, nil
}

// ---- human output ----

func printCoach(w io.Writer, v any) {
	switch r := v.(type) {
	case coachStatusJSON:
		fmt.Fprintf(w, "Period: %s to %s\n", r.Period.Since, r.Period.Until)
		for _, m := range []struct {
			name string
			v    coachMetricJSON
		}{{"corrections per task", r.Metrics.Corrections}, {"agent hours per task", r.Metrics.TaskHours},
			{"cost per task (USD)", r.Metrics.TaskCostUSD}, {"owner share of active time", r.Metrics.OwnerLoop},
			{"findings per spec review", r.Metrics.SpecFindings}, {"comments per diff review", r.Metrics.ReviewComments}} {
			fmt.Fprintf(w, "%s: %s (before: %s, n=%d)\n", m.name, fmtMetric(m.v.Value), fmtMetric(m.v.Previous), m.v.N)
		}
		last := r.LastRun
		if last == "" {
			last = "never"
		}
		fmt.Fprintf(w, "Open proposals: %d. Last run: %s\n", r.Open, last)
	case coachProposalsJSON:
		printCoachProposals(w, r.Proposals)
	case coachDecisionJSON:
		fmt.Fprintf(w, "Proposal %d: %s\n", r.ID, r.Status)
	case coachRunJSON:
		if r.Skipped != "" {
			fmt.Fprintln(w, r.Skipped)
		}
		if r.JudgeError != "" {
			fmt.Fprintf(w, "Judging failed: %s\n", r.JudgeError)
		}
		if r.DryRun {
			fmt.Fprintf(w, "Dry run: %d proposal(s) would be written.\n", len(r.Proposals))
		} else {
			fmt.Fprintf(w, "Judged %d (%d cut), %d new proposal(s).\n", r.Judged, r.Cuts, r.Written)
		}
		printCoachProposals(w, r.Proposals)
	}
}

func fmtMetric(v *float64) string {
	if v == nil {
		return "unknown"
	}
	return strconv.FormatFloat(*v, 'f', 2, 64)
}

func printCoachProposals(w io.Writer, ps []coachProposalJSON) {
	if len(ps) == 0 {
		fmt.Fprintln(w, "No proposals.")
		return
	}
	for _, p := range ps {
		dest := p.Destination
		if p.WorkbenchID != 0 {
			dest += fmt.Sprintf(" (workbench %d)", p.WorkbenchID)
		}
		if p.PromptID != "" {
			dest += " [" + p.PromptID + "]"
		}
		fmt.Fprintf(w, "#%d [%s] %s\n  where: %s\n  why: %s\n", p.ID, p.Status, p.Title, dest, p.Why)
		printCoachChange(w, p.Before, p.After)
	}
}

// printCoachChange prints what the proposal changes: the removed lines with
// "-", the added ones with "+" (the lines both texts share are left out).
func printCoachChange(w io.Writer, before, after string) {
	removed, added := coach.ChangedLines(before, after)
	if len(removed)+len(added) == 0 {
		fmt.Fprintln(w, "  change: none")
		return
	}
	fmt.Fprintln(w, "  change:")
	for _, l := range removed {
		fmt.Fprintf(w, "    - %s\n", l)
	}
	for _, l := range added {
		fmt.Fprintf(w, "    + %s\n", l)
	}
}
