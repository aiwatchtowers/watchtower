package memory

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// TestMemory04_CancelBetweenBatchesKeepsCommittedWatermark covers the
// "N windows left for the next run" path — a daemon shutdown that lands
// between two extraction batches. The batch in flight commits, the loop stops
// before the next AI call, the watermark sits exactly at the committed
// batch's last message, and the next run re-extracts only the windows that
// were left (no second pass over the committed one, so no duplicate episode).
func TestMemory04_CancelBetweenBatchesKeepsCommittedWatermark(t *testing.T) {
	d := db.OpenTestDB(t)
	v := newTestVault(t)
	seedWorkspaceRow(t, d)
	seedUserRow(t, d, "U1ALICE", "alice")
	for _, ch := range []string{"C1", "C2", "C3"} {
		seedChannelRow(t, d, ch, strings.ToLower(ch))
	}
	base := time.Now().Add(-time.Hour).Unix()
	seedMessageRow(t, d, "C1", fmt.Sprintf("%d.000001", base), "U1ALICE", "c1 one")
	seedMessageRow(t, d, "C1", fmt.Sprintf("%d.000002", base+10), "U1ALICE", "c1 two")
	seedMessageRow(t, d, "C2", fmt.Sprintf("%d.000003", base+100), "U1ALICE", "c2 one")
	seedMessageRow(t, d, "C3", fmt.Sprintf("%d.000004", base+200), "U1ALICE", "c3 one")

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	gen := &fakeGen{reply: func(string) (string, error) {
		cancel() // shutdown arrives while batch 1's AI call is in flight
		return episodeJSON("C1 decision", "C1", fmt.Sprintf("%d.000001", base), "C1"), nil
	}}
	var logs []string
	p := NewPipeline(d, v, gen, pipelineTestConfig(), func(f string, a ...any) { logs = append(logs, fmt.Sprintf(f, a...)) })

	stats, runErr := p.Run(ctx)
	require.NoError(t, runErr, "an interruption ends the run cleanly, like a failed batch")
	require.Len(t, gen.calls, 1, "no AI call after the cancellation")
	assert.Equal(t, 1, stats.Episodes, "the in-flight batch still commits")
	assert.Contains(t, strings.Join(logs, "\n"), "extraction interrupted, 2 windows left for the next run")

	wm, err := d.MemoryWatermark()
	require.NoError(t, err)
	assert.Equal(t, float64(base+10), wm, "watermark sits exactly at the committed batch's last message")

	gen.calls = nil
	gen.reply = func(string) (string, error) { return "[]", nil }
	_, err = p.Run(context.Background())
	require.NoError(t, err)
	rerun := strings.Join(gen.calls, "\n")
	assert.NotContains(t, rerun, "c1 one", "the committed window is not re-extracted")
	assert.NotContains(t, rerun, "c1 two", "the committed window is not re-extracted")
	assert.Contains(t, rerun, "c2 one", "a window left by the interruption is extracted next run")
	assert.Contains(t, rerun, "c3 one", "a window left by the interruption is extracted next run")
}
