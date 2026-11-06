package cmd

import (
	"bytes"
	"context"
	"io"
	"log"
	"os"
	"path/filepath"
	gosync "sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/slackbackfill"
	"watchtower/internal/sync"
)

// backfillGen answers every digest and rollup call with one small topic and
// counts the calls.
type backfillGen struct {
	mu gosync.Mutex
	n  int
}

func countChannelDigests(t *testing.T, database *db.DB, channel string) int {
	t.Helper()
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM digests WHERE type = 'channel' AND channel_id = ?`, channel).Scan(&n))
	return n
}

func (g *backfillGen) Generate(_ context.Context, _, _, _ string) (string, *digest.Usage, string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.n++
	return `{"summary":"s","topics":[{"title":"t","summary":"s","decisions":[],"action_items":[],"situations":[],"key_messages":[]}]}`,
		&digest.Usage{Model: "m", InputTokens: 1, OutputTokens: 1}, "", nil
}

func (g *backfillGen) calls() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.n
}

// The whole command path with digests on, over the real orchestrator and the
// stub Slack: fetch, then the chunk's digest; a second run fetches again but
// digests nothing.
func TestSlackBackfillRun_WithDigests(t *testing.T) {
	database, _ := slackBackfillEnv(t, "T_HOME")
	cfg, err := workspaceConfigFromFlags()
	require.NoError(t, err)
	cfg.Digest = config.DigestConfig{Enabled: true, MinMessages: 1}
	gen := &backfillGen{}
	pipe := digest.New(database, cfg, gen, log.New(io.Discard, "", 0))
	orch := sync.NewOrchestrator(database, newSlackClientForToken("xoxp-test"), cfg, 1)
	orch.SetLogger(log.New(io.Discard, "", 0))
	// The stub's one message is at 2026-03-13 12:00 UTC.
	floor := time.Date(2026, 3, 13, 0, 0, 0, 0, time.UTC)
	upper := floor.Add(24 * time.Hour)
	run := func() string {
		ledger, err := slackbackfill.LoadLedger(cfg.WorkspaceDir())
		require.NoError(t, err)
		var out bytes.Buffer
		r := &slackbackfill.Run{DB: database, Fetch: orch, Digest: pipe, Ledger: ledger, Out: &out}
		require.NoError(t, r.Range(context.Background(), floor, upper))
		return out.String()
	}

	assert.Contains(t, run(), "1 messages, 1 digests")
	assert.Equal(t, 1, countChannelDigests(t, database, "1:C001"))

	calls := gen.calls()
	assert.Contains(t, run(), "1 messages, 0 digests, daily rollups run for 0 days")
	assert.Equal(t, calls, gen.calls(), "the second run digests nothing")
}

// M3a at the command: with digests off the run still freezes the ledger.
func TestSlackBackfill_DigestsOffStillWritesTheLedger(t *testing.T) {
	slackBackfillEnv(t, "T_HOME")
	out, err := runSlackBackfillCmd("--account", "1", "--from", "2026-03-10", "--to", "2026-03-12")
	require.NoError(t, err, out)
	cfg, err := workspaceConfigFromFlags()
	require.NoError(t, err)
	_, err = os.Stat(filepath.Join(cfg.WorkspaceDir(), slackbackfill.LedgerFile))
	require.NoError(t, err, "the ledger is frozen with digests off")
}
