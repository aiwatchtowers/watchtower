package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log"
	"os"
	"path/filepath"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/planusage"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func runUsagePlansCmd(t *testing.T, args ...string) (planusage.Envelope, string, error) {
	t.Helper()
	var out, stderr bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&stderr)
	rootCmd.SetArgs(append([]string{"usage", "plans"}, args...))
	err := rootCmd.Execute()
	t.Cleanup(func() {
		rootCmd.SetArgs(nil)
		flagUsagePlansNow = false
		flagUsagePlansJSON = false
		flagUsagePlansProvider = "all"
		rootCmd.SetOut(nil)
		rootCmd.SetErr(nil)
	})
	var e planusage.Envelope
	if out.Len() > 0 {
		require.NoError(t, json.Unmarshal(out.Bytes(), &e), out.String())
	}
	return e, out.String(), err
}

func plansCommandCode(err error) int {
	if err == nil {
		return 0
	}
	var ec *exitCodeError
	if errors.As(err, &ec) {
		return ec.code
	}
	return 1
}

func TestUsagePlans_InvalidArgsBeforeIO(t *testing.T) {
	for _, args := range [][]string{{"--provider", "bogus"}, {"extra"}, {"--bad-flag"}} {
		t.Run(args[0], func(t *testing.T) {
			previous := flagConfig
			flagConfig = filepath.Join(t.TempDir(), "missing-config")
			t.Cleanup(func() { flagConfig = previous })
			oldOpen := openPlansDB
			openPlansDB = func(context.Context, string, bool) (*db.DB, error) {
				t.Fatal("invalid args opened DB")
				return nil, nil
			}
			t.Cleanup(func() { openPlansDB = oldOpen })
			_, out, err := runUsagePlansCmd(t, args...)
			require.Equal(t, 2, plansCommandCode(err))
			require.Empty(t, out)
			_, statErr := os.Stat(flagConfig)
			require.True(t, os.IsNotExist(statErr))
		})
	}
}

func TestUsagePlans_ReadOnlyNoMigrationsOrCreate(t *testing.T) {
	for _, enabled := range []bool{true, false} {
		for _, refresh := range []bool{false, true} {
			if enabled && refresh {
				continue
			}
			t.Run(fmtBool(enabled)+fmtBool(refresh), func(t *testing.T) {
				t.Setenv("HOME", t.TempDir())
				path := filepath.Join(t.TempDir(), "config.yaml")
				cfgText := []byte("active_workspace: test\ndb:\n  schema_format: 0\nplan_usage:\n  enabled: " + fmtBool(enabled) + "\n")
				require.NoError(t, os.WriteFile(path, cfgText, 0600))
				previous := flagConfig
				flagConfig = path
				t.Cleanup(func() { flagConfig = previous })
				oldProviders := plansProviders
				plansProviders = func(*db.DB, *config.Config, *log.Logger) planusage.Providers {
					t.Fatal("read/off invoked sources")
					return nil
				}
				t.Cleanup(func() { plansProviders = oldProviders })
				args := []string{"--json"}
				if refresh {
					args = append(args, "--now")
				}
				e, _, err := runUsagePlansCmd(t, args...)
				want := 1
				if refresh {
					want = 3
				}
				require.Equal(t, want, plansCommandCode(err))
				require.Len(t, e.Providers, 2)
				require.Equal(t, enabled, e.FeatureEnabled)
				after, err := os.ReadFile(path)
				require.NoError(t, err)
				assert.Equal(t, cfgText, after, "root schema hook did not rewrite config")
				cfg, err := config.Load(path)
				require.NoError(t, err)
				_, err = os.Stat(cfg.DBPath())
				require.True(t, os.IsNotExist(err), "no DB created")
			})
		}
	}
}

func fmtBool(v bool) string {
	if v {
		return "true"
	}
	return "false"
}

func TestUsagePlans_ReadStatusSelectionAndLocalProvider(t *testing.T) {
	d := writeActionsConfig(t)
	now := time.Now().UTC().Truncate(time.Second)
	require.NoError(t, d.UpsertPlanUsageStatus(db.PlanUsageStatus{State: "unavailable", Reason: "no_credentials", UpdatedAt: now, LimitsJSON: "[]", BreakdownJSON: "[]"}))
	before, err := os.ReadFile(flagConfig)
	require.NoError(t, err)
	oldProvider := flagProvider
	flagProvider = "ollama"
	t.Cleanup(func() { flagProvider = oldProvider })
	e, _, err := runUsagePlansCmd(t, "--json", "--provider", "claude")
	require.NoError(t, err)
	require.Len(t, e.Providers, 1)
	require.True(t, e.Providers[0].OK)
	require.Equal(t, "not_requested", e.Providers[0].RefreshOutcome)
	require.NotNil(t, e.Providers[0].Status)
	require.Equal(t, "unavailable", e.Providers[0].Status.State)
	require.Equal(t, "ollama", flagProvider, "local selector does not alter AI provider")
	after, err := os.ReadFile(flagConfig)
	require.NoError(t, err)
	require.Equal(t, before, after)
	_, err = d.Exec(`DROP TABLE codex_plan_usage_status`)
	require.NoError(t, err)
	// Reset selector before the second direct command invocation.
	flagUsagePlansProvider = "all"
	e, _, err = runUsagePlansCmd(t, "--json")
	require.Equal(t, 1, plansCommandCode(err))
	require.Len(t, e.Providers, 2)
	require.True(t, e.Providers[0].OK)
	require.False(t, e.Providers[1].OK)
	require.Nil(t, e.Providers[1].Status)
	require.Equal(t, "storage", e.Providers[1].Error.Code)
	var count int
	err = d.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='codex_plan_usage_status'`).Scan(&count)
	require.NoError(t, err)
	require.Zero(t, count, "read did not migrate missing table")
}

func TestUsagePlans_RefreshProvidersParallelPartial(t *testing.T) {
	writeActionsConfig(t)
	old := plansProviders
	var calls atomic.Int32
	started := make(chan string, 2)
	release := make(chan struct{})
	plansProviders = func(_ *db.DB, cfg *config.Config, _ *log.Logger) planusage.Providers {
		result := planusage.Providers{}
		for _, name := range []string{"claude", "codex"} {
			result = append(result, &planusage.Provider{Name: name, Workspace: cfg.WorkspaceDir(), Poll: func(context.Context) (time.Duration, error) {
				calls.Add(1)
				started <- name
				<-release
				if name == "codex" {
					return time.Minute, &planusage.OperationError{Code: "network"}
				}
				return time.Minute, nil
			}})
		}
		return result
	}
	t.Cleanup(func() { plansProviders = old })
	released := make(chan struct{})
	go func() {
		a, b := <-started, <-started
		if a != b {
			close(release)
		}
		close(released)
	}()
	e, _, err := runUsagePlansCmd(t, "--json", "--now")
	<-released
	require.Equal(t, int32(2), calls.Load())
	require.Equal(t, 1, plansCommandCode(err))
	require.True(t, e.Providers[0].OK)
	require.False(t, e.Providers[1].OK)
	require.Equal(t, "network", e.Providers[1].Error.Code)
}

func TestUsagePlans_SignalPriorityOverDisabledAndStorage(t *testing.T) {
	// A signal for the remaining provider must preserve a completed failure.
	partial := planusage.Envelope{Providers: []planusage.ProviderResult{
		{Provider: "claude", OK: false, RefreshOutcome: "failed", Error: &planusage.PublicError{Code: "network", Message: "Plan usage: network."}},
		{Provider: "codex", OK: false, RefreshOutcome: "cancelled", Error: &planusage.PublicError{Code: "cancelled", Message: "Plan usage: cancelled."}},
	}}
	maskPlansCancellation(&partial, false)
	require.Equal(t, "network", partial.Providers[0].Error.Code)
	require.Equal(t, "failed", partial.Providers[0].RefreshOutcome)
	require.Equal(t, "cancelled", partial.Providers[1].Error.Code)
	for _, sig := range []syscall.Signal{syscall.SIGINT, syscall.SIGTERM} {
		t.Run(sig.String(), func(t *testing.T) {
			writeActionsConfig(t)
			require.NoError(t, os.WriteFile(flagConfig, []byte("active_workspace: test\nplan_usage:\n  enabled: false\n"), 0600))
			started := make(chan struct{})
			old := openPlansDB
			openPlansDB = func(ctx context.Context, _ string, write bool) (*db.DB, error) {
				if write {
					return nil, errors.New("disabled request attempted writer")
				}
				close(started)
				<-ctx.Done()
				return nil, errors.New("retained storage failure")
			}
			t.Cleanup(func() { openPlansDB = old; flagUsagePlansNow = false; flagUsagePlansProvider = "all" })
			flagUsagePlansNow = true
			flagUsagePlansProvider = "all"
			var out bytes.Buffer
			command := &cobra.Command{}
			command.SetContext(context.Background())
			command.SetOut(&out)
			finished := make(chan error, 1)
			go func() { finished <- runUsagePlans(command, nil) }()
			<-started
			require.NoError(t, syscall.Kill(os.Getpid(), sig))
			err := <-finished // the signal finishes the plans command
			require.Equal(t, 128+int(sig), plansCommandCode(err))
			var e planusage.Envelope
			require.NoError(t, json.Unmarshal(out.Bytes(), &e))
			require.False(t, e.FeatureEnabled)
			require.Len(t, e.Providers, 2)
			for _, p := range e.Providers {
				require.False(t, p.OK)
				require.Nil(t, p.Status)
				require.Equal(t, "cancelled", p.Error.Code)
				require.Equal(t, "cancelled", p.RefreshOutcome)
			}
		})
	}
}
