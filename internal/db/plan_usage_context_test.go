package db

import (
	"context"
	"database/sql"
	"fmt"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"watchtower/internal/sqlcipher"

	"github.com/stretchr/testify/require"
)

func TestPlanUsage_ContextPublicationWaitCancelsWithoutWrites(t *testing.T) {
	for _, provider := range []string{"codex_success", "codex_failure", "claude_status", "claude_samples"} {
		t.Run(provider, func(t *testing.T) {
			// In a synctest bubble the database, the pool's wait and the deadline
			// all run on the bubble's clock: the deadline passes once publication
			// waits for the held connection, with no real time spent.
			synctest.Test(t, func(t *testing.T) {
				d := openTestDB(t)
				now := time.Date(2026, 11, 2, 9, 0, 0, 0, time.UTC)
				codexBefore := codexTestStatus(now, "")
				claudeBefore := PlanUsageStatus{State: "ok", FetchedAt: &now, UpdatedAt: now, LimitsJSON: "[]", BreakdownJSON: "[]"}
				require.NoError(t, d.PublishCodexPlanUsage(codexBefore, nil))
				require.NoError(t, d.UpsertPlanUsageStatus(claudeBefore))
				codexSaved, err := d.GetCodexPlanUsageStatus()
				require.NoError(t, err)
				claudeSaved, err := d.GetPlanUsageStatus()
				require.NoError(t, err)
				// The single DB connection is deliberately occupied after source work,
				// forcing publication to wait inside database/sql rather than a fetch.
				held, err := d.Conn(context.Background())
				require.NoError(t, err)
				// Best-effort fallback if an assertion exits before the explicit close below.
				defer func() { _ = held.Close() }()
				waits := d.Stats().WaitCount
				ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
				defer cancel()
				later := now.Add(time.Minute)
				done := make(chan error, 1)
				go func() {
					switch provider {
					case "codex_success":
						done <- d.PublishCodexPlanUsageContext(ctx, codexTestStatus(later, ""), nil)
					case "codex_failure":
						st := codexBefore
						st.State = "error"
						st.UpdatedAt = later
						done <- d.UpsertCodexPlanUsageStatusContext(ctx, st)
					case "claude_status":
						st := claudeBefore
						st.State = "error"
						st.UpdatedAt = later
						done <- d.UpsertPlanUsageStatusContext(ctx, st)
					case "claude_samples":
						done <- d.InsertPlanUsageSamplesContext(ctx, []PlanUsageSample{{LimitKey: "q", TakenAt: later, Percent: 90}})
					}
				}()
				err = <-done
				require.ErrorIs(t, err, context.DeadlineExceeded)
				require.Greater(t, d.Stats().WaitCount, waits, "publication actually waited on the DB connection")
				require.NoError(t, held.Close())
				codexAfter, err := d.GetCodexPlanUsageStatus()
				require.NoError(t, err)
				require.Equal(t, codexSaved, codexAfter)
				claudeAfter, err := d.GetPlanUsageStatus()
				require.NoError(t, err)
				require.Equal(t, claudeSaved, claudeAfter)
				var count int
				require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM plan_usage_samples`).Scan(&count))
				require.Zero(t, count)
			})
		})
	}
}

var planCancellationDriverID atomic.Uint64

func TestPlanUsage_ContextCancellationRollsBackStartedPublication(t *testing.T) {
	for _, provider := range []string{"codex_success", "codex_failure", "claude"} {
		t.Run(provider, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			var reached atomic.Bool
			driverName := fmt.Sprintf("plan-cancellation-%d", planCancellationDriverID.Add(1))
			sql.Register(driverName, &sqlcipher.SQLiteDriver{ConnectHook: func(conn *sqlcipher.SQLiteConn) error {
				return conn.RegisterFunc("cancel_plan_publication", func() int { reached.Store(true); cancel(); return 1 }, false)
			}})
			pool, err := sql.Open(driverName, filepath.Join(t.TempDir(), "cancellation.db")+immediateTxDSN)
			require.NoError(t, err)
			pool.SetMaxOpenConns(1)
			d := &DB{DB: pool}
			t.Cleanup(func() { _ = d.Close() })
			// Use the real production tables, with a test-only SQLite trigger that
			// cancels immediately after the status UPDATE has executed in the tx.
			for _, migration := range []string{"00115_plan_usage.sql", "00176_codex_plan_usage.sql"} {
				body, err := migrationsFS.ReadFile("migrations/" + migration)
				require.NoError(t, err)
				_, err = d.Exec(strings.Split(string(body), "-- +goose Down")[0])
				require.NoError(t, err)
			}
			now := time.Date(2026, 11, 2, 9, 0, 0, 0, time.UTC)
			require.NoError(t, d.PublishCodexPlanUsage(codexTestStatus(now, ""), nil))
			require.NoError(t, d.UpsertPlanUsageStatus(PlanUsageStatus{State: "ok", FetchedAt: &now, UpdatedAt: now, LimitsJSON: "[]", BreakdownJSON: "[]"}))
			codexBefore, err := d.GetCodexPlanUsageStatus()
			require.NoError(t, err)
			claudeBefore, err := d.GetPlanUsageStatus()
			require.NoError(t, err)
			table := "codex_plan_usage_status"
			if provider == "claude" {
				table = "plan_usage_status"
			}
			_, err = d.Exec("CREATE TRIGGER cancel_publication AFTER UPDATE ON " + table + " BEGIN SELECT cancel_plan_publication(); END;")
			require.NoError(t, err)
			later := now.Add(time.Minute)
			switch provider {
			case "codex_success":
				err = d.PublishCodexPlanUsageContext(ctx, codexTestStatus(later, ""), nil)
			case "codex_failure":
				st := *codexBefore
				st.State = "error"
				st.UpdatedAt = later
				err = d.UpsertCodexPlanUsageStatusContext(ctx, st)
			case "claude":
				st := *claudeBefore
				st.State = "error"
				st.UpdatedAt = later
				err = d.UpsertPlanUsageStatusContext(ctx, st)
			}
			require.True(t, reached.Load(), "the transaction reached its write before cancellation")
			require.Error(t, err)
			require.ErrorIs(t, ctx.Err(), context.Canceled)
			codexAfter, err := d.GetCodexPlanUsageStatus()
			require.NoError(t, err)
			require.Equal(t, codexBefore, codexAfter)
			claudeAfter, err := d.GetPlanUsageStatus()
			require.NoError(t, err)
			require.Equal(t, claudeBefore, claudeAfter)
		})
	}
}
