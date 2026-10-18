package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// setupCompactTestEnv is setupWatchTestEnv (a migrated database, so due
// after migration 134) with plenty of free disk, and the loaded config.
func setupCompactTestEnv(t *testing.T) *config.Config {
	t.Helper()
	t.Cleanup(setupWatchTestEnv(t))
	t.Cleanup(db.SetFreeDiskBytesForTest(func(string) (int64, error) { return 1 << 50, nil }))
	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	return cfg
}

func stubDaemonRunningForCompact(t *testing.T, running bool) {
	t.Helper()
	prev := daemonRunningForCompact
	daemonRunningForCompact = func(*config.Config) bool { return running }
	t.Cleanup(func() { daemonRunningForCompact = prev })
}

// execDBCompact runs `db compact args…` through rootCmd and returns stdout,
// its last non-empty line (what the Desktop decodes) and the exit code
// Execute would return.
func execDBCompact(t *testing.T, args ...string) (stdout, lastLine string, code int) {
	t.Helper()
	stdout, _, err := runRootCmd(t, []*cobra.Command{dbCompactCmd, dbCmd}, append([]string{"db", "compact"}, args...)...)
	if err != nil {
		code = 1
		var ec *exitCodeError
		if errors.As(err, &ec) {
			code = ec.code
		}
	}
	lines := strings.Split(strings.TrimSpace(stdout), "\n")
	return stdout, lines[len(lines)-1], code
}

func decodeCompactResult(t *testing.T, line string) db.CompactResult {
	t.Helper()
	var res db.CompactResult
	require.NoError(t, json.Unmarshal([]byte(line), &res), "stdout line %q", line)
	return res
}

// compactTableRows reads every row of table as "col|col…" lines, without
// migrating.
func compactTableRows(t *testing.T, path, table string) []string {
	t.Helper()
	d, err := db.OpenExisting(path, 5*time.Second)
	require.NoError(t, err)
	defer d.Close()
	rows, err := d.Query(`SELECT * FROM ` + table)
	require.NoError(t, err)
	defer rows.Close()
	cols, err := rows.Columns()
	require.NoError(t, err)
	var out []string
	for rows.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		require.NoError(t, rows.Scan(ptrs...))
		var parts []string
		for _, v := range vals {
			b, err := json.Marshal(v)
			require.NoError(t, err)
			parts = append(parts, string(b))
		}
		out = append(out, strings.Join(parts, "|"))
	}
	require.NoError(t, rows.Err())
	return out
}

func TestDBCompact_CheckJSON(t *testing.T) {
	cfg := setupCompactTestEnv(t)
	gooseBefore := compactTableRows(t, cfg.DBPath(), "goose_db_version")
	maintBefore := compactTableRows(t, cfg.DBPath(), "db_maintenance")

	_, line, code := execDBCompact(t, "--check", "--json")
	require.Equal(t, 0, code)
	var c db.CompactCheck
	require.NoError(t, json.Unmarshal([]byte(line), &c), "stdout line %q", line)
	assert.True(t, c.Due)
	assert.Equal(t, "migration:134", c.Reason)
	assert.Positive(t, c.DBBytes)
	assert.True(t, c.DiskOK)

	assert.Equal(t, gooseBefore, compactTableRows(t, cfg.DBPath(), "goose_db_version"), "--check migrated")
	assert.Equal(t, maintBefore, compactTableRows(t, cfg.DBPath(), "db_maintenance"), "--check wrote db_maintenance")
}

func TestDBCompact_IfDueCompactsThenNotDue(t *testing.T) {
	setupCompactTestEnv(t)

	_, line, code := execDBCompact(t, "--if-due", "--json")
	require.Equal(t, 0, code, line)
	res := decodeCompactResult(t, line)
	assert.True(t, res.Compacted)
	assert.Equal(t, "migration:134", res.Reason)
	assert.Positive(t, res.BytesBefore)
	assert.Positive(t, res.BytesAfter)

	_, line, code = execDBCompact(t, "--if-due", "--json")
	assert.Equal(t, 0, code)
	assert.JSONEq(t, `{"compacted":false,"skipped":"not_due"}`, line)
}

func TestDBCompact_HumanOutput(t *testing.T) {
	setupCompactTestEnv(t)

	stdout, _, code := execDBCompact(t, "--if-due")
	require.Equal(t, 0, code)
	assert.Regexp(t, `^Compacted watchtower\.db: \S+ \S+ → \S+ \S+ in \S+\n$`, stdout)

	stdout, _, code = execDBCompact(t, "--if-due")
	require.Equal(t, 0, code)
	assert.Equal(t, "watchtower.db does not need compacting.\n", stdout)
}

func TestDBCompact_DaemonRunningRefuses(t *testing.T) {
	cfg := setupCompactTestEnv(t)
	stubDaemonRunningForCompact(t, true)

	_, line, code := execDBCompact(t, "--json")
	assert.Equal(t, 3, code)
	assert.Equal(t, "daemon_running", decodeCompactResult(t, line).Skipped)
	assert.Empty(t, compactTableRows(t, cfg.DBPath(), "db_maintenance"))

	_, line, code = execDBCompact(t, "--json", "--force")
	assert.Equal(t, 0, code, line)
	assert.True(t, decodeCompactResult(t, line).Compacted)
}

// A daemon.pid left behind by a process that is gone does not read as a
// running daemon (Review Focus 3).
func TestDBCompact_StalePIDFileDoesNotRefuse(t *testing.T) {
	cfg := setupCompactTestEnv(t)
	child := exec.Command("true")
	require.NoError(t, child.Run()) // Run waits: the child is reaped
	require.NoError(t, os.WriteFile(pidFilePath(cfg), []byte(strconv.Itoa(child.Process.Pid)+"\n"), 0o600))

	_, line, code := execDBCompact(t, "--json")
	assert.Equal(t, 0, code, line)
	assert.True(t, decodeCompactResult(t, line).Compacted)
}

// An unreadable pid file names no process: the compaction proceeds (only a
// confirmed or identity-unconfirmed live pid refuses).
func TestDBCompact_MalformedPIDFileDoesNotRefuse(t *testing.T) {
	cfg := setupCompactTestEnv(t)
	require.NoError(t, os.WriteFile(pidFilePath(cfg), []byte("not a pid\n"), 0o600))

	_, line, code := execDBCompact(t, "--json")
	assert.Equal(t, 0, code, line)
	assert.True(t, decodeCompactResult(t, line).Compacted)
}

// A shutdown signal that lands during the --if-due check ends as
// interrupted (exit 4), not as not_due: the shutdown context covers the
// check too. The database is compacted first so the check alone would say
// not due.
func TestDBCompact_InterruptDuringIfDueCheck(t *testing.T) {
	cfg := setupCompactTestEnv(t)
	stubDaemonRunningForCompact(t, false)
	_, line, code := execDBCompact(t, "--if-due", "--json")
	require.Equal(t, 0, code, line)
	require.True(t, decodeCompactResult(t, line).Compacted)
	maintBefore := compactTableRows(t, cfg.DBPath(), "db_maintenance")
	prev := dbCompactFlagIfDue
	dbCompactFlagIfDue = true
	t.Cleanup(func() { dbCompactFlagIfDue = prev })
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	cmd := &cobra.Command{}
	cmd.SetContext(ctx)

	res, err := compactDatabase(cmd, cfg, cfg.DBPath())
	require.NoError(t, err)
	assert.Equal(t, "interrupted", res.Skipped)
	assert.Equal(t, 4, compactExitCode(res, err))
	assert.Equal(t, maintBefore, compactTableRows(t, cfg.DBPath(), "db_maintenance"))
}

func TestDBCompact_DiskShortExit2(t *testing.T) {
	cfg := setupCompactTestEnv(t)
	t.Cleanup(db.SetFreeDiskBytesForTest(func(string) (int64, error) { return 1, nil }))

	_, line, code := execDBCompact(t, "--json")
	assert.Equal(t, 2, code)
	assert.Equal(t, "disk", decodeCompactResult(t, line).Skipped)
	assert.Empty(t, compactTableRows(t, cfg.DBPath(), "db_maintenance"))

	_, line, code = execDBCompact(t, "--if-due", "--json")
	assert.Equal(t, 2, code)
	assert.Equal(t, "disk", decodeCompactResult(t, line).Skipped)
}

func TestDBCompact_SchemaPendingExit5(t *testing.T) {
	cfg := setupCompactTestEnv(t)
	d, err := db.OpenExistingRW(cfg.DBPath(), 5*time.Second)
	require.NoError(t, err)
	_, err = d.Exec(`DELETE FROM goose_db_version WHERE version_id = (SELECT MAX(version_id) FROM goose_db_version)`)
	require.NoError(t, err)
	require.NoError(t, d.Close())
	gooseBefore := compactTableRows(t, cfg.DBPath(), "goose_db_version")

	_, line, code := execDBCompact(t, "--json")
	assert.Equal(t, 5, code)
	assert.Equal(t, "schema_pending", decodeCompactResult(t, line).Skipped)
	assert.Equal(t, gooseBefore, compactTableRows(t, cfg.DBPath(), "goose_db_version"), "db compact migrated")

	// With --if-due the check already said no: not due, exit 0.
	_, line, code = execDBCompact(t, "--if-due", "--json")
	assert.Equal(t, 0, code)
	assert.JSONEq(t, `{"compacted":false,"skipped":"not_due"}`, line)
}

// A Go error from Compact still prints a JSON line, with error filled.
func TestDBCompact_ErrorPrintsJSON(t *testing.T) {
	cfg := setupCompactTestEnv(t)
	require.NoError(t, os.Remove(cfg.DBPath()))

	_, line, code := execDBCompact(t, "--json", "--force")
	assert.Equal(t, 1, code)
	res := decodeCompactResult(t, line)
	assert.False(t, res.Compacted)
	assert.NotEmpty(t, res.Error)
	_, err := os.Stat(cfg.DBPath())
	assert.ErrorIs(t, err, os.ErrNotExist, "db compact created the database")
}

func TestDBCompact_ExitCodeTable(t *testing.T) {
	cases := []struct {
		name string
		res  db.CompactResult
		err  error
		want int
	}{
		{"compacted", db.CompactResult{Compacted: true}, nil, 0},
		{"not_due", db.CompactResult{Skipped: "not_due"}, nil, 0},
		{"disk", db.CompactResult{Skipped: "disk"}, nil, 2},
		{"daemon_running", db.CompactResult{Skipped: "daemon_running"}, nil, 3},
		{"interrupted", db.CompactResult{Skipped: "interrupted"}, nil, 4},
		{"schema_pending", db.CompactResult{Skipped: "schema_pending"}, nil, 5},
		{"error", db.CompactResult{}, errors.New("x"), 1},
		{"compacted but recording failed", db.CompactResult{Compacted: true}, errors.New("x"), 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			assert.Equal(t, tc.want, compactExitCode(tc.res, tc.err))
		})
	}
}

// Flag misuse is exit 1, never the usageError exit 2 (that is disk).
func TestDBCompact_FlagConflictIsExit1(t *testing.T) {
	cfg := setupCompactTestEnv(t)
	for _, args := range [][]string{{"--check", "--force"}, {"--check", "--if-due"}} {
		_, _, code := execDBCompact(t, args...)
		assert.Equal(t, 1, code, "%v", args)
	}
	assert.Empty(t, compactTableRows(t, cfg.DBPath(), "db_maintenance"))
}

// With --json every error before the compaction — flag misuse, an invalid
// workspace, a config that does not load — still prints one JSON line with
// error filled (the Desktop decodes the last stdout line).
func TestDBCompact_SetupErrorsPrintJSON(t *testing.T) {
	setupCompactTestEnv(t)
	for _, args := range [][]string{{"--check", "--force", "--json"}, {"--if-due", "--json", "--workspace", "bad/ws"}} {
		stdout, line, code := execDBCompact(t, args...)
		assert.Equal(t, 1, code, "%v", args)
		assert.Equal(t, 1, strings.Count(stdout, "\n"), "%v: %q", args, stdout)
		res := decodeCompactResult(t, line)
		assert.False(t, res.Compacted)
		assert.NotEmpty(t, res.Error, "%v", args)
	}

	// A config that does not load: db compact skips the root pre-run, so
	// runDBCompact's own load reports it.
	prev := flagConfig
	flagConfig = filepath.Join(t.TempDir(), "config.yaml")
	t.Cleanup(func() { flagConfig = prev })
	require.NoError(t, os.WriteFile(flagConfig, []byte("workspaces: [not, a, map\n"), 0o600))
	_, line, code := execDBCompact(t, "--check", "--json")
	assert.Equal(t, 1, code)
	assert.Contains(t, decodeCompactResult(t, line).Error, "loading config")
}

// db compact skips the root's ensureSchemaFormat: with a stale
// schema_format, --check leaves the config file and goose_db_version as
// they were.
func TestDBCompact_SkipsRootSchemaFormatPreRun(t *testing.T) {
	cfg := setupCompactTestEnv(t)
	configBytes, err := os.ReadFile(flagConfig)
	require.NoError(t, err)
	configBytes = append(configBytes, []byte("db:\n  schema_format: 1\n")...)
	require.NoError(t, os.WriteFile(flagConfig, configBytes, 0o600))
	gooseBefore := compactTableRows(t, cfg.DBPath(), "goose_db_version")

	_, line, code := execDBCompact(t, "--check", "--json")
	require.Equal(t, 0, code, line)

	after, err := os.ReadFile(flagConfig)
	require.NoError(t, err)
	assert.Equal(t, string(configBytes), string(after), "db compact --check rewrote the config")
	assert.Equal(t, gooseBefore, compactTableRows(t, cfg.DBPath(), "goose_db_version"))
}

// The Desktop decodes these lines by key: pin the exact key sets.
func TestDBCompact_WireKeys(t *testing.T) {
	setupCompactTestEnv(t)
	_, line, code := execDBCompact(t, "--check", "--json")
	require.Equal(t, 0, code, line)
	assert.Equal(t, []string{"db_bytes", "disk_ok", "due", "free_disk_bytes", "needs_disk_bytes", "reason", "wal_bytes"}, jsonKeys(t, line))

	prevJSON := dbCompactFlagJSON
	dbCompactFlagJSON = true
	t.Cleanup(func() { dbCompactFlagJSON = prevJSON })
	var out bytes.Buffer
	failed := db.CompactResult{Reason: "migration:134", BytesBefore: 4096, Error: "vacuum: disk I/O error", Failures: 3, GaveUp: true}
	err := reportCompact(&out, "watchtower.db", failed, errors.New(failed.Error))
	require.Error(t, err)
	assert.Equal(t, []string{"bytes_before", "compacted", "error", "failures", "gave_up", "reason"}, jsonKeys(t, strings.TrimSpace(out.String())))

	out.Reset()
	full := db.CompactResult{Compacted: true, Skipped: "x", Reason: "r", BytesBefore: 1, BytesAfter: 1, DurationMS: 1, Error: "e", Failures: 1, GaveUp: true, CheckpointBusy: true}
	_ = reportCompact(&out, "watchtower.db", full, nil)
	assert.Equal(t, []string{"bytes_after", "bytes_before", "checkpoint_busy", "compacted", "duration_ms", "error", "failures", "gave_up", "reason", "skipped"}, jsonKeys(t, strings.TrimSpace(out.String())))
}

func TestDBCompact_NoDatabase(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	configPath := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(configPath, []byte("active_workspace: test-ws\nworkspaces:\n  test-ws:\n    slack_token: \"xoxp-test-token\"\n"), 0o600))
	prev := flagConfig
	flagConfig = configPath
	t.Cleanup(func() { flagConfig = prev })
	cfg, err := config.Load(configPath)
	require.NoError(t, err)

	_, line, code := execDBCompact(t, "--check", "--json")
	require.Equal(t, 0, code)
	var c db.CompactCheck
	require.NoError(t, json.Unmarshal([]byte(line), &c), "stdout line %q", line)
	assert.False(t, c.Due)
	_, err = os.Stat(cfg.DBPath())
	assert.ErrorIs(t, err, os.ErrNotExist, "--check created the database")
}
