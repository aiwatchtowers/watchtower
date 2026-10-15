package daemon

import (
	"bytes"
	"context"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	gosync "sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/guide"
	"watchtower/internal/historybackfill"
	"watchtower/internal/memory"
)

// newBackfillDaemon is a daemon over a test DB with a temp HOME and an
// existing workspace dir (the stamp file and the digest lock live there).
func newBackfillDaemon(t *testing.T) (*Daemon, *db.DB, *bytes.Buffer) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "test-ws"}
	cfg.Sync.BackfillDays = 30
	require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o755))
	database := db.OpenTestDB(t)
	d := New(cfg)
	var buf bytes.Buffer
	d.SetLogger(log.New(&buf, "", 0))
	d.SetDB(database)
	return d, database, &buf
}

func pipelineRunNames(t *testing.T, database *db.DB) []string {
	t.Helper()
	rows, err := database.Query(`SELECT pipeline FROM pipeline_runs ORDER BY id`)
	require.NoError(t, err)
	defer rows.Close()
	var out []string
	for rows.Next() {
		var name string
		require.NoError(t, rows.Scan(&name))
		out = append(out, name)
	}
	require.NoError(t, rows.Err())
	return out
}

func TestStartHistoryBackfill_FromFirstSync(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	from := time.Now().Add(-3 * 24 * time.Hour).Truncate(time.Second)

	before := time.Now()
	d.startHistoryBackfill("slack", 1, from)

	rows, err := database.ListHistoryBackfills()
	require.NoError(t, err)
	require.Len(t, rows, 1)
	r := rows[0]
	assert.Equal(t, "slack", r.SourceKind)
	assert.Equal(t, int64(1), r.AccountID)
	assert.Equal(t, float64(from.Unix()), r.UpperTS)
	assert.Equal(t, float64(from.Unix()), r.ReachedTS)
	assert.Equal(t, "running", r.Status)
	wantFloor := float64(before.AddDate(0, 0, -30).Unix())
	assert.InDelta(t, wantFloor, r.FloorTS, 5, "floor is now − backfill_days")

	// A repeat (R13: every first-sync report) is harmless.
	d.startHistoryBackfill("slack", 1, from.Add(time.Hour))
	rows, err = database.ListHistoryBackfills()
	require.NoError(t, err)
	require.Len(t, rows, 1)
	assert.Equal(t, float64(from.Unix()), rows[0].UpperTS)
}

func TestStartHistoryBackfill_OffOrAlreadyDeep(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)

	d.config.Sync.BackfillDays = 0
	d.startHistoryBackfill("slack", 1, time.Now().Add(-3*24*time.Hour))

	d.config.Sync.BackfillDays = 30
	d.startHistoryBackfill("gmail", 2, time.Now().AddDate(0, 0, -31))

	rows, err := database.ListHistoryBackfills()
	require.NoError(t, err)
	assert.Empty(t, rows)
}

func TestPhaseMemory_SkipsWhileBackfillActive(t *testing.T) {
	d, database, buf := newBackfillDaemon(t)
	d.config.Memory = enabledMemoryConfig()
	opens := 0
	d.SetMemoryPipelineOpener(func() (*memory.Pipeline, error) {
		opens++
		return nil, fmt.Errorf("vault unavailable in test")
	})
	_, err := database.StartHistoryBackfill("slack", 1, 0, 100, time.Now())
	require.NoError(t, err)

	d.phaseMemory(context.Background())
	assert.Equal(t, 0, opens, "memory waits while a backfill runs")
	assert.Equal(t, 1, strings.Count(buf.String(), "memory: waiting for the history backfill"))

	rows, err := database.ListHistoryBackfills()
	require.NoError(t, err)
	require.NoError(t, database.SetHistoryBackfillStatus(rows[0].ID, "paused", time.Now()))
	d.phaseMemory(context.Background())
	assert.Equal(t, 0, opens, "a paused backfill still holds memory")

	require.NoError(t, database.AdvanceHistoryBackfill(rows[0].ID, 0, time.Now()))
	d.phaseMemory(context.Background())
	assert.Equal(t, 1, opens, "a done backfill lets memory run")
}

// countingGenerator answers every call with a valid digest and counts calls.
type countingGenerator struct {
	mu    gosync.Mutex
	calls int
}

func (g *countingGenerator) Generate(_ context.Context, _, _, _ string) (string, *digest.Usage, string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.calls++
	return `{"summary":"s","topics":[{"title":"t","summary":"s","decisions":[],"action_items":[],"situations":[],"key_messages":[]}]}`,
		&digest.Usage{Model: "m", InputTokens: 1, OutputTokens: 1}, "", nil
}

func (g *countingGenerator) count() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.calls
}

func TestHistoryBackfill_SlackSourceProcess(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	d.config.Digest = config.DigestConfig{Enabled: true, MinMessages: 3}
	gen := &countingGenerator{}
	d.SetDigestPipeline(digest.New(database, d.config, gen, d.logger))

	dayStart := time.Now().UTC().AddDate(0, 0, -20).Truncate(24 * time.Hour)
	from, to := dayStart, dayStart.Add(48*time.Hour)
	require.NoError(t, database.UpsertChannel(db.Channel{ID: "C1", Name: "alpha", Type: "public"}))
	require.NoError(t, database.UpsertUser(db.User{ID: "U1", Name: "alice", DisplayName: "Alice"}))
	for i := range 5 {
		require.NoError(t, database.UpsertMessage(db.Message{
			ChannelID: "C1", TS: fmt.Sprintf("%d.%06d", from.Unix()+3600+int64(i*60), i),
			UserID: "U1", Text: fmt.Sprintf("alpha-%d", i),
		}))
	}
	// A second channel digest that day, so the rollup has two to merge.
	_, err := database.UpsertDigest(db.Digest{
		ChannelID: "C2", Type: "channel", PeriodFrom: float64(from.Unix()) + 7200,
		PeriodTo: float64(from.Unix()) + 7300, Summary: "s", MessageCount: 3, Model: "m",
	})
	require.NoError(t, err)

	src := slackSource{d: d}
	complete, err := src.Process(context.Background(), from, to)
	require.NoError(t, err)
	assert.True(t, complete)

	ch, err := database.GetDigests(db.DigestFilter{ChannelID: "C1", Type: "channel"})
	require.NoError(t, err)
	require.Len(t, ch, 1, "the window digested C1")
	daily, err := database.GetDigests(db.DigestFilter{Type: "daily"})
	require.NoError(t, err)
	assert.NotEmpty(t, daily, "the rollups ran after the window")
	calls := gen.count()

	d.config.Digest.Enabled = false
	complete, err = src.Process(context.Background(), from, to)
	require.NoError(t, err)
	assert.True(t, complete)
	assert.Equal(t, calls, gen.count(), "digests off: no AI call")
}

func TestHistoryBackfill_AccountState(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)

	ok, err := database.CreateSlackAccount(db.SlackAccount{TeamID: "T1"})
	require.NoError(t, err)
	revoked, err := database.CreateSlackAccount(db.SlackAccount{TeamID: "T2"})
	require.NoError(t, err)
	require.NoError(t, database.SetSlackAccountAuthState(revoked, "revoked", "token revoked"))
	removed, err := database.CreateSlackAccount(db.SlackAccount{TeamID: "T3"})
	require.NoError(t, err)
	require.NoError(t, database.SetSlackAccountRemoved(removed))

	assert.Equal(t, historybackfill.AccountOK, d.accountState("slack", ok))
	assert.Equal(t, historybackfill.AccountRevoked, d.accountState("slack", revoked))
	assert.Equal(t, historybackfill.AccountGone, d.accountState("slack", removed))
	assert.Equal(t, historybackfill.AccountGone, d.accountState("slack", 999))

	g, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@example.com", GmailEnabled: true})
	require.NoError(t, err)
	assert.Equal(t, historybackfill.AccountOK, d.accountState("gmail", g))
	require.NoError(t, database.SetGoogleAccountAuthState(g, "revoked", "grant gone"))
	assert.Equal(t, historybackfill.AccountRevoked, d.accountState("gmail", g))
	assert.Equal(t, historybackfill.AccountGone, d.accountState("gmail", 999))

	m, err := database.CreateEmailAccount(db.EmailAccount{Provider: "imap", EmailAddress: "b@example.com", Host: "imap.example.com", Port: 993, Security: "ssl", Folder: "INBOX"})
	require.NoError(t, err)
	assert.Equal(t, historybackfill.AccountOK, d.accountState("imap", m))
	assert.Equal(t, historybackfill.AccountGone, d.accountState("imap", 999))
}

// wirePeopleBackfill turns people cards on with a real pipeline, so the
// one-time hook's people run is observable as a "people-backfill" row.
func wirePeopleBackfill(t *testing.T, d *Daemon, database *db.DB) {
	t.Helper()
	d.config.People.Enabled = true
	d.config.Digest.Enabled = true
	d.SetPeoplePipeline(guide.New(database, d.config, &mockGenerator{}, d.logger))
}

func TestOnSlackBackfillDone_RunsOnceThenStamp(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	wirePeopleBackfill(t, d, database)
	floor := time.Now().AddDate(0, 0, -30)

	require.NoError(t, d.onSlackBackfillDone(context.Background(), floor))
	assert.Equal(t, []string{"people-backfill"}, pipelineRunNames(t, database))
	_, err := os.Stat(d.historyBackfillHooksStampPath())
	require.NoError(t, err, "both hooks succeeded: stamp written")

	require.NoError(t, d.onSlackBackfillDone(context.Background(), floor))
	assert.Equal(t, []string{"people-backfill"}, pipelineRunNames(t, database), "the stamp blocks a rerun")
}

func TestOnSlackBackfillDone_FailedPeopleRunLeavesNoStamp(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	wirePeopleBackfill(t, d, database)
	floor := time.Now().AddDate(0, 0, -30)

	_, err := database.Exec(`ALTER TABLE people_cards RENAME TO people_cards_hidden`)
	require.NoError(t, err)
	require.Error(t, d.onSlackBackfillDone(context.Background(), floor))
	_, err = os.Stat(d.historyBackfillHooksStampPath())
	assert.True(t, os.IsNotExist(err), "a failed people run writes no stamp")

	_, err = database.Exec(`ALTER TABLE people_cards_hidden RENAME TO people_cards`)
	require.NoError(t, err)
	require.NoError(t, d.onSlackBackfillDone(context.Background(), floor), "the next Step retries")
	assert.Equal(t, []string{"people-backfill", "people-backfill"}, pipelineRunNames(t, database))
	_, err = os.Stat(d.historyBackfillHooksStampPath())
	require.NoError(t, err)
}

func TestPhaseHistoryBackfill_DoneSlackRowsRunUntilStamped(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	_, err := database.StartHistoryBackfill("slack", 1, 0, 100, time.Now())
	require.NoError(t, err)
	rows, err := database.ListHistoryBackfills()
	require.NoError(t, err)
	require.NoError(t, database.AdvanceHistoryBackfill(rows[0].ID, 0, time.Now()))

	d.phaseHistoryBackfill(context.Background())
	assert.Equal(t, []string{"history-backfill"}, pipelineRunNames(t, database), "done slack rows, no stamp: the phase runs")
	_, err = os.Stat(d.historyBackfillHooksStampPath())
	require.NoError(t, err, "nothing wired: the hooks have nothing to do and stamp")

	d.phaseHistoryBackfill(context.Background())
	assert.Equal(t, []string{"history-backfill"}, pipelineRunNames(t, database), "stamped and nothing active: skipped")
}

func TestPhaseHistoryBackfill_NoRowsNoRun(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	d.phaseHistoryBackfill(context.Background())
	assert.Empty(t, pipelineRunNames(t, database))
	_, err := os.Stat(filepath.Join(d.config.WorkspaceDir(), "history_backfill_hooks_done.txt"))
	assert.True(t, os.IsNotExist(err))
}
