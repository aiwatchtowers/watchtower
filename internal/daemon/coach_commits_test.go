package daemon

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/coach"
	"watchtower/internal/db"
)

// commitGit runs git in dir for the test's own setup (Watchtower only reads).
func commitGit(t *testing.T, dir string, args ...string) {
	t.Helper()
	bin, err := exec.LookPath("git")
	if err != nil {
		t.Skip("git is not available")
	}
	c := exec.Command(bin, args...)
	c.Dir = dir
	c.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL="+os.DevNull, "GIT_CONFIG_NOSYSTEM=1",
		"GIT_AUTHOR_NAME=Test", "GIT_AUTHOR_EMAIL=test@example.com",
		"GIT_COMMITTER_NAME=Test", "GIT_COMMITTER_EMAIL=test@example.com")
	var stderr bytes.Buffer
	c.Stderr = &stderr
	require.NoError(t, c.Run(), "git %s: %s", strings.Join(args, " "), stderr.String())
}

// acceptedRepoEdit is a workbench whose folder is a git repository with
// CLAUDE.md committed as "Run tests.\n", and an accepted repo_claude_md edit
// whose after-text is written in the work tree but not committed.
func acceptedRepoEdit(t *testing.T, database *db.DB) (folder string, id int64) {
	t.Helper()
	folder, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	commitGit(t, folder, "init", "-q", "-b", "main")
	require.NoError(t, os.WriteFile(filepath.Join(folder, "CLAUDE.md"), []byte("Run tests.\n"), 0o644))
	commitGit(t, folder, "add", "-A")
	commitGit(t, folder, "commit", "-q", "-m", "init")
	wb, err := database.CreateWorkbench("acme-"+filepath.Base(folder), folder)
	require.NoError(t, err)
	id, err = database.InsertChatCoachProposal(db.CoachProposal{Fingerprint: "repo-" + filepath.Base(folder),
		Kind: "replace", Destination: coach.DestRepoClaudeMD, WorkbenchID: wb, Title: "Lint", Why: "Asked twice.",
		Metric: "corrections", BeforeText: "Run tests.\n", AfterText: "Run lint.\n", Sources: 1}, nil, time.Now())
	require.NoError(t, err)
	require.NoError(t, database.MarkCoachAccepted(id, "Run lint.\n", "main", nil, 0, time.Now()))
	require.NoError(t, os.WriteFile(filepath.Join(folder, "CLAUDE.md"), []byte("Run lint.\n"), 0o644))
	return folder, id
}

func measureFrom(t *testing.T, database *db.DB, id int64) time.Time {
	t.Helper()
	p, err := database.GetCoachProposal(id)
	require.NoError(t, err)
	return p.MeasureFrom
}

func TestRepoMeasureFrom_SetOnceAtCommit(t *testing.T) {
	d, database := coachDaemon(t)
	folder, id := acceptedRepoEdit(t, database)
	now := time.Date(2026, 11, 1, 9, 0, 0, 0, time.UTC)

	d.coachCommitCheck(context.Background(), now)
	assert.True(t, measureFrom(t, database, id).IsZero(), "written, not committed")

	commitGit(t, folder, "commit", "-q", "-am", "owner commits")
	d.coachCommitCheck(context.Background(), now)
	assert.Equal(t, now, measureFrom(t, database, id).UTC())

	d.coachCommitCheck(context.Background(), now.Add(24*time.Hour))
	assert.Equal(t, now, measureFrom(t, database, id).UTC(), "a second pass changes nothing")

	// A changed text committed instead: never measured.
	folder2, id2 := acceptedRepoEdit(t, database)
	require.NoError(t, os.WriteFile(filepath.Join(folder2, "CLAUDE.md"), []byte("Run lint, then tests.\n"), 0o644))
	commitGit(t, folder2, "commit", "-q", "-am", "owner commits another text")
	d.coachCommitCheck(context.Background(), now)
	assert.True(t, measureFrom(t, database, id2).IsZero())
}

// The phase runs the check once a day, before its weekly gate.
func TestRepoMeasureFrom_DailyInThePhase(t *testing.T) {
	d, database := coachDaemon(t)
	stubCoach(t, nil)
	folder, id := acceptedRepoEdit(t, database)
	commitGit(t, folder, "commit", "-q", "-am", "owner commits")
	d.lastCoach = time.Now() // the weekly part is not due
	d.lastCoachCommits = time.Now().Add(-time.Hour)
	d.phaseCoach(context.Background())
	assert.True(t, measureFrom(t, database, id).IsZero(), "checked an hour ago")

	d.lastCoachCommits = time.Now().Add(-25 * time.Hour)
	d.phaseCoach(context.Background())
	assert.False(t, measureFrom(t, database, id).IsZero())
}

func TestRepoMeasureFrom_RolledBackSkipped(t *testing.T) {
	d, database := coachDaemon(t)
	folder, id := acceptedRepoEdit(t, database)
	commitGit(t, folder, "commit", "-q", "-am", "owner commits")
	require.NoError(t, database.DecideCoachProposal(id, "accepted", "rolled_back", time.Now()))
	calls := 0
	prev := coachFileAtHead
	coachFileAtHead = func(ctx context.Context, folder, rel string) (string, bool, error) {
		calls++
		return prev(ctx, folder, rel)
	}
	t.Cleanup(func() { coachFileAtHead = prev })
	d.coachCommitCheck(context.Background(), time.Now())
	assert.Zero(t, calls, "a rolled-back edit is not read")
	assert.True(t, measureFrom(t, database, id).IsZero())
}

func TestRepoMeasureFrom_FolderGoneSkipped(t *testing.T) {
	d, database := coachDaemon(t)
	var logs bytes.Buffer
	d.logger.SetOutput(&logs)
	gone, idGone := acceptedRepoEdit(t, database)
	plain, idPlain := acceptedRepoEdit(t, database)
	require.NoError(t, os.RemoveAll(filepath.Join(plain, ".git"))) // not a git work tree any more
	ok, idOK := acceptedRepoEdit(t, database)
	commitGit(t, ok, "commit", "-q", "-am", "owner commits")
	require.NoError(t, os.RemoveAll(gone))

	d.coachCommitCheck(context.Background(), time.Now())
	assert.True(t, measureFrom(t, database, idGone).IsZero())
	assert.True(t, measureFrom(t, database, idPlain).IsZero())
	assert.False(t, measureFrom(t, database, idOK).IsZero(), "one skipped row does not stop the others")
	out := logs.String()
	assert.Contains(t, out, "folder gone")
	assert.Contains(t, out, "not readable at HEAD")
	for _, f := range []string{gone, plain, ok, "CLAUDE.md"} {
		assert.NotContains(t, out, f, "ids only in the log")
	}
}

// A failed list or a cancelled cycle does not stamp the day: tried next cycle.
func TestRepoMeasureFrom_CancelledCheckRetriedNextCycle(t *testing.T) {
	d, database := coachDaemon(t)
	stubCoach(t, nil)
	folder, id := acceptedRepoEdit(t, database)
	commitGit(t, folder, "commit", "-q", "-am", "owner commits")
	d.lastCoach = time.Now()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	assert.False(t, d.coachCommitCheck(ctx, time.Now()))
	assert.True(t, measureFrom(t, database, id).IsZero())

	d.phaseCoach(context.Background())
	assert.False(t, d.lastCoachCommits.IsZero(), "a full pass stamps the day")
	assert.False(t, measureFrom(t, database, id).IsZero())
}
