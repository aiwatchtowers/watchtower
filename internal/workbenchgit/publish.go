package workbenchgit

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/gitbin"
)

// A coach Accept or Roll Back of a workbench repository file opens a GitHub
// pull request instead of writing the owner's working copy (COACH-01 as
// amended by docs/superpowers/specs/2026-11-19-coach-repo-edits-as-prs-design.md).
// Every git call here goes through gitbin; the network ones keep the
// owner's credentials and never prompt (gitbin.ExecOwnerNetwork). Nothing in
// the owner's repository moves: no local ref, no FETCH_HEAD, no work-tree
// file — the commit is made in a detached scratch worktree and pushed only
// to the request's own coach/ branch. gh runs only in processes the owner
// starts, never in the daemon (spec D5).

// defaultNetworkBudget bounds one git network call or gh call (spec D10).
const defaultNetworkBudget = 60 * time.Second

// githubHost is the host whose folders always take the PR path (spec D8).
const githubHost = "github.com"

var (
	// ErrNoGH: gh is not installed, or not logged in to the host.
	ErrNoGH = errors.New("gh is not installed or not logged in")
	// ErrBaseDiffers: the file on the default branch is not the text the
	// proposal was made against.
	ErrBaseDiffers = errors.New("the file on the default branch differs from the one the proposal was made against")
	// ErrPushFailed: origin refused the branch, or the push needed a prompt.
	ErrPushFailed = errors.New("pushing the branch failed")
	// ErrPRFailed: gh could not find or open the pull request.
	ErrPRFailed = errors.New("opening the pull request failed")
	// ErrTimeout: a network call ran over its budget.
	ErrTimeout = errors.New("a network call timed out")
)

// BaseDiffersError is ErrBaseDiffers (errors.Is) with what the base holds
// now: Current is the file's text there ("" when it is missing), for the
// caller's diff. Its message names the file and the branch, never the text.
type BaseDiffersError struct {
	Rel, Base, Current string
}

func (e *BaseDiffersError) Error() string {
	return fmt.Sprintf("%s: %s on %s", ErrBaseDiffers, e.Rel, e.Base)
}

// Is makes errors.Is(err, ErrBaseDiffers) match.
func (e *BaseDiffersError) Is(target error) bool { return target == ErrBaseDiffers }

// PublishRequest is one pull request Publish opens.
type PublishRequest struct {
	ID            int64  // the proposal; its scratch worktree is <Options.Scratch>/<ID>
	Rel           string // the file, relative to the folder's top level
	Before, After string // the text the base must hold, the text to commit
	Branch        string // coach/<token>/proposal-<id> or coach/<token>/revert-<id>
	Title, Body   string // Body goes to gh verbatim
	// MayCreate: the file may be missing from the base when Before is ""
	// (an Accept creating CLAUDE.md or AGENTS.md). Otherwise a file missing
	// there is ErrBaseDiffers, however empty Before is.
	MayCreate bool
	// Delete removes Rel instead of writing After (which must be ""): a
	// revert of an edit that created the file. The base must still hold
	// Before.
	Delete bool
	// BaseBranch and BaseSHA are the repository's default branch and its
	// head commit (DefaultBase).
	BaseBranch, BaseSHA string
}

// PublishResult is the pull request Publish opened or found.
type PublishResult struct {
	PRURL string
	Base  string // the branch it targets
}

// ownerNetworkKey marks a context whose git network calls are the owner's
// (Publish): they keep the owner's credentials (gitbin.ExecOwnerNetwork).
// The value is the gh path the credential helper names.
type ownerNetworkKey struct{}

func withOwnerNetwork(ctx context.Context, gh string) context.Context {
	return context.WithValue(ctx, ownerNetworkKey{}, gh)
}

func ownerNetwork(ctx context.Context) (gh string, ok bool) {
	gh, ok = ctx.Value(ownerNetworkKey{}).(string)
	return gh, ok
}

// networkCall: args (subcommand first) talk to a remote.
func networkCall(args []string) bool {
	return len(args) > 0 && (args[0] == "fetch" || args[0] == "push" || args[0] == "ls-remote")
}

func ghPath(o Options) string {
	if o.GHPath == "" {
		return "gh"
	}
	return o.GHPath
}

func budget(o Options) time.Duration {
	if o.NetworkBudget <= 0 {
		return defaultNetworkBudget
	}
	return o.NetworkBudget
}

// failure is err as kind (nil = no sentinel), or ErrTimeout when a budget
// or the caller's deadline cut it off; git's own words are kept.
func failure(kind, err error) error {
	switch {
	case err == nil:
		return nil
	case errors.Is(err, context.DeadlineExceeded):
		return fmt.Errorf("%w: %s", ErrTimeout, gitError(err))
	case kind == nil:
		return err
	}
	return fmt.Errorf("%w: %s", kind, gitError(err))
}

// overBudget turns an error a deadline caused anywhere — a local git call
// under the caller's expired deadline included — into ErrTimeout.
func overBudget(err *error) {
	if *err != nil && errors.Is(*err, context.DeadlineExceeded) && !errors.Is(*err, ErrTimeout) {
		*err = fmt.Errorf("%w: %w", ErrTimeout, *err)
	}
}

// remoteURL splits a git remote URL into its host (lowercase, no user or
// port) and its path (no leading slash, no .git). The https/http/ssh/git
// URL forms and scp-like `[user@]host:path` are read; a local path or
// file:// URL has no host.
func remoteURL(raw string) (host, path string) {
	raw = strings.TrimSpace(raw)
	if strings.Contains(raw, "://") {
		u, err := url.Parse(raw)
		if err != nil || u.Scheme == "file" {
			return "", ""
		}
		host, path = u.Hostname(), u.Path
	} else {
		// scp-like: a colon before any slash, and not a Windows drive.
		colon, slash := strings.Index(raw, ":"), strings.Index(raw, "/")
		if colon <= 1 || slash >= 0 && slash < colon {
			return "", ""
		}
		host, path = raw[:colon], raw[colon+1:]
		if at := strings.LastIndex(host, "@"); at >= 0 {
			host = host[at+1:]
		}
	}
	path = strings.TrimSuffix(strings.Trim(path, "/"), ".git")
	return strings.ToLower(host), path
}

// originURLs are the folder's origin URL as configured and as git uses it
// (`git remote get-url`, through url.<x>.insteadOf); none when there is no
// origin, one when the two are the same.
func originURLs(ctx context.Context, r *repo) ([]string, error) {
	out, code, err := r.run(ctx, "config", "--get", "remote."+Remote+".url")
	switch {
	case code == 1:
		return nil, nil
	case err != nil:
		return nil, err
	}
	configured := strings.TrimSpace(string(out))
	out, err = r.git(ctx, "remote", "get-url", Remote)
	if err != nil {
		return nil, err
	}
	if rewritten := strings.TrimSpace(string(out)); rewritten != configured {
		return []string{configured, rewritten}, nil
	}
	return []string{configured}, nil
}

// chooseOrigin is the first of urls on github.com, else the first on a host
// accept takes ("" when none is): an insteadOf alias either way round
// (gh:owner/repo → github.com, or github.com → a mirror) still names the
// GitHub repository.
func chooseOrigin(urls []string, accept func(host string) bool) (host, path string) {
	for _, u := range urls {
		if h, p := remoteURL(u); h == githubHost {
			return h, p
		}
	}
	for _, u := range urls {
		if h, p := remoteURL(u); h != "" && accept(h) {
			return h, p
		}
	}
	return "", ""
}

func anyHost(string) bool { return true }

// OriginHost is the host of the folder's origin — github.com when its
// configured or its rewritten URL is there — ("" when there is no origin,
// or it is a local path). It runs no network call and no gh.
func OriginHost(ctx context.Context, o Options) (string, error) {
	r, err := open(o)
	if err != nil {
		return "", err
	}
	urls, err := originURLs(ctx, r)
	if err != nil {
		return "", err
	}
	host, _ := chooseOrigin(urls, anyHost)
	return host, nil
}

// IsGitHubFolder decides the path of a repository edit (spec D8): an
// origin on github.com (configured or rewritten URL) is always a GitHub
// folder, gh or not; another host is one only when ghLoggedIn(host) says gh
// is logged in there; no origin, or a local one, never is.
func IsGitHubFolder(ctx context.Context, o Options, ghLoggedIn func(host string) bool) (bool, error) {
	r, err := open(o)
	if err != nil {
		return false, err
	}
	urls, err := originURLs(ctx, r)
	if err != nil {
		return false, err
	}
	host, _ := chooseOrigin(urls, ghLoggedIn)
	return host != "", nil
}

// GHReady checks that gh is installed and logged in to host (`gh auth
// status --hostname <host>`): ErrNoGH when gh is missing or says the owner
// is not logged in (or must log in again), ErrTimeout over the budget, and
// any other failure — offline, GitHub down — as itself, so a logged-in
// owner is never told to log in.
func GHReady(ctx context.Context, o Options, host string) error {
	out, err := gh(ctx, o, "auth", "status", "--hostname", host)
	var missing *exec.Error
	var re *runError
	switch {
	case err == nil:
		return nil
	case errors.Is(err, context.DeadlineExceeded):
		return failure(nil, err)
	case errors.As(err, &missing), errors.Is(err, fs.ErrNotExist):
		return fmt.Errorf("%w: %s", ErrNoGH, gitError(err))
	case errors.As(err, &re) && loggedOut(string(out)+"\n"+re.stderr):
		return fmt.Errorf("%w: %s", ErrNoGH, gitError(err))
	}
	return fmt.Errorf("gh auth status: %w", err)
}

// loggedOut: gh's auth status output says there is no usable login.
func loggedOut(output string) bool {
	output = strings.ToLower(output)
	return strings.Contains(output, "not logged in") || strings.Contains(output, "gh auth login")
}

// ghRepo is the folder's origin as gh's -R argument (HOST/OWNER/REPO).
func ghRepo(ctx context.Context, r *repo) (string, error) {
	urls, err := originURLs(ctx, r)
	if err != nil {
		return "", err
	}
	host, path := chooseOrigin(urls, anyHost)
	if host == "" || strings.Count(path, "/") != 1 {
		return "", fmt.Errorf("origin %q does not name a GitHub repository", urls)
	}
	return host + "/" + path, nil
}

// OriginRepo is the folder's origin as HOST/OWNER/REPO (the repository gh
// works on). It runs no network call and no gh.
func OriginRepo(ctx context.Context, o Options) (string, error) {
	r, err := open(o)
	if err != nil {
		return "", err
	}
	return ghRepo(ctx, r)
}

// DefaultBase is the repository's default branch on GitHub (spec D4: `gh
// repo view --json defaultBranchRef`, not origin/HEAD) and its head commit,
// read from origin with `git ls-remote` — no ref of the repository moves.
func DefaultBase(ctx context.Context, o Options) (branch, sha string, err error) {
	defer overBudget(&err)
	r, err := open(o)
	if err != nil {
		return "", "", err
	}
	slug, err := ghRepo(ctx, r)
	if err != nil {
		return "", "", err
	}
	out, err := gh(ctx, o, "repo", "view", slug, "--json", "defaultBranchRef")
	if err != nil {
		return "", "", failure(nil, err)
	}
	var view struct {
		DefaultBranchRef struct{ Name string } `json:"defaultBranchRef"`
	}
	if err := json.Unmarshal(out, &view); err != nil || view.DefaultBranchRef.Name == "" {
		return "", "", fmt.Errorf("gh repo view: no default branch in %q", clip(string(out)))
	}
	branch = view.DefaultBranchRef.Name
	fetchURL, err := r.git(ctx, "remote", "get-url", Remote)
	if err != nil {
		return "", "", err
	}
	sha, err = remoteHead(ctx, o, r, strings.TrimSpace(string(fetchURL)), branch)
	switch {
	case err != nil:
		return "", "", failure(nil, err)
	case sha == "":
		return "", "", fmt.Errorf("origin has no branch %s", branch)
	}
	return branch, sha, nil
}

// remoteHead is the commit refs/heads/<branch> points at on url ("" when it
// does not exist there).
func remoteHead(ctx context.Context, o Options, r *repo, url, branch string) (string, error) {
	ctx, cancel := context.WithTimeout(withOwnerNetwork(ctx, ghPath(o)), budget(o))
	defer cancel()
	out, err := r.git(ctx, "ls-remote", "--upload-pack=git-upload-pack", url, "refs/heads/"+branch)
	if err != nil {
		return "", err
	}
	sha, _, _ := strings.Cut(strings.TrimSpace(string(out)), "\t")
	return sha, nil
}

var (
	shaPattern = regexp.MustCompile(`^[0-9a-f]{40}([0-9a-f]{24})?$`)
	// A coach branch: coach/<workspace token>/proposal-<id> or
	// coach/<workspace token>/revert-<id> (the token keeps two Watchtower
	// workspaces' proposals of the same id apart on one repository).
	branchPattern = regexp.MustCompile(`^coach/[0-9a-f]{8}/(proposal|revert)-[0-9]+$`)
)

// Publish opens a pull request with After in place of Before at Rel against
// the default branch (spec 4.3 step 3): fetch the base commit by its id
// (no ref, no FETCH_HEAD), a detached scratch worktree of it at
// <Scratch>/<ID> — a leftover of this ID removed first, this request's
// folder removed again on every path —, the file there must hold Before
// (ErrBaseDiffers), commit After without hooks, push it to
// refs/heads/<Branch> on origin and nothing else (ErrPushFailed), then
// reuse the open pull request of that branch or create one (ErrPRFailed).
// The owner's working copy, HEAD and refs are never touched. Each network
// call runs under the budget (ErrTimeout).
func Publish(ctx context.Context, o Options, req PublishRequest) (res PublishResult, err error) {
	defer overBudget(&err)
	switch {
	case req.ID <= 0 || !branchPattern.MatchString(req.Branch):
		return res, fmt.Errorf("publish: invalid proposal id %d or branch %q", req.ID, req.Branch)
	case !filepath.IsLocal(req.Rel):
		return res, fmt.Errorf("publish: %q is not a path inside the repository", req.Rel)
	case req.BaseBranch == "" || !shaPattern.MatchString(req.BaseSHA):
		return res, fmt.Errorf("publish: invalid base %q at %q", req.BaseBranch, req.BaseSHA)
	case o.Scratch == "" || !filepath.IsAbs(o.Scratch):
		return res, fmt.Errorf("publish: the scratch folder %q is not an absolute path", o.Scratch)
	case req.Delete && (req.Before == "" || req.After != ""):
		return res, errors.New("publish: a deletion needs the text the base holds and no new text")
	}
	r, err := open(o)
	if err != nil {
		return res, err
	}
	slug, err := ghRepo(ctx, r)
	if err != nil {
		return res, err
	}
	fetchURL, err := r.git(ctx, "remote", "get-url", Remote)
	if err != nil {
		return res, failure(nil, err)
	}
	pushURL, err := r.git(ctx, "remote", "get-url", "--push", Remote)
	if err != nil {
		return res, failure(nil, err)
	}
	if !sameRepository(strings.TrimSpace(string(fetchURL)), strings.TrimSpace(string(pushURL))) {
		return res, fmt.Errorf("%w: origin pushes to a different repository (%s) than it fetches from (%s)",
			ErrPushFailed, strings.TrimSpace(string(pushURL)), strings.TrimSpace(string(fetchURL)))
	}
	if err := fetchBase(ctx, o, r, strings.TrimSpace(string(fetchURL)), req.BaseSHA); err != nil {
		return res, failure(nil, err)
	}
	dir := filepath.Join(o.Scratch, strconv.FormatInt(req.ID, 10))
	removeScratch(r, dir)
	defer removeScratch(r, dir)
	if err := os.MkdirAll(o.Scratch, 0o700); err != nil {
		return res, err
	}
	if err := commitInScratch(ctx, r, dir, req); err != nil {
		return res, err
	}
	if err := push(ctx, o, r, dir, strings.TrimSpace(string(pushURL)), req.Branch); err != nil {
		return res, err
	}
	prURL, err := openPR(ctx, o, slug, req)
	if err != nil {
		return res, err
	}
	return PublishResult{PRURL: prURL, Base: req.BaseBranch}, nil
}

// sameRepository: two remote URLs name one repository — equal, or the same
// host and path (https vs ssh form of one GitHub repository).
func sameRepository(a, b string) bool {
	if a == b {
		return true
	}
	ha, pa := remoteURL(a)
	hb, pb := remoteURL(b)
	return ha != "" && ha == hb && strings.EqualFold(pa, pb)
}

// fetchBase brings the base commit into the repository's object store by
// its id: no ref (no refspec destination, no tags followed), no
// FETCH_HEAD, no submodule, no maintenance afterwards.
func fetchBase(ctx context.Context, o Options, r *repo, url, sha string) error {
	ctx, cancel := context.WithTimeout(withOwnerNetwork(ctx, ghPath(o)), budget(o))
	defer cancel()
	_, err := r.git(ctx, "fetch", "--quiet", "--no-write-fetch-head", "--no-tags", "--no-recurse-submodules",
		"--no-auto-maintenance", "--upload-pack=git-upload-pack", url, sha)
	return err
}

// removeScratch removes this request's scratch worktree — its folder and
// its registration — and nothing else of the repository's: no `worktree
// prune`, which would also drop the owner's worktrees whose folder is
// missing (an unmounted volume). It runs under its own short context so a
// timed-out Publish still cleans up. Best effort: what it cannot remove the
// next Publish of this id removes first.
func removeScratch(r *repo, dir string) {
	ctx, cancel := context.WithTimeout(context.Background(), FetchTimeout)
	defer cancel()
	if _, err := os.Lstat(dir); err == nil {
		_, _ = r.git(ctx, "worktree", "remove", "--force", dir)
		_ = os.RemoveAll(dir)
	}
	forgetWorktree(ctx, r, dir)
}

// forgetWorktree removes the registration (<common dir>/worktrees/<name>)
// whose work tree is dir, if one is left — the entry `worktree remove`
// could not drop because the folder was already gone — and no other.
func forgetWorktree(ctx context.Context, r *repo, dir string) {
	p, err := r.locatePaths(ctx)
	if err != nil {
		return
	}
	want := map[string]bool{filepath.Clean(dir): true}
	if parent, err := filepath.EvalSymlinks(filepath.Dir(dir)); err == nil {
		want[filepath.Join(parent, filepath.Base(dir))] = true
	}
	admin := filepath.Join(p.commonDir, "worktrees")
	entries, err := os.ReadDir(admin)
	if err != nil {
		return
	}
	for _, e := range entries {
		raw, err := os.ReadFile(filepath.Join(admin, e.Name(), "gitdir")) // <work tree>/.git
		if err == nil && want[filepath.Dir(filepath.Clean(strings.TrimSpace(string(raw))))] {
			_ = os.RemoveAll(filepath.Join(admin, e.Name()))
		}
	}
}

// commitInScratch adds the detached worktree at the base commit without a
// checkout (no filter or hook of the folder runs on the tree), checks the
// file holds req.Before, stages req.After with the file's mode (or, for
// req.Delete, the file's removal) and commits that one file with the
// repository's identity and no hooks.
func commitInScratch(ctx context.Context, r *repo, dir string, req PublishRequest) error {
	if _, err := r.git(ctx, "worktree", "add", "--detach", "--no-checkout", dir, req.BaseSHA); err != nil {
		return failure(nil, err)
	}
	s := &repo{o: r.o, bin: r.bin}
	s.o.Folder = dir
	if _, err := s.git(ctx, "read-tree", "HEAD"); err != nil { // the index only; no file is written
		return failure(nil, err)
	}
	rel := filepath.ToSlash(req.Rel)
	current, mode, exists, err := blobAt(ctx, s, rel)
	if err != nil {
		return failure(nil, err)
	}
	if current != req.Before || !exists && !req.MayCreate {
		return &BaseDiffersError{Rel: rel, Base: req.BaseBranch, Current: current}
	}
	if req.Delete {
		if _, err := s.git(ctx, "update-index", "--force-remove", "--", rel); err != nil {
			return failure(nil, err)
		}
		return commitScratch(ctx, s, req.Title)
	}
	// After goes into the index as a raw blob with the base's mode (an
	// executable stays one); the scratch folder's disk is never written, so
	// no filter runs and no mode is guessed from it.
	blob, _, err := s.o.Run(ctx, dir, []byte(req.After), s.bin, "hash-object", "-w", "--no-filters", "--stdin")
	if err != nil {
		return failure(nil, err)
	}
	if _, err := s.git(ctx, "update-index", "--add", "--cacheinfo",
		mode+","+strings.TrimSpace(string(blob))+","+rel); err != nil {
		return failure(nil, err)
	}
	return commitScratch(ctx, s, req.Title)
}

// commitScratch commits the scratch worktree's index without hooks.
func commitScratch(ctx context.Context, s *repo, title string) error {
	if _, err := s.git(ctx, "commit", "--no-verify", "--quiet", "-m", "coach: "+title); err != nil {
		return failure(nil, err)
	}
	return nil
}

// blobAt is the raw content of rel in the commit (no filter, no textconv),
// its mode and whether it is there at all ("", 100644 and false when it is
// not). A path that is not a regular file (a symlink, a submodule, a
// folder) is an error.
func blobAt(ctx context.Context, r *repo, rel string) (content, mode string, exists bool, err error) {
	entry, err := r.git(ctx, "ls-tree", "-z", "HEAD", "--", rel)
	switch {
	case err != nil:
		return "", "", false, err
	case len(entry) == 0:
		return "", "100644", false, nil
	}
	mode, _, _ = strings.Cut(string(entry), " ")
	if mode != "100644" && mode != "100755" {
		return "", "", false, fmt.Errorf("%s is not a regular file in the base (mode %s)", rel, mode)
	}
	out, err := r.git(ctx, "cat-file", "blob", "HEAD:"+rel)
	return string(out), mode, err == nil, err
}

// push sends the scratch worktree's HEAD to refs/heads/<branch> on url —
// the URL, not the remote's name, so no remote-tracking ref of the
// repository moves — leased on the value the branch has there now (a
// rerun replaces its own earlier push; a concurrent writer's is refused).
func push(ctx context.Context, o Options, r *repo, dir, url, branch string) error {
	s := &repo{o: r.o, bin: r.bin}
	s.o.Folder = dir
	ref := "refs/heads/" + branch
	old, err := remoteHead(ctx, o, s, url, branch)
	if err != nil {
		return failure(ErrPushFailed, err)
	}
	pctx, cancel := context.WithTimeout(withOwnerNetwork(ctx, ghPath(o)), budget(o))
	defer cancel()
	_, err = s.git(pctx, "push", "--quiet", "--no-verify", "--no-follow-tags", "--no-recurse-submodules", "--receive-pack=git-receive-pack",
		"--force-with-lease="+ref+":"+old, url, "HEAD:"+ref)
	return failure(ErrPushFailed, err)
}

// openPR is the open pull request of req.Branch, or a new one against the
// base branch.
func openPR(ctx context.Context, o Options, slug string, req PublishRequest) (string, error) {
	out, err := gh(ctx, o, "pr", "list", "-R", slug, "--head", req.Branch, "--state", "open", "--json", "url")
	if err != nil {
		return "", failure(ErrPRFailed, err)
	}
	var open []struct{ URL string }
	if err := json.Unmarshal(out, &open); err != nil {
		return "", fmt.Errorf("%w: gh pr list: %q", ErrPRFailed, clip(string(out)))
	}
	if len(open) > 0 && open[0].URL != "" {
		return open[0].URL, nil
	}
	out, err = gh(ctx, o, "pr", "create", "-R", slug, "--base", req.BaseBranch, "--head", req.Branch,
		"--title", req.Title, "--body", req.Body)
	if err != nil {
		return "", failure(ErrPRFailed, err)
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	if u := strings.TrimSpace(lines[len(lines)-1]); strings.HasPrefix(u, "https://") || strings.HasPrefix(u, "http://") {
		return u, nil
	}
	return "", fmt.Errorf("%w: gh pr create printed no URL: %q", ErrPRFailed, clip(string(out)))
}

// PRState is a pull request's state (OPEN, CLOSED or MERGED) and, once
// merged, when (`gh pr view <url> --json state,mergedAt`).
func PRState(ctx context.Context, o Options, prURL string) (state string, mergedAt time.Time, err error) {
	out, err := gh(ctx, o, "pr", "view", prURL, "--json", "state,mergedAt")
	if err != nil {
		return "", time.Time{}, ghFailure(out, err)
	}
	var view struct {
		State    string     `json:"state"`
		MergedAt *time.Time `json:"mergedAt"`
	}
	if err := json.Unmarshal(out, &view); err != nil || view.State == "" {
		return "", time.Time{}, fmt.Errorf("gh pr view: no state in %q", clip(string(out)))
	}
	if view.MergedAt != nil {
		mergedAt = view.MergedAt.UTC()
	}
	return view.State, mergedAt, nil
}

// ClosePR closes a pull request (`gh pr close`, never --delete-branch,
// which would also delete a local branch of that name the owner checked
// out) and then deletes its head branch on origin only: by a push of the
// deletion to origin's push URL, under the owner-network rules, so no
// local ref moves. The branch is deleted only when it is a coach branch
// of the same repository, origin is that repository, and it still exists
// there; otherwise it is left. ErrNoGH when gh is missing or logged out,
// ErrTimeout over the budget.
func ClosePR(ctx context.Context, o Options, prURL string) (err error) {
	defer overBudget(&err)
	out, err := gh(ctx, o, "pr", "view", prURL, "--json", "headRefName,isCrossRepository")
	if err != nil {
		return ghFailure(out, err)
	}
	var view struct {
		HeadRefName       string `json:"headRefName"`
		IsCrossRepository bool   `json:"isCrossRepository"`
	}
	if err := json.Unmarshal(out, &view); err != nil {
		return fmt.Errorf("gh pr view: no head branch in %q", clip(string(out)))
	}
	if out, err := gh(ctx, o, "pr", "close", prURL); err != nil {
		return ghFailure(out, err)
	}
	if view.IsCrossRepository || !branchPattern.MatchString(view.HeadRefName) {
		return nil
	}
	return deleteRemoteBranch(ctx, o, prURL, view.HeadRefName)
}

// deleteRemoteBranch deletes refs/heads/<branch> on origin when origin is
// the pull request's repository (else leaves it): a push of the deletion
// to the push URL, no hooks, no prompt; a branch already gone is fine.
func deleteRemoteBranch(ctx context.Context, o Options, prURL, branch string) error {
	r, err := open(o)
	if err != nil {
		return err
	}
	slug, err := ghRepo(ctx, r)
	if err != nil || !strings.EqualFold(slug, PRRepository(prURL)) {
		return nil // origin is not (or no longer names) the pull request's repository: its branch is left
	}
	fetchURL, err := r.git(ctx, "remote", "get-url", Remote)
	if err != nil {
		return failure(nil, err)
	}
	pushURL, err := r.git(ctx, "remote", "get-url", "--push", Remote)
	if err != nil {
		return failure(nil, err)
	}
	if !sameRepository(strings.TrimSpace(string(fetchURL)), strings.TrimSpace(string(pushURL))) {
		return nil
	}
	pctx, cancel := context.WithTimeout(withOwnerNetwork(ctx, ghPath(o)), budget(o))
	defer cancel()
	_, err = r.git(pctx, "push", "--quiet", "--no-verify", "--receive-pack=git-receive-pack",
		strings.TrimSpace(string(pushURL)), "--delete", "refs/heads/"+branch)
	var re *runError
	if errors.As(err, &re) && strings.Contains(re.stderr, "remote ref does not exist") {
		return nil
	}
	return failure(ErrPushFailed, err)
}

// PRRepository is HOST/OWNER/REPO of a pull request URL
// (https://HOST/OWNER/REPO/pull/N), host lowercased; "" when it is not one.
func PRRepository(prURL string) string {
	u, err := url.Parse(prURL)
	if err != nil || u.Host == "" {
		return ""
	}
	parts := strings.Split(strings.Trim(u.Path, "/"), "/")
	if len(parts) != 4 || parts[2] != "pull" || parts[0] == "" || parts[1] == "" {
		return ""
	}
	return strings.ToLower(u.Hostname()) + "/" + parts[0] + "/" + parts[1]
}

// ghFailure is a failed gh call's error: ErrNoGH when gh is missing or says
// the owner is not logged in, ErrTimeout over the budget, else gh's words.
func ghFailure(out []byte, err error) error {
	var missing *exec.Error
	var re *runError
	switch {
	case err == nil:
		return nil
	case errors.Is(err, context.DeadlineExceeded):
		return failure(nil, err)
	case errors.As(err, &missing), errors.Is(err, fs.ErrNotExist),
		errors.As(err, &re) && loggedOut(string(out)+"\n"+re.stderr):
		return fmt.Errorf("%w: %s", ErrNoGH, gitError(err))
	}
	return err
}

// gh runs gh in the folder under the budget, in its own process group
// (killed whole when the budget or ctx ends), never prompting.
func gh(ctx context.Context, o Options, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(gitbin.WithProcessGroup(ctx), budget(o))
	defer cancel()
	stdout, stderr, err := gitbin.ExecEnv(ctx, o.Folder, []string{"GH_NO_UPDATE_NOTIFIER=1"}, nil, ghPath(o), args...)
	var exitErr *exec.ExitError
	switch {
	case err == nil:
		return stdout, nil
	case ctx.Err() != nil:
		return nil, &runError{tool: "gh", args: args, err: ctx.Err()}
	case errors.As(err, &exitErr):
		return stdout, &runError{tool: "gh", args: args, err: err, stderr: string(stderr)}
	}
	return nil, err
}
