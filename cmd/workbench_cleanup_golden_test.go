package cmd

import (
	"context"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/sessioncleanup"
)

// goldenOrphanProcs lists one orphan of root: a stray build product.
type goldenOrphanProcs struct{ root string }

func (p goldenOrphanProcs) Scan(context.Context) ([]sessioncleanup.Proc, error) {
	return []sessioncleanup.Proc{{PID: 501, PPID: 1, UID: os.Getuid(), Start: "Mon Oct 12 10:00:00 2026",
		Exe: filepath.Join(p.root, ".build", "stub"), Cwd: p.root}}, nil
}
func (goldenOrphanProcs) Terminate(sessioncleanup.Proc) error { return nil }

// goldenLS lists one bundle in every worktree.
type goldenLS struct{}

func (goldenLS) Bundles(root string) []string {
	return []string{filepath.Join(root, "Build", "App.app")}
}
func (goldenLS) Unregister(context.Context, string) error        { return nil }
func (goldenLS) Register(context.Context, string) error          { return nil }
func (goldenLS) Stale(context.Context, string) ([]string, error) { return nil, nil }

var goldenCommitDate = regexp.MustCompile(`"last_commit_at":"[^"]+"`)

// TestCleanupCmd_StreamGoldenForTheDesktop pins the Desktop's decoding
// fixture to what `workbench cleanup --json --stream` prints for one
// session worktree with its branch, a bundle and an orphan process: the
// Swift CleanupScreenModel test builds its row from these very lines, so
// a name/root mix-up between the two sides fails there. Placeholders
// only: the temp folder reads /work/acme and the commit dates are fixed.
//
//	go test ./cmd -run TestCleanupCmd_StreamGoldenForTheDesktop -update
func TestCleanupCmd_StreamGoldenForTheDesktop(t *testing.T) {
	f := newCleanupFixture(t)
	root := f.pushedWorktree("wt-golden", "feat/golden")
	withFixture := cleanupDeps
	cleanupDeps = func(d *db.DB) sessioncleanup.Deps {
		deps := withFixture(d)
		deps.Procs, deps.LS = goldenOrphanProcs{root: root}, goldenLS{}
		return deps
	}
	t.Cleanup(func() { cleanupDeps = withFixture })

	out, err := runCleanupCmd(t, "--session", f.sessionArg(), "--json", "--stream", "--no-size")
	require.NoError(t, err, out)
	got := strings.ReplaceAll(out, f.base, "/work/acme")
	got = goldenCommitDate.ReplaceAllString(got, `"last_commit_at":"2026-10-01T10:00:00Z"`)

	file := filepath.Join("..", "WatchtowerDesktop", "Tests", "Core", "Fixtures", "session-cleanup-stream.jsonl")
	if *updateSessionReportGolden {
		require.NoError(t, os.WriteFile(file, []byte(got), 0o644))
		return
	}
	want, err := os.ReadFile(file)
	require.NoError(t, err, "run with -update to write the fixture")
	require.Equal(t, string(want), got)
}
