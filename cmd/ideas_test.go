package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/daemon"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/ideas"
)

// testCmdLogger is a discard logger for exercising runIdeasMineIncremental's
// log-and-continue error path without polluting test output (the
// cmd/*.go `log.New(io.Discard, "", 0)` precedent).
func testCmdLogger() *log.Logger {
	return log.New(io.Discard, "", 0)
}

// fakeCmdGen is a stub digest.Generator for exercising runIdeasBackfill
// directly, bypassing cliGenerator's real claude/codex subprocess (the
// internal/ideas fakeGen precedent, duplicated here since it's package-private
// there). calls counts invocations, the internal/ideas fakeGen precedent, so
// a test can assert whether a stage actually ran without further plumbing.
type fakeCmdGen struct {
	reply func(user string) (string, error)
	calls int
}

func (g *fakeCmdGen) Generate(_ context.Context, _, user, _ string) (string, *digest.Usage, string, error) {
	g.calls++
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

// TestIdeasPipelineNeeded pins wireIdeasPipeline's gate now that the stage-1
// stream digests are decoupled from ideas.enabled (Task 6): a pipeline is
// needed whenever EITHER the registry consolidator (ideas.enabled) or the
// stream digests phase (streams.enabled) is on, and needed by neither only
// when both are off.
func TestIdeasPipelineNeeded(t *testing.T) {
	tests := []struct {
		name           string
		ideasEnabled   bool
		streamsEnabled bool
		want           bool
	}{
		{"both enabled", true, true, true},
		{"only ideas enabled", true, false, true},
		{"only streams enabled", false, true, true},
		{"both disabled", false, false, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := &config.Config{
				Ideas:   config.IdeasConfig{Enabled: tt.ideasEnabled},
				Streams: config.StreamsConfig{Enabled: tt.streamsEnabled},
			}
			assert.Equal(t, tt.want, ideasPipelineNeeded(cfg))
		})
	}
}

// TestWireIdeasPipeline_StreamsOnlyWiresPipeline verifies the end-to-end
// wiring path (not just the predicate): with ideas.enabled=false and
// streams.enabled=true, wireIdeasPipeline still attaches an ideas.Pipeline to
// the daemon, so the independently-gated stream digests phase has something
// to run.
func TestWireIdeasPipeline_StreamsOnlyWiresPipeline(t *testing.T) {
	database := setupIdeasTestEnv(t)
	defer database.Close()

	cfg := &config.Config{
		Ideas:   config.IdeasConfig{Enabled: false},
		Streams: config.StreamsConfig{Enabled: true, IntervalHours: 6},
	}

	d := daemon.New(cfg)
	wireIdeasPipeline(d, database, cfg, nil, nil)

	assert.True(t, d.HasIdeasPipeline(),
		"wireIdeasPipeline must attach a pipeline even with ideas.enabled=false, so the streams-only phase has something to run")
}

// TestWireIdeasPipeline_BothDisabledLeavesNoPipeline is the control: with
// both ideas.enabled and streams.enabled false, wireIdeasPipeline must not
// attach a pipeline at all.
func TestWireIdeasPipeline_BothDisabledLeavesNoPipeline(t *testing.T) {
	database := setupIdeasTestEnv(t)
	defer database.Close()

	cfg := &config.Config{
		Ideas:   config.IdeasConfig{Enabled: false},
		Streams: config.StreamsConfig{Enabled: false},
	}

	d := daemon.New(cfg)
	wireIdeasPipeline(d, database, cfg, nil, nil)

	assert.False(t, d.HasIdeasPipeline())
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

// TestIdeasMine_StreamsOnlyIdeasDisabled_RunsStage1 pins the outer-gate fix:
// with ideas.enabled=false and streams.enabled=true, flagless `ideas mine`
// must reach runIdeasMineIncremental and actually run stage 1
// (RunStreamDigests) rather than short-circuiting to reportIdeasDisabled —
// before this fix a streams-only config made `ideas mine` a total no-op even
// though ideasPipelineNeeded (and the daemon's own phase wiring) already
// treat streams-only as "something to do".
//
// This drives the REAL command (ideasMineCmd.RunE), unlike the sibling
// direct-call tests above, because the bug lives specifically in
// runIdeasMine's outer gate, which a direct call to runIdeasMineIncremental
// bypasses entirely. Going through RunE means the real cliGenerator wires a
// live claude/codex subprocess (no test seam exists to swap it, see
// misc_coverage_test.go's TestCliGenerator), so this test must never let a
// stage actually reach Generate. It seeds a Jira account with an
// uninitialized floor: runJiraDigestAccount's first-run path
// (internal/ideas/jira_digest.go) initializes the floor and returns without
// calling Generate at all ("no backfill" — mirrors the empty-window no-op).
// The floor flipping from empty to set is therefore proof stage 1 actually
// executed, entirely without an AI call.
func TestIdeasMine_StreamsOnlyIdeasDisabled_RunsStage1(t *testing.T) {
	database := setupIdeasTestEnv(t)
	resetIdeasMineFlags(t)

	jiraAcctID, err := database.CreateJiraAccount(db.JiraAccount{
		CloudID: "cloud-streams-only", SiteURL: "https://example.atlassian.net", Label: "Test",
	})
	require.NoError(t, err)

	before, err := database.IdeasJiraFloor(jiraAcctID)
	require.NoError(t, err)
	require.Empty(t, before, "precondition: floor starts uninitialized")

	database.Close()

	configPath := flagConfig
	data, err := os.ReadFile(configPath)
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(configPath,
		append(data, []byte("ideas:\n  enabled: false\nstreams:\n  enabled: true\n")...), 0o600))

	var buf bytes.Buffer
	ideasMineCmd.SetOut(&buf)
	require.NoError(t, ideasMineCmd.RunE(ideasMineCmd, nil))

	require.NotContains(t, buf.String(), "Ideas registry is disabled",
		"streams-only must not short-circuit to reportIdeasDisabled's no-op line")

	cfg, err := config.Load(configPath)
	require.NoError(t, err)
	reopened, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	defer reopened.Close()

	after, err := reopened.IdeasJiraFloor(jiraAcctID)
	require.NoError(t, err)
	require.NotEmpty(t, after, "stage 1 (RunStreamDigests) must have run and initialized the jira account's floor")
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

// TestIdeasMine_FromEqualsTo_SingleDayWindow_Succeeds covers SB1: --to is
// inclusive of its whole calendar day, so --from and --to naming the same
// date is a valid one-day window (not the "from >= to" error it used to be
// before the effective upper bound was midnight of the following day).
func TestIdeasMine_FromEqualsTo_SingleDayWindow_Succeeds(t *testing.T) {
	database := setupIdeasTestEnv(t)
	require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "T1", Name: "Test"}))
	database.Close()
	resetIdeasMineFlags(t)

	require.NoError(t, ideasMineCmd.Flags().Set("from", "2020-01-01"))
	require.NoError(t, ideasMineCmd.Flags().Set("to", "2020-01-01"))

	var buf bytes.Buffer
	ideasMineCmd.SetOut(&buf)
	require.NoError(t, ideasMineCmd.RunE(ideasMineCmd, nil))
	require.Contains(t, buf.String(), `"proposed":0`)
}

// TestIdeasMine_FromAfterToDay_Errors covers "from's date after to's date =
// error" now that --to's effective bound is midnight of the following day.
func TestIdeasMine_FromAfterToDay_Errors(t *testing.T) {
	database := setupIdeasTestEnv(t)
	database.Close()
	resetIdeasMineFlags(t)

	require.NoError(t, ideasMineCmd.Flags().Set("from", "2026-08-02"))
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

// TestParseBackfillWindow_ToIsInclusiveOfWholeDay pins SB1 directly against
// the parser: a --to date's effective upper bound is midnight of the
// following day, so the whole named day is included in the window.
func TestParseBackfillWindow_ToIsInclusiveOfWholeDay(t *testing.T) {
	from, to, err := parseBackfillWindow("2026-08-01", "2026-08-01")
	require.NoError(t, err)
	require.Equal(t, "2026-08-01", from.Format(ideasMineDateLayout))
	require.Equal(t, "2026-08-02", to.Format(ideasMineDateLayout))
}

// TestParseBackfillWindow_EmptyTo_StaysZero covers the "--to omitted"
// branch: the returned to must stay the zero value so Pipeline.Backfill
// substitutes time.Now() itself, not midnight-tomorrow of some fabricated
// date.
func TestParseBackfillWindow_EmptyTo_StaysZero(t *testing.T) {
	_, to, err := parseBackfillWindow("2026-08-01", "")
	require.NoError(t, err)
	require.True(t, to.IsZero())
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
	require.Contains(t, out, `"input_tokens":0`, "GB15: token usage fields must be present even when zero")
	require.Contains(t, out, `"output_tokens":0`)
	require.Contains(t, out, `"api_calls":0`)
	require.Contains(t, out, `"slack_refs_dropped":0`, "the IDEA-02 drop counters must be present even when zero")
	require.Contains(t, out, `"refs_rejected":0`)

	// The lock must be released once the command returns, so a follow-up
	// backfill (or the daemon) is never left blocked by this one.
	require.False(t, ideas.BackfillLockFresh(func() string {
		cfg, cerr := config.Load(flagConfig)
		require.NoError(t, cerr)
		return cfg.WorkspaceDir()
	}()))
}

// TestIdeasMine_Incremental_ReportsDropCounters pins the flagless path's
// reporting of the two IDEA-02 drop counters. They were log-only before, which
// left the owner reading "proposed=0" unable to tell a quiet day apart from a
// run that mined a Slack candidate whose timestamp resolved to no live message
// and then discarded the model's citation of it. One topic here carries a real
// candidate and a hallucinated one, and the model cites the hallucinated ref:
// one unverifiable Slack ref dropped, one invented ref rejected, nothing
// written.
func TestIdeasMine_Incremental_ReportsDropCounters(t *testing.T) {
	database := setupIdeasTestEnv(t)
	require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "T1", Name: "Test"}))

	require.NoError(t, database.UpsertMessage(db.Message{
		ChannelID: "C1", TS: "1785746329.642879", UserID: "U1", Text: "we should try X", RawJSON: "{}",
	}))
	ideasJSON, err := json.Marshal([]digest.IdeaCandidate{
		{Text: "real idea", By: "Ann", MessageTS: "1785746329.642879"},
		{Text: "hallucinated idea", By: "Ann", MessageTS: "1754131080.000000"},
	})
	require.NoError(t, err)
	now := float64(time.Now().Unix())
	digestID, err := database.UpsertDigest(db.Digest{
		ChannelID: "C1", Type: "channel", PeriodFrom: now, PeriodTo: now + 60,
		Summary: "s", Topics: "[]", Decisions: "[]", ActionItems: "[]", PeopleSignals: "[]", Situations: "[]",
	})
	require.NoError(t, err)
	require.NoError(t, database.InsertDigestTopics(digestID, []db.DigestTopic{{
		Idx: 0, Title: "general", Summary: "s", Decisions: "[]", ActionItems: "[]",
		Situations: "[]", KeyMessages: "[]", Ideas: string(ideasJSON),
	}}))

	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	gen := &fakeCmdGen{reply: func(string) (string, error) {
		return `{"ops":[{"op":"new_idea","title":"Ghost","essence":"e",
			"mentions":[{"source":"slack","ref":"C1|1754131080.000000","quote":"hallucinated idea","author":"Ann","said_at":"2026-08-01T00:00:00Z"}]}]}`, nil
	}}
	pipe := ideas.New(database, cfg, gen, nil)

	var buf bytes.Buffer
	require.NoError(t, runIdeasMineIncremental(context.Background(), cfg, pipe, &buf, testCmdLogger()))
	database.Close()

	assert.Contains(t, buf.String(), "proposed=0 slack_refs_dropped=1 refs_rejected=1")
}

// TestIdeasMine_Incremental_StreamsEnabled_RunsStage1First verifies the
// flagless `ideas mine` path runs the stage-1 stream pre-digests
// (pipe.RunStreamDigests) before the stage-2 consolidator when
// cfg.Streams.Enabled is true — a single connected Jira account with one
// in-window issue produces exactly one extra Generate call (the jira pass;
// there is no Gmail account seeded, so the email pass is a no-op), on top of
// the consolidator's own zero calls (ideas.Enabled is left false so Run
// short-circuits per TestRun_IdeasDisabled_ShortCircuits' contract, isolating
// the count to stage 1 alone).
func TestIdeasMine_Incremental_StreamsEnabled_RunsStage1First(t *testing.T) {
	database := setupIdeasTestEnv(t)

	jiraAcctID, err := database.CreateJiraAccount(db.JiraAccount{
		CloudID: "cloud-streams-on", SiteURL: "https://example.atlassian.net", Label: "Test",
	})
	require.NoError(t, err)
	jbase := time.Now().Add(-time.Hour)
	_, err = database.Exec(`UPDATE jira_accounts SET ideas_jira_floor = ? WHERE id = ?`, jbase.Format(time.RFC3339), jiraAcctID)
	require.NoError(t, err)
	updatedAt := jbase.Add(10 * time.Second).Format(time.RFC3339)
	_, err = database.Exec(`INSERT INTO jira_issues
		(account_id, key, id, project_key, board_id, summary, description_text, status, status_category, sprint_id, created_at, updated_at, synced_at)
		VALUES (?, 'WT-1', 'WT-1', 'WT', 0, 'Issue', 'we should try X', 'Open', 'new', 0, ?, ?, ?)`,
		jiraAcctID, updatedAt, updatedAt, updatedAt)
	require.NoError(t, err)

	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	cfg.Streams.Enabled = true
	// Ideas.Enabled off isolates the call count to stage 1 alone: Run's
	// cfg.Ideas.Enabled gate returns 0, nil immediately (no floor writes, no
	// workspace row needed), the TestRun_IdeasDisabled_ShortCircuits contract.
	cfg.Ideas.Enabled = false
	gen := &fakeCmdGen{reply: func(string) (string, error) {
		return `{"topics":[{"title":"t","summary":"s","ideas":[],"decisions":[]}]}`, nil
	}}
	pipe := ideas.New(database, cfg, gen, testCmdLogger())

	var buf bytes.Buffer
	require.NoError(t, runIdeasMineIncremental(context.Background(), cfg, pipe, &buf, testCmdLogger()))
	database.Close()

	assert.Equal(t, 1, gen.calls, "stage 1's jira pass must run when streams.enabled is true")
}

// TestIdeasMine_Incremental_StreamsDisabled_SkipsStage1 is the control: the
// same seeded jira account produces zero Generate calls when
// cfg.Streams.Enabled is false, confirming RunStreamDigests is skipped
// outright rather than called and finding nothing to do.
func TestIdeasMine_Incremental_StreamsDisabled_SkipsStage1(t *testing.T) {
	database := setupIdeasTestEnv(t)

	jiraAcctID, err := database.CreateJiraAccount(db.JiraAccount{
		CloudID: "cloud-streams-off", SiteURL: "https://example.atlassian.net", Label: "Test",
	})
	require.NoError(t, err)
	jbase := time.Now().Add(-time.Hour)
	_, err = database.Exec(`UPDATE jira_accounts SET ideas_jira_floor = ? WHERE id = ?`, jbase.Format(time.RFC3339), jiraAcctID)
	require.NoError(t, err)
	updatedAt := jbase.Add(10 * time.Second).Format(time.RFC3339)
	_, err = database.Exec(`INSERT INTO jira_issues
		(account_id, key, id, project_key, board_id, summary, description_text, status, status_category, sprint_id, created_at, updated_at, synced_at)
		VALUES (?, 'WT-1', 'WT-1', 'WT', 0, 'Issue', 'we should try X', 'Open', 'new', 0, ?, ?, ?)`,
		jiraAcctID, updatedAt, updatedAt, updatedAt)
	require.NoError(t, err)

	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	cfg.Streams.Enabled = false
	gen := &fakeCmdGen{reply: func(string) (string, error) {
		return `{"topics":[{"title":"t","summary":"s","ideas":[],"decisions":[]}]}`, nil
	}}
	pipe := ideas.New(database, cfg, gen, testCmdLogger())

	var buf bytes.Buffer
	require.NoError(t, runIdeasMineIncremental(context.Background(), cfg, pipe, &buf, testCmdLogger()))
	database.Close()

	assert.Zero(t, gen.calls, "stage 1 must not run at all when streams.enabled is false")
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

	var envelope backfillEnvelope
	require.NoError(t, json.Unmarshal(buf.Bytes(), &envelope))
	assert.Positive(t, envelope.InputTokens, "GB15: the backfill envelope must report real accumulated token usage, not zero, once AI calls actually ran")
	assert.Positive(t, envelope.OutputTokens)
	assert.Positive(t, envelope.APICalls)
}
