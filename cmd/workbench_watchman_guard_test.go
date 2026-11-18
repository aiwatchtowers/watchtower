package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentkind"
	"watchtower/internal/db"
	"watchtower/internal/watchman"
	"watchtower/internal/watchmanact"
)

// TestWATCHMAN01_HardLimitsDeniedWhileArmed pins WATCHMAN-01's guard layer:
// every row of the hard-limit table (spec §5), and a limit the owner added,
// is denied by the guard hook while the session is armed, with the parked
// reason, and allowed when it is not.
func TestWATCHMAN01_HardLimitsDeniedWhileArmed(t *testing.T) {
	bash := func(cmd string) watchman.PermissionAsk {
		return watchman.PermissionAsk{Tool: "Bash", Summary: cmd, WorkbenchFolder: "/wb", Worktrees: []string{"/wt"},
			Branch: &watchman.BranchInfo{Current: "feature/x"}}
	}
	file := func(tool, path string) watchman.PermissionAsk {
		return watchman.PermissionAsk{Tool: tool, Summary: path, WorkbenchFolder: "/wb", Worktrees: []string{"/wt"}}
	}
	extra := []db.WatchmanExtraLimit{{ID: 1, Kind: "command", Pattern: "terraform apply"}}
	cases := []struct {
		limit watchman.HardLimit
		ask   watchman.PermissionAsk
	}{
		{watchman.LimitUnreadable, bash(`echo "open`)},
		{watchman.LimitSendPack, bash("git send-pack origin feat")},
		{watchman.LimitMainRef, bash("git push origin main")},
		{watchman.LimitTag, bash("git tag v1.0")},
		{watchman.LimitRelease, bash("gh release create v1.0")},
		{watchman.LimitTestFlight, bash("fastlane pilot upload")},
		{watchman.LimitForcePush, bash("git push --force origin feature/x")},
		{watchman.LimitResetShared, bash("git reset --hard origin/feature/x")},
		{watchman.LimitDeleteOutside, bash("rm -rf /etc/acme")},
		{watchman.LimitOutward, watchman.PermissionAsk{Tool: "mcp__watchtower-workbench__send_slack_message", Summary: `{"text":"hi"}`}},
		{watchman.LimitStandingGrant, file("Write", "/wt/.claude/settings.local.json")},
		{watchman.LimitOutsideFolder, file("Edit", "/etc/hosts")},
		{watchman.LimitOwner, bash("terraform apply -auto-approve")},
	}
	covered := map[watchman.HardLimit]bool{}
	for _, tc := range cases {
		covered[tc.limit] = true
	}
	for _, l := range append(watchman.BuiltinLimits(), watchman.LimitOwner) {
		assert.True(t, covered[l], "no case for %s", l)
	}
	for _, tc := range cases {
		in := hookEvent{Event: "PreToolUse", ToolName: tc.ask.Tool}
		deny, limit := watchmanGuardDecision(in, true, tc.ask, extra)
		assert.True(t, deny, tc.limit)
		assert.Equal(t, tc.limit, limit)
		assert.Equal(t, "Parked for the owner: "+string(tc.limit)+" — continue with other work", watchmanGuardReason(limit))
		deny, _ = watchmanGuardDecision(in, false, tc.ask, extra)
		assert.False(t, deny, tc.limit)
	}
	// An ordinary call is allowed while armed.
	deny, _ := watchmanGuardDecision(hookEvent{ToolName: "Bash"}, true, bash("go test ./internal/db"), extra)
	assert.False(t, deny)
}

// countingGuardStore records each store call the guard makes.
type countingGuardStore struct {
	*db.DB
	calls    []string
	parkErr  error
	extraErr error
}

func (s *countingGuardStore) WatchmanArmedSession(id int64) (db.ArmedSession, bool, error) {
	s.calls = append(s.calls, "armed")
	return s.DB.WatchmanArmedSession(id)
}

func (s *countingGuardStore) SessionWorktrees(ctx context.Context, id int64) ([]db.SessionWorktree, error) {
	s.calls = append(s.calls, "worktrees")
	return s.DB.SessionWorktrees(ctx, id)
}

func (s *countingGuardStore) WatchmanExtraLimits() ([]db.WatchmanExtraLimit, error) {
	s.calls = append(s.calls, "extra")
	if s.extraErr != nil {
		return nil, s.extraErr
	}
	return s.DB.WatchmanExtraLimits()
}

func (s *countingGuardStore) ParkWatchmanGuard(it db.WatchmanItem, at time.Time) error {
	s.calls = append(s.calls, "park")
	if s.parkErr != nil {
		return s.parkErr
	}
	return s.DB.ParkWatchmanGuard(it, at)
}

// guardSession is a live claude session of a fresh workbench, named by the
// terminal env var; armed hands it to Watchman.
func guardSession(t *testing.T, armed bool) (id int64, folder string) {
	t.Helper()
	wb := agentsFixture(t)
	id, folder = armSession(t, wb, "claude", nil, false)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(id, 10))
	if armed {
		var path string
		d := openAgentsTestMain(t, &path)
		require.NoError(t, d.UpsertWatchmanArming(db.WatchmanArming{Scope: "session", RefID: id, ArmedAt: time.Now(), ArmedBy: "cli"}))
	}
	return id, folder
}

// guardDeps are the real database and sidecar, a fixed branch and clock,
// and the store counted in *store.
func guardDeps(t *testing.T, store **countingGuardStore) watchmanGuardDeps {
	t.Helper()
	deps := defaultWatchmanGuardDeps()
	open := deps.open
	deps.open = func() (watchmanGuardStore, error) {
		s, err := open()
		if err != nil {
			return nil, err
		}
		*store = &countingGuardStore{DB: s.(*db.DB)}
		return *store, nil
	}
	deps.branch = func(context.Context, string) string { return "feature/x" }
	deps.now = func() time.Time { return time.Date(2026, 11, 18, 2, 0, 0, 0, time.UTC) }
	return deps
}

func guardInput(t *testing.T, tool string, input any, cwd string) string {
	t.Helper()
	raw, err := json.Marshal(map[string]any{"hook_event_name": "PreToolUse", "session_id": "sid", "tool_name": tool,
		"tool_input": input, "cwd": cwd})
	require.NoError(t, err)
	return string(raw)
}

func runGuardHook(deps watchmanGuardDeps, input string) (stdout, stderr string) {
	var out, errOut bytes.Buffer
	runWatchmanGuard(strings.NewReader(input), &out, &errOut, agentkind.Claude, deps)
	return out.String(), errOut.String()
}

// guardDenial decodes the hook's stdout; "" when it printed nothing.
func guardDenial(t *testing.T, stdout string) string {
	t.Helper()
	if stdout == "" {
		return ""
	}
	var d preToolUseDenial
	require.NoError(t, json.Unmarshal([]byte(stdout), &d))
	require.Equal(t, "PreToolUse", d.HookSpecificOutput.HookEventName)
	require.Equal(t, "deny", d.HookSpecificOutput.PermissionDecision)
	return d.HookSpecificOutput.PermissionDecisionReason
}

func guardItems(t *testing.T) []db.WatchmanItem {
	t.Helper()
	var path string
	d := openAgentsTestMain(t, &path)
	rows, err := d.Query(`SELECT kind, ref_kind, ref_id, session_id, state, outcome, park_reason, question, created_at FROM watchman_items ORDER BY id`)
	require.NoError(t, err)
	defer rows.Close()
	var out []db.WatchmanItem
	for rows.Next() {
		var it db.WatchmanItem
		var created string
		require.NoError(t, rows.Scan(&it.Kind, &it.RefKind, &it.RefID, &it.SessionID, &it.State, &it.Outcome, &it.ParkReason, &it.Question, &created))
		at, err := time.Parse(time.RFC3339, created)
		require.NoError(t, err)
		it.CreatedAt = at
		out = append(out, it)
	}
	require.NoError(t, rows.Err())
	return out
}

func TestWatchmanGuard_UnarmedReadsOneRow(t *testing.T) {
	_, folder := guardSession(t, false)
	var store *countingGuardStore
	out, _ := runGuardHook(guardDeps(t, &store), guardInput(t, "Bash", map[string]string{"command": "git push origin main"}, folder))
	assert.Empty(t, out)
	require.NotNil(t, store)
	assert.Equal(t, []string{"armed"}, store.calls)
	assert.Empty(t, guardItems(t))
}

func TestWatchmanGuard_QueuesParkedItem(t *testing.T) {
	id, folder := guardSession(t, true)
	var store *countingGuardStore
	deps := guardDeps(t, &store)
	out, errOut := runGuardHook(deps, guardInput(t, "Bash", map[string]string{"command": "git push origin main"}, folder))
	assert.Equal(t, "Parked for the owner: main_ref — continue with other work", guardDenial(t, out), errOut)
	items := guardItems(t)
	require.Len(t, items, 1)
	it := items[0]
	assert.Equal(t, "guard", it.Kind)
	assert.Equal(t, "guard", it.RefKind)
	assert.Equal(t, int64(1), it.RefID)
	assert.Equal(t, id, it.SessionID)
	assert.Equal(t, "done", it.State)
	assert.Equal(t, "parked", it.Outcome)
	assert.Equal(t, "main_ref", it.ParkReason)
	assert.Equal(t, "main_ref — Bash: git push origin main", it.Question)

	// An ordinary call in the armed session passes and journals nothing more.
	out, _ = runGuardHook(deps, guardInput(t, "Bash", map[string]string{"command": "go test ./internal/db"}, folder))
	assert.Empty(t, out)
	assert.Len(t, guardItems(t), 1)
	// An edit inside the session's folder passes; one outside is parked.
	out, _ = runGuardHook(deps, guardInput(t, "Edit", map[string]string{"file_path": folder + "/main.go"}, folder))
	assert.Empty(t, out)
	out, _ = runGuardHook(deps, guardInput(t, "Edit", map[string]string{"file_path": "/etc/hosts"}, folder))
	assert.Equal(t, "Parked for the owner: outside_folder — continue with other work", guardDenial(t, out))
}

func TestWatchmanGuard_OwnerLimitDenied(t *testing.T) {
	_, folder := guardSession(t, true)
	var path string
	d := openAgentsTestMain(t, &path)
	_, err := d.AddWatchmanExtraLimit("command", "terraform apply")
	require.NoError(t, err)
	var store *countingGuardStore
	out, _ := runGuardHook(guardDeps(t, &store), guardInput(t, "Bash", map[string]string{"command": "terraform apply -auto-approve"}, folder))
	assert.Equal(t, "Parked for the owner: owner — continue with other work", guardDenial(t, out))
}

func TestWatchmanGuard_JournalFailureStillDenies(t *testing.T) {
	_, folder := guardSession(t, true)
	var store *countingGuardStore
	deps := guardDeps(t, &store)
	open := deps.open
	deps.open = func() (watchmanGuardStore, error) {
		s, err := open()
		if err == nil {
			s.(*countingGuardStore).parkErr = errors.New("database is locked")
		}
		return s, err
	}
	out, errOut := runGuardHook(deps, guardInput(t, "Bash", map[string]string{"command": "gh release create v1"}, folder))
	assert.Equal(t, "Parked for the owner: release — continue with other work", guardDenial(t, out))
	assert.Contains(t, errOut, "the denial was not journalled")
	assert.Contains(t, store.calls, "park")
	assert.Empty(t, guardItems(t))
}

func TestWatchmanGuard_MCPWriteToolDenied(t *testing.T) {
	_, folder := guardSession(t, true)
	var store *countingGuardStore
	out, _ := runGuardHook(guardDeps(t, &store),
		guardInput(t, "mcp__watchtower-workbench__send_slack_message", map[string]string{"channel": "C1", "text": "hi"}, folder))
	assert.Equal(t, "Parked for the owner: outward — continue with other work", guardDenial(t, out))
	items := guardItems(t)
	require.Len(t, items, 1)
	assert.True(t, strings.HasPrefix(items[0].Question, "outward — mcp__watchtower-workbench__send_slack_message: "), items[0].Question)
}

func TestWatchmanGuard_DBUnreadableUsesSidecar(t *testing.T) {
	id, folder := guardSession(t, false)
	push := guardInput(t, "Bash", map[string]string{"command": "git push origin main"}, folder)
	sidecar := testSidecarPath(t)
	write := func(sessions []db.ArmedSession, targets bool) {
		t.Helper()
		require.NoError(t, watchmanact.WriteSidecar(sidecar, sessions, targets))
	}
	// A locked database: the arm read does not answer within the budget.
	release := make(chan struct{})
	t.Cleanup(func() { close(release) })
	locked := func() watchmanGuardDeps {
		deps := defaultWatchmanGuardDeps()
		deps.open = func() (watchmanGuardStore, error) { return blockedGuardStore{release: release}, nil }
		deps.after = func(time.Duration) <-chan time.Time {
			c := make(chan time.Time, 1)
			c <- time.Time{}
			return c
		}
		deps.branch = func(context.Context, string) string { return "feature/x" }
		return deps
	}
	// No database at all.
	missing := func() watchmanGuardDeps {
		deps := locked()
		deps.open = func() (watchmanGuardStore, error) { return nil, errors.New("unable to open database file") }
		deps.after = time.After
		return deps
	}
	for name, deps := range map[string]func() watchmanGuardDeps{"locked": locked, "missing": missing} {
		t.Run(name, func(t *testing.T) {
			write(nil, false) // nothing armed: allowed
			out, errOut := runGuardHook(deps(), push)
			assert.Empty(t, out)
			assert.Contains(t, errOut, "the arm sidecar decides")

			write([]db.ArmedSession{{SessionID: id, Folder: folder}}, false) // this session armed: denied
			out, _ = runGuardHook(deps(), push)
			assert.Equal(t, "Parked for the owner: main_ref — continue with other work", guardDenial(t, out))
			// Placed by the sidecar's worktree: an edit inside it passes.
			out, _ = runGuardHook(deps(), guardInput(t, "Edit", map[string]string{"file_path": folder + "/a.go"}, folder))
			assert.Empty(t, out)

			write([]db.ArmedSession{{SessionID: id + 100, Folder: "/elsewhere"}}, false) // another session armed: allowed
			out, _ = runGuardHook(deps(), push)
			assert.Empty(t, out)

			write(nil, true) // a target armed: denied
			out, _ = runGuardHook(deps(), push)
			assert.Equal(t, "Parked for the owner: main_ref — continue with other work", guardDenial(t, out))
		})
	}
	assert.Empty(t, guardItems(t)) // nothing journalled without the database
}

// blockedGuardStore is a database whose reads wait until release closes
// (at the test's end), as on a lock nobody lets go of in time.
type blockedGuardStore struct{ release chan struct{} }

func (s blockedGuardStore) WatchmanArmedSession(int64) (db.ArmedSession, bool, error) {
	<-s.release
	return db.ArmedSession{}, false, errors.New("database is locked")
}

func (s blockedGuardStore) SessionWorktrees(context.Context, int64) ([]db.SessionWorktree, error) {
	<-s.release
	return nil, nil
}

func (s blockedGuardStore) WatchmanExtraLimits() ([]db.WatchmanExtraLimit, error) {
	<-s.release
	return nil, nil
}

func (s blockedGuardStore) ParkWatchmanGuard(db.WatchmanItem, time.Time) error {
	<-s.release
	return nil
}

func (blockedGuardStore) Close() error { return nil }

func TestWatchmanGuard_NoTerminalRowAllows(t *testing.T) {
	_, folder := guardSession(t, true)
	t.Setenv(terminalSessionEnv, "")
	var store *countingGuardStore
	out, _ := runGuardHook(guardDeps(t, &store), guardInput(t, "Bash", map[string]string{"command": "git push origin main"}, folder))
	assert.Empty(t, out)
	assert.Nil(t, store) // nothing was even opened
}

// The pre-push hook's bypasses (Task 6 review): a push to main that skips or
// replaces the hook, and the plumbing send-pack, are denied by the guard
// while armed.
func TestWatchmanGuard_HookBypassesToMainDenied(t *testing.T) {
	_, folder := guardSession(t, true)
	var store *countingGuardStore
	deps := guardDeps(t, &store)
	for cmd, limit := range map[string]string{
		"git push --no-verify origin main":                                                              "main_ref",
		"git -c core.hooksPath=/dev/null push origin main":                                              "main_ref",
		"GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/x git push origin main": "main_ref",
		"git send-pack origin HEAD:refs/heads/main":                                                     "send_pack",
		"git send-pack origin feat":                                                                     "send_pack",
	} {
		out, _ := runGuardHook(deps, guardInput(t, "Bash", map[string]string{"command": cmd}, folder))
		assert.Equal(t, "Parked for the owner: "+limit+" — continue with other work", guardDenial(t, out), cmd)
	}
}

func TestWatchmanGuard_EachDenialIsItsOwnItemOnItsNight(t *testing.T) {
	_, folder := guardSession(t, true)
	var store *countingGuardStore
	deps := guardDeps(t, &store)
	night1 := time.Date(2026, 11, 18, 2, 0, 0, 0, time.UTC)
	for _, at := range []time.Time{night1, night1.AddDate(0, 0, 1)} {
		deps.now = func() time.Time { return at }
		out, _ := runGuardHook(deps, guardInput(t, "Bash", map[string]string{"command": "git push origin main"}, folder))
		require.NotEmpty(t, guardDenial(t, out))
	}
	items := guardItems(t)
	require.Len(t, items, 2)
	assert.True(t, items[0].CreatedAt.Equal(night1))
	assert.True(t, items[1].CreatedAt.Equal(night1.AddDate(0, 0, 1)))
	assert.NotEqual(t, items[0].RefID, items[1].RefID)
}

// An input the guard cannot read (here over the 1 MiB limit) still costs
// the one arming read: armed, the call is denied as unreadable; not armed,
// it runs.
func TestWatchmanGuard_UnreadableInputDeniedWhileArmed(t *testing.T) {
	huge := guardInput(t, "Bash", map[string]string{"command": "echo " + strings.Repeat("x", hookStdinLimit+1)}, "")
	t.Run("armed", func(t *testing.T) {
		guardSession(t, true)
		var store *countingGuardStore
		out, _ := runGuardHook(guardDeps(t, &store), huge)
		assert.Equal(t, "Parked for the owner: unreadable — continue with other work", guardDenial(t, out))
		items := guardItems(t)
		require.Len(t, items, 1)
		assert.Equal(t, "unreadable", items[0].ParkReason)
	})
	t.Run("not armed", func(t *testing.T) {
		guardSession(t, false)
		var store *countingGuardStore
		out, _ := runGuardHook(guardDeps(t, &store), huge)
		assert.Empty(t, out)
		assert.Equal(t, []string{"armed"}, store.calls)
	})
}

func TestWatchmanGuard_LimitsReadErrorDenies(t *testing.T) {
	_, folder := guardSession(t, true)
	var store *countingGuardStore
	deps := guardDeps(t, &store)
	open := deps.open
	deps.open = func() (watchmanGuardStore, error) {
		s, err := open()
		if err == nil {
			s.(*countingGuardStore).extraErr = errors.New("database is locked")
		}
		return s, err
	}
	out, errOut := runGuardHook(deps, guardInput(t, "Bash", map[string]string{"command": "go test ./internal/db"}, folder))
	assert.Equal(t, "Parked for the owner: unreadable — continue with other work", guardDenial(t, out))
	assert.Contains(t, errOut, "the owner's limits")
}

// The database locked past the budget: the sidecar's owner limits apply.
func TestWatchmanGuard_DBLockedAppliesSidecarLimits(t *testing.T) {
	id, folder := guardSession(t, false)
	require.NoError(t, watchmanact.WriteSidecar(testSidecarPath(t), []db.ArmedSession{{SessionID: id, Folder: folder}}, false,
		db.WatchmanExtraLimit{Kind: "command", Pattern: "terraform apply"}))
	release := make(chan struct{})
	t.Cleanup(func() { close(release) })
	deps := defaultWatchmanGuardDeps()
	deps.open = func() (watchmanGuardStore, error) { return blockedGuardStore{release: release}, nil }
	deps.after = func(time.Duration) <-chan time.Time {
		c := make(chan time.Time, 1)
		c <- time.Time{}
		return c
	}
	deps.branch = func(context.Context, string) string { return "feature/x" }
	out, _ := runGuardHook(deps, guardInput(t, "Bash", map[string]string{"command": "terraform apply -auto-approve"}, folder))
	assert.Equal(t, "Parked for the owner: owner — continue with other work", guardDenial(t, out))
	out, _ = runGuardHook(deps, guardInput(t, "Bash", map[string]string{"command": "go test ./internal/db"}, folder))
	assert.Empty(t, out)
}

// A relative path is judged where the tool's working directory puts it.
func TestWatchmanGuard_RelativePathsResolvedAgainstCwd(t *testing.T) {
	_, folder := guardSession(t, true)
	var store *countingGuardStore
	deps := guardDeps(t, &store)
	elsewhere := t.TempDir()
	for _, tc := range []struct {
		tool  string
		input map[string]string
		cwd   string
		want  string
	}{
		{"Edit", map[string]string{"file_path": "notes.txt"}, folder, ""},
		{"Edit", map[string]string{"file_path": "notes.txt"}, elsewhere, "outside_folder"},
		{"Read", map[string]string{"file_path": "notes.txt"}, elsewhere, "outside_folder"},
		{"Bash", map[string]string{"command": "rm -rf build"}, folder, ""},
		{"Bash", map[string]string{"command": "rm -rf build"}, elsewhere, "delete_outside"},
		// The start directory is no directory change: a local reset of the
		// working tree from outside the worktrees is not reset_shared.
		{"Bash", map[string]string{"command": "git reset --hard"}, elsewhere, ""},
		{"Bash", map[string]string{"command": "cd /tmp && git reset --hard HEAD~1"}, folder, "reset_shared"},
	} {
		out, _ := runGuardHook(deps, guardInput(t, tc.tool, tc.input, tc.cwd))
		want := ""
		if tc.want != "" {
			want = "Parked for the owner: " + tc.want + " — continue with other work"
		}
		assert.Equal(t, want, guardDenial(t, out), "%s %v in %s", tc.tool, tc.input, tc.cwd)
	}
}

// The guard reads no shared branches (no network in the hook), so it fails
// closed: a reset --hard to an explicit target parks, one with no target
// (the working tree only) passes.
func TestWatchmanGuard_SharedUnknownResetParks(t *testing.T) {
	_, folder := guardSession(t, true)
	var store *countingGuardStore
	deps := guardDeps(t, &store)
	for _, tc := range []struct{ command, want string }{
		{"git reset --hard HEAD~3", "Parked for the owner: reset_shared — continue with other work"},
		{"git branch -f feat HEAD~2", "Parked for the owner: reset_shared — continue with other work"},
		{"git reset --hard", ""},
		{"git reset --hard HEAD", ""},
	} {
		out, _ := runGuardHook(deps, guardInput(t, "Bash", map[string]string{"command": tc.command}, folder))
		assert.Equal(t, tc.want, guardDenial(t, out), tc.command)
	}
}

// The guard runs on every tool call of an armed session: ordinary shell
// shapes the table cannot see into are allowed; one that names a
// hard-limit action is still denied (round 5).
func TestWatchmanGuard_HiddenShapesNeedALimitWord(t *testing.T) {
	_, folder := guardSession(t, true)
	var store *countingGuardStore
	deps := guardDeps(t, &store)
	for _, tc := range []struct{ command, want string }{
		{"git commit -m \"$(cat <<'EOF'\nFix the export\nEOF\n)\"", ""},
		{`gh pr create --title "Fix" --body "$(cat body.md)"`, ""},
		{"for f in *.go; do gofmt -l $f; done", ""},
		{"make build &", ""},
		{"echo $(date)", ""},
		{"(cd sub && make)", ""},
		{`curl 'https://example.com/?a=1&b=2'`, ""},
		{"gh pr view 1 # merge", ""},
		// The commit/PR-body heredoc idiom, limit words in its body (round 6).
		{"git commit -m \"$(cat <<'EOF'\nrelease notes before merge\nEOF\n)\"", ""},
		{"gh pr create --title \"Fix\" --body \"$(cat <<'EOF'\nreview the push and the tag\nEOF\n)\"", ""},
		{"sh -c \"$(cat <<'EOF'\ngit push origin main\nEOF\n)\"", "Parked for the owner: unreadable — continue with other work"},
		{"git commit -m \"$(cat <<EOF\n$(git push)\nEOF\n)\"", "Parked for the owner: unreadable — continue with other work"},
		{"echo 'git push' | sh", "Parked for the owner: unreadable — continue with other work"},
		{"$G push origin feat", "Parked for the owner: unreadable — continue with other work"},
		// The merge backstop reads the blanked body too (round 6 ruling).
		{"gh pr create --title \"Fix\" --body \"$(cat <<'EOF'\nmerge it into feature/x after the review\nEOF\n)\"", ""},
		{"gh pr merge 1", "Parked for the owner: main_ref — continue with other work"},
		{"sh -c \"$(cat <<'EOF'\ngh pr merge 1\nEOF\n)\"", "Parked for the owner: unreadable — continue with other work"},
		// A sibling part could run a blanked body (round 7).
		{"echo \"$(cat <<'EOF'\ngit push origin main\nEOF\n)\" | sh", "Parked for the owner: unreadable — continue with other work"},
		{"printf '%s\\n' \"$(cat <<'EOF'\ngit push origin main\nEOF\n)\" | bash", "Parked for the owner: unreadable — continue with other work"},
		{"cat() { sh; }; git commit -m \"$(cat <<'EOF'\ngit push origin main\nEOF\n)\"", "Parked for the owner: unreadable — continue with other work"},
		{"x $(git push origin HEAD:main)", "Parked for the owner: unreadable — continue with other work"},
		{"true & gh pr merge 1", "Parked for the owner: unreadable — continue with other work"},
		{`echo "open`, "Parked for the owner: unreadable — continue with other work"},
	} {
		out, _ := runGuardHook(deps, guardInput(t, "Bash", map[string]string{"command": tc.command}, folder))
		assert.Equal(t, tc.want, guardDenial(t, out), tc.command)
	}
}

func TestWatchmanGuard_PanicDeniesOnlyWhenArmed(t *testing.T) {
	call := func(folder string) string {
		return guardInput(t, "Bash", map[string]string{"command": "go test ./..."}, folder)
	}
	t.Run("armed", func(t *testing.T) {
		_, folder := guardSession(t, true)
		var store *countingGuardStore
		deps := guardDeps(t, &store)
		deps.branch = func(context.Context, string) string { panic("boom") }
		out, _ := runGuardHook(deps, call(folder))
		assert.Equal(t, "Parked for the owner: unreadable — continue with other work", guardDenial(t, out))
	})
	t.Run("arming unknown", func(t *testing.T) {
		_, folder := guardSession(t, true)
		deps := defaultWatchmanGuardDeps()
		deps.open = func() (watchmanGuardStore, error) { return nil, errors.New("unable to open database file") }
		deps.sidecar = func() (watchmanact.Sidecar, error) { panic("boom") }
		out, _ := runGuardHook(deps, call(folder))
		assert.Empty(t, out)
	})
}

func TestWatchmanGuard_UnreadableSidecarDenies(t *testing.T) {
	_, folder := guardSession(t, false)
	require.NoError(t, os.MkdirAll(testSidecarPath(t), 0o755)) // there, but not a readable file
	deps := defaultWatchmanGuardDeps()
	deps.open = func() (watchmanGuardStore, error) { return nil, errors.New("unable to open database file") }
	out, _ := runGuardHook(deps, guardInput(t, "Bash", map[string]string{"command": "go test ./..."}, folder))
	assert.Equal(t, "Parked for the owner: unreadable — continue with other work", guardDenial(t, out))
}

// A sidecar whose owner's limits are not all in it (limits-unavailable):
// an armed session's calls are denied as unreadable; an unarmed one runs.
func TestWatchmanGuard_SidecarLimitsUnavailableDenies(t *testing.T) {
	id, folder := guardSession(t, false)
	deps := defaultWatchmanGuardDeps()
	deps.open = func() (watchmanGuardStore, error) { return nil, errors.New("unable to open database file") }
	call := guardInput(t, "Bash", map[string]string{"command": "go test ./..."}, folder)
	bad := []db.WatchmanExtraLimit{{Kind: "command", Pattern: "make\ndeploy"}}
	require.NoError(t, watchmanact.WriteSidecar(testSidecarPath(t), []db.ArmedSession{{SessionID: id, Folder: folder}}, false, bad...))
	out, _ := runGuardHook(deps, call)
	assert.Equal(t, "Parked for the owner: unreadable — continue with other work", guardDenial(t, out))
	require.NoError(t, watchmanact.WriteSidecar(testSidecarPath(t), nil, false, bad...))
	out, _ = runGuardHook(deps, call)
	assert.Empty(t, out)
}
