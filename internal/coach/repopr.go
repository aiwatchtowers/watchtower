package coach

import (
	"errors"
	"fmt"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/logredact"
)

// A workbench repository edit in a GitHub folder is accepted as a pull
// request (docs/superpowers/specs/2026-11-19-coach-repo-edits-as-prs-design.md):
// Accept opens it instead of writing the owner's working copy, Rollback
// reverts or closes it, and SyncPRs starts the verdict window at its merge.
// internal/coach still runs no git and no gh (COACH-01): the four seams on
// Applier (RepoRoute, RepoPublish, RepoPRState, RepoClosePR) are filled by
// cmd only, over workbenchgit, and their failures carry the sentinels below.

var (
	// ErrNoGH: gh is not installed, or not logged in, in a GitHub folder.
	ErrNoGH = errors.New("gh is not installed or not logged in")
	// ErrBaseDiffers: the file on the default branch is not the text the
	// pull request must change.
	ErrBaseDiffers = errors.New("the file on the default branch differs")
	// ErrPushFailed: origin refused the branch, or the push needed a prompt.
	ErrPushFailed = errors.New("pushing the branch failed")
	// ErrPRFailed: gh could not find, open or close the pull request.
	ErrPRFailed = errors.New("the pull request call failed")
	// ErrTimeout: a git or gh network call ran over its budget.
	ErrTimeout = errors.New("a network call timed out")

	// errPRNotWired is an Applier built without the pull-request seams
	// meeting a pull-request route or row: never written or undone locally.
	errPRNotWired = errors.New("repo_* pull request: GitHub seams not wired")
)

// The owner's sentences for the pull-request refusals; BaseDiffersLine takes
// the file's relative path. Each refusal leaves the proposal as it was.
const (
	NoGHLine        = "Log in with `gh auth login` to let Watchtower open the pull request."
	BaseDiffersLine = "%s on the default branch differs from the one the chat read — pull, then ask the chat again."
	PushFailedLine  = "GitHub refused the branch, or the push needed a password prompt."
	PRFailedLine    = "GitHub did not open or close the pull request — press the button again to retry."
	TimeoutLine     = "GitHub did not answer in time; nothing changed — try again."
)

// The pull-request states RepoPRState reports (gh pr view --json state).
const (
	prOpen   = "OPEN"
	prClosed = "CLOSED"
	prMerged = "MERGED"
)

// RepoRoute is how a workbench folder takes a repository edit: PR true opens
// a pull request, false writes the working copy (a folder whose origin is not
// a GitHub repository gh can reach).
type RepoRoute struct{ PR bool }

// RepoPublishReq is one pull request RepoPublish opens: After committed over
// Before (the text the default branch must hold, else ErrBaseDiffers) to the
// file Rel (relative to the workbench folder, forward slashes) on Branch
// (coach/proposal-<id> or coach/revert-<id>), titled Title with Body. ID
// names the proposal. cmd resolves the base branch and its commit.
type RepoPublishReq struct {
	ID            int64
	Rel           string
	Before, After string
	Branch        string
	Title, Body   string
}

// prRefusal is a seam failure in the owner's words: the sentence, then the
// seam's own message (git's or gh's words, never the file's text).
type prRefusal struct {
	line  string
	cause error
}

func (e prRefusal) Error() string { return e.line + " (" + e.cause.Error() + ")" }
func (e prRefusal) Unwrap() error { return e.cause }

// prError is err as the owner reads it: a mirrored sentinel gets its
// sentence (ErrBaseDiffers naming rel); any other error is returned as is.
func prError(err error, rel string) error {
	var line string
	switch {
	case errors.Is(err, ErrNoGH):
		line = NoGHLine
	case errors.Is(err, ErrBaseDiffers):
		line = fmt.Sprintf(BaseDiffersLine, rel)
	case errors.Is(err, ErrPushFailed):
		line = PushFailedLine
	case errors.Is(err, ErrPRFailed):
		line = PRFailedLine
	case errors.Is(err, ErrTimeout):
		line = TimeoutLine
	default:
		return err
	}
	return prRefusal{line: line, cause: err}
}

// repoRoute is the folder of p's workbench and whether its edit opens a pull
// request. A nil RepoRoute is the working-copy route, with no lookup at all.
func (a *Applier) repoRoute(p db.CoachProposal) (folder string, pr bool, err error) {
	if a.RepoRoute == nil {
		return "", false, nil
	}
	if folder, err = repoFolder(a.DB, p.WorkbenchID); err != nil {
		return "", false, err
	}
	if err := checkRepoRoot(folder); err != nil {
		return "", false, err
	}
	route, err := a.RepoRoute(folder)
	if err != nil {
		return "", false, prError(err, "")
	}
	return folder, route.PR, nil
}

// repoRel is p's file relative to its workbench folder (RepoRelPath), or
// why it has none.
func repoRel(p db.CoachProposal) (string, error) {
	rel, ok := RepoRelPath(p.Destination, p.Skill)
	if ok {
		return rel, nil
	}
	if skillDestinations[p.Destination] {
		return "", errBadSkillName
	}
	return "", errNotSupported
}

// acceptPR is accept's pull-request route: the working copy is neither
// checked, read nor written. The after-text (edited, or the proposed one) is
// validated against the proposal's before-text, which the default branch
// must still hold (ErrBaseDiffers; the proposal stays open); then
// RepoPublish opens the pull request and the proposal is accepted with its
// URL. A failure leaves the proposal open: the next Accept pushes the same
// branch again and finds the same pull request.
func (a *Applier) acceptPR(p db.CoachProposal, folder, edited string, baseline *float64, n int, now time.Time) (AcceptResult, error) {
	id := p.ID
	fail := func(err error) (AcceptResult, error) {
		return AcceptResult{}, fmt.Errorf("coach proposal %d (%s): %w", id, p.Destination, err)
	}
	if a.RepoPublish == nil {
		return fail(errPRNotWired)
	}
	rel, err := repoRel(p)
	if err != nil {
		return fail(err)
	}
	after := p.AfterText
	if edited != "" {
		after = edited
	}
	cur := CurrentText{Destination: p.Destination, WorkbenchID: p.WorkbenchID, PromptID: p.PromptID, Skill: p.Skill,
		Text: p.BeforeText, Budget: BudgetOf(p.Destination, p.BeforeText)}
	if err := ValidateAfter(cur, after); err != nil {
		return AcceptResult{}, logredact.Errorf("coach proposal %d (%s): %w: %s", id, p.Destination, ErrInvalidEdit,
			logredact.Text(err.Error()))
	}
	prURL, branch, err := a.RepoPublish(folder, RepoPublishReq{
		ID: id, Rel: rel, Before: p.BeforeText, After: after,
		Branch: fmt.Sprintf("coach/proposal-%d", id),
		Title:  p.Title,
		Body:   p.Why + fmt.Sprintf("\n\n_Opened by the Watchtower coach on your Accept (proposal %d)._", id),
	})
	if err != nil {
		return fail(prError(err, rel))
	}
	if err := a.DB.MarkCoachAccepted(id, after, branch, prURL, baseline, n, now); err != nil {
		return AcceptResult{}, fmt.Errorf("accepting coach proposal %d (pull request %s open): %w", id, prURL, err)
	}
	return AcceptResult{WrittenBranch: branch, PRURL: prURL}, nil
}

// rollbackPR is Rollback of an edit Accept opened a pull request for, by the
// pull request's state: merged — a revert pull request (Before and After
// swapped, branch coach/revert-<id>) whose base must hold the accepted text,
// else ErrChangedSince (no diff: the coach never reads the default branch);
// open — the pull request is closed; closed unmerged — nothing on GitHub.
// Then the proposal goes rolled_back with the revert's URL. A seam failure
// refuses and leaves it accepted. force does not apply: a base that moved
// cannot be reverted by a pull request either way.
func (a *Applier) rollbackPR(p db.CoachProposal) (string, error) {
	id := p.ID
	fail := func(err error) (string, error) {
		return "", fmt.Errorf("rolling back coach proposal %d (%s): %w", id, p.Destination, err)
	}
	if a.RepoPRState == nil || a.RepoPublish == nil || a.RepoClosePR == nil {
		return fail(errPRNotWired)
	}
	rel, err := repoRel(p)
	if err != nil {
		return fail(err)
	}
	folder, err := repoFolder(a.DB, p.WorkbenchID)
	if err != nil {
		return fail(err)
	}
	state, _, err := a.RepoPRState(folder, p.PRURL)
	if err != nil {
		return fail(prError(err, rel))
	}
	var revertURL string
	switch state {
	case prMerged:
		revertURL, _, err = a.RepoPublish(folder, RepoPublishReq{
			ID: id, Rel: rel, Before: p.AfterText, After: p.BeforeText,
			Branch: fmt.Sprintf("coach/revert-%d", id),
			Title:  "Revert: " + p.Title,
			Body:   fmt.Sprintf("Reverts %s — rolled back in Watchtower (coach proposal %d).", p.PRURL, id),
		})
		if errors.Is(err, ErrBaseDiffers) {
			return fail(fmt.Errorf("%w: %w", ErrChangedSince, prError(err, rel)))
		}
		if err != nil {
			return fail(prError(err, rel))
		}
	case prOpen:
		if err := a.RepoClosePR(folder, p.PRURL); err != nil {
			return fail(prError(err, rel))
		}
	case prClosed:
	default:
		return fail(fmt.Errorf("pull request %s is in an unknown state %q", p.PRURL, state))
	}
	if err := a.DB.MarkCoachRolledBack(id, revertURL, a.now()); err != nil {
		if revertURL != "" { // the next Rollback finds the same revert pull request
			return "", fmt.Errorf("rolling back coach proposal %d (revert pull request %s open): %w", id, revertURL, err)
		}
		return "", fmt.Errorf("rolling back coach proposal %d: %w", id, err)
	}
	return revertURL, nil
}

// SyncPRs brings the accepted pull-request edits not yet measured up to date
// with GitHub (ListPRProposalsAwaitingMerge, by RepoPRState): merged at most
// repoCommitWait after the Accept — the verdict window starts at the merge
// (measure_from); merged later, or still open repoCommitWait after the
// Accept — a final too_little_data, as a working-copy edit never committed;
// closed unmerged — rolled_back, the owner's rejection. Each rule reads the
// merge and the Accept time, never the sync time, so a late sync decides as
// an early one would. A row whose state cannot be read is skipped (its error
// joined into the result); a row another process changed meanwhile is
// skipped silently. n counts the rows changed. Only `coach sync-prs` calls
// it; nothing runs it in the daemon (no gh there).
func (a *Applier) SyncPRs(now time.Time) (int, error) {
	rows, err := a.DB.ListPRProposalsAwaitingMerge()
	if err != nil {
		return 0, err
	}
	if len(rows) == 0 {
		return 0, nil
	}
	if a.RepoPRState == nil {
		return 0, errPRNotWired
	}
	n := 0
	var errs []error
	for _, p := range rows {
		changed, err := a.syncPR(p, now)
		if errors.Is(err, db.ErrCoachStateChanged) {
			continue
		}
		if err != nil {
			errs = append(errs, fmt.Errorf("syncing coach proposal %d: %w", p.ID, err))
			continue
		}
		if changed {
			n++
		}
	}
	return n, errors.Join(errs...)
}

// syncPR applies SyncPRs' rules to one row; changed is whether it moved.
func (a *Applier) syncPR(p db.CoachProposal, now time.Time) (bool, error) {
	folder, err := repoFolder(a.DB, p.WorkbenchID)
	if err != nil {
		return false, err
	}
	state, mergedAt, err := a.RepoPRState(folder, p.PRURL)
	if err != nil {
		rel, _ := RepoRelPath(p.Destination, p.Skill)
		return false, prError(err, rel)
	}
	switch state {
	case prMerged:
		if mergedAt.IsZero() {
			return false, fmt.Errorf("pull request %s is merged with no merge time", p.PRURL)
		}
		if mergedAt.Sub(p.DecidedAt) <= repoCommitWait {
			// A merge stamped before the Accept (clock skew, or merged while
			// the Accept was still recording) is measured from the Accept.
			return a.DB.SetCoachMeasureFrom(p.ID, maxTime(mergedAt, p.DecidedAt))
		}
	case prOpen:
		if now.Sub(p.DecidedAt) < repoCommitWait {
			return false, nil
		}
	case prClosed:
		return true, a.DB.MarkCoachRolledBack(p.ID, "", now)
	default:
		return false, fmt.Errorf("pull request %s is in an unknown state %q", p.PRURL, state)
	}
	return true, a.DB.SetCoachVerdict(p.ID, "too_little_data", nil, now)
}

func maxTime(a, b time.Time) time.Time {
	if a.After(b) {
		return a
	}
	return b
}
