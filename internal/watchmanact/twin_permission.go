package watchmanact

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os/exec"
	"strings"
	"time"

	"watchtower/internal/askanswer"
	"watchtower/internal/db"
	"watchtower/internal/watchman"
)

// A permission prompt of an armed session (spec 2026-11-16-watchman-design
// §§4, 5): the hard-limit table and the owner's limits (watchman.CheckLimits)
// run in Go on the request before the model and on its choice after; a hit,
// a clipped summary or anything the table cannot read denies it for the
// owner (parked). Every write is askanswer.ClosePermission, decided_by
// watchman, with the item's finish in the same transaction (WATCHMAN-02).
//
// Writers of the request row: the Mac (Workchat card, SessionControl), the
// phone (hub), the twin (here), the hook's own closes (expired, answered on
// the Mac). All go through the `status = 'pending'` compare-and-set: the
// first wins, a loser writes nothing — the twin's item is then journalled
// owner first, or, when the hook stopped waiting (expired) or the session
// was deleted, dropped before a decision and finished superseded after one.

// The twin's choices on a permission prompt.
const (
	PermissionAllow = "allow"
	PermissionDeny  = "deny"
)

var permissionOptions = []string{PermissionAllow, PermissionDeny}

// Builder copy: a permission's park reasons.
const (
	reasonClipped           = "the request was cut short; its hidden tail cannot be checked"
	reasonUnreadablePrefix  = "the hard-limit check could not read "
	permissionLiveReadLimit = 30 * time.Second // each live git or gh read
)

// permission decides a leased permission item: the request read (gone: the
// item goes; no longer pending: someone answered first), the attempt and
// learning parks, then decidePermission and its write.
func (j *job) permission(ctx context.Context) {
	req, err := j.t.d.DB.GetPermissionRequest(j.it.RefID)
	switch {
	case errors.Is(err, db.ErrPermissionRequestNotFound):
		j.drop()
		return
	case err != nil:
		j.fail(ctx, err)
		return
	}
	j.perm = req
	if req.Status != db.PermissionPending {
		j.permissionLost(j.outcome(OutcomeOwnerFirst))
		return
	}
	if j.it.Attempts > MaxAttempts {
		j.park(ctx, failedReason(j.it.Error))
		return
	}
	learning, err := j.t.stillLearning(j.it.WorkbenchID)
	if err != nil {
		j.fail(ctx, err)
		return
	}
	if learning {
		j.park(ctx, LearningReason)
		return
	}
	o, err := j.t.decidePermission(ctx, j.it, req)
	if err != nil {
		j.decideFailed(ctx, err)
		return
	}
	if o.Outcome == OutcomeParked {
		j.parked = &o
	}
	j.closePermission(ctx, o.Outcome == OutcomeAnswered && o.Choice == PermissionAllow, o)
}

// decidePermission is the twin's decision on request req of item it, with
// no write: parked (deny) when the request hits a hard limit or an owner's
// limit (every PR merge does: merging is the owner's in phase 2), was
// clipped, or its places or the owner's limits cannot be read; otherwise
// the model decides between allow and deny, and an allow is checked again
// on fresh reads (the live branch, its shared branches and the owner's
// limits may have moved while the model ran). A model that hands it to the owner is handed
// (deny). The error is the model's.
func (t *Twin) decidePermission(ctx context.Context, it db.WatchmanItem, req *db.PermissionRequest) (db.WatchmanOutcome, error) {
	now := t.d.Clock()
	park := func(reason string, dec *watchman.Decision) db.WatchmanOutcome {
		o := outcomeOf(dec, OutcomeParked, now)
		o.ParkReason = reason
		return o
	}
	if reason := t.limitPark(ctx, it, req); reason != "" {
		return park(reason, nil), nil
	}
	if req.SummaryClipped {
		return park(reasonClipped, nil), nil
	}
	dec, err := t.d.Decide(ctx, watchman.Item{
		WorkbenchID: it.WorkbenchID, ItemID: it.ID, SessionID: it.SessionID, Category: watchman.CategoryPermission, Options: permissionOptions,
		Situation:     watchman.Clip(watchman.Redact("Tool: "+req.ToolName+"\n"+strings.TrimSpace(req.Summary)), watchman.SituationLimit),
		DecidedBefore: now,
	})
	if err != nil {
		return db.WatchmanOutcome{}, err
	}
	if dec.Choice == PermissionAllow {
		if reason := t.limitPark(ctx, it, req); reason != "" {
			return park(reason, &dec), nil
		}
	}
	if dec.Handoff == watchman.HandoffOwnerOnly {
		return outcomeOf(&dec, OutcomeHanded, now), nil
	}
	return outcomeOf(&dec, OutcomeAnswered, now), nil
}

// limitPark reads request req as the hard-limit table sees it now and the
// owner's limits, and returns the park reason: a limit hit, or what could
// not be read (fail closed); "" when the request may be decided.
func (t *Twin) limitPark(ctx context.Context, it db.WatchmanItem, req *db.PermissionRequest) string {
	ask, err := t.permissionAsk(ctx, req)
	if err != nil {
		log.Printf("watchman twin: item %d: %v", it.ID, err)
		return reasonUnreadablePrefix + err.Error()
	}
	extra, err := t.d.DB.WatchmanExtraLimits()
	if err != nil {
		log.Printf("watchman twin: item %d: %v", it.ID, err)
		return reasonUnreadablePrefix + "the owner's limits"
	}
	if l, hit := watchman.CheckLimits(ask, extra); hit {
		return limitReason(l)
	}
	return ""
}

// permissionAsk is request req as the hard-limit table reads it: the
// session's folder and worktrees and its workbench's folder; a shell
// command a branch-dependent row can hit also gets the session's live
// branch and the branches it shares (liveBranchInfo). The error names what
// could not be read.
func (t *Twin) permissionAsk(ctx context.Context, req *db.PermissionRequest) (watchman.PermissionAsk, error) {
	s, err := t.d.DB.GetTerminalSession(req.TerminalSessionID)
	if err != nil {
		return watchman.PermissionAsk{}, fmt.Errorf("the session: %w", err)
	}
	wb, err := t.d.DB.GetWorkbench(req.WorkbenchID)
	if err != nil {
		return watchman.PermissionAsk{}, fmt.Errorf("the workbench: %w", err)
	}
	wts, err := t.d.DB.SessionWorktrees(ctx, req.TerminalSessionID)
	if err != nil {
		return watchman.PermissionAsk{}, fmt.Errorf("the session's worktrees: %w", err)
	}
	ask := watchman.PermissionAsk{
		Tool: req.ToolName, Summary: req.Summary, SummaryClipped: req.SummaryClipped,
		WorkbenchFolder: wb.FolderPath, Worktrees: []string{s.FolderPath},
		// Cwd stays unknown: the row does not record where the call starts,
		// so a relative path is unplaced and the path rows park it.
	}
	for _, w := range wts {
		ask.Worktrees = append(ask.Worktrees, w.Root)
	}
	// Only a command a branch-dependent row can hit pays for the live reads
	// (git, and gh over the network).
	if req.ToolName == "Bash" && watchman.BranchDependent(ask) {
		dir := s.FolderPath
		ask.Branch = t.liveBranchInfo(ctx, dir)
	}
	return ask, nil
}

// liveBranch is the branch checked out in dir, "" when it cannot be read
// (the table then treats it as shared).
func (t *Twin) liveBranch(ctx context.Context, dir string) string {
	ctx, cancel := context.WithTimeout(ctx, permissionLiveReadLimit)
	defer cancel()
	out, err := t.d.Run(ctx, dir, "git", "rev-parse", "--abbrev-ref", "HEAD")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// liveBranchInfo is the session's branch at dir and the branches it shares
// with others, read live: the default branches, the base of the current
// branch's PR, and the current branch itself when an open PR builds on it.
// The two gh lookups run apart. Shared stays nil (unknown: every
// destructive ref move then parks) when the branch is unknown or detached
// or a lookup that could add a shared branch failed; an open PR on top of
// the current branch still marks it shared then (Current "": the table's
// most closed view, the current branch shared and the rest unknown).
func (t *Twin) liveBranchInfo(ctx context.Context, dir string) *watchman.BranchInfo {
	current := t.liveBranch(ctx, dir)
	b := &watchman.BranchInfo{Current: current}
	if current == "" || current == "HEAD" {
		return b
	}
	base, hasPR, ownErr := t.ownPRBase(ctx, dir)
	onTop, topErr := t.prOnTop(ctx, dir, current)
	switch {
	case topErr != nil:
		return b
	case ownErr != nil:
		if onTop {
			b.Current = ""
		}
		return b
	}
	b.Shared = []string{"main", "master"}
	if hasPR {
		b.Shared = append(b.Shared, base)
	}
	if onTop {
		b.Shared = append(b.Shared, current)
	}
	return b
}

// ownPRBase is the base of the current branch's PR at dir; hasPR false
// with no error when gh says the branch has none.
func (t *Twin) ownPRBase(ctx context.Context, dir string) (base string, hasPR bool, err error) {
	rctx, cancel := context.WithTimeout(ctx, permissionLiveReadLimit)
	defer cancel()
	out, err := t.d.Run(rctx, dir, "gh", "pr", "view", "--json", "baseRefName", "--jq", ".baseRefName")
	if err != nil {
		if noPullRequest(err) {
			return "", false, nil
		}
		return "", false, err
	}
	base = strings.TrimSpace(string(out))
	if base == "" || strings.ContainsAny(base, " \t\n") {
		return "", false, fmt.Errorf("unreadable PR base %q", watchman.Clip(base, 80))
	}
	return base, true, nil
}

// noPullRequest reports gh's answer for a branch with no PR (not a
// failed read).
func noPullRequest(err error) bool {
	text := err.Error()
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		text += " " + string(ee.Stderr)
	}
	return strings.Contains(text, "no pull requests found")
}

// prOnTop reports an open PR whose base is branch at dir.
func (t *Twin) prOnTop(ctx context.Context, dir, branch string) (bool, error) {
	rctx, cancel := context.WithTimeout(ctx, permissionLiveReadLimit)
	defer cancel()
	out, err := t.d.Run(rctx, dir, "gh", "pr", "list", "--base", branch, "--state", "open", "--limit", "1", "--json", "number")
	if err != nil {
		return false, err
	}
	var prs []struct {
		Number int `json:"number"`
	}
	if err := json.Unmarshal(out, &prs); err != nil {
		return false, err
	}
	return len(prs) > 0, nil
}

// closePermission writes the twin's allow or deny on the request with the
// item's finish o in the same transaction. A lost compare-and-set writes
// nothing (permissionLost); a lost lease writes nothing at all.
func (j *job) closePermission(ctx context.Context, allow bool, o db.WatchmanOutcome) {
	closed, err := j.t.d.Answerer.ClosePermission(ctx, askanswer.PermissionDecision{
		RequestID: j.perm.ID, SessionID: j.perm.TerminalSessionID, Allow: allow, DecidedBy: askanswer.ByWatchman,
		Also: func(tx *sql.Tx) error { return j.finishTx(tx, o) },
	})
	switch {
	case errors.Is(err, errLeaseLost):
		log.Printf("watchman twin: item %d: lease lost, nothing written", j.it.ID)
	case errors.Is(err, errKindChanged):
		j.release()
	case err != nil:
		j.fail(ctx, err)
	case !closed:
		j.permissionLost(o)
	}
}

// permissionLost closes an item whose request was no longer pending: an
// answer of the Mac or the phone (or a newer prompt of the session) is the
// owner's, journalled owner first with a park's reason and text dropped; a
// hook that stopped waiting (expired) or a request gone with its session
// drops the item before any decision and finishes it superseded, its choice
// kept, after one.
func (j *job) permissionLost(o db.WatchmanOutcome) {
	o.ParkReason, o.Error = "", ""
	req, err := j.t.d.DB.GetPermissionRequest(j.it.RefID)
	if errors.Is(err, db.ErrPermissionRequestNotFound) || (err == nil && req.Status == db.PermissionExpired) {
		if o.Choice == "" {
			j.drop()
			return
		}
		o.Outcome = OutcomeSuperseded
		j.finishAlone(o)
		return
	}
	if o.Outcome == OutcomeParked {
		o.Choice, o.Rationale = "", ""
	}
	o.Outcome = OutcomeOwnerFirst
	j.finishAlone(o)
}
