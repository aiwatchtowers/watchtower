package cmd

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/spf13/pflag"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// newResolveEnv is a workspace with an empty inbox, run outside any agent
// (the suite itself may run under one).
func newResolveEnv(t *testing.T) *db.DB {
	t.Helper()
	for _, name := range agentEnvMarkers {
		t.Setenv(name, "")
		require.NoError(t, os.Unsetenv(name))
	}
	t.Cleanup(setupInboxTestEnv(t))
	database, err := openDBFromConfig()
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	return database
}

// seedResolveItem inserts an inbox item at createdAt and returns its id.
func seedResolveItem(t *testing.T, d *db.DB, trigger, sender, status string, createdAt time.Time) int64 {
	t.Helper()
	inboxTestSeq++
	res, err := d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, status, created_at)
		VALUES ('C001', ?, ?, ?, ?, ?)`, fmt.Sprintf("1712000%03d.000100", inboxTestSeq), sender, trigger, status,
		createdAt.UTC().Format(time.RFC3339))
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

// runInboxResolveCLI runs `inbox resolve args…` and returns stdout.
func runInboxResolveCLI(t *testing.T, args ...string) (string, error) {
	t.Helper()
	var out, errOut bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&errOut)
	rootCmd.SetArgs(append([]string{"inbox", "resolve"}, args...))
	err := rootCmd.Execute()
	rootCmd.SetArgs(nil)
	// Only the command's own flags: the inherited --config must keep the
	// test's value.
	inboxResolveCmd.LocalNonPersistentFlags().VisitAll(func(f *pflag.Flag) {
		_ = f.Value.Set(f.DefValue)
		f.Changed = false
	})
	return out.String(), err
}

// lastJSONLine decodes the last stdout line.
func lastJSONLine(t *testing.T, out string) map[string]any {
	t.Helper()
	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	var got map[string]any
	require.NoError(t, json.Unmarshal([]byte(lines[len(lines)-1]), &got), "stdout %q", out)
	return got
}

func idStrings(ids ...int64) []any {
	out := make([]any, len(ids))
	for i, id := range ids {
		out[i] = fmt.Sprint(id)
	}
	return out
}

func statusOf(t *testing.T, d *db.DB, id int64) (status, reason string) {
	t.Helper()
	require.NoError(t, d.QueryRow(`SELECT status, resolved_reason FROM inbox_items WHERE id = ?`, id).Scan(&status, &reason))
	return status, reason
}

func TestInboxResolve_DryRunSenderJSON(t *testing.T) {
	d := newResolveEnv(t)
	now := time.Now()
	a1 := seedResolveItem(t, d, "email_received", "Colleague-A@Example.com", "pending", now.Add(-time.Hour))
	a2 := seedResolveItem(t, d, "email_received", " colleague-a@example.com", "pending", now.Add(-2*time.Hour))
	seedResolveItem(t, d, "email_received", "colleague-b@example.com", "pending", now.Add(-time.Hour))
	seedResolveItem(t, d, "email_received", "colleague-a@example.com", "resolved", now.Add(-time.Hour))

	out, err := runInboxResolveCLI(t, "--dry-run", "--sender", "COLLEAGUE-A@example.com", "--trigger", "email_received", "--json")
	require.NoError(t, err)
	got := lastJSONLine(t, out)
	assert.Equal(t, map[string]any{"count": float64(2), "ids": idStrings(a1, a2)}, got)
	status, _ := statusOf(t, d, a1)
	assert.Equal(t, "pending", status, "a dry run writes nothing")

	out, err = runInboxResolveCLI(t, "--dry-run", "--sender", "colleague-a@example.com", "--trigger", "email_received")
	require.NoError(t, err)
	assert.Equal(t, "2 items match\n", out)
}

func TestInboxResolve_DryRunOlderPeopleJSON(t *testing.T) {
	d := newResolveEnv(t)
	now := time.Now()
	old1 := seedResolveItem(t, d, "mention", "U002", "pending", now.Add(-8*24*time.Hour))
	old2 := seedResolveItem(t, d, "dm", "U002", "pending", now.Add(-30*24*time.Hour))
	seedResolveItem(t, d, "mention", "U002", "pending", now.Add(-6*24*time.Hour))
	seedResolveItem(t, d, "email_received", "colleague-a@example.com", "pending", now.Add(-30*24*time.Hour))

	out, err := runInboxResolveCLI(t, "--dry-run", "--older-than", "7d", "--people", "--json")
	require.NoError(t, err)
	assert.Equal(t, map[string]any{"count": float64(2), "ids": idStrings(old1, old2)}, lastJSONLine(t, out))
}

func TestInboxResolve_IdsJSON(t *testing.T) {
	d := newResolveEnv(t)
	now := time.Now()
	open1 := seedResolveItem(t, d, "mention", "U002", "pending", now)
	open2 := seedResolveItem(t, d, "email_received", "colleague-a@example.com", "pending", now)
	closed := seedResolveItem(t, d, "dm", "U002", "dismissed", now)

	ids := fmt.Sprintf("%d,%d,%d,%d,999", open2, closed, open1, open2)
	out, err := runInboxResolveCLI(t, "--ids", ids, "--json")
	require.NoError(t, err)
	assert.Equal(t, map[string]any{"resolved": float64(2), "skipped": float64(2), "ids": idStrings(open2, open1)},
		lastJSONLine(t, out))
	for _, id := range []int64{open1, open2} {
		status, reason := statusOf(t, d, id)
		assert.Equal(t, "resolved", status)
		assert.Equal(t, "Marked done in bulk", reason)
	}
	status, _ := statusOf(t, d, closed)
	assert.Equal(t, "dismissed", status)

	open3 := seedResolveItem(t, d, "mention", "U002", "pending", now)
	out, err = runInboxResolveCLI(t, "--ids", fmt.Sprintf("%d,%d", open3, closed))
	require.NoError(t, err)
	assert.Equal(t, "Resolved 1, skipped 1\n", out)
}

func TestInboxResolve_PartialFailureJSON(t *testing.T) {
	d := newResolveEnv(t)
	now := time.Now()
	ids := make([]string, 0, 250)
	var last int64
	for range 250 {
		last = seedResolveItem(t, d, "mention", "U002", "pending", now)
		ids = append(ids, fmt.Sprint(last))
	}
	_, err := d.Exec(fmt.Sprintf(`CREATE TRIGGER fail_second_chunk BEFORE UPDATE OF status ON inbox_items
		WHEN OLD.id = %d BEGIN SELECT RAISE(ABORT, 'chunk refused'); END`, last))
	require.NoError(t, err)

	out, err := runInboxResolveCLI(t, "--ids", strings.Join(ids, ","), "--json")
	require.Error(t, err)
	got := lastJSONLine(t, out)
	assert.ElementsMatch(t, []string{"resolved", "of", "error"}, keysOf(got))
	assert.Equal(t, float64(200), got["resolved"])
	assert.Equal(t, float64(250), got["of"])
	assert.Contains(t, got["error"], "chunk refused")
	status, _ := statusOf(t, d, last)
	assert.Equal(t, "pending", status)
}

// Without --json a partial failure names how many it closed.
func TestInboxResolve_PartialFailureText(t *testing.T) {
	d := newResolveEnv(t)
	now := time.Now()
	ids := make([]string, 0, 201)
	var last int64
	for range 201 {
		last = seedResolveItem(t, d, "mention", "U002", "pending", now)
		ids = append(ids, fmt.Sprint(last))
	}
	_, err := d.Exec(fmt.Sprintf(`CREATE TRIGGER fail_second_chunk BEFORE UPDATE OF status ON inbox_items
		WHEN OLD.id = %d BEGIN SELECT RAISE(ABORT, 'chunk refused'); END`, last))
	require.NoError(t, err)

	out, err := runInboxResolveCLI(t, "--ids", strings.Join(ids, ","))
	require.Error(t, err)
	assert.Empty(t, out)
	assert.Contains(t, err.Error(), "closed 200 of 201: ")
	assert.Contains(t, err.Error(), "chunk refused")
}

// An item archived between the dry run and the press is skipped.
func TestInboxResolve_IdsSkipArchived(t *testing.T) {
	d := newResolveEnv(t)
	id := seedResolveItem(t, d, "mention", "U002", "pending", time.Now().Add(-20*24*time.Hour))
	_, err := d.Exec(`UPDATE inbox_items SET archived_at = ?, archive_reason = 'stale' WHERE id = ?`,
		time.Now().UTC().Format(time.RFC3339), id)
	require.NoError(t, err)
	out, err := runInboxResolveCLI(t, "--ids", fmt.Sprint(id), "--json")
	require.NoError(t, err)
	assert.Equal(t, map[string]any{"resolved": float64(0), "skipped": float64(1), "ids": []any{}}, lastJSONLine(t, out))
	status, _ := statusOf(t, d, id)
	assert.Equal(t, "pending", status)
}

// AGENT-07: every bulk form is the owner's; an agent is refused before
// anything is read or written.
func TestInboxResolve_RefusedUnderAgent(t *testing.T) {
	forms := [][]string{
		{"--dry-run", "--sender", "colleague-a@example.com", "--trigger", "email_received", "--json"},
		{"--dry-run", "--older-than", "7d", "--people", "--json"},
		{"--ids", "1", "--json"},
	}
	for _, marker := range agentEnvMarkers {
		for _, form := range forms {
			t.Run(marker+" "+form[0]+" "+form[1], func(t *testing.T) {
				d := newResolveEnv(t)
				id := seedResolveItem(t, d, "mention", "U002", "pending", time.Now().Add(-30*24*time.Hour))
				require.Equal(t, int64(1), id)
				t.Setenv(marker, "1")

				out, err := runInboxResolveCLI(t, form...)
				require.Error(t, err)
				assert.Contains(t, err.Error(), "refusing to resolve inbox items in bulk under an AI agent")
				got := lastJSONLine(t, out)
				assert.Equal(t, float64(0), got["resolved"])
				assert.Equal(t, float64(0), got["of"])
				assert.Contains(t, got["error"], marker)
				assert.NotContains(t, got, "count", "nothing read")
				status, _ := statusOf(t, d, id)
				assert.Equal(t, "pending", status, "nothing written")
			})
		}
	}
}

func TestInboxResolve_FlagRules(t *testing.T) {
	cases := map[string][]string{
		"empty sender":       {"--dry-run", "--sender", "", "--trigger", "email_received", "--json"},
		"blank sender":       {"--dry-run", "--sender", "  ", "--trigger", "email_received", "--json"},
		"other trigger":      {"--dry-run", "--sender", "a@example.com", "--trigger", "mention", "--json"},
		"sender no trigger":  {"--dry-run", "--sender", "a@example.com", "--json"},
		"trigger no sender":  {"--dry-run", "--trigger", "email_received", "--json"},
		"older 0d":           {"--dry-run", "--older-than", "0d", "--people", "--json"},
		"older hours":        {"--dry-run", "--older-than", "7h", "--people", "--json"},
		"older 400d":         {"--dry-run", "--older-than", "400d", "--people", "--json"},
		"people alone":       {"--dry-run", "--people", "--json"},
		"older no people":    {"--dry-run", "--older-than", "7d", "--json"},
		"both filters":       {"--dry-run", "--sender", "a@example.com", "--trigger", "email_received", "--older-than", "7d", "--people", "--json"},
		"id with flags":      {"1", "--json"},
		"id with ids":        {"1", "--ids", "1", "--json"},
		"dry run with ids":   {"--dry-run", "--ids", "1", "--json"},
		"filter without dry": {"--older-than", "7d", "--people", "--json"},
		"ids with filter":    {"--ids", "1", "--people", "--json"},
		"zero id":            {"--ids", "0", "--json"},
		"negative id":        {"--ids", "-3", "--json"},
		"not a number":       {"--ids", "1,x", "--json"},
		"empty entry":        {"--ids", "1,,2", "--json"},
		"empty ids":          {"--ids", "", "--json"},
		"nothing":            {"--json"},
	}
	over := make([]string, 10001)
	for i := range over {
		over[i] = fmt.Sprint(i + 1)
	}
	cases["over 10 000 ids"] = []string{"--ids", strings.Join(over, ","), "--json"}

	for name, args := range cases {
		t.Run(name, func(t *testing.T) {
			d := newResolveEnv(t)
			id := seedResolveItem(t, d, "mention", "U002", "pending", time.Now().Add(-30*24*time.Hour))
			out, err := runInboxResolveCLI(t, args...)
			require.Error(t, err)
			got := lastJSONLine(t, out)
			assert.Equal(t, map[string]any{"resolved": float64(0), "of": float64(0), "error": err.Error()}, got)
			status, _ := statusOf(t, d, id)
			assert.Equal(t, "pending", status)
		})
	}
}

// The single-id form keeps its reason and output, and stays open to an
// agent.
func TestInboxResolve_SingleIDUnchanged(t *testing.T) {
	d := newResolveEnv(t)
	id := seedResolveItem(t, d, "mention", "U002", "pending", time.Now())
	t.Setenv("CLAUDECODE", "1")
	out, err := runInboxResolveCLI(t, fmt.Sprint(id))
	require.NoError(t, err)
	assert.Equal(t, fmt.Sprintf("Inbox item #%d resolved\n", id), out)
	status, reason := statusOf(t, d, id)
	assert.Equal(t, "resolved", status)
	assert.Equal(t, "Manually resolved", reason)

	_, err = runInboxResolveCLI(t)
	require.Error(t, err, "no id and no flags")
}
