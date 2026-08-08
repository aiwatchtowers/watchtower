package cmd

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/ideas"
)

// fakeCmdGen is a stub digest.Generator for exercising runIdeasBackfill
// directly, bypassing cliGenerator's real claude/codex subprocess (the
// internal/ideas fakeGen precedent, duplicated here since it's package-private
// there).
type fakeCmdGen struct {
	reply func(user string) (string, error)
}

func (g *fakeCmdGen) Generate(_ context.Context, _, user, _ string) (string, *digest.Usage, string, error) {
	out, err := g.reply(user)
	if err != nil {
		return "", nil, "", err
	}
	return out, &digest.Usage{InputTokens: 10, OutputTokens: 5, TotalAPITokens: 15}, "sess", nil
}

// setupIdeasTestEnv creates a temp HOME with a config file and an empty
// workspace DB, points flagConfig at it, and returns the opened DB (the
// setupMemoryTestEnv precedent). Caller must Close() the returned DB.
func setupIdeasTestEnv(t *testing.T) *db.DB {
	t.Helper()
	tmpDir := t.TempDir()

	configPath := filepath.Join(tmpDir, "config.yaml")
	configYAML := `active_workspace: test-ws
workspaces:
  test-ws:
    slack_token: "xoxp-test-token"
`
	require.NoError(t, os.WriteFile(configPath, []byte(configYAML), 0o600))

	wsDir := filepath.Join(tmpDir, ".local", "share", "watchtower", "test-ws")
	require.NoError(t, os.MkdirAll(wsDir, 0o755))

	database, err := db.Open(filepath.Join(wsDir, "watchtower.db"))
	require.NoError(t, err)

	t.Setenv("HOME", tmpDir)
	oldFlagConfig := flagConfig
	flagConfig = configPath
	t.Cleanup(func() { flagConfig = oldFlagConfig })

	return database
}

func seedIdeaRowCmd(t *testing.T, database *db.DB, idea db.Idea) int64 {
	t.Helper()
	tx, err := database.Begin()
	require.NoError(t, err)
	id, err := database.CreateIdeaTx(tx, idea)
	require.NoError(t, err)
	require.NoError(t, tx.Commit())
	return id
}

// TestIdeasList_PrintsSeededTitle verifies `ideas list` prints a seeded
// idea's title in its table output.
func TestIdeasList_PrintsSeededTitle(t *testing.T) {
	database := setupIdeasTestEnv(t)
	seedIdeaRowCmd(t, database, db.Idea{
		Kind:          "idea",
		Title:         "Ship the ideas registry CLI",
		Essence:       "Wire the daemon phase and the CLI commands.",
		Status:        "proposed",
		Source:        "mined",
		LastMentionAt: "2026-08-07T12:00:00Z",
	})
	database.Close()

	var buf bytes.Buffer
	ideasListCmd.SetOut(&buf)
	ideasListCmd.SetArgs(nil)
	require.NoError(t, ideasListCmd.Flags().Set("kind", ""))
	require.NoError(t, ideasListCmd.Flags().Set("status", ""))
	require.NoError(t, ideasListCmd.RunE(ideasListCmd, nil))

	out := buf.String()
	require.Contains(t, out, "Ship the ideas registry CLI")
	require.Contains(t, out, "proposed")
}

// TestIdeasList_KindFilter_ExcludesOtherKind verifies the --kind flag is
// passed through to the DB filter.
func TestIdeasList_KindFilter_ExcludesOtherKind(t *testing.T) {
	database := setupIdeasTestEnv(t)
	seedIdeaRowCmd(t, database, db.Idea{
		Kind: "idea", Title: "An idea", Status: "proposed", LastMentionAt: "2026-08-07T12:00:00Z",
	})
	seedIdeaRowCmd(t, database, db.Idea{
		Kind: "decision", Title: "A decision", Status: "proposed", LastMentionAt: "2026-08-07T12:00:00Z",
	})
	database.Close()

	var buf bytes.Buffer
	ideasListCmd.SetOut(&buf)
	require.NoError(t, ideasListCmd.Flags().Set("kind", "decision"))
	t.Cleanup(func() { require.NoError(t, ideasListCmd.Flags().Set("kind", "")) })
	require.NoError(t, ideasListCmd.RunE(ideasListCmd, nil))

	out := buf.String()
	require.Contains(t, out, "A decision")
	require.NotContains(t, out, "An idea")
}

// TestIdeasMine_Disabled_NoOp verifies `ideas mine` short-circuits cleanly
// (no generator call, no error) when ideas.enabled is false.
func TestIdeasMine_Disabled_NoOp(t *testing.T) {
	database := setupIdeasTestEnv(t)
	database.Close()

	configPath := flagConfig
	data, err := os.ReadFile(configPath)
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(configPath, append(data, []byte("ideas:\n  enabled: false\n")...), 0o600))

	var buf bytes.Buffer
	ideasMineCmd.SetOut(&buf)
	require.NoError(t, ideasMineCmd.RunE(ideasMineCmd, nil))

	require.Contains(t, buf.String(), "disabled")
}

// TestIdeasMine_Backfill_Disabled_PrintsEnvelope covers GB9: on the --from
// backfill path, ideas.enabled=false must emit a machine-readable
// {"disabled":true} envelope on stdout (the Desktop "Find ideas" sheet's
// parse target) — never prose there — plus a human-readable line on
// stderr, and still exit 0.
func TestIdeasMine_Backfill_Disabled_PrintsEnvelope(t *testing.T) {
	database := setupIdeasTestEnv(t)
	database.Close()
	resetIdeasMineFlags(t)

	configPath := flagConfig
	data, err := os.ReadFile(configPath)
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(configPath, append(data, []byte("ideas:\n  enabled: false\n")...), 0o600))

	from := time.Now().Add(-48 * time.Hour).Format(ideasMineDateLayout)
	require.NoError(t, ideasMineCmd.Flags().Set("from", from))

	var outBuf, errBuf bytes.Buffer
	ideasMineCmd.SetOut(&outBuf)
	ideasMineCmd.SetErr(&errBuf)
	require.NoError(t, ideasMineCmd.RunE(ideasMineCmd, nil))

	require.Equal(t, "{\"disabled\":true}\n", outBuf.String(), "stdout must carry ONLY the machine-readable envelope, not prose")
	require.Contains(t, errBuf.String(), "disabled", "stderr should still carry a human-readable line")
}

// resetIdeasMineFlags clears --from/--to on the shared package-level
// ideasMineCmd so one test's flag values never leak into the next (the
// --kind cleanup precedent above).
func resetIdeasMineFlags(t *testing.T) {
	t.Helper()
	t.Cleanup(func() {
		require.NoError(t, ideasMineCmd.Flags().Set("from", ""))
		require.NoError(t, ideasMineCmd.Flags().Set("to", ""))
	})
}

// TestIdeasMine_ToWithoutFrom_Errors covers the CLI's "--to alone = error"
// contract (spec §3): --to only makes sense as a bound on a --from window.
func TestIdeasMine_ToWithoutFrom_Errors(t *testing.T) {
	database := setupIdeasTestEnv(t)
	database.Close()
	resetIdeasMineFlags(t)

	require.NoError(t, ideasMineCmd.Flags().Set("to", "2026-08-01"))

	err := ideasMineCmd.RunE(ideasMineCmd, nil)
	require.Error(t, err)
	require.Contains(t, err.Error(), "--to requires --from")
}

// TestIdeasMine_FromAfterTo_Errors covers "from >= to = error".
func TestIdeasMine_FromAfterTo_Errors(t *testing.T) {
	database := setupIdeasTestEnv(t)
	database.Close()
	resetIdeasMineFlags(t)

	require.NoError(t, ideasMineCmd.Flags().Set("from", "2026-08-10"))
	require.NoError(t, ideasMineCmd.Flags().Set("to", "2026-08-01"))

	err := ideasMineCmd.RunE(ideasMineCmd, nil)
	require.Error(t, err)
	require.Contains(t, err.Error(), "--from must be before --to")
}

// TestIdeasMine_FromEqualsTo_Errors covers the equal-boundary half of
// "from >= to = error".
func TestIdeasMine_FromEqualsTo_Errors(t *testing.T) {
	database := setupIdeasTestEnv(t)
	database.Close()
	resetIdeasMineFlags(t)

	require.NoError(t, ideasMineCmd.Flags().Set("from", "2026-08-01"))
	require.NoError(t, ideasMineCmd.Flags().Set("to", "2026-08-01"))

	err := ideasMineCmd.RunE(ideasMineCmd, nil)
	require.Error(t, err)
	require.Contains(t, err.Error(), "--from must be before --to")
}

// TestIdeasMine_InvalidFromDate_Errors covers the YYYY-MM-DD parse contract.
func TestIdeasMine_InvalidFromDate_Errors(t *testing.T) {
	database := setupIdeasTestEnv(t)
	database.Close()
	resetIdeasMineFlags(t)

	require.NoError(t, ideasMineCmd.Flags().Set("from", "not-a-date"))

	err := ideasMineCmd.RunE(ideasMineCmd, nil)
	require.Error(t, err)
	require.Contains(t, err.Error(), "invalid --from date")
}

// TestIdeasMine_Backfill_LockHeld_Errors covers the CLI's lock-acquire step
// and GB7's bidirectional lock: a fresh backfill lock already held by the
// DAEMON must surface as a clear error naming the actual holder, not
// silently proceed and race it.
func TestIdeasMine_Backfill_LockHeld_Errors(t *testing.T) {
	database := setupIdeasTestEnv(t)
	database.Close()
	resetIdeasMineFlags(t)

	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)

	release, err := ideas.AcquireBackfillLock(cfg.WorkspaceDir(), "daemon")
	require.NoError(t, err)
	defer release()

	from := time.Now().Add(-48 * time.Hour).Format(ideasMineDateLayout)
	require.NoError(t, ideasMineCmd.Flags().Set("from", from))

	err = ideasMineCmd.RunE(ideasMineCmd, nil)
	require.Error(t, err)
	require.Contains(t, err.Error(), "the daemon is mining right now")
}

// TestIdeasMine_Backfill_EmptyWindow_PrintsEnvelope covers the happy path:
// a window with no material at all backfills cleanly and prints the final
// JSON envelope (spec §3 step 5) with zero counts.
func TestIdeasMine_Backfill_EmptyWindow_PrintsEnvelope(t *testing.T) {
	database := setupIdeasTestEnv(t)
	require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "T1", Name: "Test"}))
	database.Close()
	resetIdeasMineFlags(t)

	from := time.Now().Add(-48 * time.Hour).Format(ideasMineDateLayout)
	require.NoError(t, ideasMineCmd.Flags().Set("from", from))

	var buf bytes.Buffer
	ideasMineCmd.SetOut(&buf)
	require.NoError(t, ideasMineCmd.RunE(ideasMineCmd, nil))

	out := buf.String()
	require.Contains(t, out, `"proposed":0`)
	require.Contains(t, out, `"mentions_deduped":0`)
	require.Contains(t, out, `"capped":false`)

	// The lock must be released once the command returns, so a follow-up
	// backfill (or the daemon) is never left blocked by this one.
	require.False(t, ideas.BackfillLockFresh(func() string {
		cfg, cerr := config.Load(flagConfig)
		require.NoError(t, cerr)
		return cfg.WorkspaceDir()
	}()))
}

// TestIdeasMine_Backfill_Capped_PrintsEnvelope covers GB2 at the CLI layer:
// when a drain phase hits its own per-phase cycle cap without converging,
// the printed envelope must carry "capped":true. Calls runIdeasBackfill
// directly with a fake generator (bypassing cliGenerator's real claude/codex
// subprocess) so this stays a fast, hermetic unit test.
func TestIdeasMine_Backfill_Capped_PrintsEnvelope(t *testing.T) {
	database := setupIdeasTestEnv(t)
	require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "T1", Name: "Test"}))

	restore := ideas.SetBackfillMaxCyclesForTest(1)
	t.Cleanup(restore)

	res, err := database.Exec(`INSERT INTO google_accounts (email, label, gmail_enabled, gmail_last_internal_date)
		VALUES ('acct@example.com', 'Test', 1, 0)`)
	require.NoError(t, err)
	acctID, err := res.LastInsertId()
	require.NoError(t, err)

	fromStr := "2020-01-01"
	from, err := time.Parse(ideasMineDateLayout, fromStr)
	require.NoError(t, err)
	require.NoError(t, database.SetIdeasEmailFloor(acctID, float64(from.Add(-time.Hour).Unix())))

	// More messages than one gmail pre-digest pass's own fetch window (500),
	// so a single-cycle stage-1 cap genuinely cuts the drain off mid-window.
	base := from.Add(time.Hour).Unix()
	tx, err := database.Begin()
	require.NoError(t, err)
	for i := 0; i < 501; i++ {
		ts := time.Unix(base+int64(i), 0).UTC().Format(time.RFC3339)
		_, ierr := tx.Exec(`INSERT INTO gmail_messages (account_id, id, thread_id, from_email, from_name, subject, body_text, internal_date)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
			acctID, fmt.Sprintf("m%d", i), fmt.Sprintf("thr-%d", i), "a@example.com", "Ann", "s", "we should try X", ts)
		require.NoError(t, ierr)
	}
	require.NoError(t, tx.Commit())

	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)

	gen := &fakeCmdGen{reply: func(user string) (string, error) {
		if strings.Contains(user, "=== REGISTRY ===") {
			return `{"ops":[]}`, nil
		}
		return fmt.Sprintf(`{"topics":[{"title":"t","summary":"s","ideas":[{"text":"try X","author":"Ann","ref":"gmail:%d:thr-0"}],"decisions":[]}]}`, acctID), nil
	}}
	pipe := ideas.New(database, cfg, gen, nil)

	var buf bytes.Buffer
	ideasMineCmd.SetOut(&buf)
	require.NoError(t, runIdeasBackfill(context.Background(), ideasMineCmd, cfg, pipe, fromStr, ""))
	database.Close()

	require.Contains(t, buf.String(), `"capped":true`)
}
