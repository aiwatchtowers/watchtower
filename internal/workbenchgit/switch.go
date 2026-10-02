package workbenchgit

import (
	"context"
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
)

// restoreBudget bounds putting the stash back after a failed switch; it
// runs even when the caller's context is already done.
const restoreBudget = 10 * time.Second

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
	// StashMessage its message. It is never popped after a switch that
	// succeeded; after one that failed it is put back (StashRestored).
	Stashed       string `json:"stashed"`
	StashMessage  string `json:"stash_message"`
	StashRestored bool   `json:"stash_restored"`
	Error         string `json:"error"`  // git's stderr when a git call failed
	Status        Status `json:"status"` // read after the call
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
	if !st.StatusOK {
		res.Error = st.StatusError
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
	defer func() { res.Status = ReadStatus(ctx, o) }()
	if st.Dirty {
		if !res.stash(ctx, r, st) {
			return res
		}
	}
	if _, err := r.git(ctx, "switch", "--no-guess", target.Name); err != nil {
		res.Error = gitError(err)
		res.restore(ctx, r)
		return res
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
	if name == "" || strings.HasPrefix(name, "-") {
		res.Refused, res.RefusedDetail = RefusedInvalidName, "a branch name may not be empty or start with -"
		return res
	}
	// --branch also expands @{-N}: a name that comes back changed is not a
	// plain name.
	out, err := r.git(ctx, "check-ref-format", "--branch", name)
	if err != nil || strings.TrimSpace(string(out)) != name {
		res.Refused, res.RefusedDetail = RefusedInvalidName, name+" is not a valid branch name"
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
	defer func() { res.Status = ReadStatus(ctx, o) }()
	if _, err := r.git(ctx, "switch", "-c", name); err != nil {
		res.Error = gitError(err)
		return res
	}
	res.Created, res.Switched = true, true
	return res
}

// start refuses a folder without git or outside a work tree and opens the
// repository otherwise.
func (res *SwitchResult) start(o Options, st Status) (*repo, bool) {
	switch {
	case !st.GitAvailable:
		res.Refused, res.RefusedDetail = RefusedGitUnavailable, st.Note
		return nil, false
	case !st.Git:
		res.Refused, res.RefusedDetail = RefusedNotGit, st.Note
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

// stash saves every change, untracked files included, under a message that
// names the switch; false when the switch must not go on.
func (res *SwitchResult) stash(ctx context.Context, r *repo, st Status) bool {
	from := st.Branch
	if st.Detached {
		from = st.Head
	}
	msg := "watchtower: switching from " + from + " to " + res.Branch
	before, err := r.stashTip(ctx)
	if err != nil {
		res.Error = gitError(err)
		return false
	}
	if _, err := r.git(ctx, "stash", "push", "--include-untracked", "-m", msg); err != nil {
		res.Error = gitError(err)
		return false
	}
	after, err := r.stashTip(ctx)
	if err != nil {
		res.Error = gitError(err)
		return false
	}
	if after != before { // git saves nothing when no change is stashable
		res.Stashed, res.StashMessage = after, msg
	}
	return true
}

// restore puts this run's stash back after a failed switch, only while it
// is still the newest stash.
func (res *SwitchResult) restore(ctx context.Context, r *repo) {
	if res.Stashed == "" {
		return
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), restoreBudget)
	defer cancel()
	tip, err := r.stashTip(ctx)
	if err == nil && tip != res.Stashed {
		res.Error = clip(res.Error + "; the stash was not restored: it is no longer the newest stash")
		return
	}
	if err == nil {
		_, err = r.git(ctx, "stash", "pop", "--index")
	}
	if err != nil {
		res.Error = clip(res.Error + "; the stash was not restored: " + gitError(err))
		return
	}
	res.StashRestored = true
}

// stashTip is refs/stash's commit id, "" when there is no stash.
func (r *repo) stashTip(ctx context.Context) (string, error) {
	out, code, err := r.o.Run(ctx, r.o.Folder, nil, r.bin, "rev-parse", "--verify", "--quiet", "refs/stash")
	switch {
	case err == nil:
		return strings.TrimSpace(string(out)), nil
	case code == 1 && ctx.Err() == nil: // --quiet: a missing ref exits 1
		return "", nil
	}
	return "", err
}
