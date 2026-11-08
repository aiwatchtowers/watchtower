package cmd

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"slices"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/fsutil"
	"watchtower/internal/reviewai"
)

// Board #1025, tech spec §3.7: one overview run at a time per branch
// folder — the run lock, the streamed form's wait, busy for every other
// form.

const (
	lockChildEnv       = "WATCHTOWER_TEST_REVIEW_LOCK_CHILD" // hold | run
	lockChildPathEnv   = "WATCHTOWER_TEST_REVIEW_LOCK_PATH"
	lockChildConfigEnv = "WATCHTOWER_TEST_REVIEW_LOCK_CONFIG"
	lockChildArgsEnv   = "WATCHTOWER_TEST_REVIEW_LOCK_ARGS"
)

// TestReviewOverviewLockHelperProcess is the second process of these tests
// (a re-exec of the test binary): "hold" takes the run lock as an agent and
// blocks; "run" runs the overview command with a generator that answers
// two calls and hangs on the rest. Both block until they are killed.
func TestReviewOverviewLockHelperProcess(t *testing.T) {
	switch os.Getenv(lockChildEnv) {
	case "hold":
		if _, err := reviewai.AcquireRun(context.Background(), os.Getenv(lockChildPathEnv), "agent", nil); err != nil {
			fmt.Fprintln(os.Stderr, "holder:", err)
			os.Exit(3)
		}
		fmt.Println("locked")
		select {}
	case "run":
		flagConfig = os.Getenv(lockChildConfigEnv)
		reviewAIGeneratorFactory = func(*config.Config) digest.Generator { return &firstCallsGen{answer: 2} }
		_, _, err := runWorkbench(t, strings.Split(os.Getenv(lockChildArgsEnv), "\x1f")...)
		fmt.Fprintln(os.Stderr, "run ended:", err)
		os.Exit(4)
	}
}

// firstCallsGen answers its first answer calls like keyReviewGen and hangs
// every later one until its context ends.
type firstCallsGen struct {
	mu     sync.Mutex
	calls  int
	answer int
	inner  keyReviewGen
}

func (g *firstCallsGen) Generate(ctx context.Context, system, user, model string) (string, *digest.Usage, string, error) {
	g.mu.Lock()
	g.calls++
	n := g.calls
	g.mu.Unlock()
	if n > g.answer {
		<-ctx.Done()
		return "", nil, "", ctx.Err()
	}
	return g.inner.Generate(ctx, system, user, model)
}

// startLockChild re-execs the test binary as a lock child with env; the
// returned kill ends its whole process group (also run by t.Cleanup).
func startLockChild(t *testing.T, env ...string) (c *exec.Cmd, stdout io.Reader, kill func()) {
	t.Helper()
	c = exec.Command(os.Args[0], "-test.run=^TestReviewOverviewLockHelperProcess$")
	c.Env = append(append(os.Environ(), "GO_WANT_HELPER_PROCESS=1"), env...)
	c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	var stderr bytes.Buffer
	c.Stderr = &stderr
	out, err := c.StdoutPipe()
	require.NoError(t, err)
	require.NoError(t, c.Start())
	kill = sync.OnceFunc(func() {
		_ = syscall.Kill(-c.Process.Pid, syscall.SIGKILL)
		_ = c.Wait()
	})
	t.Cleanup(kill)
	return c, out, kill
}

// holdOverviewLock starts a process holding the run lock of repo as an
// agent; kill releases it.
func holdOverviewLock(t *testing.T, wb int64, repo string) (path string, kill func()) {
	t.Helper()
	path = overviewLockPath(t, wb, repo)
	_, out, kill := startLockChild(t, lockChildEnv+"=hold", lockChildPathEnv+"="+path)
	ready := make(chan string, 1)
	go func() {
		line, _ := bufio.NewReader(out).ReadString('\n')
		ready <- line
	}()
	select {
	case line := <-ready:
		require.Equal(t, "locked\n", line)
	case <-time.After(60 * time.Second):
		kill()
		t.Fatal("the holder never took the lock")
	}
	return path, kill
}

func overviewLockPath(t *testing.T, wb int64, repo string) string {
	t.Helper()
	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	return reviewai.LockPath(cfg.WorkspaceDir(), wb, realFolderPath(repo))
}

// lineWriter hands every complete line written to it to lines.
type lineWriter struct {
	mu    sync.Mutex
	buf   []byte
	lines chan string
}

func (w *lineWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.buf = append(w.buf, p...)
	for {
		i := bytes.IndexByte(w.buf, '\n')
		if i < 0 {
			return len(p), nil
		}
		w.lines <- string(w.buf[:i])
		w.buf = w.buf[i+1:]
	}
}

// streamOverviewAsync runs the streamed form in the background: its lines
// arrive on the returned channel, closed when the command returns.
func streamOverviewAsync(t *testing.T, wb int64, args ...string) <-chan string {
	t.Helper()
	w := &lineWriter{lines: make(chan string, 1000)}
	done := make(chan struct{})
	go func() {
		defer close(done)
		defer close(w.lines)
		rootCmd.SetOut(w)
		rootCmd.SetErr(io.Discard)
		rootCmd.SetArgs(append([]string{"workbench", "review", "overview", "--workbench", itoa(wb), "--json", "--stream"}, args...))
		_ = rootCmd.Execute()
		rootCmd.SetArgs(nil)
		resetSetFlags(append(workbenchCmd.Commands(), workbenchCmd, rootCmd)...)
		resetSetFlags(workbenchReviewCmd.Commands()...)
	}()
	t.Cleanup(func() {
		select {
		case <-done:
		case <-time.After(60 * time.Second):
			t.Error("the streamed command never returned")
		}
	})
	return w.lines
}

// nextLine is the stream's next line within a minute.
func nextLine(t *testing.T, lines <-chan string) (string, bool) {
	t.Helper()
	select {
	case l, ok := <-lines:
		return l, ok
	case <-time.After(60 * time.Second):
		t.Fatal("no stream line in a minute")
	}
	return "", false
}

func decodeLine(t *testing.T, l string) map[string]any {
	t.Helper()
	var m map[string]any
	require.NoError(t, json.Unmarshal([]byte(l), &m), l)
	return m
}

func shortLockWait(t *testing.T, w reviewai.LockWait, waitingEvery time.Duration) {
	t.Helper()
	oldWait, oldEvery := reviewLockWait, reviewWaitingEvery
	reviewLockWait, reviewWaitingEvery = w, waitingEvery
	t.Cleanup(func() { reviewLockWait, reviewWaitingEvery = oldWait, oldEvery })
}

// A non-streamed run against a held lock answers busy at once (exit 1)
// and never calls the model.
func TestReviewOverviewLock_NonStreamedIsBusyAtOnce(t *testing.T) {
	_, wb, _, round, repo := bigOverviewRound(t)
	holdOverviewLock(t, wb, repo)
	g := &keyReviewGen{}
	useReviewGenerator(t, g)
	start := time.Now()
	out, _, err := runWorkbench(t, "review", "overview", "--workbench", itoa(wb), "--json", "--round", round)
	resetSetFlags(workbenchReviewCmd.Commands()...)
	assert.Less(t, time.Since(start), time.Second)
	var ec *exitCodeError
	require.ErrorAs(t, err, &ec)
	assert.Equal(t, 1, ec.code)
	env := decodeLine(t, strings.TrimSpace(out))
	assert.Equal(t, "busy", env["error_class"])
	assert.Equal(t, "Another run is describing this branch now; run this again when it finishes — what it describes is kept.", env["error"])
	assert.Zero(t, g.calls)

	// --cached-only takes no lock.
	cached := reviewJSON(t, wb, "overview", "--round", round, "--cached-only")
	assert.Equal(t, true, cached["ok"], cached)
}

// The streamed form waits for the holder: it prints waiting once, a cached
// line for each part the holder writes meanwhile, and once it holds the
// lock it calls the model only for the chapters still without a part — no
// part_hash is described twice.
func TestReviewOverviewLock_StreamedWaiterShowsTheHoldersPartsThenCallsTheRest(t *testing.T) {
	database, wb, _, round, repo := bigOverviewRound(t)
	first := &keyReviewGen{}
	useReviewGenerator(t, first)
	require.Equal(t, true, reviewJSON(t, wb, "overview", "--round", round)["ok"])
	_, batches, _ := first.count()
	require.Len(t, batches, 2)
	holderBatch, rest := batches[0], batches[1]
	parts := savedParts(t, database, holderBatch)
	_, err := database.Exec(`DELETE FROM review_overview_parts`)
	require.NoError(t, err)
	_, err = database.Exec(`DELETE FROM review_overviews`)
	require.NoError(t, err)

	_, kill := holdOverviewLock(t, wb, repo)
	shortLockWait(t, reviewai.LockWait{Every: 20 * time.Millisecond}, 24*time.Hour)
	g := &keyReviewGen{}
	useReviewGenerator(t, g)
	lines := streamOverviewAsync(t, wb, "--round", round)

	l, _ := nextLine(t, lines)
	assert.Equal(t, "map", decodeLine(t, l)["event"])
	l, _ = nextLine(t, lines)
	assert.Equal(t, map[string]any{"event": "waiting", "by": "agent"}, decodeLine(t, l))

	// The holder finishes its first batch.
	for _, p := range parts {
		require.NoError(t, database.PutReviewOverviewPart(p, time.Now()))
	}
	var cached []string
	for len(cached) < len(holderBatch) {
		l, ok := nextLine(t, lines)
		require.True(t, ok, "the stream ended while waiting")
		e := decodeLine(t, l)
		if e["event"] == "chapter" {
			assert.Equal(t, "cached", e["state"], l)
			cached = append(cached, e["key"].(string))
		}
	}
	assert.ElementsMatch(t, holderBatch, cached)
	assert.Zero(t, g.calls, "no call while waiting")

	kill()
	var events []map[string]any
	for l := range lines {
		events = append(events, decodeLine(t, l))
	}
	require.NotEmpty(t, events)
	assert.Equal(t, true, events[len(events)-1]["ok"], events[len(events)-1])
	_, calls, _ := g.count()
	require.Len(t, calls, 1, "one batch: the chapters still without a part")
	assert.ElementsMatch(t, rest, calls[0])
	for _, e := range events {
		assert.NotEqual(t, "waiting", e["event"], "waiting is printed once")
		if e["event"] == "chapter" {
			assert.Equal(t, "ok", e["state"], "a cached line the wait printed is not printed again: %v", e)
			assert.Contains(t, rest, e["key"])
		}
	}
}

// savedParts is the part rows of the chapters keys.
func savedParts(t *testing.T, database *db.DB, keys []string) []db.ReviewOverviewPart {
	t.Helper()
	rows, err := database.Query(`SELECT project_id, part_hash, json, model FROM review_overview_parts`)
	require.NoError(t, err)
	defer rows.Close()
	var out []db.ReviewOverviewPart
	for rows.Next() {
		var p db.ReviewOverviewPart
		require.NoError(t, rows.Scan(&p.ProjectID, &p.Hash, &p.JSON, &p.Model))
		var d reviewai.ChapterDesc
		require.NoError(t, json.Unmarshal([]byte(p.JSON), &d))
		if slices.Contains(keys, d.Key) {
			out = append(out, p)
		}
	}
	require.NoError(t, rows.Err())
	require.Len(t, out, len(keys))
	return out
}

// A holder that never releases: the wait ends at its cap with busy and
// the card's sentence; the model is never called.
func TestReviewOverviewLock_WaitCapIsBusy(t *testing.T) {
	_, wb, _, round, repo := bigOverviewRound(t)
	holdOverviewLock(t, wb, repo)
	shortLockWait(t, reviewai.LockWait{Cap: 300 * time.Millisecond, Every: 50 * time.Millisecond}, time.Minute)
	g := &keyReviewGen{}
	useReviewGenerator(t, g)
	var events []map[string]any
	for l := range streamOverviewAsync(t, wb, "--round", round) {
		events = append(events, decodeLine(t, l))
	}
	require.GreaterOrEqual(t, len(events), 3, events)
	assert.Equal(t, "map", events[0]["event"])
	assert.Equal(t, "waiting", events[1]["event"])
	last := events[len(events)-1]
	assert.Equal(t, "busy", last["error_class"])
	assert.Equal(t, "Another overview of this branch is still running.", last["error"])
	assert.Zero(t, g.calls)
}

// An agent's run killed after two of four batches leaves their parts and
// the lock; a re-run calls the model only for the other two.
func TestReviewOverviewLock_KilledAgentRunKeepsItsParts(t *testing.T) {
	database, wb, session, repo := reviewFixture(t)
	for i := range 32 {
		writeRepoFile(t, repo, fmt.Sprintf("d%02d/f.go", i), strings.Repeat(fmt.Sprintf("line %d\n", i), 300))
	}
	round := itoa(int64(startRound(t, wb, session)["id"].(float64)))
	path := overviewLockPath(t, wb, repo)
	_, _, kill := startLockChild(t, lockChildEnv+"=run", lockChildConfigEnv+"="+flagConfig, "CLAUDECODE=1",
		lockChildArgsEnv+"="+strings.Join([]string{"review", "overview", "--workbench", itoa(wb), "--json", "--round", round}, "\x1f"))
	require.Eventually(t, func() bool {
		return countRows(t, database, "SELECT COUNT(*) FROM review_overview_parts") == 16
	}, 2*time.Minute, 50*time.Millisecond, "two batches of eight chapters described")
	assert.Equal(t, "agent", reviewai.ReadHolder(path).By, "the agent marker names the holder")
	kill()

	unlock, ok, err := fsutil.TryLockFile(path)
	require.NoError(t, err)
	require.True(t, ok, "the kernel dropped the killed run's lock")
	unlock()

	g := &keyReviewGen{}
	useReviewGenerator(t, g)
	out := reviewJSON(t, wb, "overview", "--round", round)
	require.Equal(t, true, out["ok"], out)
	calls, batches, _ := g.count()
	assert.Equal(t, 3, calls, "the two batches left and the summary")
	described := 0
	for _, b := range batches {
		described += len(b)
	}
	assert.Equal(t, 16, described)
	assert.Equal(t, 32, countRows(t, database, "SELECT COUNT(*) FROM review_overview_parts"))
}

// deadlineGen records the deadline of each call's context.
type deadlineGen struct {
	keyReviewGen
	deadlines []time.Time
}

func (g *deadlineGen) Generate(ctx context.Context, system, user, model string) (string, *digest.Usage, string, error) {
	dl, _ := ctx.Deadline()
	g.mu.Lock()
	g.deadlines = append(g.deadlines, dl)
	g.mu.Unlock()
	return g.keyReviewGen.Generate(ctx, system, user, model)
}

// The wait does not count into the run's ceiling: a call made after a wait
// near the cap still gets its whole budget.
func TestReviewOverviewLock_WaitDoesNotCountIntoTheCeiling(t *testing.T) {
	_, wb, _, round, repo := overviewRoundIn(t)
	_, kill := holdOverviewLock(t, wb, repo)
	shortLockWait(t, reviewai.LockWait{Cap: 3 * time.Second, Every: 20 * time.Millisecond}, time.Minute)
	g := &deadlineGen{}
	useReviewGenerator(t, g)
	time.AfterFunc(time.Second, kill)
	var last map[string]any
	for l := range streamOverviewAsync(t, wb, "--round", round) {
		last = decodeLine(t, l)
	}
	require.Equal(t, true, last["ok"], last)
	require.Len(t, g.deadlines, 1)
	assert.Greater(t, time.Until(g.deadlines[0]), time.Minute, "the call's budget is not cut by the wait's cap")
}
