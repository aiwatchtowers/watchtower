package workbenchgit

import (
	"context"
	"errors"
	"time"
)

// Remote is the only remote the header fetches and checks out from.
const Remote = "origin"

// FetchTimeout bounds one `git fetch` from origin: a slow network or a
// remote that never answers gives a quiet "timed out", not a stuck call.
const FetchTimeout = 20 * time.Second

// FetchResult is the `workbench git fetch` envelope.
type FetchResult struct {
	WorkbenchID  int64  `json:"workbench_id"`
	GitAvailable bool   `json:"git_available"`
	Git          bool   `json:"git"`
	Note         string `json:"note"`
	Remote       string `json:"remote"`
	// NoRemote: the repository has no origin remote; nothing ran.
	NoRemote bool `json:"no_remote"`
	Fetched  bool `json:"fetched"`
	// FetchedAt is when this fetch finished (UTC), set only when Fetched.
	FetchedAt *time.Time `json:"fetched_at"`
	TimedOut  bool       `json:"timed_out"`
	Error     string     `json:"error"` // git's stderr when the fetch failed
	// Refused is RefusedFolderNotAWorktree, RefusedFolderUnreadable or
	// RefusedGitFailed when the folder asked for could not be used; nothing
	// ran.
	Refused       string `json:"refused"`
	RefusedDetail string `json:"refused_detail"`
}

// unattendedKey marks a context whose fetch nobody asked for just now.
type unattendedKey struct{}

// isUnattended: ctx carries a fetch the owner did not start (Fetch's
// unattended), which keeps ssh off the ssh agent and the Keychain.
func isUnattended(ctx context.Context) bool {
	v, _ := ctx.Value(unattendedKey{}).(bool)
	return v
}

// Fetch runs `git fetch --prune origin`: it updates origin's remote-tracking
// refs (one deleted on origin goes, so a branch tracking it reads
// upstream_gone) and never touches the work tree, the index or a local
// branch. No credential helper, askpass or ssh prompt can run (execRunner);
// a remote that needs one fails with git's words in Error. It never fails
// itself: the outcome is in the envelope. FetchTimeout bounds the fetch.
// unattended is a fetch the owner did not start just now (the Desktop's
// automatic one): ssh then signs in without the ssh agent or the Keychain,
// so an agent that approves each use never shows its prompt.
func Fetch(ctx context.Context, o Options, unattended bool) FetchResult {
	res := FetchResult{Remote: Remote}
	r, _, available, note, err := probe(ctx, o)
	res.GitAvailable, res.Note = available, note
	if r == nil {
		return res
	}
	res.Git = true
	if err != nil {
		res.Error = gitError(err)
		return res
	}
	switch _, code, err := r.run(ctx, "config", "--get", "remote."+Remote+".url"); {
	case code == 1:
		res.NoRemote = true
		return res
	case err != nil:
		res.Error = gitError(err)
		return res
	}
	fetchCtx, cancel := context.WithTimeout(context.WithValue(ctx, unattendedKey{}, unattended), FetchTimeout)
	defer cancel()
	// No submodule repositories (their own config), no gc or maintenance
	// run afterwards, and git's own upload-pack name for the remote side:
	// the folder's remote.origin.uploadpack would win over a -c. (A path
	// remote, whose upload-pack would run here, is refused outright:
	// gitbin's GIT_ALLOW_PROTOCOL has no file.)
	if _, err := r.git(fetchCtx, "fetch", "--prune", "--quiet", "--no-recurse-submodules", "--no-auto-maintenance",
		"--upload-pack=git-upload-pack", Remote); err != nil {
		res.TimedOut = errors.Is(err, context.DeadlineExceeded)
		res.Error = gitError(err)
		return res
	}
	now := time.Now().UTC()
	res.Fetched, res.FetchedAt = true, &now
	return res
}
