package digest

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

type scheduledDigestGenerator struct {
	mu          sync.Mutex
	wait        bool
	fail        string
	material    bool
	calls       int
	prompts     map[string]string
	quotaIssued chan struct{}
}

func (g *scheduledDigestGenerator) RoutingPreflight(context.Context) error {
	if g.wait {
		return testProviderWait{}
	}
	return nil
}
func (g *scheduledDigestGenerator) Generate(_ context.Context, system, user, _ string) (string, *Usage, string, error) {
	prompt := system + user
	if strings.Contains(prompt, "flaky") && g.fail != "" {
		g.mu.Lock()
		g.calls++
		g.prompts["failed"] = prompt
		g.mu.Unlock()
		if g.quotaIssued != nil {
			close(g.quotaIssued)
		}
		if g.material {
			return "", nil, "", errors.New("material invalid")
		}
		return "", nil, "", testProviderWait{}
	}
	if g.quotaIssued != nil {
		<-g.quotaIssued
	}
	g.mu.Lock()
	g.calls++
	g.prompts["success"] = prompt
	g.mu.Unlock()
	return validDigestJSON(), nil, "", nil
}
func TestScheduledDigestDeferredRetryOnlyMissingStableWindow(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()
	cfg.Digest.MinMessages = 5
	cfg.Digest.BatchMaxChannels = 1
	cfg.AI.Workers = 2
	t.Setenv("HOME", t.TempDir())
	require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o700))
	seedChannel(t, database, "C_OK", "steady")
	seedChannel(t, database, "C_FAIL", "flaky")
	seedUser(t, database, "U1", "member", "Member")
	base := time.Now().Add(-2 * time.Hour).Unix()
	for i := range 35 {
		for _, id := range []string{"C_OK", "C_FAIL"} {
			seedMessage(t, database, id, fmt.Sprintf("%d.000000", base+int64(i)), "U1", "message")
		}
	}
	gen := &scheduledDigestGenerator{fail: "flaky", prompts: map[string]string{}, quotaIssued: make(chan struct{})}
	p := New(database, cfg, gen, testLogger())
	p.DeferredSchedule = true
	n, _, err := p.RunChannelDigests(context.Background())
	require.Equal(t, 1, n)
	require.True(t, ProviderDeferred(err))
	saved, err := database.GetLatestDigest("C_OK", "channel")
	require.NoError(t, err)
	require.NotNil(t, saved)
	unsaved, err := database.GetLatestDigest("C_FAIL", "channel")
	require.NoError(t, err)
	require.Nil(t, unsaved)
	var considered float64
	require.NoError(t, database.QueryRow("SELECT coalesce(digest_considered_ts,0) FROM channels WHERE id='C_FAIL'").Scan(&considered))
	require.Zero(t, considered)
	path := filepath.Join(cfg.WorkspaceDir(), "digest_pending_window.json")
	data, err := os.ReadFile(path)
	require.NoError(t, err)
	var pending digestWindow
	require.NoError(t, json.Unmarshal(data, &pending))
	// New input after the interrupted upper bound belongs to a later ordinary
	// schedule, including new input on the channel that already committed.
	seedMessage(t, database, "C_OK", fmt.Sprintf("%.6f", pending.To+1), "U1", "later input")
	next := &scheduledDigestGenerator{prompts: map[string]string{}}
	restarted := New(database, cfg, next, testLogger())
	restarted.DeferredSchedule = true
	n, _, err = restarted.RunChannelDigests(context.Background())
	require.NoError(t, err)
	require.Equal(t, 1, n)
	require.Equal(t, 1, next.calls)
	require.Equal(t, gen.prompts["failed"], next.prompts["success"], "same missing input and window after restart")
	savedAgain, err := database.GetLatestDigest("C_OK", "channel")
	require.NoError(t, err)
	require.Equal(t, saved.ID, savedAgain.ID)
	_, err = os.Stat(path)
	require.ErrorIs(t, err, os.ErrNotExist)
}
func TestScheduledDigestKnownWaitWritesNoInputOrSuccessMarks(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()
	t.Setenv("HOME", t.TempDir())
	require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o700))
	gen := &scheduledDigestGenerator{wait: true, prompts: map[string]string{}}
	p := New(database, cfg, gen, testLogger())
	p.DeferredSchedule = true
	_, _, err := p.RunChannelDigests(context.Background())
	require.True(t, ProviderDeferred(err))
	require.Zero(t, gen.calls)
	entries, err := os.ReadDir(cfg.WorkspaceDir())
	require.NoError(t, err)
	require.Empty(t, entries)
	var count int
	require.NoError(t, database.QueryRow("SELECT count(*) FROM digests").Scan(&count))
	require.Zero(t, count)
}
func TestDeferredChunkErrorsRetainMaterialFailure(t *testing.T) {
	err := &ChunkErrors{Errs: []error{testProviderWait{}, errors.New("storage failed")}}
	require.False(t, ProviderDeferred(err))
	require.True(t, ProviderDeferred(&ChunkErrors{Errs: []error{testProviderWait{}, fmt.Errorf("wrapped: %w", testProviderWait{})}}))
}

type mixedDigestGenerator struct{ material error }

func (mixedDigestGenerator) RoutingPreflight(context.Context) error { return nil }
func (g mixedDigestGenerator) Generate(_ context.Context, system, user, _ string) (string, *Usage, string, error) {
	if strings.Contains(system+user, "flaky") {
		return "", nil, "", testProviderWait{}
	}
	return "", nil, "", g.material
}
func TestScheduledDigestMixedQuotaAndMaterialRemainOrdinaryFailure(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()
	cfg.Digest.MinMessages = 1
	cfg.Digest.BatchMaxChannels = 1
	cfg.AI.Workers = 2
	seedChannel(t, database, "C_BAD", "material")
	seedChannel(t, database, "C_WAIT", "flaky")
	seedUser(t, database, "U1", "member", "Member")
	base := time.Now().Add(-time.Hour).Unix()
	for i := range 35 {
		for _, id := range []string{"C_BAD", "C_WAIT"} {
			seedMessage(t, database, id, fmt.Sprintf("%d.000000", base+int64(i)), "U1", "message")
		}
	}
	material := errors.New("material invalid")
	p := New(database, cfg, mixedDigestGenerator{material}, testLogger())
	n, _, err := p.RunChannelDigests(context.Background())
	require.Zero(t, n)
	require.ErrorIs(t, err, material)
	require.False(t, ProviderDeferred(err))
	var wait testProviderWait
	require.ErrorAs(t, err, &wait, "typed quota is retained beside the ordinary failure")
}

func TestScheduledDigestResumeHonorsCurrentMute(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()
	cfg.Digest.MinMessages = 1
	t.Setenv("HOME", t.TempDir())
	require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o700))
	seedChannel(t, database, "C1", "flaky")
	seedUser(t, database, "U1", "member", "Member")
	base := time.Now().Add(-time.Hour).Unix()
	for i := range 35 {
		seedMessage(t, database, "C1", fmt.Sprintf("%d.000000", base+int64(i)), "U1", "message")
	}
	gen := &scheduledDigestGenerator{fail: "flaky", prompts: map[string]string{}}
	p := New(database, cfg, gen, testLogger())
	p.DeferredSchedule = true
	_, _, err := p.RunChannelDigests(context.Background())
	require.True(t, ProviderDeferred(err))
	require.NoError(t, database.SetMuteForLLM("C1", true))
	next := &scheduledDigestGenerator{prompts: map[string]string{}}
	resumed := New(database, cfg, next, testLogger())
	resumed.DeferredSchedule = true
	n, _, err := resumed.RunChannelDigests(context.Background())
	require.NoError(t, err)
	require.Zero(t, n)
	require.Zero(t, next.calls)
	card, err := database.GetLatestDigest("C1", "channel")
	require.NoError(t, err)
	require.Nil(t, card)
	var considered float64
	require.NoError(t, database.QueryRow("SELECT coalesce(digest_considered_ts,0) FROM channels WHERE id='C1'").Scan(&considered))
	require.Zero(t, considered)
}
