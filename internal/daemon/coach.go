package daemon

import (
	"context"
	"errors"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/agentlog"
	"watchtower/internal/agentreport"
	"watchtower/internal/coach"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/fsutil"
	"watchtower/internal/instructions"
	"watchtower/internal/providerrouting"
	"watchtower/internal/providers"
	"watchtower/internal/providers/transport"
	"watchtower/internal/sessionfeed"
	"watchtower/internal/sessionreport"
	"watchtower/internal/workbenchgit"
)

// coachInterval is the gap between two coach runs; coachRetryAfter the gap
// after a failed run (a collect or model error) before it is tried again.
const (
	coachInterval   = 7 * 24 * time.Hour
	coachRetryAfter = 24 * time.Hour
	// coachCommitsEvery is the gap between two measure checks of the
	// accepted changes (coachMeasureCheck); coachHeadReadBudget caps one git
	// read.
	coachCommitsEvery   = 24 * time.Hour
	coachHeadReadBudget = 15 * time.Second
	// coachPRFreshFor: a cached PR state older than this is refreshed for the
	// awaiting branch before the measure check reads it.
	coachPRFreshFor = time.Hour
	// coachMemoryWriteSlack: an index written this long after its cleanup
	// session's recorded end still counts as the session's write.
	coachMemoryWriteSlack = 2 * time.Minute
	// coachSessionIdleEnds: a cleanup session whose agent has sat idle this
	// long (waiting, or never reported) counts as ended at its last activity.
	coachSessionIdleEnds = time.Hour
)

// coachGeneratorFactory is the seam tests override. The coach prompt carries
// the owner's own typed text, which every CLI generator sends on stdin, never
// argv (CHAT-04); the model tier comes from
// digest.TierForSource("coach.propose") (strong). The reserve leaves are CLI
// children only, isolated (digest.IsolateChild).
var coachGeneratorFactory = func(cfg *config.Config) digest.Generator {
	snapshot := *cfg
	snapshot.AI.Providers = maps.Clone(cfg.AI.Providers)
	cfg = &snapshot
	if err := providers.Allowed(cfg.AI.Provider); err != nil {
		return digest.RefusedGenerator{Err: err} // #608: the run fails with the policy error, no fallback
	}
	gen := transport.For(cfg.AI.Provider).NewGenerator(transport.Options{Config: cfg})
	legacy := digest.WithCallTimeout(gen, digest.DaemonAICallTimeout)
	return providerrouting.WrapGenerator(cfg, legacy, func(provider string) digest.Generator {
		if !providers.RunsChild(provider) {
			err := providers.Allowed(provider)
			if err == nil {
				err = fmt.Errorf("coach: reserve provider %q runs no CLI child", provider)
			}
			return digest.RefusedGenerator{Err: err}
		}
		return transport.For(provider).NewGenerator(transport.Options{Config: cfg, IsolatedChild: true})
	}, providerrouting.GeneratorOptions{Timeout: digest.DaemonAICallTimeout})
}

// coachSessionDirs is the test seam for the transcript directories the owner
// lines are read from (the same rules as the cmd terminal seams: Claude
// Code's dir is always ~/.claude; Codex's is an absolute $CODEX_HOME, else
// ~/.codex).
var coachSessionDirs = func() sessionfeed.Dirs {
	dirs := sessionfeed.Dirs{ClaudeProjects: filepath.Join(agentlog.DefaultClaudeDir(), "projects")}
	if dir := os.Getenv("CODEX_HOME"); filepath.IsAbs(dir) {
		dirs.CodexHome = dir
	} else if home, err := os.UserHomeDir(); err == nil {
		dirs.CodexHome = filepath.Join(home, ".codex")
	}
	return dirs
}

// Seams tests replace to count and script the steps.
var (
	// coachFileAtHead reads a workbench file at the folder's HEAD: the
	// read-only `git show` of workbenchgit.FileAtHead (COACH-01:
	// TestCOACH01_NoGitWrites scans this file).
	coachFileAtHead = func(ctx context.Context, folder, rel string) (string, bool, error) {
		return workbenchgit.FileAtHead(ctx, workbenchgit.Options{Folder: folder}, rel)
	}
	runCoachImport   = coach.ImportSuggestions
	runCoachJudge    = coach.Judge
	runCoachProposer = func(ctx context.Context, p *coach.Proposer, in coach.Inputs) (int, *digest.Usage, error) {
		return p.Run(ctx, in)
	}
	runCoachContext = coach.ProposeContext
	// coachRefreshPR refreshes the session report's PR cache for one branch
	// of a workbench (gh and git; never inside a write transaction): an
	// incomplete refresh (no gh, no network, auth, the budget) is an error
	// and the measure check retries at its next run.
	coachRefreshPR = func(ctx context.Context, database *db.DB, workbenchID int64, branch string) error {
		res := sessionreport.Refresh(ctx, database, workbenchID, []string{"branch:" + branch},
			sessionreport.RefreshOptions{Network: true})
		if res.Note != "" {
			return errors.New(res.Note)
		}
		return nil
	}
	// coachHomeDir is the home ~/.claude and ~/.claude.json live in.
	coachHomeDir = os.UserHomeDir
)

func (d *Daemon) lastCoachPath() string {
	return filepath.Join(d.config.WorkspaceDir(), "last_coach.txt")
}

func (d *Daemon) lastCoachFailedPath() string {
	return filepath.Join(d.config.WorkspaceDir(), "last_coach_failed.txt")
}

func (d *Daemon) loadLastCoach() {
	d.lastCoach = readUnixStamp(d.lastCoachPath())
	d.lastCoachFailed = readUnixStamp(d.lastCoachFailedPath())
}

// readUnixStamp reads a file of unix seconds; zero when missing or unreadable.
func readUnixStamp(path string) time.Time {
	data, err := os.ReadFile(path)
	if err != nil {
		return time.Time{}
	}
	unix, err := strconv.ParseInt(strings.TrimSpace(string(data)), 10, 64)
	if err != nil {
		return time.Time{}
	}
	return time.Unix(unix, 0)
}

func (d *Daemon) saveLastCoach() {
	data := strconv.FormatInt(d.lastCoach.Unix(), 10)
	if err := os.WriteFile(d.lastCoachPath(), []byte(data), 0o600); err != nil {
		d.logger.Printf("coach: failed to save stamp: %v", err)
	}
	d.lastCoachFailed = time.Time{}
	if err := os.Remove(d.lastCoachFailedPath()); err != nil && !os.IsNotExist(err) {
		d.logger.Printf("coach: failed to clear the failure stamp: %v", err)
	}
}

// markCoachFailed records a failed run: the next try is coachRetryAfter later.
func (d *Daemon) markCoachFailed(now time.Time) {
	d.lastCoachFailed = now
	data := strconv.FormatInt(now.Unix(), 10)
	if err := os.WriteFile(d.lastCoachFailedPath(), []byte(data), 0o600); err != nil {
		d.logger.Printf("coach: failed to save the failure stamp: %v", err)
	}
}

// phaseCoach runs the measure check of the accepted changes once a day
// (coachMeasureCheck: commits, merges, memory cleanups, settings turned back
// on), and runs the agent coach once a week: fold
// the old instruction suggestions in (once ever, ImportSuggestions), judge the accepted proposals
// that are old enough, collect the signals, ask for new proposals. The fold
// runs under the lock, before proposing, so it and `coach run` never race on
// the free slots; its error is logged and the pass goes on. There is no
// catch-up: a stamp of any age gives exactly one run. The weekly stamp is
// written only when the proposing step ran to completion (spec §6.2: a failed
// run is retried next time): a collect or model error writes the failure stamp
// instead and is retried a day later, not every cycle; a cycle cancelled
// mid-run writes neither and the next cycle runs again; a judging error alone
// does not hold the week. No plan-limit gate (ask #655). Logs carry counts,
// never text. The mechanical context proposer (coachContext) runs in the
// weekly pass after judging, and on its own, under the same lock, in the
// first cycle after an analytics import wrote events.
func (d *Daemon) phaseCoach(ctx context.Context) {
	if d.db == nil || ctx.Err() != nil {
		return
	}
	now := time.Now()
	if d.lastCoachCommits.IsZero() || now.Sub(d.lastCoachCommits) >= coachCommitsEvery {
		if d.coachMeasureCheck(ctx, now) {
			d.lastCoachCommits = now
		}
	}
	weekly := (d.lastCoach.IsZero() || now.Sub(d.lastCoach) >= coachInterval) &&
		(d.lastCoachFailed.IsZero() || now.Sub(d.lastCoachFailed) >= coachRetryAfter)
	if !weekly && !d.coachContextFresh.Load() {
		return
	}
	// The same lock `coach run` holds: a pass already running (the owner's
	// own) is not doubled; nothing is stamped, so the next cycle looks again.
	unlock, ok, err := fsutil.TryLockFile(coach.LockPath(d.config.WorkspaceDir()))
	if err != nil {
		d.logger.Printf("coach: lock: %v", err)
		return
	}
	if !ok {
		d.logger.Printf("coach: busy, skipped")
		return
	}
	defer unlock()
	if !weekly { // only fresh analytics facts: the context proposer alone
		d.coachContext(ctx, now)
		return
	}
	d.trackedPipelineRun("coach", func() pipelineRunStats {
		if n, err := runCoachImport(d.db, d.config.Digest.Language, now); err != nil {
			d.logger.Printf("coach: folding instruction suggestions: %v", err)
		} else if n > 0 {
			d.logger.Printf("coach: %d instruction suggestion(s) folded into proposals", n)
		}
		if d.agentLog == nil {
			d.logger.Printf("coach: agentlog.db is not open, judging skipped")
		} else if judged, cuts, err := runCoachJudge(d.db, d.agentLog, now); err != nil {
			d.logger.Printf("coach: judging: %v", err)
		} else {
			d.logger.Printf("coach: %d judged, %d cut", judged, cuts)
		}
		d.coachContext(ctx, now)
		in, err := coach.Collect(ctx, d.db, d.agentLog, instructions.NewFeedReader(ctx, d.db, coachSessionDirs()), now)
		if err != nil {
			if ctx.Err() == nil {
				d.markCoachFailed(now)
			}
			d.logger.Printf("coach: collecting signals: %v (retried tomorrow)", err)
			return pipelineRunStats{err: err}
		}
		gen := d.coachGenerator(ctx)
		p := &coach.Proposer{DB: d.db, Gen: gen, Now: func() time.Time { return now }, Logger: d.logger, Lang: d.config.Digest.Language}
		n, usage, err := runCoachProposer(ctx, p, in)
		stats := pipelineRunStats{items: n, err: err}
		if usage != nil {
			stats.inTok, stats.outTok, stats.totalAPI = usage.InputTokens(), usage.OutputTokens(), usage.TotalAPITokens()
		}
		if ctx.Err() != nil { // a cycle cancelled mid-run (sleep/wake) is retried next cycle
			return stats
		}
		if err != nil {
			d.markCoachFailed(now)
			d.logger.Printf("coach: %v (retried tomorrow)", err)
			return stats
		}
		d.lastCoach = now
		d.saveLastCoach()
		d.logger.Printf("coach: %d written", n)
		return stats
	})
}

// coachGenerator keeps the coach's stdin-only factory while sharing worker
// admission and the caller's immutable routing inputs with the rest of the job.
func (d *Daemon) coachGenerator(ctx context.Context) digest.Generator {
	gen := coachGeneratorFactory(config.RoutingSnapshot(ctx, d.config))
	if d.aiWorkerPool != nil {
		gen = digest.WithCallTimeout(digest.NewPooledGenerator(gen, d.aiWorkerPool), digest.DaemonAICallTimeout)
	}
	return gen
}

// coachMeasureCheck starts the verdict window of the accepted changes that
// are measured from an event, not from the Accept (spec §4.3a, D68; spec
// 2026-11-12 C3, C8, C10), and catches a settings change undone outside
// Watchtower. For each accepted row without a verdict:
//   - a settings key (plugin, server, connectors) that reads its before-text
//     again gets the verdict reverted_outside (the card offers Turn Off Again,
//     coach reapply) instead of being measured into no_effect;
//   - a repository change accepted through a session: its session's branch is
//     copied while the session row has one, then its PR is read from the
//     session report's cache (workbench_pr_states, refreshed for that branch
//     when older than coachPRFreshFor): merged → measure_from = the merge
//     time; closed unmerged → too_little_data; no branch (the session row was
//     deleted first) never falls back to the HEAD rule;
//   - a memory cleanup, decided once: nothing while its session runs; at
//     the first check that sees it ended — finished, idle for
//     coachSessionIdleEnds (ended at its last activity), or its row gone
//     (ended now) — an index that differs from before_text
//     and was last written by then records measure_from = the end and
//     after_text = the index (Rollback compares against it);
//   - a repository edit accepted before sessions (via_session = 0) keeps the
//     HEAD rule (coachEditAtHead): measure_from = now the first time the file
//     at the folder's HEAD equals the accepted text.
//
// A session row still without measure_from repoCommitWait after the Accept
// ends as too_little_data (the judge applies the same rule weekly). Every
// write is a compare-and-set (a second pass is a no-op), its own short
// write; git, gh and file reads run outside any write transaction. A row
// that cannot be read today (a folder gone, a failed refresh, an unreadable
// file) is skipped and tried at the next check. Logs carry ids, never a
// path, a branch or a value. done is false when the list failed or the cycle
// was cancelled: the check is tried again next cycle, not a day later.
func (d *Daemon) coachMeasureCheck(ctx context.Context, now time.Time) (done bool) {
	ps, err := d.db.ListCoachProposals("accepted")
	if err != nil {
		d.logger.Printf("coach: measure check: %v", err)
		return false
	}
	home, _ := coachHomeDir() // "": settings and memory rows are skipped today
	a := &coach.Applier{DB: d.db, Home: home, Now: func() time.Time { return now }}
	measured := 0
	for _, p := range ps {
		if ctx.Err() != nil {
			return false
		}
		if p.Verdict != "" {
			continue
		}
		var set bool
		switch {
		case coach.IsSettingsDestination(p.Destination):
			d.coachRevertedCheck(a, p, now)
		case !p.MeasureFrom.IsZero():
		case p.Destination == coach.DestMemoryIndex:
			set = d.coachMemoryCheck(a, p, now)
		case coach.IsRepoDestination(p.Destination) && p.ViaSession:
			set = d.coachMergeCheck(ctx, p, now)
		case coach.IsRepoDestination(p.Destination):
			set = d.coachHeadCheck(ctx, p, now)
		}
		if set {
			measured++
		}
	}
	if measured > 0 {
		d.logger.Printf("coach: measure check: %d change(s) landed, measured from now on", measured)
	}
	return true
}

// coachHeadCheck is the legacy rule of a repository edit accepted before
// sessions: measure_from = now once the file at the folder's HEAD holds the
// accepted text.
func (d *Daemon) coachHeadCheck(ctx context.Context, p db.CoachProposal, now time.Time) bool {
	seen, why := d.coachEditAtHead(ctx, p)
	if why != "" {
		d.logger.Printf("coach: measure check: proposal %d (workbench %d) skipped today: %s", p.ID, p.WorkbenchID, why)
		return false
	}
	return seen && d.coachSetMeasureFrom(p, now)
}

func (d *Daemon) coachSetMeasureFrom(p db.CoachProposal, at time.Time) bool {
	set, err := d.db.SetCoachMeasureFrom(p.ID, at)
	if err != nil {
		d.logger.Printf("coach: measure check: proposal %d: %v", p.ID, err)
		return false
	}
	return set
}

// coachMergeCheck follows the PR of a repository change accepted through a
// session (C8).
func (d *Daemon) coachMergeCheck(ctx context.Context, p db.CoachProposal, now time.Time) bool {
	branch := d.coachProposalBranch(p)
	if branch != "" {
		switch pr, ok := d.coachBranchPR(ctx, p, branch, now); {
		case !ok:
		case pr.State == "merged":
			at, err := time.Parse(time.RFC3339, pr.MergedAt)
			if err != nil { // git saw the merge, gh did not say when
				at = now
			}
			if at.Before(p.DecidedAt) { // a reused branch name's older merge
				at = p.DecidedAt
			}
			return d.coachSetMeasureFrom(p, at)
		case pr.State == "closed":
			d.coachTooLittleData(p, now, "PR closed unmerged")
			return false
		}
	}
	if coach.MeasureWaitOver(p, now) {
		d.coachTooLittleData(p, now, "not merged in time")
	}
	return false
}

// coachProposalBranch is p's session branch: the copied one, else the live
// session's (copied onto the row now), "" when there is none yet.
func (d *Daemon) coachProposalBranch(p db.CoachProposal) string {
	if p.SessionBranch != "" || p.SessionID == nil {
		return p.SessionBranch
	}
	branch, err := d.db.CoachSessionBranch(*p.SessionID)
	if err != nil {
		d.logger.Printf("coach: measure check: proposal %d: %v", p.ID, err)
		return ""
	}
	if branch == "" {
		return ""
	}
	if err := d.db.SetCoachSessionBranch(p.ID, branch); err != nil {
		d.logger.Printf("coach: measure check: proposal %d: %v", p.ID, err)
	}
	return branch
}

// coachBranchPR is branch's cached PR state in p's workbench, refreshed
// first (that branch only, through the session report's refresher) when the
// cache row is missing or older than coachPRFreshFor. ok is false when the
// state could not be read: a failed refresh is logged and the row waits.
func (d *Daemon) coachBranchPR(ctx context.Context, p db.CoachProposal, branch string, now time.Time) (db.PRState, bool) {
	ref := "branch:" + branch
	states, err := d.db.PRStates(p.WorkbenchID)
	if err != nil {
		d.logger.Printf("coach: measure check: proposal %d: PR states not readable", p.ID)
		return db.PRState{}, false
	}
	row, cached := states[ref]
	checked, perr := time.Parse(time.RFC3339, row.CheckedAt)
	if cached && perr == nil && now.Sub(checked) < coachPRFreshFor {
		return row, true
	}
	if err := coachRefreshPR(ctx, d.db, p.WorkbenchID, branch); err != nil {
		d.logger.Printf("coach: measure check: proposal %d (workbench %d): PR state not refreshed, retried next check",
			p.ID, p.WorkbenchID)
		return db.PRState{}, false
	}
	if states, err = d.db.PRStates(p.WorkbenchID); err != nil {
		d.logger.Printf("coach: measure check: proposal %d: PR states not readable", p.ID)
		return db.PRState{}, false
	}
	row, cached = states[ref]
	return row, cached
}

// coachMemoryCheck decides a memory cleanup once, at the first check that
// sees its session ended (C10): an index that differs from before_text and
// was written no later than the end (coachMemoryWriteSlack) is the
// session's — measured from the end, after_text = that index; anything
// else (unchanged, or written only after the end by another session's
// auto-memory) is recorded as ended without a change (after_text =
// before_text, no measure_from). A row already decided (after_text set) is
// never looked at again: a later write is never the cleanup's. Only a
// Restart (a new session) clears the decision.
func (d *Daemon) coachMemoryCheck(a *coach.Applier, p db.CoachProposal, now time.Time) bool {
	if p.AfterText != "" { // decided: ended without a change
		return d.coachMemoryWait(p, now)
	}
	ended := now // a session row deleted: ended when first seen gone
	if p.SessionID != nil {
		found, at, err := d.db.CoachSessionEnd(*p.SessionID, now, coachSessionIdleEnds)
		if err != nil {
			d.logger.Printf("coach: measure check: proposal %d: %v", p.ID, err)
			return false
		}
		if found && at.IsZero() {
			return d.coachMemoryWait(p, now) // still running
		}
		if found {
			ended = at
		}
	}
	if a.Home == "" {
		return false
	}
	text, modified, err := a.MemoryIndexNow(p)
	if err != nil {
		d.logger.Printf("coach: measure check: proposal %d (workbench %d) skipped today: %v", p.ID, p.WorkbenchID, err)
		return false
	}
	if text == p.BeforeText || modified.After(ended.Add(coachMemoryWriteSlack)) {
		if _, err := d.db.SetCoachMemoryUnchanged(p.ID); err != nil {
			d.logger.Printf("coach: measure check: proposal %d: %v", p.ID, err)
			return false
		}
		return d.coachMemoryWait(p, now)
	}
	set, err := d.db.SetCoachMemoryMeasured(p.ID, ended, text)
	if err != nil {
		d.logger.Printf("coach: measure check: proposal %d: %v", p.ID, err)
		return false
	}
	return set
}

// coachMemoryWait leaves a memory row waiting; past repoCommitWait it ends
// as too_little_data.
func (d *Daemon) coachMemoryWait(p db.CoachProposal, now time.Time) bool {
	if coach.MeasureWaitOver(p, now) {
		d.coachTooLittleData(p, now, "the session left the index unchanged")
	}
	return false
}

func (d *Daemon) coachTooLittleData(p db.CoachProposal, now time.Time, why string) {
	if err := d.db.SetCoachVerdict(p.ID, "too_little_data", nil, now); err != nil {
		if !errors.Is(err, db.ErrCoachStateChanged) {
			d.logger.Printf("coach: measure check: proposal %d: %v", p.ID, err)
		}
		return
	}
	d.logger.Printf("coach: measure check: proposal %d: too little data (%s)", p.ID, why)
}

// coachRevertedCheck gives an accepted settings change whose key reads its
// before-text again the verdict reverted_outside.
func (d *Daemon) coachRevertedCheck(a *coach.Applier, p db.CoachProposal, now time.Time) {
	if a.Home == "" {
		return
	}
	back, err := a.SettingsReverted(p)
	if err != nil {
		d.logger.Printf("coach: measure check: proposal %d skipped today: %v", p.ID, err)
		return
	}
	if !back {
		return
	}
	if err := d.db.SetCoachVerdict(p.ID, "reverted_outside", nil, now); err != nil {
		if !errors.Is(err, db.ErrCoachStateChanged) {
			d.logger.Printf("coach: measure check: proposal %d: %v", p.ID, err)
		}
		return
	}
	d.logger.Printf("coach: measure check: proposal %d turned back on outside Watchtower", p.ID)
}

// coachEditAtHead reports whether p's file at its workbench folder's HEAD
// holds p's accepted text; why names a skip (never the folder or the path).
func (d *Daemon) coachEditAtHead(ctx context.Context, p db.CoachProposal) (seen bool, why string) {
	rel, ok := coach.RepoRelPath(p.Destination, p.Skill)
	if !ok {
		return false, "not a repository file"
	}
	w, err := d.db.GetWorkbench(p.WorkbenchID)
	if err != nil {
		return false, "workbench not readable"
	}
	if fi, err := os.Stat(w.FolderPath); err != nil || !fi.IsDir() {
		return false, "folder gone"
	}
	readCtx, cancel := context.WithTimeout(ctx, coachHeadReadBudget)
	defer cancel()
	text, ok, err := coachFileAtHead(readCtx, w.FolderPath, rel)
	if err != nil {
		return false, "not readable at HEAD (not a git work tree, or git failed)"
	}
	return ok && text == p.AfterText, ""
}

// coachContext runs one pass of the mechanical context proposer over the
// workbenches with agent analytics on (the caller holds coach.lock): the
// install-wide rules once, the per-workbench ones for each. The fresh-import
// flag is cleared first, so an import landing meanwhile runs it again next
// cycle; a cancelled pass sets it again. Errors are logged; a line is logged
// only when something was written. Logs carry ids, counts, labels and source
// names, never a path or a config value.
func (d *Daemon) coachContext(ctx context.Context, now time.Time) {
	d.coachContextFresh.Store(false)
	if d.agentLog == nil {
		return
	}
	ids, err := d.db.AgentAnalyticsWorkbenchIDs()
	if err != nil {
		d.logger.Printf("coach: context: listing workbenches: %v", err)
		return
	}
	if len(ids) == 0 {
		return
	}
	home, err := coachHomeDir()
	if err != nil {
		d.logger.Printf("coach: context: no home folder, skipped")
		return
	}
	env := coach.ContextEnv{DB: d.db, AgentLog: d.agentLog, Home: home, Now: func() time.Time { return now },
		Lang: agentreport.LangOf(d.config.Digest.Language), Logger: d.logger}
	n, err := runCoachContext(ctx, env, ids)
	if ctx.Err() != nil {
		d.coachContextFresh.Store(true) // not done: the next cycle runs it
		return
	}
	if err != nil {
		d.logger.Printf("coach: context: %v", err)
	}
	if n > 0 {
		d.logger.Printf("coach: context: %d proposal(s) written", n)
	}
}
