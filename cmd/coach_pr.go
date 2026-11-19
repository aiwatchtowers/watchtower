package cmd

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"watchtower/internal/coach"
	"watchtower/internal/workbenchgit"
)

// A coach Accept or Roll Back of a workbench repository file in a GitHub
// folder goes through a pull request (docs/superpowers/specs/2026-11-19-coach-repo-edits-as-prs-design.md).
// This file fills coach.Applier's four pull-request seams over workbenchgit:
// the only place the pull-request helpers are called (COACH-01,
// TestCOACH01_NoGitWrites), in the processes the owner starts — `coach
// accept`, `coach rollback`, `coach sync-prs` — never in the daemon.

// coachPRBudget bounds a whole Accept, Roll Back or sync of pull requests
// (spec D10); each network call has its own 60 s budget inside it.
const coachPRBudget = 3 * time.Minute

// coachScratchDir is the folder the scratch worktrees go in, under the
// workspace (spec 4.1); `workbench cleanup` lists what is left there.
const coachScratchDir = "coach-pr"

// coachBranchTokenFile holds the workspace's branch token, in the workspace
// folder.
const coachBranchTokenFile = "coach_branch_token"

var coachTokenPattern = regexp.MustCompile(`^[0-9a-f]{8}$`)

// coachBranchToken is the workspace's branch token: 8 random hex digits made
// once and kept in <workspace>/coach_branch_token, so every Accept and
// Rollback of this workspace — across restarts, and a retry of the same
// proposal — names the same branches, while another workspace (on this
// Mac or another one, on the same repository) never does. It is written
// whole: a temp file linked into place, so a concurrent first call reads
// the winner's token, never a half-written one.
func coachBranchToken(workspace string) (string, error) {
	path := filepath.Join(workspace, coachBranchTokenFile)
	for range 3 {
		raw, err := os.ReadFile(path)
		if err == nil {
			tok := strings.TrimSpace(string(raw))
			if !coachTokenPattern.MatchString(tok) {
				return "", fmt.Errorf("%s holds no branch token: remove it to make a new one", path)
			}
			return tok, nil
		}
		if !errors.Is(err, fs.ErrNotExist) {
			return "", fmt.Errorf("reading the branch token: %w", err)
		}
		if err := newCoachBranchToken(workspace, path); err != nil && !errors.Is(err, fs.ErrExist) {
			return "", fmt.Errorf("making the branch token: %w", err)
		}
	}
	return "", errors.New("the branch token could not be read")
}

// newCoachBranchToken links a fresh token file into path; fs.ErrExist when
// another process made it first.
func newCoachBranchToken(workspace, path string) error {
	var b [4]byte
	if _, err := rand.Read(b[:]); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(workspace, coachBranchTokenFile+".*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	_, werr := tmp.WriteString(hex.EncodeToString(b[:]) + "\n")
	if err := errors.Join(werr, tmp.Close()); err != nil {
		return err
	}
	return os.Link(tmp.Name(), path)
}

// coachScopedBranch is branch (coach/proposal-<id> or coach/revert-<id>)
// in the workspace's namespace: coach/<token>/proposal-<id>.
func coachScopedBranch(token, branch string) (string, error) {
	rest, ok := strings.CutPrefix(branch, "coach/")
	if !ok {
		return "", fmt.Errorf("%q is not a coach branch", branch)
	}
	return "coach/" + token + "/" + rest, nil
}

// coachGitHubCalls are the workbenchgit pull-request calls the seams make.
type coachGitHubCalls struct {
	isGitHub    func(ctx context.Context, o workbenchgit.Options, ghLoggedIn func(host string) bool) (bool, error)
	originHost  func(ctx context.Context, o workbenchgit.Options) (string, error)
	originRepo  func(ctx context.Context, o workbenchgit.Options) (string, error)
	ghReady     func(ctx context.Context, o workbenchgit.Options, host string) error
	defaultBase func(ctx context.Context, o workbenchgit.Options) (branch, sha string, err error)
	publish     func(ctx context.Context, o workbenchgit.Options, req workbenchgit.PublishRequest) (workbenchgit.PublishResult, error)
	prState     func(ctx context.Context, o workbenchgit.Options, prURL string) (string, time.Time, error)
	closePR     func(ctx context.Context, o workbenchgit.Options, prURL string) error
}

// coachGitHub is the real workbenchgit (a seam for tests).
var coachGitHub = coachGitHubCalls{
	isGitHub: workbenchgit.IsGitHubFolder, originHost: workbenchgit.OriginHost, originRepo: workbenchgit.OriginRepo,
	ghReady: workbenchgit.GHReady, defaultBase: workbenchgit.DefaultBase, publish: workbenchgit.Publish,
	prState: workbenchgit.PRState, closePR: workbenchgit.ClosePR,
}

// coachGHPath is the gh the seams run: PATH's, else Homebrew's or
// /usr/local's (the Desktop starts the CLI with a GUI app's PATH); "" lets
// workbenchgit look gh up itself (missing: no_gh).
var coachGHPath = func() string {
	if p, err := exec.LookPath("gh"); err == nil {
		return p
	}
	for _, p := range []string{"/opt/homebrew/bin/gh", "/usr/local/bin/gh"} {
		if fi, err := os.Stat(p); err == nil && !fi.IsDir() {
			return p
		}
	}
	return ""
}

// prApplier is the coach's Applier with the pull-request seams filled over
// ctx: every git and gh call they make ends with it.
func (e *coachEnv) prApplier(ctx context.Context) *coach.Applier {
	a := e.applier()
	g := coachGitHub
	gh := coachGHPath()
	scratch := filepath.Join(e.cfg.WorkspaceDir(), coachScratchDir)
	opts := func(folder string) workbenchgit.Options {
		return workbenchgit.Options{Folder: folder, GHPath: gh, Scratch: scratch}
	}
	a.RepoRoute = func(folder string) (coach.RepoRoute, error) { return coachRoute(ctx, g, opts(folder)) }
	token := func() (string, error) { return coachBranchToken(e.cfg.WorkspaceDir()) }
	a.RepoPublish = func(folder string, req coach.RepoPublishReq) (string, string, error) {
		return coachPublish(ctx, g, opts(folder), token, req)
	}
	a.RepoPRState = func(folder, prURL string) (string, time.Time, error) {
		state, mergedAt, err := g.prState(ctx, opts(folder), prURL)
		return state, mergedAt, coachGitHubErr(err, coach.ErrPRUnreadable)
	}
	a.RepoClosePR = func(folder, prURL string) error {
		return coachGitHubErr(g.closePR(ctx, opts(folder), prURL), coach.ErrPRFailed)
	}
	return a
}

// coachRoute decides how a folder takes a repository edit (spec D8): a
// folder that is not a git work tree, or whose origin is not a GitHub
// repository gh can reach, keeps the working-copy route (which refuses
// not_git itself); a GitHub folder whose gh is missing or logged out is
// refused (no_gh, D3), never dropped to the working copy.
func coachRoute(ctx context.Context, g coachGitHubCalls, o workbenchgit.Options) (coach.RepoRoute, error) {
	if !coachFolderStatus(ctx, o.Folder).Git {
		return coach.RepoRoute{}, nil
	}
	isGitHub, err := g.isGitHub(ctx, o, func(host string) bool { return g.ghReady(ctx, o, host) == nil })
	if err != nil {
		return coach.RepoRoute{}, coachGitHubErr(err, nil)
	}
	if !isGitHub {
		return coach.RepoRoute{}, nil
	}
	host, err := g.originHost(ctx, o)
	if err != nil {
		return coach.RepoRoute{}, coachGitHubErr(err, nil)
	}
	if err := g.ghReady(ctx, o, host); err != nil {
		return coach.RepoRoute{}, coachGitHubErr(err, nil)
	}
	return coach.RepoRoute{PR: true}, nil
}

// coachPublish opens req's pull request against the repository's default
// branch, on req's branch in the workspace's namespace (coachScopedBranch),
// and returns its URL and the branch pushed. A revert is refused before
// anything moves when the folder's origin is gone or is no longer the
// repository of the pull request it reverts (ErrOriginMoved).
func coachPublish(ctx context.Context, g coachGitHubCalls, o workbenchgit.Options, token func() (string, error),
	req coach.RepoPublishReq) (string, string, error) {
	if req.Reverts != "" {
		origin, err := g.originRepo(ctx, o)
		if err != nil {
			return "", "", fmt.Errorf("%w: %v", coach.ErrOriginMoved, err)
		}
		if pr := workbenchgit.PRRepository(req.Reverts); pr == "" || !strings.EqualFold(pr, origin) {
			return "", "", fmt.Errorf("%w: pull request %s, origin %s", coach.ErrOriginMoved, req.Reverts, origin)
		}
	}
	tok, err := token()
	if err != nil {
		return "", "", err
	}
	branch, err := coachScopedBranch(tok, req.Branch)
	if err != nil {
		return "", "", err
	}
	base, sha, err := g.defaultBase(ctx, o)
	if err != nil {
		return "", "", coachGitHubErr(err, nil)
	}
	res, err := g.publish(ctx, o, workbenchgit.PublishRequest{
		ID: req.ID, Rel: req.Rel, Before: req.Before, After: req.After, Branch: branch,
		Title: req.Title, Body: req.Body, MayCreate: req.MayCreate, Delete: req.Delete, BaseBranch: base, BaseSHA: sha,
	})
	if err != nil {
		return "", "", coachGitHubErr(err, nil)
	}
	return res.PRURL, branch, nil
}

// coachGitHubErr is a workbenchgit failure as the coach's sentinel (its
// owner sentence and --json code follow from it): a timeout, gh missing or
// logged out, the base moved (with the base's text, for the rollback diff),
// a refused push, a failed pull-request call; anything else is other (nil:
// the error as it is).
func coachGitHubErr(err, other error) error {
	var bd *workbenchgit.BaseDiffersError
	switch {
	case err == nil:
		return nil
	case errors.Is(err, workbenchgit.ErrTimeout):
		return fmt.Errorf("%w: %v", coach.ErrTimeout, err)
	case errors.Is(err, workbenchgit.ErrNoGH):
		return fmt.Errorf("%w: %v", coach.ErrNoGH, err)
	case errors.As(err, &bd):
		return &coach.BaseDiffersError{Current: bd.Current, Detail: bd.Rel + " on " + bd.Base}
	case errors.Is(err, workbenchgit.ErrPushFailed):
		return fmt.Errorf("%w: %v", coach.ErrPushFailed, err)
	case errors.Is(err, workbenchgit.ErrPRFailed):
		return fmt.Errorf("%w: %v", coach.ErrPRFailed, err)
	case other != nil:
		return fmt.Errorf("%w: %v", other, err)
	}
	return err
}

// coachPRContext is ctx (Background when the command has none) bounded by
// coachPRBudget.
func coachPRContext(ctx context.Context) (context.Context, context.CancelFunc) {
	if ctx == nil {
		ctx = context.Background()
	}
	return context.WithTimeout(ctx, coachPRBudget)
}
