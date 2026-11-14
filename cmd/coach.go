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
	"watchtower/internal/agentreport"
	"watchtower/internal/coach"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/fsutil"
	"watchtower/internal/instructions"
	"watchtower/internal/sessionfeed"
	"watchtower/internal/workbenchgit"
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
		"`proposals` read; `accept`, `decline`, `rollback`, `dismiss`, `reapply` and `run` are the owner's own\n" +
		"decisions and are refused under an AI agent. A repository or memory change is accepted through a\n" +
		"workbench session the Desktop starts with `brief` (`accept --session`). --json prints a pinned shape;\n" +
		"a failure prints {\"ok\":false,\"error\":…} and exits non-zero.",
}

var (
	coachFlagJSON      bool
	coachFlagWorkbench int64
	coachFlagStatus    string
	coachFlagStdin     bool
	coachFlagForce     bool
	coachFlagDryRun    bool
	coachFlagDays      int
	coachFlagAgent     string
	coachFlagSession   int64
	coachFlagRestart   bool
	coachFlagRevert    bool
)

// coachGeneratorFactory is the seam tests override. The prompt carries the
// owner's own text, which every CLI generator sends on stdin, never argv
// (CHAT-04).
var coachGeneratorFactory = func(cfg *config.Config) digest.Generator {
	return digest.WithCallTimeout(cliGenerator(cfg), digest.DaemonAICallTimeout)
}

// coachJudge is the verdict step of `coach run` (a seam for tests).
var coachJudge = coach.Judge

// coachImportSuggestions is the one-time suggestion fold of `coach run` (a
// seam for tests).
var coachImportSuggestions = coach.ImportSuggestions

// coachHome is the home folder ~/.claude lives in (a seam for tests).
var coachHome = os.UserHomeDir

func init() {
	statusCmd := &cobra.Command{Use: "status", Short: "Metrics of the last N days (default 14) against the N before",
		Args: cobra.NoArgs, RunE: func(c *cobra.Command, _ []string) error { return coachRun(c, runCoachStatus) }}
	statusCmd.Flags().Int64Var(&coachFlagWorkbench, "workbench", 0, "workbench id (default: every workbench with analytics on)")
	statusCmd.Flags().IntVar(&coachFlagDays, "days", coachDefaultDays, "length of the period in days (1 to 90)")
	statusCmd.Flags().StringVar(&coachFlagAgent, "agent", agentreport.AgentAll, "whose sessions the agent metrics count: all, claude or codex")
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
	acceptCmd.Flags().Int64Var(&coachFlagSession, "session", 0,
		"the workbench session the Desktop started for a repository or memory proposal")
	acceptCmd.Flags().BoolVar(&coachFlagRestart, "restart", false,
		"move an accepted session proposal that ended with nothing to measure to the new --session")
	briefCmd := &cobra.Command{Use: "brief <id> [--revert]", Short: "The brief of the session that carries out a proposal",
		Args: cobra.ExactArgs(1), RunE: func(c *cobra.Command, a []string) error {
			// Read-only, but it is the first step of an owner's Accept.
			if err := coachRefuseUnderAgent(c, "brief a coach session"); err != nil {
				return err
			}
			return coachRun(c, func(_ *cobra.Command, e *coachEnv) (any, error) { return runCoachBrief(e, a[0]) })
		}}
	briefCmd.Flags().BoolVar(&coachFlagRevert, "revert", false, "the brief of the session that reverts a merged change")
	dismissCmd := &cobra.Command{Use: "dismiss <id>", Short: "Close an accepted session proposal that ended with nothing to measure",
		Args: cobra.ExactArgs(1), RunE: func(c *cobra.Command, a []string) error {
			if err := coachRefuseUnderAgent(c, "dismiss a coach proposal"); err != nil {
				return err
			}
			return coachRun(c, func(_ *cobra.Command, e *coachEnv) (any, error) { return runCoachDismiss(e, a[0]) })
		}}
	reapplyCmd := &cobra.Command{Use: "reapply <id>", Short: "Turn a setting off again after it was turned back on outside Watchtower",
		Args: cobra.ExactArgs(1), RunE: func(c *cobra.Command, a []string) error {
			if err := coachRefuseUnderAgent(c, "reapply a coach proposal"); err != nil {
				return err
			}
			return coachRun(c, func(_ *cobra.Command, e *coachEnv) (any, error) { return runCoachReapply(e, a[0]) })
		}}
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
	verbs := []*cobra.Command{statusCmd, proposalsCmd, acceptCmd, declineCmd, rollbackCmd, runCmd, briefCmd,
		dismissCmd, reapplyCmd}
	for _, c := range verbs {
		c.Flags().BoolVar(&coachFlagJSON, "json", false, "output JSON")
	}
	coachCmd.AddCommand(verbs...)
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
// line on stderr, so a caller that only keeps stderr of a failed run still
// reads the reason. Execute() prints the error as prose after it, so the object
// is not necessarily the last line: a reader takes the last line that decodes
// as a JSON object.
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
	a := &coach.Applier{DB: e.db, AgentLog: e.al, Home: home, CodexHome: coach.CodexHomeFromEnv(),
		RepoState: coachRepoState(), RepoBranch: coachRepoBranch()}
	if e.cfg != nil {
		a.WorkspaceDir = e.cfg.WorkspaceDir() // a removed MCP server's saved entry (coach-undo)
	}
	return a
}

// coachRepoState is the coach's reader of one workbench repository file's git
// state (coach.Applier.RepoState, coach.Env.RepoState): workbenchgit.PathStatus,
// `git status` only. With coachRepoBranch it is the only cmd code that calls
// workbenchgit for the coach (COACH-01: TestCOACH01_NoGitWrites).
func coachRepoState() func(folder, rel string) (coach.RepoFileState, error) {
	return func(folder, rel string) (coach.RepoFileState, error) {
		ctx, cancel := context.WithTimeout(context.Background(), workbenchGitReadBudget)
		defer cancel()
		st, err := workbenchgit.PathStatus(ctx, workbenchgit.Options{Folder: folder}, rel)
		return coach.RepoFileState{Git: st.Git, Dirty: st.Dirty}, err
	}
}

// coachRepoBranch is the branch checked out in a workbench folder
// (coach.Applier.RepoBranch): workbenchgit.ReadStatus's branch, or
// "detached:<short sha>" for a detached HEAD; a folder that is not a work tree
// or a failed status read is an error.
func coachRepoBranch() func(folder string) (string, error) {
	return func(folder string) (string, error) {
		ctx, cancel := context.WithTimeout(context.Background(), workbenchGitReadBudget)
		defer cancel()
		return coachBranchOf(coachFolderStatus(ctx, folder))
	}
}

// coachFolderStatus is the read-only `git status` of a workbench folder
// (workbenchgit.ReadStatus); a seam so tests count the reads.
var coachFolderStatus = func(ctx context.Context, folder string) workbenchgit.Status {
	return workbenchgit.ReadStatus(ctx, workbenchgit.Options{Folder: folder})
}

// coachBranchOf names the branch of a folder's status: the branch, or
// "detached:<short sha>" for a detached HEAD; not a work tree or a failed
// status read is an error.
func coachBranchOf(st workbenchgit.Status) (string, error) {
	switch {
	case !st.Git:
		return "", coach.ErrRepoNotGit
	case !st.StatusOK:
		return "", errors.New("reading the branch: git status failed")
	case st.Detached:
		return "detached:" + st.Head, nil
	}
	return st.Branch, nil
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
	if coachFlagAgent == "" || !agentreport.ValidAgent(coachFlagAgent) {
		return nil, fmt.Errorf("--agent must be all, claude or codex, not %q", coachFlagAgent)
	}
	period := time.Duration(coachFlagDays) * 24 * time.Hour
	now := time.Now().UTC()
	since := now.Add(-period)
	cur, err := coach.Measure(e.db, e.al, coachFlagWorkbench, since, now, coachFlagAgent)
	if err != nil {
		return nil, err
	}
	prev, err := coach.Measure(e.db, e.al, coachFlagWorkbench, since.Add(-period), since, coachFlagAgent)
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
	// Origin is "weekly" (the coach run) or "chat" (the tuning chat).
	Origin string `json:"origin"`
	// Skill names the skill of a skill destination ("" for the others).
	Skill string `json:"skill"`
	// ConversationID is the tuning chat a chat proposal came from; null for
	// a weekly one and once that conversation is deleted.
	ConversationID *int64 `json:"conversation_id"`
	// WrittenBranch is the branch a workbench repository file was written on
	// at Accept ("" for every other destination).
	WrittenBranch string `json:"written_branch"`
	// MeasureFrom is when the daemon first saw a repository edit committed:
	// its verdict window starts there; null until then and for the others.
	MeasureFrom *string `json:"measure_from"`
	// FolderBranch is only on an open repository proposal: the branch checked
	// out in the workbench folder now ("detached:<short sha>"; "" when it
	// cannot be read). No key on any other row.
	FolderBranch *string `json:"folder_branch,omitempty"`
	// SessionID is the workbench session a repository or memory Accept
	// started (null before, and once the Desktop deleted that session);
	// ViaSession tells such a row from one accepted before sessions and
	// survives that delete; SessionBranch is the session's branch, copied
	// while the session existed. SourceKey is a context proposal's source
	// (plugin id, server name, "connectors", "memory").
	SessionID     *int64 `json:"session_id"`
	SourceKey     string `json:"source_key"`
	ViaSession    bool   `json:"via_session"`
	SessionBranch string `json:"session_branch"`
	// PR is the pull request of a session row's branch as the session report
	// cached it (number, merged|open|closed, and its URL when the agent's own
	// transcript linked it); null when there is none.
	PR      *int64  `json:"pr"`
	PRState *string `json:"pr_state"`
	PRURL   *string `json:"pr_url"`
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
		RevertsID: p.RevertsID, Budget: coach.BudgetOf(p.Destination, p.BeforeText),
		Origin: p.Origin, Skill: p.Skill, ConversationID: p.ConversationID,
		WrittenBranch: p.WrittenBranch, MeasureFrom: stampPtr(p.MeasureFrom),
		SessionID: p.SessionID, SourceKey: p.SourceKey, ViaSession: p.ViaSession, SessionBranch: p.SessionBranch}
}

func proposalsOf(ps []db.CoachProposal) coachProposalsJSON {
	out := coachProposalsJSON{OK: true, Proposals: make([]coachProposalJSON, 0, len(ps))}
	for _, p := range ps {
		out.Proposals = append(out.Proposals, proposalJSON(p))
	}
	return out
}

func runCoachProposals(cmd *cobra.Command, e *coachEnv) (any, error) {
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
	out := proposalsOf(ps)
	withFolderBranches(e.db, out.Proposals)
	withSessionPRs(cmd.ErrOrStderr(), e, ps, out.Proposals)
	return out, nil
}

// withSessionPRs gives each row accepted through a session its PR (out[i]
// is ps[i]'s JSON): found in the session report's cache by session_branch,
// falling back to the live session's branch while that is still empty, so a
// deleted session row never hides a PR the copied branch still finds. The PR
// keys are cosmetic: a failed lookup leaves them null, logs one line on
// logw and never fails the listing.
func withSessionPRs(logw io.Writer, e *coachEnv, ps []db.CoachProposal, out []coachProposalJSON) {
	states := map[int64]map[string]db.PRState{}
	for i, p := range ps {
		pr, err := coachSessionPR(e.db, p, states)
		if err != nil {
			fmt.Fprintf(logw, "coach: proposal %d: reading its PR: %v\n", p.ID, err)
			continue
		}
		if pr == nil {
			continue
		}
		n, state := pr.PRNumber.Int64, pr.State
		out[i].PR, out[i].PRState = &n, &state
		url, err := coachPRURL(e.al, p.WorkbenchID, strings.TrimPrefix(pr.Ref, "branch:"), n)
		if err != nil {
			fmt.Fprintf(logw, "coach: proposal %d: reading its PR link: %v\n", p.ID, err)
			continue
		}
		out[i].PRURL = url
	}
}

// coachSessionPR is the cached PR of a row accepted through a session (nil
// when its branch is unknown or has no PR); states caches each workbench's
// cache rows.
func coachSessionPR(d *db.DB, p db.CoachProposal, states map[int64]map[string]db.PRState) (*db.PRState, error) {
	if !p.ViaSession || p.WorkbenchID == 0 {
		return nil, nil
	}
	branch := p.SessionBranch
	if branch == "" && p.SessionID != nil {
		var err error
		if branch, err = d.CoachSessionBranch(*p.SessionID); err != nil {
			return nil, err
		}
	}
	if branch == "" {
		return nil, nil
	}
	wb, ok := states[p.WorkbenchID]
	if !ok {
		var err error
		if wb, err = d.PRStates(p.WorkbenchID); err != nil {
			return nil, err
		}
		states[p.WorkbenchID] = wb
	}
	s, ok := wb["branch:"+branch]
	if !ok || !s.PRNumber.Valid {
		return nil, nil
	}
	return &s, nil
}

// coachPRURL is pull request n's URL as an agent session of workbench wb on
// branch linked it in its transcript (Claude Code's pr-link record): only an
// https link ending in /pull/<n>, from a session on that branch, so another
// repository's PR with the same number is never taken; nil when there is
// none or more than one such link. Watchtower reads no git remote for it
// (COACH-01).
func coachPRURL(al *agentlogdb.DB, wb int64, branch string, n int64) (*string, error) {
	rows, err := al.Query(`SELECT DISTINCT e.target FROM agent_log_events e
		JOIN agent_log_sessions s ON s.session_uuid = e.session_uuid
		WHERE e.kind = 'pr_link' AND s.project_id = ? AND s.git_branch = ? AND e.target LIKE ?
		LIMIT 2`, wb, branch, "https://%/pull/"+strconv.FormatInt(n, 10))
	if err != nil {
		return nil, fmt.Errorf("reading the PR link: %w", err)
	}
	defer rows.Close()
	var urls []string
	for rows.Next() {
		var u string
		if err := rows.Scan(&u); err != nil {
			return nil, fmt.Errorf("reading the PR link: %w", err)
		}
		urls = append(urls, u)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading the PR link: %w", err)
	}
	if len(urls) != 1 {
		return nil, nil
	}
	return &urls[0], nil
}

// withFolderBranches gives each open repository proposal the branch checked
// out in its workbench folder now: one read-only status per workbench per
// call; "" when the workbench or its folder cannot be read or is not a git
// work tree (spec §4.3a: the open card names the branch it would land on).
func withFolderBranches(d *db.DB, ps []coachProposalJSON) {
	branches := map[int64]string{}
	for i := range ps {
		p := &ps[i]
		if p.Status != "open" {
			continue
		}
		if _, ok := coach.RepoRelPath(p.Destination, p.Skill); !ok {
			continue
		}
		branch, ok := branches[p.WorkbenchID]
		if !ok {
			branch = coachFolderBranch(d, p.WorkbenchID)
			branches[p.WorkbenchID] = branch
		}
		p.FolderBranch = &branch
	}
}

// coachFolderBranch is the branch checked out in a workbench's folder, ""
// when it cannot be read.
func coachFolderBranch(d *db.DB, wb int64) string {
	w, err := d.GetWorkbench(wb)
	if err != nil {
		return ""
	}
	if fi, err := os.Stat(w.FolderPath); err != nil || !fi.IsDir() {
		return ""
	}
	ctx, cancel := context.WithTimeout(context.Background(), workbenchGitReadBudget)
	defer cancel()
	branch, err := coachBranchOf(coachFolderStatus(ctx, w.FolderPath))
	if err != nil {
		return ""
	}
	return branch
}

// ---- accept, decline, rollback ----

type coachDecisionJSON struct {
	OK     bool   `json:"ok"`
	ID     int64  `json:"id"`
	Status string `json:"status"`
}

// coachAcceptJSON is an Accept's decision plus, for a pack overlay, the
// installed copies re-rendered and the copies left because the owner edited
// them by hand (both 0 for any other destination).
type coachAcceptJSON struct {
	coachDecisionJSON
	PackCopiesUpdated int `json:"pack_copies_updated"`
	PackCopiesDrifted int `json:"pack_copies_drifted"`
	// WrittenPath is the workbench repository file written, relative to the
	// workbench folder; "" for every other destination.
	WrittenPath string `json:"written_path"`
	// WrittenBranch is the branch that file was written on ("" for every
	// other destination, or when the branch could not be read).
	WrittenBranch string `json:"written_branch"`
}

// coachAcceptSessionJSON is an Accept (or a Restart) through a workbench
// session: the Accept's keys plus the session recorded.
type coachAcceptSessionJSON struct {
	coachAcceptJSON
	SessionID int64 `json:"session_id"`
}

// coachVerdictJSON is a decision on an accepted row that sets or clears its
// verdict (dismiss, reapply).
type coachVerdictJSON struct {
	coachDecisionJSON
	Verdict string `json:"verdict"`
}

// coachBriefJSON is `coach brief --json`: the session's title and prompt.
type coachBriefJSON struct {
	OK     bool   `json:"ok"`
	ID     int64  `json:"id"`
	Title  string `json:"title"`
	Prompt string `json:"prompt"`
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
	if coachFlagSession != 0 || coachFlagRestart {
		return runCoachAcceptSession(e, id)
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
	res, err := e.applier().Accept(id, edited)
	if err != nil {
		return nil, codedCoachErr(err)
	}
	return coachAcceptJSON{coachDecisionJSON: coachDecisionJSON{OK: true, ID: id, Status: "accepted"},
		PackCopiesUpdated: res.PackCopiesUpdated, PackCopiesDrifted: res.PackCopiesDrifted,
		WrittenPath: res.WrittenPath, WrittenBranch: res.WrittenBranch}, nil
}

// runCoachAcceptSession records the Accept (or with --restart the new
// session) of a repository or memory proposal the Desktop started a session
// for; nothing but the row is written.
func runCoachAcceptSession(e *coachEnv, id int64) (any, error) {
	switch {
	case coachFlagSession < 0:
		return nil, fmt.Errorf("--session must be a session id, not %d", coachFlagSession)
	case coachFlagSession == 0:
		return nil, errors.New("--restart needs --session <id>")
	case coachFlagStdin:
		return nil, errors.New("--stdin does not go with --session: the session writes the change")
	}
	verb := "accept a coach proposal through a session"
	if coachFlagRestart {
		verb = "start a coach proposal's session again"
	}
	if err := coachConfirm(e, verb, id, ""); err != nil {
		return nil, err
	}
	a := e.applier()
	run := a.AcceptWithSession
	if coachFlagRestart {
		run = a.Restart
	}
	if err := run(id, coachFlagSession); err != nil {
		return nil, codedCoachErr(err)
	}
	return coachAcceptSessionJSON{coachAcceptJSON: coachAcceptJSON{
		coachDecisionJSON: coachDecisionJSON{OK: true, ID: id, Status: "accepted"}}, SessionID: coachFlagSession}, nil
}

// runCoachBrief prints the brief of the session that carries out a
// repository or memory proposal, or with --revert the session that reverts a
// merged repository change (its PR named). Read-only.
func runCoachBrief(e *coachEnv, arg string) (any, error) {
	id, err := parseCoachID(arg)
	if err != nil {
		return nil, err
	}
	p, err := e.db.GetCoachProposal(id)
	if err != nil {
		return nil, err
	}
	if !coach.IsSessionDestination(p.Destination) {
		return nil, codedCoachErr(fmt.Errorf("coach proposal %d (%s) is applied by Accept, not by a session: %w",
			id, p.Destination, coach.ErrRefused))
	}
	lang := agentreport.LangOf(e.cfg.Digest.Language)
	if !coachFlagRevert {
		title, prompt := coach.Brief(p, lang)
		return coachBriefJSON{OK: true, ID: id, Title: title, Prompt: prompt}, nil
	}
	if p.Destination == coach.DestMemoryIndex || p.Status != "accepted" || !p.ViaSession {
		return nil, codedCoachErr(fmt.Errorf("coach proposal %d has no merged session change to revert: %w",
			id, coach.ErrRefused))
	}
	pr, err := coachSessionPR(e.db, p, map[int64]map[string]db.PRState{})
	if err != nil {
		return nil, err
	}
	if pr == nil || pr.State != "merged" {
		return nil, codedCoachErr(fmt.Errorf("coach proposal %d: its PR is not merged, nothing to revert: %w",
			id, coach.ErrRefused))
	}
	title, prompt := coach.RevertBrief(p, pr.PRNumber.Int64, lang)
	return coachBriefJSON{OK: true, ID: id, Title: title, Prompt: prompt}, nil
}

func runCoachDismiss(e *coachEnv, arg string) (any, error) {
	id, err := parseCoachID(arg)
	if err != nil {
		return nil, err
	}
	if err := coachConfirm(e, "dismiss a coach proposal", id, ""); err != nil {
		return nil, err
	}
	if err := e.applier().Dismiss(id); err != nil {
		return nil, codedCoachErr(err)
	}
	return coachVerdictJSON{coachDecisionJSON: coachDecisionJSON{OK: true, ID: id, Status: "accepted"},
		Verdict: "too_little_data"}, nil
}

func runCoachReapply(e *coachEnv, arg string) (any, error) {
	id, err := parseCoachID(arg)
	if err != nil {
		return nil, err
	}
	if err := coachConfirm(e, "turn a setting off again", id, ""); err != nil {
		return nil, err
	}
	if err := e.applier().Reapply(id); err != nil {
		return nil, codedCoachErr(err)
	}
	return coachVerdictJSON{coachDecisionJSON: coachDecisionJSON{OK: true, ID: id, Status: "accepted"}}, nil
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
	case errors.Is(err, db.ErrCoachSessionHasPR):
		code = "has_pr"
	case errors.Is(err, coach.ErrRepoDirty):
		code = "dirty"
	case errors.Is(err, coach.ErrRepoNotGit):
		code = "not_git"
	case errors.Is(err, coach.ErrRefused):
		code = "refused"
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

// runCoachNow is the weekly pass on demand: fold the old instruction
// suggestions in (once ever, coach.ImportSuggestions, under the lock), judge,
// collect, propose. It ignores the daemon's stamp and does not write it. No
// plan-limit gate (ask #655). --dry-run folds nothing, judges nothing and
// writes nothing: it prints what the model would have proposed.
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
		// A failed fold must not stop the run (the daemon's phase logs it too).
		if _, err := coachImportSuggestions(e.db, e.cfg.Digest.Language, now); err != nil {
			fmt.Fprintf(cmd.ErrOrStderr(), "coach: folding instruction suggestions: %v\n", err)
		}
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
	case coachAcceptSessionJSON:
		fmt.Fprintf(w, "Proposal %d: %s through session %d\n", r.ID, r.Status, r.SessionID)
	case coachVerdictJSON:
		verdict := r.Verdict
		if verdict == "" {
			verdict = "measuring again"
		}
		fmt.Fprintf(w, "Proposal %d: %s (%s)\n", r.ID, r.Status, verdict)
	case coachBriefJSON:
		fmt.Fprintf(w, "%s\n\n%s", r.Title, r.Prompt)
	case coachAcceptJSON:
		fmt.Fprintf(w, "Proposal %d: %s\n", r.ID, r.Status)
		if r.PackCopiesUpdated > 0 || r.PackCopiesDrifted > 0 {
			fmt.Fprintf(w, "Installed copies updated: %d; edited by hand and not updated: %d\n",
				r.PackCopiesUpdated, r.PackCopiesDrifted)
		}
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
		if p.Skill != "" {
			dest += " [" + p.Skill + "]"
		}
		if p.FolderBranch != nil && *p.FolderBranch != "" {
			dest += " on " + *p.FolderBranch
		}
		fmt.Fprintf(w, "#%d [%s] %s\n  where: %s\n", p.ID, p.Status, p.Title, dest)
		if p.Origin == "chat" {
			from := "deleted"
			if p.ConversationID != nil {
				from = strconv.FormatInt(*p.ConversationID, 10)
			}
			fmt.Fprintf(w, "  from: chat %s\n", from)
		}
		fmt.Fprintf(w, "  why: %s\n", p.Why)
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
