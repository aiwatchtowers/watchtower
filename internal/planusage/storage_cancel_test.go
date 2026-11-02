package planusage

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"watchtower/internal/codex"
	"watchtower/internal/db"
)

// A read can have a result ready when cancellation arrives. Returning that
// result must not let the adapter publish after the operation was cancelled.
type pausedCodexStore struct {
	*db.DB
	entered, release chan struct{}
	point            string
	reads            int
	once             sync.Once
}

func (s *pausedCodexStore) pause() { s.once.Do(func() { close(s.entered) }); <-s.release }
func (s *pausedCodexStore) GetCodexPlanUsageStatusContext(ctx context.Context) (*db.CodexPlanUsageStatus, error) {
	st, err := s.DB.GetCodexPlanUsageStatusContext(ctx)
	s.reads++
	if s.point == "retained" && s.reads == 2 {
		s.pause()
	}
	return st, err
}
func (s *pausedCodexStore) CodexPlanUsageHistoryContext(ctx context.Context, scope, key string, since, published, reset time.Time) ([]db.PlanUsageSample, error) {
	samples, err := s.DB.CodexPlanUsageHistoryContext(ctx, scope, key, since, published, reset)
	if s.point == "history" {
		s.pause()
	}
	return samples, err
}

func TestCodexPoller_CancelDuringStorageDoesNotPublish(t *testing.T) {
	for _, point := range []string{"history", "retained"} {
		for _, deadline := range []bool{false, true} {
			t.Run(point+"/"+fmtBoolForTest(deadline), func(t *testing.T) {
				d, err := db.Open(":memory:")
				require.NoError(t, err)
				defer d.Close()
				now := at(10, 0)
				scope := strings.Repeat("a", 64)
				reset := now.Add(time.Hour)
				require.NoError(t, StoreCodexUsage(d, now, testCodexSnapshot(scope, reset, 10)))
				before, err := d.GetCodexPlanUsageStatus()
				require.NoError(t, err)
				store := &pausedCodexStore{DB: d, point: point, entered: make(chan struct{}), release: make(chan struct{})}
				p := &CodexPoller{Store: store, Now: func() time.Time { return now.Add(time.Minute) }, failures: 3,
					Read: func(context.Context) (codex.UsageSnapshot, error) {
						if point == "retained" {
							return codex.UsageSnapshot{}, &codex.UsageError{Code: "network"}
						}
						return testCodexSnapshot(scope, reset, 90), nil
					}}
				var ctx context.Context
				var cancel context.CancelFunc
				if deadline {
					ctx, cancel = context.WithTimeout(context.Background(), 100*time.Millisecond)
				} else {
					ctx, cancel = context.WithCancel(context.Background())
				}
				defer cancel()
				done := make(chan error, 1)
				go func() { _, err := p.PollOnce(ctx); done <- err }()
				<-store.entered
				if deadline {
					<-ctx.Done()
				} else {
					cancel()
				}
				close(store.release)
				require.ErrorIs(t, <-done, ctx.Err())
				after, err := d.GetCodexPlanUsageStatus()
				require.NoError(t, err)
				require.Equal(t, before, after)
				var count int
				require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM codex_plan_usage_samples`).Scan(&count))
				require.Equal(t, 1, count)
				require.Equal(t, 3, p.failures, "a cancelled store does not change backoff")
			})
		}
	}
}

func fmtBoolForTest(v bool) string {
	if v {
		return "deadline"
	}
	return "cancel"
}

type pausedClaudeStore struct {
	*db.DB
	entered, release chan struct{}
	point            string
	once             sync.Once
}

func (s *pausedClaudeStore) pause() { s.once.Do(func() { close(s.entered) }); <-s.release }
func (s *pausedClaudeStore) PlanUsageSamplesSinceContext(ctx context.Context, key string, since time.Time) ([]db.PlanUsageSample, error) {
	samples, err := s.DB.PlanUsageSamplesSinceContext(ctx, key, since)
	if s.point == "history" {
		s.pause()
	}
	return samples, err
}
func (s *pausedClaudeStore) UpsertPlanUsageStatusContext(ctx context.Context, st db.PlanUsageStatus) error {
	if s.point == "publication" {
		s.pause()
	}
	return s.DB.UpsertPlanUsageStatusContext(ctx, st)
}

func TestPollOnce_CancelDuringStorageDoesNotPublish(t *testing.T) {
	for _, point := range []string{"history", "publication"} {
		t.Run(point, func(t *testing.T) {
			fetch := &fakeFetch{body: load(t, "usage_full.json")}
			p, d := newPoller(t, validCreds, fetch, at(10, 0))
			_, err := p.PollOnce(context.Background())
			require.NoError(t, err)
			before, err := d.GetPlanUsageStatus()
			require.NoError(t, err)
			store := &pausedClaudeStore{DB: d, point: point, entered: make(chan struct{}), release: make(chan struct{})}
			p.Store = store
			p.Now = func() time.Time { return at(10, 5) }
			p.failures = 3
			if point == "publication" {
				fetch.err = errors.New("synthetic source network failure")
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			done := make(chan error, 1)
			go func() { _, err := p.PollOnce(ctx); done <- err }()
			<-store.entered
			cancel()
			close(store.release)
			require.ErrorIs(t, <-done, context.Canceled)
			after, err := d.GetPlanUsageStatus()
			require.NoError(t, err)
			require.Equal(t, before, after)
			require.Equal(t, 3, p.failures)
			// Claude samples still precede status. Unpublished observations remain
			// invisible to the published-history query after cancellation.
			reset := *before.FetchedAt
			var limits []WindowLimit
			limits, err = DecodeWindowLimits(before.LimitsJSON)
			require.NoError(t, err)
			for _, l := range limits {
				if l.ResetsAt != nil {
					reset = *l.ResetsAt
					history, err := d.PlanUsageHistory(l.Key, at(9, 0), *before.FetchedAt, reset)
					require.NoError(t, err)
					for _, s := range history {
						require.False(t, s.TakenAt.After(*before.FetchedAt))
					}
				}
			}
		})
	}
}
