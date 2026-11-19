package workbenchgit

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// ghURL is the GitHub repository the test folders' origin names; git
// reaches it through url.<bare>.insteadOf, gh only through the stub.
const ghURL = "https://github.com/example/repo.git"

// publishFixture is a folder whose origin names ghURL, rewritten to a bare
// repository in a temp folder, on main with CLAUDE.md, plus a feature branch,
// both pushed; a stub gh in stub/.
type publishFixture struct {
	dir, origin, scratch, stub string
	gh                         string
	base                       string // origin's main
}

func newPublishFixture(t *testing.T) *publishFixture {
	t.Helper()
	f := &publishFixture{dir: newRepo(t)}
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	f.origin, f.scratch, f.stub = filepath.Join(root, "origin.git"), filepath.Join(root, "coach-pr"), filepath.Join(root, "stub")
	gitIn(t, root, "init", "-q", "--bare", "-b", "main", f.origin)
	commit(t, f.dir, "CLAUDE.md", "# Rules\n", "rules")
	gitIn(t, f.dir, "remote", "add", Remote, ghURL)
	gitIn(t, f.dir, "config", "url."+f.origin+".insteadOf", ghURL)
	gitIn(t, f.dir, "push", "-q", Remote, "main", "feature")
	f.base = gitIn(t, f.origin, "rev-parse", "refs/heads/main")
	if err := os.Mkdir(f.stub, 0o755); err != nil {
		t.Fatal(err)
	}
	f.gh = filepath.Join(f.stub, "gh")
	if err := os.WriteFile(f.gh, []byte(stubGH(f.stub)), 0o755); err != nil {
		t.Fatal(err)
	}
	return f
}

// stubGH answers the gh calls Publish, DefaultBase, PRState, ClosePR and
// GHReady make, logging each argv (one per line) to <stub>/log. Flags in
// <stub>: fail-create (pr create fails), loggedout / offline (auth status
// fails saying so),
// hang (pr list writes its pid to <stub>/pid, signals <stub>/ready, then
// blocks on <stub>/hold), view (pr
// view's JSON). An opened PR's URL is kept in <stub>/pr-<branch, / as _>.
func stubGH(stub string) string {
	return `#!/bin/sh
S='` + stub + `'
echo "$*" >> "$S/log"
head=
prev=
for a in "$@"; do [ "$prev" = --head ] && head=$(printf '%s' "$a" | tr / _); prev=$a; done
case "$1 $2" in
"auth status")
  [ -e "$S/loggedout" ] && { echo "You are not logged into any GitHub hosts. To log in, run: gh auth login" >&2; exit 1; }
  [ -e "$S/offline" ] && { echo "error connecting to api.github.com" >&2; exit 1; }
  exit 0 ;;
"repo view") echo '{"defaultBranchRef":{"name":"main"}}' ;;
"pr list")
  if [ -e "$S/hang" ]; then echo $$ > "$S/pid"; printf x > "$S/ready"; exec cat "$S/hold"; fi
  if [ -e "$S/pr-$head" ]; then printf '[{"url":"%s"}]\n' "$(cat "$S/pr-$head")"; else echo '[]'; fi ;;
"pr create")
  [ -e "$S/fail-create" ] && { echo "GraphQL: simulated failure" >&2; exit 1; }
  n=$(ls "$S" | grep -c '^pr-')
  u="https://github.com/example/repo/pull/$((n+1))"
  echo "$u" > "$S/pr-$head"
  echo "Creating pull request"; echo "$u" ;;
"pr view") cat "$S/view" ;;
"pr close") exit 0 ;;
*) echo "unexpected gh $*" >&2; exit 2 ;;
esac
`
}

func (f *publishFixture) options(r *recorder) Options {
	o := Options{Folder: f.dir, GHPath: f.gh, Scratch: f.scratch}
	if r != nil {
		o.Run = r.run
	}
	return o
}

func (f *publishFixture) request(id int64) PublishRequest {
	return PublishRequest{
		ID: id, Rel: "CLAUDE.md", Before: "# Rules\n", After: "# Rules\n\n- be brief\n",
		Branch: "coach/proposal-" + itoa(id), Title: "Be brief", Body: "Why:\n`brief` — \"quoted\" $HOME",
		BaseBranch: "main", BaseSHA: f.base,
	}
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

func (f *publishFixture) flag(t *testing.T, name string) {
	t.Helper()
	writeFile(t, f.stub, name, "")
}

func (f *publishFixture) unflag(t *testing.T, name string) {
	t.Helper()
	if err := os.Remove(filepath.Join(f.stub, name)); err != nil {
		t.Fatal(err)
	}
}

// ghCalls is every gh argv the stub saw.
func (f *publishFixture) ghCalls(t *testing.T) []string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(f.stub, "log"))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	return strings.Split(strings.TrimSuffix(string(raw), "\n"), "\n")
}

func countPrefix(calls []string, prefix string) int {
	n := 0
	for _, c := range calls {
		if strings.HasPrefix(c, prefix) {
			n++
		}
	}
	return n
}

// refs is every ref of the repository at dir with its value.
func refs(t *testing.T, dir string) []string {
	t.Helper()
	out := gitIn(t, dir, "for-each-ref", "--format=%(refname) %(objectname)")
	if out == "" {
		return nil
	}
	return strings.Split(out, "\n")
}

func (f *publishFixture) assertScratchGone(t *testing.T, id int64) {
	t.Helper()
	if _, err := os.Lstat(filepath.Join(f.scratch, itoa(id))); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("scratch folder of %d is still there (%v)", id, err)
	}
	if wt := gitIn(t, f.dir, "worktree", "list", "--porcelain"); strings.Contains(wt, "worktree "+filepath.Join(f.scratch, itoa(id))+"\n") {
		t.Errorf("the scratch worktree of %d is still registered:\n%s", id, wt)
	}
}

func TestPublish_OpensThePR(t *testing.T) {
	f := newPublishFixture(t)
	rec := &recorder{}
	req := f.request(7)
	res, err := Publish(context.Background(), f.options(rec), req)
	if err != nil {
		t.Fatal(err)
	}
	if res.PRURL != "https://github.com/example/repo/pull/1" || res.Base != "main" {
		t.Fatalf("result = %+v", res)
	}
	tip := gitIn(t, f.origin, "rev-parse", "refs/heads/coach/proposal-7")
	if got := gitIn(t, f.origin, "rev-parse", tip+"^"); got != f.base {
		t.Errorf("the commit's parent = %s, want the base %s", got, f.base)
	}
	if got := gitIn(t, f.origin, "show", tip+":CLAUDE.md"); got != strings.TrimSpace(req.After) {
		t.Errorf("CLAUDE.md on the branch = %q", got)
	}
	if got := gitIn(t, f.origin, "log", "-1", "--format=%s", tip); got != "coach: Be brief" {
		t.Errorf("message = %q", got)
	}
	if got := gitIn(t, f.origin, "diff-tree", "--no-commit-id", "--name-only", "-r", tip); got != "CLAUDE.md" {
		t.Errorf("the commit changes %q, want only CLAUDE.md", got)
	}
	calls := f.ghCalls(t)
	want := "pr create -R github.com/example/repo --base main --head coach/proposal-7 --title Be brief --body " + req.Body
	if !strings.HasSuffix(strings.Join(calls, "\n"), want) { // the body is multi-line in the log
		t.Errorf("gh calls %q lack %q", calls, want)
	}
	f.assertScratchGone(t, 7)
	for _, c := range rec.argv() {
		switch c[0] {
		case "commit", "push":
			if !slices.Contains(c, "--no-verify") {
				t.Errorf("%v runs the repository's hooks", c)
			}
		case "worktree":
			if c[1] == "add" && (!slices.Contains(c, "--detach") || !slices.Contains(c, "--no-checkout")) {
				t.Errorf("%v is not a detached worktree without a checkout", c)
			}
		case "fetch":
			if !slices.Contains(c, "--no-write-fetch-head") || !slices.Contains(c, "--no-tags") || c[len(c)-1] != f.base {
				t.Errorf("%v is not a fetch of the base by its id", c)
			}
		}
	}
}

func TestPublish_BaseDiffers(t *testing.T) {
	f := newPublishFixture(t)
	req := f.request(3)
	req.Before = "# Other rules\n"
	_, err := Publish(context.Background(), f.options(nil), req)
	if !errors.Is(err, ErrBaseDiffers) {
		t.Fatalf("err = %v, want ErrBaseDiffers", err)
	}
	if got := refs(t, f.origin); len(got) != 2 {
		t.Errorf("origin refs = %q, want main and feature only", got)
	}
	if calls := f.ghCalls(t); len(calls) != 0 {
		t.Errorf("gh ran: %q", calls)
	}
	f.assertScratchGone(t, 3)
}

// A proposal may create a file: an empty Before matches a missing path.
func TestPublish_NewFile(t *testing.T) {
	f := newPublishFixture(t)
	req := f.request(4)
	req.Rel, req.Before, req.After = filepath.Join(".claude", "skills", "x", "SKILL.md"), "", "skill\n"
	if _, err := Publish(context.Background(), f.options(nil), req); err != nil {
		t.Fatal(err)
	}
	if got := gitIn(t, f.origin, "show", "coach/proposal-4:.claude/skills/x/SKILL.md"); got != "skill" {
		t.Errorf("new file = %q", got)
	}
}

func TestPublish_PushFailed(t *testing.T) {
	f := newPublishFixture(t)
	// refs/heads/coach on origin: coach/proposal-5 cannot be created next to it.
	gitIn(t, f.origin, "update-ref", "refs/heads/coach", f.base)
	_, err := Publish(context.Background(), f.options(nil), f.request(5))
	if !errors.Is(err, ErrPushFailed) {
		t.Fatalf("err = %v, want ErrPushFailed", err)
	}
	if !strings.Contains(err.Error(), "coach") {
		t.Errorf("err %q lacks git's words", err)
	}
	if calls := f.ghCalls(t); countPrefix(calls, "pr ") != 0 {
		t.Errorf("gh pr ran after a failed push: %q", calls)
	}
	f.assertScratchGone(t, 5)
}

// gh pr create failing leaves the branch on origin; a rerun pushes it again
// and opens the PR, and the next one finds that PR instead of opening
// another.
func TestPublish_PRFailedThenRerunReuses(t *testing.T) {
	f := newPublishFixture(t)
	o := f.options(nil)
	f.flag(t, "fail-create")
	_, err := Publish(context.Background(), o, f.request(9))
	if !errors.Is(err, ErrPRFailed) || !strings.Contains(err.Error(), "simulated failure") {
		t.Fatalf("err = %v, want ErrPRFailed with gh's words", err)
	}
	first := gitIn(t, f.origin, "rev-parse", "refs/heads/coach/proposal-9")
	f.unflag(t, "fail-create")
	res, err := Publish(context.Background(), o, f.request(9))
	if err != nil {
		t.Fatal(err)
	}
	if again := gitIn(t, f.origin, "rev-parse", "refs/heads/coach/proposal-9"); again == first {
		t.Log("the rerun's commit is identical to the first one")
	}
	res2, err := Publish(context.Background(), o, f.request(9))
	if err != nil {
		t.Fatal(err)
	}
	if res2.PRURL != res.PRURL {
		t.Errorf("rerun PR = %s, want the open %s", res2.PRURL, res.PRURL)
	}
	if n := countPrefix(f.ghCalls(t), "pr create"); n != 2 {
		t.Errorf("pr create ran %d times, want 2 (the failed one and the first success)", n)
	}
	f.assertScratchGone(t, 9)
}

// A leftover scratch worktree of the same id (an Accept killed half-way) is
// removed first; another id's folder is left alone.
func TestPublish_RemovesLeftoverOfItsID(t *testing.T) {
	f := newPublishFixture(t)
	gitIn(t, f.dir, "worktree", "add", "-q", "--detach", filepath.Join(f.scratch, "11"), "HEAD")
	writeFile(t, filepath.Join(f.scratch, "11"), "junk.txt", "left over\n")
	other := filepath.Join(f.scratch, "12")
	if err := os.MkdirAll(other, 0o755); err != nil {
		t.Fatal(err)
	}
	writeFile(t, other, "keep.txt", "another proposal's\n")
	// The owner's worktree on a volume that is not mounted: registered, its
	// folder missing. No cleanup may drop its registration.
	ownerWT := addWorktree(t, f.dir, "owner-wt", "main")
	if err := os.RemoveAll(ownerWT); err != nil {
		t.Fatal(err)
	}
	// A leftover of id 13 whose folder is gone but whose registration is not.
	gitIn(t, f.dir, "worktree", "add", "-q", "--detach", filepath.Join(f.scratch, "13"), "HEAD")
	if err := os.RemoveAll(filepath.Join(f.scratch, "13")); err != nil {
		t.Fatal(err)
	}
	for _, id := range []int64{11, 13} {
		if _, err := Publish(context.Background(), f.options(nil), f.request(id)); err != nil {
			t.Fatalf("publish %d: %v", id, err)
		}
		f.assertScratchGone(t, id)
	}
	if got := readFile(t, other, "keep.txt"); got != "another proposal's\n" {
		t.Errorf("another id's folder changed: %q", got)
	}
	if wt := gitIn(t, f.dir, "worktree", "list", "--porcelain"); !strings.Contains(wt, "worktree "+ownerWT+"\n") {
		t.Errorf("the owner's worktree with a missing folder lost its registration:\n%s", wt)
	}
}

// An executable file keeps its mode; the commit changes only its content.
func TestPublish_KeepsTheFileMode(t *testing.T) {
	f := newPublishFixture(t)
	writeFile(t, f.dir, "run.sh", "#!/bin/sh\n")
	if err := os.Chmod(filepath.Join(f.dir, "run.sh"), 0o755); err != nil {
		t.Fatal(err)
	}
	gitIn(t, f.dir, "add", "run.sh")
	gitIn(t, f.dir, "commit", "-q", "-m", "script")
	gitIn(t, f.dir, "push", "-q", Remote, "main")
	req := f.request(14)
	req.Rel, req.Before, req.After, req.BaseSHA = "run.sh", "#!/bin/sh\n", "#!/bin/sh\necho hi\n", gitIn(t, f.origin, "rev-parse", "main")
	if _, err := Publish(context.Background(), f.options(nil), req); err != nil {
		t.Fatal(err)
	}
	if got := gitIn(t, f.origin, "ls-tree", "coach/proposal-14", "run.sh"); !strings.HasPrefix(got, "100755 ") {
		t.Errorf("run.sh on the branch = %q, want mode 100755", got)
	}
	if got := gitIn(t, f.origin, "diff-tree", "-r", "--summary", "coach/proposal-14^", "coach/proposal-14"); strings.Contains(got, "mode change") {
		t.Errorf("the commit changes the mode: %q", got)
	}
}

// An origin whose push URL is another repository (a fork) is refused before
// anything is pushed anywhere.
func TestPublish_PushURLElsewhereRefused(t *testing.T) {
	f := newPublishFixture(t)
	fork := filepath.Join(filepath.Dir(f.origin), "fork.git")
	gitIn(t, filepath.Dir(f.origin), "init", "-q", "--bare", fork)
	gitIn(t, f.dir, "config", "remote."+Remote+".pushurl", fork)
	_, err := Publish(context.Background(), f.options(nil), f.request(15))
	if !errors.Is(err, ErrPushFailed) || !strings.Contains(err.Error(), "different repository") {
		t.Fatalf("err = %v, want ErrPushFailed naming the other repository", err)
	}
	if got := refs(t, fork); len(got) != 0 {
		t.Errorf("the fork gained refs: %q", got)
	}
	if got := refs(t, f.origin); len(got) != 2 {
		t.Errorf("origin refs = %q", got)
	}
	if calls := f.ghCalls(t); len(calls) != 0 {
		t.Errorf("gh ran: %q", calls)
	}
}

func TestPublish_ParallelIDs(t *testing.T) {
	f := newPublishFixture(t)
	o := f.options(nil)
	var wg sync.WaitGroup
	errs := make([]error, 2)
	for i, id := range []int64{21, 22} {
		wg.Go(func() { _, errs[i] = Publish(context.Background(), o, f.request(id)) })
	}
	wg.Wait()
	for i, err := range errs {
		if err != nil {
			t.Errorf("publish %d: %v", i, err)
		}
	}
	for _, id := range []int64{21, 22} {
		gitIn(t, f.origin, "rev-parse", "--verify", "refs/heads/coach/proposal-"+itoa(id))
		f.assertScratchGone(t, id)
	}
}

// A gh call that hangs is cut off when its budget ends: ErrTimeout, the
// stub's process group killed, the scratch folder removed.
func TestPublish_HangingGHTimesOut(t *testing.T) {
	f := newPublishFixture(t)
	f.flag(t, "hang")
	for _, name := range []string{"ready", "hold"} {
		if err := syscall.Mkfifo(filepath.Join(f.stub, name), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	ctx := newExpiringCtx()
	expire := ctx.expire
	t.Cleanup(func() {
		expire()
		// Unblock the reader below if the stub never got there, and a stub
		// that outlived its kill: its cat sees EOF on hold and exits.
		for _, name := range []string{"ready", "hold"} {
			if w, err := os.OpenFile(filepath.Join(f.stub, name), os.O_WRONLY|syscall.O_NONBLOCK, 0); err == nil {
				_ = w.Close()
			}
		}
	})
	go func() {
		_, _ = os.ReadFile(filepath.Join(f.stub, "ready")) // the stub is now blocked on hold
		expire()
	}()
	_, err := Publish(ctx, f.options(nil), f.request(31))
	if !errors.Is(err, ErrTimeout) {
		t.Fatalf("err = %v, want ErrTimeout", err)
	}
	f.assertScratchGone(t, 31)
	// Publish returned only after the killed stub was waited for, so its pid
	// is gone now — no polling.
	pid, err := strconv.Atoi(strings.TrimSpace(readFile(t, f.stub, "pid")))
	if err != nil {
		t.Fatal(err)
	}
	if err := syscall.Kill(pid, 0); !errors.Is(err, syscall.ESRCH) {
		t.Errorf("the hanging stub %d is still alive (%v)", pid, err)
	}
}

// A deadline already past maps to ErrTimeout for every network helper.
func TestPublish_PastDeadlineIsTimeout(t *testing.T) {
	f := newPublishFixture(t)
	ctx, cancel := context.WithDeadline(context.Background(), time.Unix(0, 0))
	defer cancel()
	o := f.options(nil)
	if _, err := Publish(ctx, o, f.request(32)); !errors.Is(err, ErrTimeout) {
		t.Errorf("Publish: %v, want ErrTimeout", err)
	}
	if err := GHReady(ctx, o, githubHost); !errors.Is(err, ErrTimeout) {
		t.Errorf("GHReady: %v, want ErrTimeout", err)
	}
	if _, _, err := DefaultBase(ctx, o); !errors.Is(err, ErrTimeout) {
		t.Errorf("DefaultBase: %v, want ErrTimeout", err)
	}
	if _, _, err := PRState(ctx, o, "https://github.com/example/repo/pull/1"); !errors.Is(err, ErrTimeout) {
		t.Errorf("PRState: %v, want ErrTimeout", err)
	}
	if err := ClosePR(ctx, o, "https://github.com/example/repo/pull/1"); !errors.Is(err, ErrTimeout) {
		t.Errorf("ClosePR: %v, want ErrTimeout", err)
	}
}

func TestDefaultBase(t *testing.T) {
	f := newPublishFixture(t)
	branch, sha, err := DefaultBase(context.Background(), f.options(nil))
	if err != nil {
		t.Fatal(err)
	}
	if branch != "main" || sha != f.base {
		t.Fatalf("DefaultBase = %s %s, want main %s", branch, sha, f.base)
	}
	if calls := f.ghCalls(t); !slices.Contains(calls, "repo view github.com/example/repo --json defaultBranchRef") {
		t.Errorf("gh calls = %q", calls)
	}
}

func TestPRStateAndClosePR(t *testing.T) {
	f := newPublishFixture(t)
	o := f.options(nil)
	const pr = "https://github.com/example/repo/pull/4"
	writeFile(t, f.stub, "view", `{"state":"MERGED","mergedAt":"2026-11-01T10:00:00Z"}`)
	state, at, err := PRState(context.Background(), o, pr)
	if err != nil || state != "MERGED" || !at.Equal(time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)) {
		t.Fatalf("PRState = %s %v %v", state, at, err)
	}
	writeFile(t, f.stub, "view", `{"state":"OPEN","mergedAt":null}`)
	if state, at, err = PRState(context.Background(), o, pr); err != nil || state != "OPEN" || !at.IsZero() {
		t.Fatalf("PRState = %s %v %v", state, at, err)
	}
	if err := ClosePR(context.Background(), o, pr); err != nil {
		t.Fatal(err)
	}
	if calls := f.ghCalls(t); !slices.Contains(calls, "pr close "+pr+" --delete-branch") ||
		!slices.Contains(calls, "pr view "+pr+" --json state,mergedAt") {
		t.Errorf("gh calls = %q", calls)
	}
	writeFile(t, f.stub, "view", `not json`)
	if _, _, err := PRState(context.Background(), o, pr); err == nil {
		t.Error("PRState accepted output with no state")
	}
}

func TestGHReady(t *testing.T) {
	f := newPublishFixture(t)
	o := f.options(nil)
	if err := GHReady(context.Background(), o, githubHost); err != nil {
		t.Fatalf("logged in: %v", err)
	}
	f.flag(t, "offline")
	if err := GHReady(context.Background(), o, githubHost); err == nil || errors.Is(err, ErrNoGH) ||
		!strings.Contains(err.Error(), "error connecting") {
		t.Fatalf("offline: %v, want a plain error with gh's words, not ErrNoGH", err)
	}
	f.unflag(t, "offline")
	f.flag(t, "loggedout")
	if err := GHReady(context.Background(), o, githubHost); !errors.Is(err, ErrNoGH) {
		t.Fatalf("logged out: %v, want ErrNoGH", err)
	}
	o.GHPath = filepath.Join(f.stub, "missing-gh")
	if err := GHReady(context.Background(), o, githubHost); !errors.Is(err, ErrNoGH) {
		t.Fatalf("missing gh: %v, want ErrNoGH", err)
	}
	if calls := f.ghCalls(t); !slices.Contains(calls, "auth status --hostname github.com") {
		t.Errorf("gh calls = %q", calls)
	}
}

func TestRemoteURL(t *testing.T) {
	for raw, want := range map[string][2]string{
		"https://github.com/example/repo.git":           {"github.com", "example/repo"},
		"https://user:tok@GitHub.com/example/repo/":     {"github.com", "example/repo"}, // leak-check:allow: test git remote URL, not an email
		"ssh://git@github.com:22/example/repo.git":      {"github.com", "example/repo"}, // leak-check:allow: test git remote URL, not an email
		"git@github.com:example/repo.git":               {"github.com", "example/repo"}, // leak-check:allow: test git remote URL, not an email
		"github.com:example/repo":                       {"github.com", "example/repo"},
		"git@ghe.example.com:team/repo.git":             {"ghe.example.com", "team/repo"}, // leak-check:allow: test git remote URL, not an email
		"https://gitlab.example.com/group/sub/repo.git": {"gitlab.example.com", "group/sub/repo"},
		"/srv/git/repo.git":                             {"", ""},
		"./repo":                                        {"", ""},
		"file:///srv/git/repo.git":                      {"", ""},
		"C:/repo":                                       {"", ""},
	} {
		host, path := remoteURL(raw)
		if host != want[0] || path != want[1] {
			t.Errorf("remoteURL(%q) = %q %q, want %q %q", raw, host, path, want[0], want[1])
		}
	}
}

// Path choice (spec D8): a github.com origin in any of the three URL forms is
// a GitHub folder without asking gh; another host only when gh is logged in
// there; no origin or a local one never.
func TestIsGitHubFolder(t *testing.T) {
	dir := newRepo(t)
	o := Options{Folder: dir}
	asked := ""
	loggedIn := func(answer bool) func(string) bool {
		return func(host string) bool { asked = host; return answer }
	}
	check := func(url string, ghAnswer, want bool, wantAsked string) {
		t.Helper()
		gitIn(t, dir, "remote", "set-url", Remote, url)
		asked = ""
		got, err := IsGitHubFolder(context.Background(), o, loggedIn(ghAnswer))
		if err != nil || got != want || asked != wantAsked {
			t.Errorf("%s (gh logged in: %v) = %v %v, asked %q; want %v, asked %q", url, ghAnswer, got, err, asked, want, wantAsked)
		}
	}
	if got, err := IsGitHubFolder(context.Background(), o, loggedIn(true)); err != nil || got || asked != "" {
		t.Errorf("no origin = %v %v (asked %q), want false", got, err, asked)
	}
	gitIn(t, dir, "remote", "add", Remote, "x")
	check("https://github.com/example/repo.git", false, true, "")
	check("ssh://git@github.com/example/repo.git", false, true, "")             // leak-check:allow: test git remote URL, not an email
	check("git@github.com:example/repo.git", false, true, "")                   // leak-check:allow: test git remote URL, not an email
	check("git@ghe.example.com:team/repo.git", false, false, "ghe.example.com") // leak-check:allow: test git remote URL, not an email
	check("https://ghe.example.com/team/repo.git", true, true, "ghe.example.com")
	check("/srv/git/repo.git", true, false, "")
	if host, err := OriginHost(context.Background(), Options{Folder: dir}); err != nil || host != "" {
		t.Errorf("OriginHost of a path = %q %v", host, err)
	}
	// insteadOf either way round: an alias that git rewrites to github.com,
	// and a github.com URL that git rewrites to a mirror.
	gitIn(t, dir, "config", "url.https://github.com/.insteadOf", "gh:")
	check("gh:example/repo.git", false, true, "")
	gitIn(t, dir, "config", "--unset", "url.https://github.com/.insteadOf")
	gitIn(t, dir, "config", "url./srv/mirror/.insteadOf", "https://github.com/")
	check("https://github.com/example/repo.git", false, true, "")
}

// A push or ls-remote outside an owner's Publish never runs: only the
// owner's network calls carry credentials.
func TestExecRunner_RefusesAPushOutsidePublish(t *testing.T) {
	dir := newRepo(t)
	for _, args := range [][]string{{"push", "origin", "main"}, {"ls-remote", "origin"}} {
		if _, _, err := execRunner(context.Background(), dir, nil, gitBin(t), args...); err == nil {
			t.Errorf("%v ran outside a publish", args)
		}
	}
}

// COACH-01 (amended, docs/inventory/coach.md): Publish commits in a
// detached scratch worktree and pushes only its own branch. The owner's
// working copy (dirty, with an untracked file), HEAD, every local ref —
// origin/* and FETCH_HEAD included — and the stash stay as they were, and
// origin gains coach/proposal-<id> and nothing else.
func TestCOACH01_PublishTouchesOnlyItsBranch(t *testing.T) {
	f := newPublishFixture(t)
	gitIn(t, f.dir, "fetch", "-q", Remote) // origin/* and FETCH_HEAD exist
	// An annotated tag reachable from the base that origin lacks, and the
	// owner's push.followTags: the push must still send only its branch.
	gitIn(t, f.dir, "tag", "-a", "-m", "release", "v1", "main")
	gitIn(t, f.dir, "config", "push.followTags", "true")
	gitIn(t, f.dir, "switch", "-q", "feature")
	writeFile(t, f.dir, "feature.txt", "owner's uncommitted edit\n")
	writeFile(t, f.dir, "notes.txt", "owner's untracked file\n")
	writeFile(t, f.dir, "CLAUDE.md", "owner's own CLAUDE.md draft\n")

	type snapshot struct {
		refs                     []string
		head, symbolic, status   string
		fetchHead, stash, wtList string
		files                    map[string]string
	}
	take := func() snapshot {
		raw, err := os.ReadFile(filepath.Join(f.dir, ".git", "FETCH_HEAD"))
		if err != nil {
			t.Fatal(err)
		}
		s := snapshot{
			refs: refs(t, f.dir), head: gitIn(t, f.dir, "rev-parse", "HEAD"),
			symbolic: gitIn(t, f.dir, "symbolic-ref", "HEAD"), status: gitIn(t, f.dir, "status", "--porcelain=v1", "-uall"),
			fetchHead: string(raw), stash: gitIn(t, f.dir, "stash", "list"),
			wtList: gitIn(t, f.dir, "worktree", "list", "--porcelain"), files: map[string]string{},
		}
		for _, name := range []string{"feature.txt", "notes.txt", "CLAUDE.md", "README.md"} {
			s.files[name] = readFile(t, f.dir, name)
		}
		return s
	}
	before, originBefore := take(), refs(t, f.origin)
	if !slices.ContainsFunc(before.refs, func(r string) bool { return strings.HasPrefix(r, "refs/remotes/origin/") }) {
		t.Fatalf("setup: no origin/* refs in %q", before.refs)
	}

	res, err := Publish(context.Background(), f.options(nil), f.request(42))
	if err != nil {
		t.Fatal(err)
	}
	if res.PRURL == "" {
		t.Fatal("no PR URL")
	}

	after := take()
	if !slices.Equal(after.refs, before.refs) {
		t.Errorf("local refs changed:\nbefore %q\nafter  %q", before.refs, after.refs)
	}
	for name, pair := range map[string][2]string{
		"HEAD": {before.head, after.head}, "HEAD ref": {before.symbolic, after.symbolic},
		"status": {before.status, after.status}, "FETCH_HEAD": {before.fetchHead, after.fetchHead},
		"stash": {before.stash, after.stash}, "worktree list": {before.wtList, after.wtList},
	} {
		if pair[0] != pair[1] {
			t.Errorf("%s changed:\nbefore %q\nafter  %q", name, pair[0], pair[1])
		}
	}
	for name, content := range before.files {
		if after.files[name] != content {
			t.Errorf("%s in the working copy changed: %q → %q", name, content, after.files[name])
		}
	}
	originAfter := refs(t, f.origin)
	var added []string
	for _, r := range originAfter {
		if !slices.Contains(originBefore, r) {
			added = append(added, strings.Fields(r)[0])
		}
	}
	if len(added) != 1 || added[0] != "refs/heads/coach/proposal-42" || len(originAfter) != len(originBefore)+1 {
		t.Errorf("origin refs: before %q, after %q; want only refs/heads/coach/proposal-42 added", originBefore, originAfter)
	}
}
