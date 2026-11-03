package daemon

import (
	"bytes"
	"context"
	"fmt"
	"log"
	"os"
	"testing"
	"time"

	"watchtower/internal/digest"
	"watchtower/internal/guide"
	"watchtower/internal/providers"

	"github.com/stretchr/testify/require"
)

type preflightFailureGenerator struct {
	err   error
	calls int
}

func (g *preflightFailureGenerator) RoutingPreflight(context.Context) error { return g.err }
func (g *preflightFailureGenerator) Generate(context.Context, string, string, string) (string, *digest.Usage, string, error) {
	g.calls++
	return "", nil, "", g.err
}
func TestDaemon_PreflightOrdinaryFailuresAreObservableBeforeEligibility(t *testing.T) {
	for _, owner := range []string{"people", "rollup"} {
		for _, mode := range []string{"no-data", "budget", "throttle"} {
			if owner == "rollup" && mode == "throttle" {
				continue
			}
			for _, category := range []providers.ErrorCategory{providers.Policy, providers.Capability} {
				t.Run(fmt.Sprintf("%s/%s/%s", owner, mode, category), func(t *testing.T) {
					d, database := firstRunTestSetup(t)
					gen := &preflightFailureGenerator{err: &providers.Failure{Provider: "claude", Category: category}}
					var logs bytes.Buffer
					d.SetLogger(log.New(&logs, "", 0))
					attempts := 1
					if mode == "budget" {
						attempts = maxDailyAIAttempts
					}
					var path string
					if owner == "people" {
						d.SetPeoplePipeline(guide.New(database, d.config, gen, d.logger))
						path = d.peopleAttemptsPath()
					} else {
						d.SetDigestPipeline(digest.New(database, d.config, gen, d.logger))
						path = d.rollupAttemptsPath()
					}
					date := time.Now().Format("2006-01-02")
					if owner == "rollup" {
						date = rollupBudgetDate(time.Now())
					}
					require.NoError(t, saveAttemptMarker(path, attemptMarker{date: date, attempts: attempts}))
					before, err := os.ReadFile(path)
					require.NoError(t, err)
					if owner == "people" {
						d.loadPeopleAttempts()
						if mode == "throttle" {
							d.lastPeople = time.Now()
						}
						previous := d.lastPeople
						d.phasePeopleCards(context.Background())
						require.Equal(t, previous, d.lastPeople)
						require.Equal(t, attempts, d.peopleAttempts)
					} else {
						d.loadRollupAttempts()
						d.runRollupPhase(context.Background(), time.Now())
						require.Equal(t, attempts, d.rollupAttempts)
					}
					after, err := os.ReadFile(path)
					require.NoError(t, err)
					require.Equal(t, before, after)
					require.Zero(t, gen.calls)
					require.Contains(t, logs.String(), string(category), "ordinary metadata failure must not disappear behind an eligibility gate")
					var rows int
					require.NoError(t, database.QueryRow("SELECT count(*) FROM pipeline_runs").Scan(&rows))
					require.Zero(t, rows)
				})
			}
		}
	}
}
func TestDaemon_PreflightExpectedCancellationIsBenign(t *testing.T) {
	d, database := firstRunTestSetup(t)
	gen := &preflightFailureGenerator{err: context.Canceled}
	var logs bytes.Buffer
	d.SetLogger(log.New(&logs, "", 0))
	d.SetPeoplePipeline(guide.New(database, d.config, gen, d.logger))
	d.SetDigestPipeline(digest.New(database, d.config, gen, d.logger))
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	d.phasePeopleCards(ctx)
	d.runRollupPhase(ctx, time.Now())
	require.Empty(t, logs.String())
	require.Zero(t, gen.calls)
	require.Zero(t, d.peopleAttempts)
	require.Zero(t, d.rollupAttempts)
}
