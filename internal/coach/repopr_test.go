package coach

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// fakeGitHub is the four pull-request seams over a fake GitHub: route is
// what RepoRoute answers (routeErr refuses), state/mergedAt what RepoPRState
// answers (stateErr refuses), publishErr and closeErr refuse RepoPublish and
// RepoClosePR. It records every request, closed URL and folder seen.
type fakeGitHub struct {
	route                                    RepoRoute
	state                                    string
	mergedAt                                 time.Time
	routeErr, stateErr, publishErr, closeErr error
	published                                []RepoPublishReq
	closed, folders                          []string
	stateCalls                               int
}

func (f *fakeGitHub) wire(a *Applier) {
	a.RepoRoute = func(folder string) (RepoRoute, error) {
		f.folders = append(f.folders, folder)
		return f.route, f.routeErr
	}
	a.RepoPublish = func(folder string, req RepoPublishReq) (string, string, error) {
		f.folders = append(f.folders, folder)
		if f.publishErr != nil {
			return "", "", f.publishErr
		}
		f.published = append(f.published, req)
		return fmt.Sprintf("https://github.com/acme/repo/pull/%d", len(f.published)), req.Branch, nil
	}
	a.RepoPRState = func(folder, _ string) (string, time.Time, error) {
		f.folders = append(f.folders, folder)
		f.stateCalls++
		return f.state, f.mergedAt, f.stateErr
	}
	a.RepoClosePR = func(folder, url string) error {
		f.folders = append(f.folders, folder)
		if f.closeErr != nil {
			return f.closeErr
		}
		f.closed = append(f.closed, url)
		return nil
	}
}

// prApplier is an Applier on a plain folder (no git: the pull-request route
// needs none here) whose working-copy seams fail the test if called.
func prApplier(t *testing.T, d dbs) (*Applier, *fakeGitHub, string, int64) {
	t.Helper()
	folder, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(filepath.Join(folder, "CLAUDE.md"), []byte("The owner's own edit.\n"), 0o644))
	a := newApplier(t, d)
	a.RepoState = func(string, string) (RepoFileState, error) {
		t.Error("the pull-request route reads no working-copy git state")
		return RepoFileState{}, errors.New("unexpected")
	}
	a.RepoBranch = func(string) (string, error) {
		t.Error("the pull-request route reads no working-copy branch")
		return "", errors.New("unexpected")
	}
	f := &fakeGitHub{route: RepoRoute{PR: true}}
	f.wire(a)
	return a, f, folder, repoWorkbench(t, d, folder)
}

// Spec §4.3: Accept in a GitHub folder opens the pull request with the
// proposal's before-text as the base and stores its URL; the working copy —
// dirty, and not holding the before-text — is neither checked, read nor
// written. An edited text goes into the pull request instead.
func TestAcceptPR_OpensPRAndLeavesWorkingCopy(t *testing.T) {
	d := openDBs(t)
	a, f, folder, wb := prApplier(t, d)
	before := folderFiles(t, folder)

	id := propose(t, d, repoProposal(DestRepoClaudeMD, wb, "", "Run tests.\n", "Run tests.\nKeep diffs small.\n"))
	r, err := a.Accept(id, "")
	require.NoError(t, err)
	assert.Equal(t, "https://github.com/acme/repo/pull/1", r.PRURL)
	assert.Equal(t, fmt.Sprintf("coach/proposal-%d", id), r.WrittenBranch)
	assert.Equal(t, "CLAUDE.md", r.WrittenPath)
	require.Len(t, f.published, 1)
	assert.Equal(t, RepoPublishReq{ID: id, Rel: "CLAUDE.md", Before: "Run tests.\n", After: "Run tests.\nKeep diffs small.\n",
		Branch: fmt.Sprintf("coach/proposal-%d", id), Title: "title", Body: f.published[0].Body, MayCreate: true}, f.published[0])
	assert.Contains(t, f.published[0].Body, "why")
	for _, seen := range f.folders {
		assert.Equal(t, folder, seen)
	}

	p := proposal(t, d, id)
	assert.Equal(t, "accepted", p.Status)
	assert.Equal(t, r.PRURL, p.PRURL)
	assert.Equal(t, r.WrittenBranch, p.WrittenBranch)
	assert.Equal(t, "Run tests.\nKeep diffs small.\n", p.AfterText)
	assert.Equal(t, applyNow, p.DecidedAt.UTC())
	assert.True(t, p.MeasureFrom.IsZero(), "measured from the merge only")
	assert.Equal(t, before, folderFiles(t, folder), "the working copy is never written")

	// A skill, edited by the owner: the owner's text is what the PR commits.
	id = propose(t, d, repoProposal(DestRepoCodexSkill, wb, "b", "Read the board.\n", "Read the board first.\n"))
	r, err = a.Accept(id, "Read the board, then the plan.\n")
	require.NoError(t, err)
	require.Len(t, f.published, 2)
	assert.Equal(t, ".agents/skills/b/SKILL.md", f.published[1].Rel)
	assert.Equal(t, "Read the board, then the plan.\n", f.published[1].After)
	assert.False(t, f.published[1].MayCreate, "a skill is never created by an Accept")
	assert.Equal(t, ".agents/skills/b/SKILL.md", r.WrittenPath)
	assert.Equal(t, "Read the board, then the plan.\n", proposal(t, d, id).AfterText)
	assert.Equal(t, before, folderFiles(t, folder))
}

// D2: a folder RepoRoute keeps on the working copy takes today's route —
// written, branch recorded, no pull request — and so does an Applier with no
// RepoRoute at all (the daemon's and the tuning chat's).
func TestAcceptPR_NonGitHubFolderKeepsWorkingCopyRoute(t *testing.T) {
	d := openDBs(t)
	folder := fullRepo(t)
	wb := repoWorkbench(t, d, folder)
	a, _ := repoApplier(t, d)
	f := &fakeGitHub{route: RepoRoute{PR: false}}
	f.wire(a)

	id := propose(t, d, repoProposal(DestRepoClaudeMD, wb, "", "Run tests.\n", "Run lint.\n"))
	r, err := a.Accept(id, "")
	require.NoError(t, err)
	assert.Empty(t, r.PRURL)
	assert.Equal(t, "main", r.WrittenBranch)
	assert.Equal(t, "Run lint.\n", readFile(t, filepath.Join(folder, "CLAUDE.md")))
	assert.Empty(t, f.published)
	assert.Empty(t, proposal(t, d, id).PRURL)

	git(t, folder, "commit", "-q", "-am", "owner commits")
	a.RepoRoute = nil
	id = propose(t, d, repoProposal(DestRepoWorkflow, wb, "", "# Workflow\n", "# Workflow\nReview first.\n"))
	_, err = a.Accept(id, "")
	require.NoError(t, err)
	assert.Equal(t, "accepted", proposal(t, d, id).Status)
	assert.Empty(t, f.published)
}

// D3 and §5: a GitHub folder without gh, and every Publish failure, refuse
// in the owner's words; the proposal stays open (never superseded) and the
// working copy is untouched.
func TestAcceptPR_RefusalsLeaveProposalOpen(t *testing.T) {
	cases := []struct {
		name     string
		set      func(f *fakeGitHub)
		sentinel error
		line     string
	}{
		{"no gh", func(f *fakeGitHub) { f.routeErr = fmt.Errorf("%w: gh: not logged in", ErrNoGH) }, ErrNoGH, NoGHLine},
		{"base differs", func(f *fakeGitHub) { f.publishErr = fmt.Errorf("%w: CLAUDE.md on main", ErrBaseDiffers) },
			ErrBaseDiffers, fmt.Sprintf(BaseDiffersLine, "CLAUDE.md")},
		{"push failed", func(f *fakeGitHub) { f.publishErr = fmt.Errorf("%w: remote: denied", ErrPushFailed) },
			ErrPushFailed, PushFailedLine},
		{"pr failed", func(f *fakeGitHub) { f.publishErr = fmt.Errorf("%w: gh pr create: 422", ErrPRFailed) },
			ErrPRFailed, PRFailedLine},
		{"timeout", func(f *fakeGitHub) { f.publishErr = fmt.Errorf("%w: git push", ErrTimeout) }, ErrTimeout, TimeoutLine},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			d := openDBs(t)
			a, f, folder, wb := prApplier(t, d)
			before := folderFiles(t, folder)
			c.set(f)
			id := propose(t, d, repoProposal(DestRepoClaudeMD, wb, "", "Run tests.\n", "Run lint.\n"))
			_, err := a.Accept(id, "")
			require.ErrorIs(t, err, c.sentinel)
			assert.Contains(t, err.Error(), c.line)
			p := proposal(t, d, id)
			assert.Equal(t, "open", p.Status)
			assert.Empty(t, p.PRURL)
			assert.Equal(t, before, folderFiles(t, folder))
		})
	}
}

// The pull-request route validates the text against the proposal's
// before-text before any GitHub call, and refuses unwired seams.
func TestAcceptPR_InvalidEditAndUnwiredSeams(t *testing.T) {
	d := openDBs(t)
	a, f, _, wb := prApplier(t, d)
	id := propose(t, d, repoProposal(DestRepoClaudeMD, wb, "", "Run tests.\n", "Run lint.\n"))
	_, err := a.Accept(id, strings.Repeat("x", skillBudget(len("Run tests.\n"))+1))
	require.ErrorIs(t, err, ErrInvalidEdit)
	assert.Empty(t, f.published)
	assert.Equal(t, "open", proposal(t, d, id).Status)

	a.RepoPublish = nil
	_, err = a.Accept(id, "")
	require.ErrorIs(t, err, errPRNotWired)
	assert.Equal(t, "open", proposal(t, d, id).Status)
}

// prAccepted is the n-th accepted pull-request row of the CLAUDE.md
// proposal, through Accept over the Applier's seams.
func prAccepted(t *testing.T, d dbs, a *Applier, wb int64, n int) int64 {
	t.Helper()
	p := repoProposal(DestRepoClaudeMD, wb, "", "Run tests.\n", "Run lint.\n")
	p.Fingerprint = fmt.Sprintf("pr|%d", n)
	id := propose(t, d, p)
	_, err := a.Accept(id, "")
	require.NoError(t, err)
	return id
}

// Spec §4.5: Rollback by the pull request's state. Merged → a revert pull
// request with the texts swapped on coach/revert-<id>, recorded apart from
// the original; open → closed; closed by hand → only the status. The working
// copy is never touched.
func TestRollbackPR_ByState(t *testing.T) {
	d := openDBs(t)
	a, f, folder, wb := prApplier(t, d)
	before := folderFiles(t, folder)

	f.state = prMerged
	id := prAccepted(t, d, a, wb, 1)
	r, err := a.RollbackWithResult(id, false)
	require.NoError(t, err)
	assert.Equal(t, "https://github.com/acme/repo/pull/2", r.RevertPRURL)
	require.Len(t, f.published, 2)
	assert.Equal(t, RepoPublishReq{ID: id, Rel: "CLAUDE.md", Before: "Run lint.\n", After: "Run tests.\n",
		Branch: fmt.Sprintf("coach/revert-%d", id), Title: "Revert: title", Body: f.published[1].Body,
		Reverts: "https://github.com/acme/repo/pull/1"}, f.published[1])
	assert.Contains(t, f.published[1].Body, "https://github.com/acme/repo/pull/1")
	p := proposal(t, d, id)
	assert.Equal(t, "rolled_back", p.Status)
	assert.Equal(t, "https://github.com/acme/repo/pull/1", p.PRURL, "the original pull request stays")
	assert.Equal(t, r.RevertPRURL, p.RevertPRURL)

	f.state = prOpen
	id = prAccepted(t, d, a, wb, 2)
	url := proposal(t, d, id).PRURL
	diff, err := a.Rollback(id, false)
	require.NoError(t, err)
	assert.Empty(t, diff)
	assert.Equal(t, []string{url}, f.closed)
	p = proposal(t, d, id)
	assert.Equal(t, "rolled_back", p.Status)
	assert.Empty(t, p.RevertPRURL)

	f.state = prClosed
	id = prAccepted(t, d, a, wb, 3)
	closedURL := proposal(t, d, id).PRURL
	published := len(f.published)
	r, err = a.RollbackWithResult(id, false)
	require.NoError(t, err)
	assert.Empty(t, r.RevertPRURL)
	assert.Len(t, f.published, published, "no push for a pull request closed by hand")
	assert.Equal(t, []string{url, closedURL}, f.closed,
		"a closed pull request goes through the idempotent close: only its leftover branch is deleted")
	assert.Equal(t, "rolled_back", proposal(t, d, id).Status)

	assert.Equal(t, before, folderFiles(t, folder))
}

// Finding 3: a pull request already closed — by hand, or by a Rollback
// whose branch deletion failed — is rolled back even when deleting its
// leftover branch fails again (logged, not fatal); and a close that a
// concurrent `coach sync-prs` saw first (it marked the row rolled_back
// between the close and MarkCoachRolledBack) counts as done.
func TestRollbackPR_ClosedAndRacingSync(t *testing.T) {
	d := openDBs(t)
	a, f, _, wb := prApplier(t, d)
	f.state, f.closeErr = prClosed, fmt.Errorf("%w: git push --delete: denied", ErrPushFailed)
	id := prAccepted(t, d, a, wb, 6)
	_, err := a.RollbackWithResult(id, false)
	require.NoError(t, err, "a leftover branch that cannot be deleted does not block the rollback")
	assert.Equal(t, "rolled_back", proposal(t, d, id).Status)

	f.state, f.closeErr = prOpen, nil
	id = prAccepted(t, d, a, wb, 7)
	a.RepoClosePR = func(string, string) error {
		_, err := d.Exec(`UPDATE coach_proposals SET status = 'rolled_back' WHERE id = ?`, id) // the sync wins the row
		return err
	}
	r, err := a.RollbackWithResult(id, false)
	require.NoError(t, err, "the sync marked the closed pull request rolled back first: done")
	assert.Empty(t, r.RevertPRURL)
	assert.Equal(t, "rolled_back", proposal(t, d, id).Status)

	// Another writer moved the row elsewhere (not rolled back): still the CAS error.
	id = prAccepted(t, d, a, wb, 8)
	a.RepoClosePR = func(string, string) error {
		_, err := d.Exec(`UPDATE coach_proposals SET status = 'superseded' WHERE id = ?`, id)
		return err
	}
	_, err = a.RollbackWithResult(id, false)
	require.ErrorIs(t, err, db.ErrCoachStateChanged)
}

// Spec §4.5: a failed state read, revert push or close refuses and leaves
// the proposal accepted with nothing recorded; a default branch that no
// longer holds the accepted text is ErrChangedSince.
func TestRollbackPR_FailuresStayAccepted(t *testing.T) {
	cases := []struct {
		name     string
		set      func(f *fakeGitHub)
		sentinel error
	}{
		{"gh fails", func(f *fakeGitHub) { f.stateErr = fmt.Errorf("%w: gh missing", ErrNoGH) }, ErrNoGH},
		{"state read fails", func(f *fakeGitHub) { f.stateErr = fmt.Errorf("%w: gh pr view: 502", ErrPRUnreadable) }, ErrPRUnreadable},
		{"revert push fails", func(f *fakeGitHub) {
			f.state, f.publishErr = prMerged, fmt.Errorf("%w: protected", ErrPushFailed)
		}, ErrPushFailed},
		{"base moved", func(f *fakeGitHub) {
			f.state, f.publishErr = prMerged, fmt.Errorf("%w: CLAUDE.md on main", ErrBaseDiffers)
		}, ErrChangedSince},
		{"close fails", func(f *fakeGitHub) { f.state, f.closeErr = prOpen, fmt.Errorf("%w: gh pr close", ErrPRFailed) }, ErrPRFailed},
		{"timeout", func(f *fakeGitHub) { f.stateErr = fmt.Errorf("%w: gh pr view", ErrTimeout) }, ErrTimeout},
		{"unknown state", func(f *fakeGitHub) { f.state = "DRAFT" }, nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			d := openDBs(t)
			a, f, _, wb := prApplier(t, d)
			id := prAccepted(t, d, a, wb, 4)
			c.set(f)
			diff, err := a.Rollback(id, true)
			require.Error(t, err)
			if c.sentinel != nil {
				require.ErrorIs(t, err, c.sentinel)
			}
			assert.Empty(t, diff, "no base text from the seam: no diff")
			p := proposal(t, d, id)
			assert.Equal(t, "accepted", p.Status)
			assert.Empty(t, p.RevertPRURL)
		})
	}
	// The base check names the file in the owner's words, as Accept's does.
	d := openDBs(t)
	a, f, _, wb := prApplier(t, d)
	id := prAccepted(t, d, a, wb, 5)
	f.state, f.publishErr = prMerged, fmt.Errorf("%w: CLAUDE.md on main", ErrBaseDiffers)
	_, err := a.Rollback(id, false)
	require.ErrorIs(t, err, ErrBaseDiffers)
	assert.Contains(t, err.Error(), fmt.Sprintf(BaseDiffersLine, "CLAUDE.md"))
}

// Spec §4.5: a revert whose base moved shows the diff accepted → the base's
// text now (changed_since, as the working-copy route does).
func TestRollbackPR_BaseMovedShowsTheDiff(t *testing.T) {
	d := openDBs(t)
	a, f, _, wb := prApplier(t, d)
	id := prAccepted(t, d, a, wb, 7)
	f.state = prMerged
	f.publishErr = &BaseDiffersError{Current: "Run lint.\nAnd format.\n", Detail: "CLAUDE.md on main"}
	r, err := a.RollbackWithResult(id, false)
	require.ErrorIs(t, err, ErrChangedSince)
	require.ErrorIs(t, err, ErrBaseDiffers)
	assert.Contains(t, r.Diff, "+And format.")
	assert.NotContains(t, err.Error(), "And format.", "the error never carries the file's text")
	diff, err := a.Rollback(id, true)
	require.ErrorIs(t, err, ErrChangedSince)
	assert.Equal(t, r.Diff, diff)
	assert.Equal(t, "accepted", proposal(t, d, id).Status)
}

// Ask #1169 on the PR route: reverting the Accept that created CLAUDE.md or
// AGENTS.md deletes the file again; a file that existed (or a skill, which
// Accept never creates) gets its before-text back.
func TestRollbackPR_CreatedFileIsDeleted(t *testing.T) {
	d := openDBs(t)
	a, f, _, wb := prApplier(t, d)
	f.state = prMerged
	for i, dest := range []string{DestRepoClaudeMD, DestRepoAgentsMD} {
		p := repoProposal(dest, wb, "", "", "Run tests.\n")
		p.Fingerprint = fmt.Sprintf("created|%d", i)
		id := propose(t, d, p)
		_, err := a.Accept(id, "")
		require.NoError(t, err)
		_, err = a.RollbackWithResult(id, false)
		require.NoError(t, err)
		last := f.published[len(f.published)-1]
		assert.True(t, last.Delete, dest)
		assert.Equal(t, "Run tests.\n", last.Before, dest)
		assert.Empty(t, last.After, dest)
	}
	id := prAccepted(t, d, a, wb, 8)
	_, err := a.RollbackWithResult(id, false)
	require.NoError(t, err)
	assert.False(t, f.published[len(f.published)-1].Delete, "an edited file is written back, not deleted")
}

// A failed state read names the pull request, never "did not open or close
// it" (PRFailedLine); gh missing keeps its own sentence. SyncPRs reports it
// the same way.
func TestRollbackPR_UnreadableStateSaysSo(t *testing.T) {
	d := openDBs(t)
	a, f, _, wb := prApplier(t, d)
	id := prAccepted(t, d, a, wb, 9)
	f.stateErr = fmt.Errorf("%w: gh pr view: HTTP 502", ErrPRUnreadable)
	_, err := a.Rollback(id, false)
	require.ErrorIs(t, err, ErrPRUnreadable)
	assert.Contains(t, err.Error(), fmt.Sprintf(PRUnreadableLine, "#1"))
	assert.NotContains(t, err.Error(), PRFailedLine)
	_, err = a.SyncPRs(applyNow)
	require.ErrorIs(t, err, ErrPRUnreadable)
	assert.Contains(t, err.Error(), fmt.Sprintf(PRUnreadableLine, "#1"))

	f.stateErr = fmt.Errorf("%w: %w: gh", ErrPRUnreadable, ErrNoGH)
	_, err = a.Rollback(id, false)
	assert.Contains(t, err.Error(), NoGHLine)
	assert.Equal(t, "accepted", proposal(t, d, id).Status)
}

// A refusal of the route (no gh) comes before the baseline measure: an
// Applier that cannot measure still gets the no_gh sentence.
func TestAcceptPR_RouteRefusalBeforeTheMeasure(t *testing.T) {
	d := openDBs(t)
	a, f, _, wb := prApplier(t, d)
	a.AgentLog = nil // the measure would fail
	f.routeErr = fmt.Errorf("%w: gh: not logged in", ErrNoGH)
	id := propose(t, d, repoProposal(DestRepoClaudeMD, wb, "", "Run tests.\n", "Run lint.\n"))
	_, err := a.Accept(id, "")
	require.ErrorIs(t, err, ErrNoGH)
	assert.NotContains(t, err.Error(), "baseline")
}

func TestPRNumber(t *testing.T) {
	assert.Equal(t, "#12", prNumber("https://github.com/acme/repo/pull/12"))
	assert.Equal(t, "#12", prNumber("https://github.com/acme/repo/pull/12/"))
	assert.Equal(t, "x", prNumber("x"))
}

// An Applier without the pull-request seams (the daemon's, the tuning
// chat's) never rolls a pull-request row back on the working copy.
func TestRollbackPR_SeamsNotWiredRefuses(t *testing.T) {
	d := openDBs(t)
	a, _, folder, wb := prApplier(t, d)
	id := prAccepted(t, d, a, wb, 6)
	before := folderFiles(t, folder)
	a.RepoRoute, a.RepoPublish, a.RepoPRState, a.RepoClosePR = nil, nil, nil, nil
	_, err := a.Rollback(id, true)
	require.ErrorIs(t, err, errPRNotWired)
	assert.Equal(t, "accepted", proposal(t, d, id).Status)
	assert.Equal(t, before, folderFiles(t, folder))
}

// syncFixture is an Applier over fake GitHub with one accepted pull-request
// row decided at judgeDecided.
func syncFixture(t *testing.T) (dbs, *Applier, *fakeGitHub, int64) {
	t.Helper()
	d, id := repoPRJudgeFixture(t, 0, "https://github.com/acme/repo/pull/7")
	a := newApplier(t, d)
	f := &fakeGitHub{}
	f.wire(a)
	return d, a, f, id
}

// Spec §4.4: SyncPRs decides on the merge and the Accept time only — a merge
// within repoCommitWait starts the window at the merge however late the sync
// runs; a merge after it, or a pull request still open after it, is a final
// too_little_data; closed unmerged is rolled_back.
func TestSyncPRs_Rules(t *testing.T) {
	day := 24 * time.Hour

	// Merged on day 29, synced on day 40: measured from the merge.
	d, a, f, id := syncFixture(t)
	f.state, f.mergedAt = prMerged, judgeDecided.Add(29*day)
	n, err := a.SyncPRs(judgeDecided.Add(40 * day))
	require.NoError(t, err)
	assert.Equal(t, 1, n)
	p := proposal(t, d, id)
	assert.Equal(t, f.mergedAt, p.MeasureFrom.UTC())
	assert.Empty(t, p.Verdict)
	// Measured: no longer listed, not synced again.
	n, err = a.SyncPRs(judgeDecided.Add(41 * day))
	require.NoError(t, err)
	assert.Zero(t, n)
	assert.Equal(t, 1, f.stateCalls)

	// Merged before the Accept's own stamp: measured from the Accept.
	d, a, f, id = syncFixture(t)
	f.state, f.mergedAt = prMerged, judgeDecided.Add(-time.Hour)
	_, err = a.SyncPRs(judgeDecided.Add(day))
	require.NoError(t, err)
	assert.Equal(t, judgeDecided, proposal(t, d, id).MeasureFrom.UTC())

	// Merged on day 31 (synced on day 32): too_little_data, never measured.
	d, a, f, id = syncFixture(t)
	f.state, f.mergedAt = prMerged, judgeDecided.Add(31*day)
	now := judgeDecided.Add(32 * day)
	n, err = a.SyncPRs(now)
	require.NoError(t, err)
	assert.Equal(t, 1, n)
	p = proposal(t, d, id)
	assert.Equal(t, "too_little_data", p.Verdict)
	assert.Equal(t, now, p.VerdictAt.UTC())
	assert.True(t, p.MeasureFrom.IsZero())
	assert.Equal(t, "accepted", p.Status)

	// Open under 30 days: nothing; open 30 days after the Accept: too_little_data.
	d, a, f, id = syncFixture(t)
	f.state = prOpen
	n, err = a.SyncPRs(judgeDecided.Add(29 * day))
	require.NoError(t, err)
	assert.Zero(t, n)
	assert.Empty(t, proposal(t, d, id).Verdict)
	n, err = a.SyncPRs(judgeDecided.Add(repoCommitWait))
	require.NoError(t, err)
	assert.Equal(t, 1, n)
	assert.Equal(t, "too_little_data", proposal(t, d, id).Verdict)

	// Closed without merge: the owner's rejection.
	d, a, f, id = syncFixture(t)
	f.state = prClosed
	n, err = a.SyncPRs(judgeDecided.Add(day))
	require.NoError(t, err)
	assert.Equal(t, 1, n)
	p = proposal(t, d, id)
	assert.Equal(t, "rolled_back", p.Status)
	assert.Empty(t, p.Verdict)
	assert.Empty(t, p.RevertPRURL)
}

// A failed state read leaves the row as it was and is reported; the other
// rows are still synced. Rows without a pull request are never read.
func TestSyncPRs_FailureSkipsTheRow(t *testing.T) {
	d, a, _, id := syncFixture(t)
	wb := proposal(t, d, id).WorkbenchID
	local := propose(t, d, db.CoachProposal{Destination: DestRepoAgentsMD, WorkbenchID: wb, AfterText: "Be brief.\n"})
	require.NoError(t, d.MarkCoachAccepted(local, "Be brief.\n", "main", "", nil, 0, judgeDecided))
	second := propose(t, d, db.CoachProposal{Destination: DestRepoWorkflow, WorkbenchID: wb, AfterText: "# W\n"})
	require.NoError(t, d.MarkCoachAccepted(second, "# W\n", "coach/proposal-x", "https://github.com/acme/repo/pull/8",
		nil, 0, judgeDecided))

	calls := 0
	a.RepoPRState = func(_, url string) (string, time.Time, error) {
		calls++
		if strings.HasSuffix(url, "/7") {
			return "", time.Time{}, fmt.Errorf("%w: gh pr view", ErrNoGH)
		}
		return prClosed, time.Time{}, nil
	}
	n, err := a.SyncPRs(judgeDecided.Add(time.Hour))
	require.ErrorIs(t, err, ErrNoGH)
	assert.Equal(t, 1, n)
	assert.Equal(t, 2, calls, "the working-copy row is not a pull request")
	p := proposal(t, d, id)
	assert.Equal(t, "accepted", p.Status)
	assert.Empty(t, p.Verdict)
	assert.True(t, p.MeasureFrom.IsZero())
	assert.Equal(t, "rolled_back", proposal(t, d, second).Status)
	assert.Equal(t, "accepted", proposal(t, d, local).Status)

	// Merged with no merge time: refused, the row left.
	d, a, f, id := syncFixture(t)
	f.state = prMerged
	_, err = a.SyncPRs(judgeDecided.Add(time.Hour))
	require.Error(t, err)
	assert.True(t, proposal(t, d, id).MeasureFrom.IsZero())
}

// No pull-request seams: nothing to sync is fine, a row to sync is an error.
func TestSyncPRs_NotWired(t *testing.T) {
	d := openDBs(t)
	n, err := newApplier(t, d).SyncPRs(applyNow)
	require.NoError(t, err)
	assert.Zero(t, n)

	d, a, _, id := syncFixture(t)
	a.RepoPRState = nil
	_, err = a.SyncPRs(applyNow)
	require.ErrorIs(t, err, errPRNotWired)
	assert.Equal(t, "accepted", proposal(t, d, id).Status)
}

// Spec §4.4: the judge gives no final verdict to a pull-request row without
// measure_from (only SyncPRs decides it); once SyncPRs set measure_from at a
// merge within repoCommitWait, the row is judged like any other.
func TestJudge_PRRowWaitsForSyncPRs(t *testing.T) {
	d, id := repoPRJudgeFixture(t, 5, "https://github.com/acme/repo/pull/7")
	j, c := runJudge(t, d, judgeDecided.Add(31*24*time.Hour))
	assert.Zero(t, j+c)
	p := proposal(t, d, id)
	assert.Empty(t, p.Verdict, "no verdict before SyncPRs decides")
	assert.True(t, p.VerdictAt.IsZero())

	set, err := d.SetCoachMeasureFrom(id, judgeDecided.Add(time.Hour))
	require.NoError(t, err)
	require.True(t, set)
	j, _ = runJudge(t, d, judgeDecided.Add(time.Hour+15*24*time.Hour))
	assert.Equal(t, 1, j)
	assert.Equal(t, "works", proposal(t, d, id).Verdict)
}
