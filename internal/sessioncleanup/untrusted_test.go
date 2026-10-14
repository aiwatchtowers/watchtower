package sessioncleanup

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A planted .git/config (an fsmonitor command, a filter driver every file
// is routed to) never runs while a plan reads the worktrees — status included
// — and the fsmonitor not while the apply removes the work (security review
// #155).
func TestProj18_PlantedGitConfigRunsNoCommand(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	pushed := f.pushedWork("wt-pushed", "feat/pushed")
	marker := filepath.Join(f.base, "planted-ran")
	script := filepath.Join(f.base, "planted")
	writeFile(t, script, "#!/bin/sh\ntouch '"+marker+"'\ncat\n")
	if err := os.Chmod(script, 0o755); err != nil {
		t.Fatal(err)
	}
	gitIn(t, f.repo, "config", "core.fsmonitor", script)
	gitIn(t, f.repo, "config", "filter.planted.clean", script)
	gitIn(t, f.repo, "config", "filter.planted.process", script)
	gitIn(t, f.repo, "config", "filter.planted.required", "true")
	writeFile(t, filepath.Join(f.repo, ".git", "info", "attributes"), "* filter=planted\n")
	// Same size as the committed content: only hashing it (the clean
	// filter's moment) tells it changed.
	writeFile(t, filepath.Join(pushed, "wt-pushed.txt"), "WORK\n")
	f.record(pushed, "feat/pushed")

	p := f.plan(Request{})
	wantItem(t, p, "worktree:"+pushed, ActionKeep, ReasonUncommittedChanges)
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("the folder's planted command ran during the plan")
	}

	// The owner-confirmed `worktree remove` keeps the repository's filters,
	// as a terminal would (gitbin.OwnerArgs); its fsmonitor never runs.
	gitIn(t, f.repo, "config", "--remove-section", "filter.planted")
	if err := os.Remove(filepath.Join(f.repo, ".git", "info", "attributes")); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(pushed, "wt-pushed.txt"), "work\n")
	res := f.apply(Request{}, nil, nil)
	wantResultItem(t, res, "worktree:"+pushed, ActionRemove, "", true)
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("the folder's fsmonitor ran during the apply")
	}
}

// The owner-confirmed writes keep the repository's hooks (as a terminal
// would) but no fsmonitor; every other run is a read with neither.
// Not parallel: it writes an executable and runs it, and a parallel test's
// fork in between holds the write descriptor until its exec, so the run
// fails with ETXTBSY ("text file busy", golang/go#22315; seen on main CI
// 2026-10-14). Sequential tests run while the parallel ones are paused.
func TestSystemGit_ReadsAndOwnerWritesArgv(t *testing.T) {
	bin := filepath.Join(t.TempDir(), "git")
	// Answers the filter-driver listing with "none" (exit 1) and echoes the
	// rest.
	if err := os.WriteFile(bin, []byte("#!/bin/sh\ncase \"$*\" in *--get-regexp*) exit 1;; esac\necho \"$*\"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	const read = "-c core.fsmonitor=false -c core.hooksPath=/dev/null -c log.showSignature=false "
	const owner = "-c core.fsmonitor=false "
	for _, tc := range []struct{ args, want string }{
		{"status --porcelain --untracked-files=normal --ignore-submodules=all", read},
		{"worktree list --porcelain", read},
		{"for-each-ref refs/heads", read},
		{"worktree remove /tmp/wt", owner},
		{"update-ref -d refs/heads/x abc", owner},
		{"config --remove-section branch.x", owner},
	} {
		out, _, err := SystemGit{}.RunGit(context.Background(), t.TempDir(), bin, strings.Fields(tc.args)...)
		if err != nil {
			t.Fatalf("%s: %v", tc.args, err)
		}
		if got := strings.TrimSpace(string(out)); got != tc.want+tc.args {
			t.Errorf("%s: argv = %q", tc.args, got)
		}
	}
}
