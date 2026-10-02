package workbenchgit

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"strings"
	"time"
)

// What a switch needs the owner to confirm before it runs.
const (
	// NeedUncommitted: the worktree has changes; they would be stashed.
	NeedUncommitted = "uncommitted_changes"
	// NeedAgent: a Claude Code session is working in the folder; its files
	// would be swapped under it.
	NeedAgent = "agent_running"
)

// Why a switch or a create was refused. No flag overrides a refusal.
const (
	RefusedGitUnavailable      = "git_unavailable"
	RefusedNotGit              = "not_git"
	RefusedUnknownBranch       = "unknown_branch"
	RefusedCheckedOutElsewhere = "checked_out_elsewhere"
	RefusedOperationInProgress = "operation_in_progress"
	RefusedInvalidName         = "invalid_name"
	RefusedExists              = "exists"
	RefusedGitFailed           = "git_failed"
)

// restoreBudget bounds what runs after a git write even when the caller's
// context is already done: finding the stash, reading HEAD after a failed
// switch and putting the stash back.
const restoreBudget = 10 * time.Second

// statusAfterBudget bounds the status read after a git write.
const statusAfterBudget = 5 * time.Second

// SwitchRequest is one `workbench git switch`. Stash and ConfirmAgent are
// the owner's confirmations; AgentRunning is the Desktop's fact that a
// Claude Code session works in the folder.
type SwitchRequest struct {
	Branch       string
	Stash        bool
	AgentRunning bool
	ConfirmAgent bool
}

// SwitchResult is the `workbench git switch` and `workbench git create`
// envelope.
type SwitchResult struct {
	WorkbenchID int64  `json:"workbench_id"`
	Branch      string `json:"branch"`
	Switched    bool   `json:"switched"`
	Already     bool   `json:"already"`
	Created     bool   `json:"created"`
	// NeedsConfirmation lists what the owner must confirm (NeedUncommitted,
	// NeedAgent); nothing was written.
	NeedsConfirmation []string `json:"needs_confirmation"`
	Changes           int      `json:"changes"`
	Refused           string   `json:"refused"`
	RefusedDetail     string   `json:"refused_detail"`
	// Stashed is the commit id of the stash this switch made ("" for none),
	// StashMessage its message. The entry always stays on the stack; after
	// a failed switch it is applied back (StashRestored), or StashError says
	// why not.
	Stashed       string `json:"stashed"`
	StashMessage  string `json:"stash_message"`
	StashRestored bool   `json:"stash_restored"`
	StashError    string `json:"stash_error"`
	Error         string `json:"error"` // git's stderr when a git call failed
	// Warning is git's stderr when switch exited non-zero but HEAD moved
	// anyway (a failing post-checkout hook): the switch counts as done.
	Warning string `json:"warning"`
	Status  Status `json:"status"` // read after the call
}

// Switch switches the folder's worktree to the local branch req.Branch.
// The checks run in a fixed order and the first that stops the switch
// returns before any git write: git present, an exact local branch name,
// not already on it, not checked out in another worktree, no operation in
// progress, then the owner's confirmations — uncommitted changes without
// req.Stash, a running agent without req.ConfirmAgent. It never forces,
// discards, resets or cleans.
func Switch(ctx context.Context, o Options, req SwitchRequest) (res SwitchResult) {
	res = SwitchResult{Branch: req.Branch, NeedsConfirmation: []string{}}
	st := ReadStatus(ctx, o)
	res.Status, res.Changes = st, st.Changes
	r, ok := res.start(o, st)
	if !ok {
		return res
	}
	branches, err := r.branches(ctx, st.TopLevel)
	if err != nil {
		res.Error = gitError(err)
		return res
	}
	target, found := findBranch(branches, req.Branch)
	switch {
	case !found:
		res.Refused, res.RefusedDetail = RefusedUnknownBranch, "no local branch is named "+req.Branch
		return res
	case !st.Detached && st.Branch == target.Name:
		res.Already = true
		return res
	case target.Worktree != "":
		res.Refused, res.RefusedDetail = RefusedCheckedOutElsewhere, target.Worktree
		return res
	case st.Operation != "":
		res.Refused, res.RefusedDetail = RefusedOperationInProgress, st.Operation
		return res
	case st.Unmerged > 0:
		res.Refused, res.RefusedDetail = RefusedOperationInProgress, "unmerged paths"
		return res
	}
	if st.Dirty && !req.Stash {
		res.NeedsConfirmation = append(res.NeedsConfirmation, NeedUncommitted)
	}
	if req.AgentRunning && !req.ConfirmAgent {
		res.NeedsConfirmation = append(res.NeedsConfirmation, NeedAgent)
	}
	if len(res.NeedsConfirmation) > 0 {
		return res
	}
	// From here on git may write: the envelope carries the status after.
	defer func() { res.Status = statusAfter(ctx, o) }()
	if st.Dirty {
		if !res.stash(ctx, r, st) {
			return res
		}
	}
	// git otherwise overwrites an ignored file the target branch tracks.
	if _, err := r.git(ctx, "switch", "--no-guess", "--no-overwrite-ignore", target.Name); err != nil {
		if !r.headIs(ctx, target.Name) {
			res.Error = gitError(err)
			res.restore(ctx, r)
			return res
		}
		res.Warning = gitError(err)
	}
	res.Switched = true
	return res
}

// Create creates the branch name at HEAD and switches to it. Nothing in the
// worktree changes, so neither uncommitted changes nor a running agent
// stop it.
func Create(ctx context.Context, o Options, name string) (res SwitchResult) {
	res = SwitchResult{Branch: name, NeedsConfirmation: []string{}}
	st := ReadStatus(ctx, o)
	res.Status, res.Changes = st, st.Changes
	r, ok := res.start(o, st)
	if !ok {
		return res
	}
	// The rules `check-ref-format --branch` adds to a ref's. --branch
	// exits 128 on a bad name, the code of git failing, so the plain ref
	// check runs instead: exit 1 is an invalid name, anything else an error.
	if name == "" || name == "HEAD" || strings.HasPrefix(name, "-") {
		res.Refused, res.RefusedDetail = RefusedInvalidName, "a branch name may not be empty, HEAD or start with -"
		return res
	}
	switch _, code, err := r.run(ctx, "check-ref-format", "refs/heads/"+name); {
	case code == 1:
		res.Refused, res.RefusedDetail = RefusedInvalidName, name+" is not a valid branch name"
		return res
	case err != nil:
		res.Error = gitError(err)
		return res
	}
	branches, err := r.branches(ctx, st.TopLevel)
	if err != nil {
		res.Error = gitError(err)
		return res
	}
	if _, found := findBranch(branches, name); found {
		res.Refused, res.RefusedDetail = RefusedExists, "a local branch is already named "+name
		return res
	}
	// From here on git may write: the envelope carries the status after.
	defer func() { res.Status = statusAfter(ctx, o) }()
	if _, err := r.git(ctx, "switch", "-c", name); err != nil {
		if !r.headIs(ctx, name) {
			res.Error = gitError(err)
			return res
		}
		res.Warning = gitError(err)
	}
	res.Created, res.Switched = true, true
	return res
}

// start refuses a folder without git, outside a repository or whose status
// could not be read, and opens the repository otherwise.
func (res *SwitchResult) start(o Options, st Status) (*repo, bool) {
	switch {
	case !st.GitAvailable:
		res.Refused, res.RefusedDetail = RefusedGitUnavailable, st.Note
		return nil, false
	case !st.Git:
		res.Refused, res.RefusedDetail = RefusedNotGit, st.Note
		return nil, false
	case !st.StatusOK:
		res.Refused, res.RefusedDetail = RefusedGitFailed, st.StatusError
		return nil, false
	}
	r, err := open(o)
	if err != nil { // the folder changed since the status was read
		res.Refused, res.RefusedDetail = RefusedNotGit, err.Error()
		return nil, false
	}
	return r, true
}

// findBranch matches name exactly against the local branch names; an
// option-like name never matches.
func findBranch(branches []Branch, name string) (Branch, bool) {
	if name == "" || strings.HasPrefix(name, "-") {
		return Branch{}, false
	}
	for _, b := range branches {
		if b.Name == name {
			return b, true
		}
	}
	return Branch{}, false
}

// statusAfter reads the status once git may have written, on its own
// budget even when the caller's context is already done.
func statusAfter(ctx context.Context, o Options) Status {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), statusAfterBudget)
	defer cancel()
	return ReadStatus(ctx, o)
}

// headIs reports whether HEAD is now the local branch name: a switch that
// exited non-zero may still have moved it (a failing post-checkout hook).
// It runs even when the caller's context is already done.
func (r *repo) headIs(ctx context.Context, name string) bool {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), restoreBudget)
	defer cancel()
	out, err := r.git(ctx, "symbolic-ref", "-q", "HEAD")
	return err == nil && strings.TrimSpace(string(out)) == "refs/heads/"+name
}

// stash saves every change, untracked files included, under a message that
// names the switch and carries a nonce; false when the switch must not go
// on. The stash stack is shared by every worktree and session, so this
// run's entry is found by its exact message, never taken from the stack's
// tip.
func (res *SwitchResult) stash(ctx context.Context, r *repo, st Status) bool {
	from := st.Branch
	if st.Detached {
		from = st.Head
	}
	msg := fmt.Sprintf("watchtower: switching from %s to %s [%s]", from, res.Branch, nonce())
	_, pushErr := r.git(ctx, "stash", "push", "--include-untracked", "-m", msg)
	// A push that failed may still have made the entry: look either way.
	findCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), restoreBudget)
	defer cancel()
	sha, findErr := r.findStash(findCtx, msg)
	if sha != "" {
		res.Stashed, res.StashMessage = sha, msg
	}
	switch {
	case pushErr != nil && sha != "":
		res.Error = clip("a stash was created (" + msg + ") but git stash push failed: " + gitError(pushErr))
		return false
	case pushErr != nil:
		res.Error = gitError(pushErr)
		return false
	case findErr != nil:
		res.Error = clip("git stash push succeeded but its entry was not found: " + gitError(findErr))
		return false
	}
	// No entry after a clean push: git saved nothing, nothing was stashable.
	return true
}

// nonce makes a stash message unique across sessions.
func nonce() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b) // crypto/rand.Read never fails
	return hex.EncodeToString(b)
}

// findStash is the commit id of the stash entry whose message is exactly
// msg, "" when there is none.
func (r *repo) findStash(ctx context.Context, msg string) (string, error) {
	out, err := r.git(ctx, "stash", "list", "--format=%H%x00%gs")
	if err != nil {
		return "", err
	}
	for _, line := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
		if line == "" {
			continue
		}
		sha, subject, ok := strings.Cut(line, "\x00")
		if !ok || sha == "" {
			return "", fmt.Errorf("git stash list: unexpected line %q", line)
		}
		// The subject is "On <branch>: <message>"; a branch name holds no ':'.
		if _, m, _ := strings.Cut(subject, ": "); m == msg {
			return sha, nil
		}
	}
	return "", nil
}

// restore applies this run's stash, by its commit id, after a failed
// switch. The entry stays on the stack: it is never popped or dropped.
func (res *SwitchResult) restore(ctx context.Context, r *repo) {
	if res.Stashed == "" {
		return
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), restoreBudget)
	defer cancel()
	if _, err := r.git(ctx, "stash", "apply", "--index", res.Stashed); err != nil {
		res.StashError = gitError(err)
		return
	}
	res.StashRestored = true
}
