package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/coach"
	"watchtower/internal/db"
	"watchtower/internal/workbenchgit"
)

const fakeBaseSHA = "0123456789abcdef0123456789abcdef01234567"

// fakeGitHubCmd replaces the workbenchgit pull-request calls with a fake
// GitHub: a GitHub folder whose gh is logged in, default branch main, every
// Publish opening pull/<n>. It records the requests, the options and
// whether each call's context carries the Accept/Roll Back deadline.
type fakeGitHubCmd struct {
	ghErr, baseErr, publishErr, stateErr, closeErr, originErr error
	notGitHub                                                 bool
	origin, state                                             string
	mergedAt                                                  time.Time
	published                                                 []workbenchgit.PublishRequest
	closed, ghHosts                                           []string
	opts                                                      []workbenchgit.Options
	noDeadline                                                int
}

func (f *fakeGitHubCmd) seen(ctx context.Context, o workbenchgit.Options) {
	f.opts = append(f.opts, o)
	if dl, ok := ctx.Deadline(); !ok || time.Until(dl) > coachPRBudget {
		f.noDeadline++
	}
}

func installFakeGitHub(t *testing.T) *fakeGitHubCmd {
	t.Helper()
	f := &fakeGitHubCmd{origin: "github.com/acme/repo", state: "MERGED"}
	prev, prevGH, prevStatus := coachGitHub, coachGHPath, coachFolderStatus
	t.Cleanup(func() { coachGitHub, coachGHPath, coachFolderStatus = prev, prevGH, prevStatus })
	coachGHPath = func() string { return "/fake/gh" }
	coachFolderStatus = func(context.Context, string) workbenchgit.Status {
		return workbenchgit.Status{Git: true, StatusOK: true}
	}
	coachGitHub = coachGitHubCalls{
		// origin's one URL names f.origin (HOST/OWNER/REPO): github.com
		// always, another host when accept takes it.
		githubOrigin: func(ctx context.Context, o workbenchgit.Options, accept func(string) bool) (workbenchgit.GitHubRepo, error) {
			f.seen(ctx, o)
			if f.notGitHub || f.originErr != nil {
				return workbenchgit.GitHubRepo{}, f.originErr
			}
			host, _, _ := strings.Cut(f.origin, "/")
			if host != "github.com" && !accept(host) {
				return workbenchgit.GitHubRepo{}, nil
			}
			return workbenchgit.GitHubRepo{Host: host, Repo: f.origin}, nil
		},
		ghReady: func(ctx context.Context, o workbenchgit.Options, host string) error {
			f.seen(ctx, o)
			f.ghHosts = append(f.ghHosts, host)
			return f.ghErr
		},
		defaultBase: func(ctx context.Context, o workbenchgit.Options) (string, string, error) {
			f.seen(ctx, o)
			return "main", fakeBaseSHA, f.baseErr
		},
		publish: func(ctx context.Context, o workbenchgit.Options, req workbenchgit.PublishRequest) (workbenchgit.PublishResult, error) {
			f.seen(ctx, o)
			if f.publishErr != nil {
				return workbenchgit.PublishResult{}, f.publishErr
			}
			f.published = append(f.published, req)
			return workbenchgit.PublishResult{PRURL: fmt.Sprintf("https://github.com/acme/repo/pull/%d", 10+len(f.published)),
				Base: req.BaseBranch}, nil
		},
		prState: func(ctx context.Context, o workbenchgit.Options, _ string) (string, time.Time, error) {
			f.seen(ctx, o)
			return f.state, f.mergedAt, f.stateErr
		},
		closePR: func(ctx context.Context, o workbenchgit.Options, prURL string) error {
			f.seen(ctx, o)
			if f.closeErr != nil {
				return f.closeErr
			}
			f.closed = append(f.closed, prURL)
			return nil
		},
	}
	return f
}

// prWorkbench is a workbench on a plain folder (git is faked).
func prWorkbench(t *testing.T, d *db.DB) int64 {
	t.Helper()
	folder, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	wb, err := d.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	return wb
}

// acceptedPRRow is insertRepoProposal accepted through pull request prURL.
func acceptedPRRow(t *testing.T, d *db.DB, wb int64, fp, prURL string, at time.Time) int64 {
	t.Helper()
	id := insertRepoProposal(t, d, wb, fp)
	require.NoError(t, d.MarkCoachAccepted(id, "Run tests.\n", "coach/proposal-"+strconv.FormatInt(id, 10), prURL, nil, 0, at))
	return id
}

func coachWorkspaceScratch(t *testing.T) string {
	t.Helper()
	cfg, err := workspaceConfigFromFlags()
	require.NoError(t, err)
	return filepath.Join(cfg.WorkspaceDir(), coachScratchDir)
}

// coachTestBranch is kind-<id> in the test workspace's branch namespace.
func coachTestBranch(t *testing.T, kind string, id int64) string {
	t.Helper()
	cfg, err := workspaceConfigFromFlags()
	require.NoError(t, err)
	tok, err := coachBranchToken(cfg.WorkspaceDir())
	require.NoError(t, err)
	return fmt.Sprintf("coach/%s/%s-%d", tok, kind, id)
}

// Spec §4.3: Accept in a GitHub folder opens the pull request against the
// default branch from the workspace's scratch folder under the 3-minute
// budget; --json reports pr_url and the branch pushed.
func TestCoachAcceptPR_JSON(t *testing.T) {
	d := coachSetup(t)
	f := installFakeGitHub(t)
	id := insertRepoProposal(t, d, prWorkbench(t, d), "pr1")

	out, err := runCoach(t, "", "accept", strconv.FormatInt(id, 10), "--json")
	require.NoError(t, err, out)
	top := coachJSONObject(t, out)
	assert.ElementsMatch(t, []string{"ok", "id", "status", "pack_copies_updated", "pack_copies_drifted",
		"written_path", "written_branch", "pr_url"}, coachObjectKeys(t, json.RawMessage(out)))
	assert.JSONEq(t, `"https://github.com/acme/repo/pull/11"`, string(top["pr_url"]))
	assert.JSONEq(t, strconv.Quote(coachTestBranch(t, "proposal", id)), string(top["written_branch"]))
	assert.JSONEq(t, `"CLAUDE.md"`, string(top["written_path"]))
	require.Len(t, f.published, 1)
	assert.Equal(t, workbenchgit.PublishRequest{ID: id, Rel: "CLAUDE.md", Before: "", After: "Run tests.\n",
		Branch: coachTestBranch(t, "proposal", id), Title: "Run tests", Body: f.published[0].Body,
		MayCreate: true, BaseBranch: "main", BaseSHA: fakeBaseSHA}, f.published[0])
	for _, o := range f.opts {
		assert.Equal(t, "/fake/gh", o.GHPath)
		assert.Equal(t, coachWorkspaceScratch(t), o.Scratch)
	}
	assert.Zero(t, f.noDeadline, "every call runs under the 3-minute budget")
	p, err := d.GetCoachProposal(id)
	require.NoError(t, err)
	assert.Equal(t, "https://github.com/acme/repo/pull/11", p.PRURL)

	// Human output names the pull request.
	id2 := insertRepoProposal(t, d, prWorkbench(t, d), "pr2")
	out, err = runCoach(t, "", "accept", strconv.FormatInt(id2, 10))
	require.NoError(t, err)
	assert.Contains(t, out, "Pull request: https://github.com/acme/repo/pull/12")
}

// The pull-request failures reach --json as their codes with the owner's
// sentence; the proposal stays open.
func TestCoachAcceptPR_FailureCodes(t *testing.T) {
	cases := []struct {
		name, code, line string
		set              func(f *fakeGitHubCmd)
	}{
		{"no gh", "no_gh", coach.NoGHLine, func(f *fakeGitHubCmd) { f.ghErr = fmt.Errorf("%w: gh: not logged in", workbenchgit.ErrNoGH) }},
		{"base differs", "base_differs", fmt.Sprintf(coach.BaseDiffersLine, "CLAUDE.md"), func(f *fakeGitHubCmd) {
			f.publishErr = &workbenchgit.BaseDiffersError{Rel: "CLAUDE.md", Base: "main", Current: "Theirs.\n"}
		}},
		{"push failed", "push_failed", coach.PushFailedLine, func(f *fakeGitHubCmd) {
			f.publishErr = fmt.Errorf("%w: remote: denied", workbenchgit.ErrPushFailed)
		}},
		{"pr failed", "pr_failed", coach.PRFailedLine, func(f *fakeGitHubCmd) {
			f.publishErr = fmt.Errorf("%w: gh pr create: 422", workbenchgit.ErrPRFailed)
		}},
		{"timeout", "timeout", coach.TimeoutLine, func(f *fakeGitHubCmd) {
			f.baseErr = fmt.Errorf("%w: gh repo view", workbenchgit.ErrTimeout)
		}},
		{"fetch failed", "failed", "fetch", func(f *fakeGitHubCmd) { f.publishErr = errors.New("git fetch: bad object") }},
		{"gh offline", "github_unreachable", coach.UnreachableLine, func(f *fakeGitHubCmd) {
			f.ghErr = fmt.Errorf("%w: gh auth status: error connecting to api.github.com", workbenchgit.ErrUnreachable)
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			d := coachSetup(t)
			f := installFakeGitHub(t)
			c.set(f)
			id := insertRepoProposal(t, d, prWorkbench(t, d), "pr-fail")
			out, err := runCoach(t, "", "accept", strconv.FormatInt(id, 10), "--json")
			require.Error(t, err)
			top := coachJSONObject(t, out)
			assert.JSONEq(t, `false`, string(top["ok"]))
			assert.JSONEq(t, strconv.Quote(c.code), string(top["code"]))
			assert.Contains(t, string(top["error"]), c.line)
			assert.NotContains(t, out, "Theirs.", "the base's text is never in the failure")
			p, err := d.GetCoachProposal(id)
			require.NoError(t, err)
			assert.Equal(t, "open", p.Status)
			assert.Empty(t, p.PRURL)
		})
	}
}

// Follow-up 2: on a host other than github.com, a gh that cannot check the
// login (offline, over budget) refuses the Accept with that code — nothing
// published, nothing written — instead of dropping to the working copy; only
// gh missing or not logged in to that host keeps D8's working-copy route.
func TestCoachAcceptPR_OtherHostUncheckedLoginRefuses(t *testing.T) {
	for _, c := range []struct {
		name, code string
		err        error
	}{
		{"offline", "github_unreachable", fmt.Errorf("%w: gh auth status: error connecting", workbenchgit.ErrUnreachable)},
		{"over budget", "timeout", fmt.Errorf("%w: gh auth status", workbenchgit.ErrTimeout)},
	} {
		t.Run(c.name, func(t *testing.T) {
			d := coachSetup(t)
			f := installFakeGitHub(t)
			f.origin, f.ghErr = "ghe.example.com/team/repo", c.err
			wb := prWorkbench(t, d)
			id := insertRepoProposal(t, d, wb, "unchecked")
			out, err := runCoach(t, "", "accept", strconv.FormatInt(id, 10), "--json")
			require.Error(t, err)
			assert.JSONEq(t, strconv.Quote(c.code), string(coachJSONObject(t, out)["code"]), out)
			assert.Empty(t, f.published)
			p, err := d.GetCoachProposal(id)
			require.NoError(t, err)
			assert.Equal(t, "open", p.Status)
			folder, err := d.GetWorkbench(wb)
			require.NoError(t, err)
			_, err = os.Stat(filepath.Join(folder.FolderPath, "CLAUDE.md"))
			assert.ErrorIs(t, err, os.ErrNotExist, "the working copy is not written")
		})
	}

	// Not logged in to that host: D8's working-copy route, the file written.
	d := coachSetup(t)
	f := installFakeGitHub(t)
	f.origin, f.ghErr = "ghe.example.com/team/repo", fmt.Errorf("%w: gh: not logged in", workbenchgit.ErrNoGH)
	coachFolderStatus = func(ctx context.Context, folder string) workbenchgit.Status {
		return workbenchgit.ReadStatus(ctx, workbenchgit.Options{Folder: folder})
	}
	repo := gitBranchRepo(t)
	wb, err := d.CreateWorkbench("acme", repo)
	require.NoError(t, err)
	id := insertRepoProposal(t, d, wb, "logged-out")
	out, err := runCoach(t, "", "accept", strconv.FormatInt(id, 10), "--json")
	require.NoError(t, err, out)
	assert.Empty(t, f.published)
	raw, err := os.ReadFile(filepath.Join(repo, "CLAUDE.md"))
	require.NoError(t, err)
	assert.Equal(t, "Run tests.\n", string(raw))
}

// Finding 5: the repository the route chose — here on a GitHub Enterprise
// host gh is logged in to — is the one GHReady checks and Publish works on.
func TestCoachAcceptPR_RouteRepoCarriesThrough(t *testing.T) {
	d := coachSetup(t)
	f := installFakeGitHub(t)
	f.origin = "ghe.example.com/team/repo"
	id := insertRepoProposal(t, d, prWorkbench(t, d), "ghe")
	out, err := runCoach(t, "", "accept", strconv.FormatInt(id, 10), "--json")
	require.NoError(t, err, out)
	require.Len(t, f.published, 1)
	assert.Equal(t, []string{"ghe.example.com", "ghe.example.com"}, f.ghHosts, "the chosen host, never another URL's")
	last := f.opts[len(f.opts)-1]
	assert.Equal(t, "ghe.example.com/team/repo", last.Repo, "Publish works on the routed repository")
}

// Finding 4: one Accept, Decline or Roll Back of a proposal at a time
// across processes — a second is refused at once with in_progress and
// changes nothing; once the first ends the lock is free again.
func TestCoachProposalLock(t *testing.T) {
	ws := t.TempDir()
	unlock, err := coachProposalLock(ws, 7)
	require.NoError(t, err)
	type result struct{ err error }
	got := make(chan result)
	go func() { // another process's decision of the same proposal
		u, err := coachProposalLock(ws, 7)
		if u != nil {
			u()
		}
		got <- result{err}
	}()
	second := <-got
	require.ErrorIs(t, second.err, coach.ErrInProgress)
	assert.Contains(t, second.err.Error(), coach.InProgressLine)
	assert.Equal(t, "in_progress", codedCoachErr(second.err).code)
	other, err := coachProposalLock(ws, 8)
	require.NoError(t, err, "another proposal is not blocked")
	other()
	unlock()
	again, err := coachProposalLock(ws, 7)
	require.NoError(t, err, "free once the first decision ended")
	again()
}

// The verbs take the lock: with another decision of the proposal running,
// Accept, Decline and Roll Back are refused with in_progress and nothing
// reaches GitHub or the row.
func TestCoachVerbs_RefusedWhileAnotherDecisionRuns(t *testing.T) {
	d := coachSetup(t)
	f := installFakeGitHub(t)
	cfg, err := workspaceConfigFromFlags()
	require.NoError(t, err)
	open := insertRepoProposal(t, d, prWorkbench(t, d), "lock-open")
	accepted := acceptedPRRow(t, d, prWorkbench(t, d), "lock-acc", "https://github.com/acme/repo/pull/3", time.Now())
	for _, c := range []struct {
		verb   string
		id     int64
		status string
	}{{"accept", open, "open"}, {"decline", open, "open"}, {"rollback", accepted, "accepted"}} {
		unlock, err := coachProposalLock(cfg.WorkspaceDir(), c.id)
		require.NoError(t, err)
		out, err := runCoach(t, "", c.verb, strconv.FormatInt(c.id, 10), "--json")
		unlock()
		require.Error(t, err, c.verb)
		assert.JSONEq(t, `"in_progress"`, string(coachJSONObject(t, out)["code"]), c.verb)
		p, err := d.GetCoachProposal(c.id)
		require.NoError(t, err)
		assert.Equal(t, c.status, p.Status, c.verb)
	}
	assert.Empty(t, f.published)
	assert.Empty(t, f.closed)
	out, err := runCoach(t, "", "accept", strconv.FormatInt(open, 10), "--json")
	require.NoError(t, err, out)
}

// A folder that is not a GitHub one keeps the working-copy route (D2): no
// pull request, the file is written.
func TestCoachAcceptPR_NonGitHubFolderWritesTheWorkingCopy(t *testing.T) {
	d := coachSetup(t)
	f := installFakeGitHub(t)
	f.notGitHub = true
	coachFolderStatus = func(ctx context.Context, folder string) workbenchgit.Status { // a real repository here
		return workbenchgit.ReadStatus(ctx, workbenchgit.Options{Folder: folder})
	}
	repo := gitBranchRepo(t)
	wb, err := d.CreateWorkbench("acme", repo)
	require.NoError(t, err)
	id := insertRepoProposal(t, d, wb, "local")
	out, err := runCoach(t, "", "accept", strconv.FormatInt(id, 10), "--json")
	require.NoError(t, err, out)
	assert.JSONEq(t, `""`, string(coachJSONObject(t, out)["pr_url"]))
	assert.Empty(t, f.published)
	raw, err := os.ReadFile(filepath.Join(repo, "CLAUDE.md"))
	require.NoError(t, err)
	assert.Equal(t, "Run tests.\n", string(raw))
}

// Spec §4.5 and the carry-in rulings: a merged pull request is reverted by
// one that deletes the file the Accept created; --json reports
// revert_pr_url.
func TestCoachRollbackPR_Merged(t *testing.T) {
	d := coachSetup(t)
	f := installFakeGitHub(t)
	wb := prWorkbench(t, d)
	id := acceptedPRRow(t, d, wb, "rb1", "https://github.com/acme/repo/pull/3", time.Now())

	out, err := runCoach(t, "", "rollback", strconv.FormatInt(id, 10), "--json")
	require.NoError(t, err, out)
	assert.JSONEq(t, fmt.Sprintf(`{"ok":true,"id":%d,"status":"rolled_back","revert_pr_url":"https://github.com/acme/repo/pull/11"}`, id), out)
	require.Len(t, f.published, 1)
	req := f.published[0]
	assert.True(t, req.Delete, "the Accept created CLAUDE.md: the revert deletes it")
	assert.Equal(t, "Run tests.\n", req.Before)
	assert.Empty(t, req.After)
	assert.Equal(t, coachTestBranch(t, "revert", id), req.Branch)
	assert.False(t, req.MayCreate, "a revert's base must hold the accepted file")
	assert.Zero(t, f.noDeadline)
	p, err := d.GetCoachProposal(id)
	require.NoError(t, err)
	assert.Equal(t, "rolled_back", p.Status)
	assert.Equal(t, "https://github.com/acme/repo/pull/11", p.RevertPRURL)

	// Human output; an open pull request is closed.
	f.state = "OPEN"
	id = acceptedPRRow(t, d, wb, "rb2", "https://github.com/acme/repo/pull/4", time.Now())
	out, err = runCoach(t, "", "rollback", strconv.FormatInt(id, 10))
	require.NoError(t, err)
	assert.Contains(t, out, "rolled_back")
	assert.Equal(t, []string{"https://github.com/acme/repo/pull/4"}, f.closed)
}

// Rollback refusals: the base moved (changed_since with the diff), origin
// is another repository (origin_moved, nothing pushed), the state cannot be
// read (pr_unreadable, never "did not open or close"), gh missing (no_gh),
// closing fails (pr_failed). The proposal stays accepted.
func TestCoachRollbackPR_FailureCodes(t *testing.T) {
	cases := []struct {
		name, code, text string
		set              func(f *fakeGitHubCmd)
	}{
		{"base moved", "changed_since", "Run tests.", func(f *fakeGitHubCmd) {
			f.publishErr = &workbenchgit.BaseDiffersError{Rel: "CLAUDE.md", Base: "main", Current: "Run tests.\nAnd lint.\n"}
		}},
		{"origin moved", "origin_moved", coach.OriginMovedLine, func(f *fakeGitHubCmd) { f.origin = "github.com/acme/other" }},
		{"origin gone", "origin_moved", coach.OriginMovedLine, func(f *fakeGitHubCmd) {
			f.originErr = errors.New(`origin [] does not name a GitHub repository`)
		}},
		{"state unreadable", "pr_unreadable", fmt.Sprintf(coach.PRUnreadableLine, "#3"), func(f *fakeGitHubCmd) {
			f.stateErr = errors.New("gh pr view: HTTP 502")
		}},
		{"no gh", "no_gh", coach.NoGHLine, func(f *fakeGitHubCmd) {
			f.stateErr = fmt.Errorf("%w: exec: gh: not found", workbenchgit.ErrNoGH)
		}},
		{"state timeout", "timeout", coach.TimeoutLine, func(f *fakeGitHubCmd) {
			f.stateErr = fmt.Errorf("%w: gh pr view", workbenchgit.ErrTimeout)
		}},
		{"close fails", "pr_failed", coach.PRFailedLine, func(f *fakeGitHubCmd) {
			f.state, f.closeErr = "OPEN", errors.New("gh pr close: HTTP 403")
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			d := coachSetup(t)
			f := installFakeGitHub(t)
			c.set(f)
			id := acceptedPRRow(t, d, prWorkbench(t, d), "rbf", "https://github.com/acme/repo/pull/3", time.Now())
			out, err := runCoach(t, "", "rollback", strconv.FormatInt(id, 10), "--json")
			require.Error(t, err)
			top := coachJSONObject(t, out)
			assert.JSONEq(t, strconv.Quote(c.code), string(top["code"]), out)
			if c.code == "changed_since" {
				var diff string
				require.NoError(t, json.Unmarshal(top["diff"], &diff))
				assert.Contains(t, diff, "+And lint.")
				assert.NotContains(t, string(top["error"]), "And lint.")
			} else {
				assert.Contains(t, string(top["error"]), c.text)
			}
			if c.code != "pr_failed" {
				assert.NotContains(t, string(top["error"]), coach.PRFailedLine, "only a failed close says so")
			}
			if c.code == "origin_moved" || c.code == "no_gh" {
				assert.Empty(t, f.published, "refused before anything is pushed")
			}
			p, err := d.GetCoachProposal(id)
			require.NoError(t, err)
			assert.Equal(t, "accepted", p.Status)
			assert.Empty(t, p.RevertPRURL)
		})
	}

	// Human output of a moved base: the diff, and no --force advice.
	d := coachSetup(t)
	f := installFakeGitHub(t)
	f.publishErr = &workbenchgit.BaseDiffersError{Rel: "CLAUDE.md", Base: "main", Current: "Run tests.\nAnd lint.\n"}
	id := acceptedPRRow(t, d, prWorkbench(t, d), "rbh", "https://github.com/acme/repo/pull/3", time.Now())
	out, err := runCoach(t, "", "rollback", strconv.FormatInt(id, 10))
	require.Error(t, err)
	assert.Contains(t, out, "+And lint.")
	assert.NotContains(t, err.Error(), "--force")
}

// The branch token is made once per workspace and read back the same.
func TestCoachBranchToken(t *testing.T) {
	ws := t.TempDir()
	tok, err := coachBranchToken(ws)
	require.NoError(t, err)
	assert.Regexp(t, `^[0-9a-f]{8}$`, tok)
	again, err := coachBranchToken(ws)
	require.NoError(t, err)
	assert.Equal(t, tok, again)
	entries, err := os.ReadDir(ws)
	require.NoError(t, err)
	assert.Len(t, entries, 1, "no temp file left")
	assert.NotEqual(t, tok, func() string { other, _ := coachBranchToken(t.TempDir()); return other }())

	require.NoError(t, os.WriteFile(filepath.Join(ws, coachBranchTokenFile), []byte("nope\n"), 0o600))
	_, err = coachBranchToken(ws)
	require.Error(t, err)

	b, err := coachScopedBranch("0a1b2c3d", "coach/revert-7")
	require.NoError(t, err)
	assert.Equal(t, "coach/0a1b2c3d/revert-7", b)
	_, err = coachScopedBranch("0a1b2c3d", "main")
	require.Error(t, err)
}

// Spec §4.4: `coach sync-prs` starts a merged pull request's verdict window
// at its merge; a row it cannot read is reported, not a failure.
func TestCoachSyncPRs(t *testing.T) {
	d := coachSetup(t)
	f := installFakeGitHub(t)
	wb := prWorkbench(t, d)
	accepted := time.Now().Add(-48 * time.Hour).UTC().Truncate(time.Second)
	id := acceptedPRRow(t, d, wb, "s1", "https://github.com/acme/repo/pull/3", accepted)
	f.mergedAt = accepted.Add(time.Hour)

	out, err := runCoach(t, "", "sync-prs", "--json")
	require.NoError(t, err, out)
	assert.JSONEq(t, `{"ok":true,"changed":1,"sync_error":"","sync_code":""}`, out)
	assert.Zero(t, f.noDeadline)
	p, err := d.GetCoachProposal(id)
	require.NoError(t, err)
	assert.Equal(t, f.mergedAt, p.MeasureFrom.UTC())

	// Nothing left to sync.
	out, err = runCoach(t, "", "sync-prs")
	require.NoError(t, err)
	assert.Contains(t, out, "0 changed")

	// gh logged out: the row stays, the reason is reported.
	acceptedPRRow(t, d, wb, "s2", "https://github.com/acme/repo/pull/4", accepted)
	f.stateErr = fmt.Errorf("%w: gh auth login", workbenchgit.ErrNoGH)
	out, err = runCoach(t, "", "sync-prs", "--json")
	require.NoError(t, err, out)
	top := coachJSONObject(t, out)
	assert.JSONEq(t, `0`, string(top["changed"]))
	assert.JSONEq(t, `"no_gh"`, string(top["sync_code"]))
	assert.Contains(t, string(top["sync_error"]), "gh auth login")
}

// sync-prs is refused under an AI agent's markers, like the owner verbs.
func TestCoachSyncPRs_RefusedUnderAgent(t *testing.T) {
	d := coachSetup(t)
	f := installFakeGitHub(t)
	id := acceptedPRRow(t, d, prWorkbench(t, d), "s3", "https://github.com/acme/repo/pull/3", time.Now())
	t.Setenv(agentEnvMarkers[0], "1")
	out, err := runCoach(t, "", "sync-prs", "--json")
	require.Error(t, err)
	assert.Contains(t, err.Error(), agentEnvMarkers[0])
	assert.JSONEq(t, `false`, string(coachJSONObject(t, out)["ok"]))
	assert.Empty(t, f.opts, "GitHub is never asked")
	p, err := d.GetCoachProposal(id)
	require.NoError(t, err)
	assert.True(t, p.MeasureFrom.IsZero())
}

// coachGitHubErr maps each workbenchgit failure to the coach sentinel its
// code follows from; the fallback names an unreadable state or a failed
// close, never a timeout or a missing gh.
func TestCoachGitHubErr(t *testing.T) {
	assert.NoError(t, coachGitHubErr(nil, coach.ErrPRUnreadable))
	for _, c := range []struct {
		in   error
		want error
	}{
		{fmt.Errorf("%w: x", workbenchgit.ErrTimeout), coach.ErrTimeout},
		{fmt.Errorf("%w: x", workbenchgit.ErrNoGH), coach.ErrNoGH},
		{fmt.Errorf("%w: x", workbenchgit.ErrPushFailed), coach.ErrPushFailed},
		{fmt.Errorf("%w: x", workbenchgit.ErrPRFailed), coach.ErrPRFailed},
		{&workbenchgit.BaseDiffersError{Current: "x"}, coach.ErrBaseDiffers},
		{errors.New("other"), coach.ErrPRUnreadable},
	} {
		got := coachGitHubErr(c.in, coach.ErrPRUnreadable)
		assert.ErrorIs(t, got, c.want, c.in.Error())
	}
	var bd *coach.BaseDiffersError
	require.ErrorAs(t, coachGitHubErr(&workbenchgit.BaseDiffersError{Current: "Theirs.\n"}, nil), &bd)
	assert.Equal(t, "Theirs.\n", bd.Current)
	plain := errors.New("plain")
	assert.Equal(t, plain, coachGitHubErr(plain, nil))
	assert.False(t, strings.Contains(coachGitHubErr(&workbenchgit.BaseDiffersError{Current: "Theirs."}, nil).Error(), "Theirs"))
}
