package guide

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"testing"
	"time"
	"watchtower/internal/digest"
	"watchtower/internal/providerrouting"

	"github.com/stretchr/testify/require"
)

func TestPeopleQuotaDoesNotCreateFallbackCard(t *testing.T) {
	for _, messages := range []int{4, 12} {
		t.Run(fmt.Sprintf("messages=%d", messages), func(t *testing.T) {
			for _, tc := range []struct {
				err      error
				deferred bool
			}{{&providerrouting.Deferred{Provider: "claude", Attempts: 1}, true}, {digest.ErrAICall, false}} {
				database := testDB(t)
				seedUser(t, database, "U1", "member")
				seedChannel(t, database, "C1", "general")
				now := time.Now()
				for i := range messages {
					seedMessage(t, database, "C1", fmt.Sprintf("%d.000000", now.Add(time.Duration(i-20)*time.Minute).Unix()), "U1", "message")
				}
				gen := &mockGenerator{err: tc.err}
				var generator digest.Generator = gen
				if !tc.deferred {
					generator = routedPeopleMock{gen}
				}
				pipe := New(database, testConfig(), generator, testLogger())
				pipe.ForceRegenerate = true
				n, err := pipe.RunForWindow(context.Background(), float64(now.Add(-time.Hour).Unix()), float64(now.Unix()))
				require.Error(t, err)
				if tc.deferred {
					require.True(t, digest.ProviderDeferred(err))
					require.Zero(t, n)
				}
				card, cardErr := database.GetLatestPeopleCard("U1")
				require.NoError(t, cardErr)
				if tc.deferred || messages >= MinSituationMessages {
					require.Nil(t, card)
				}
				require.EqualValues(t, 1, gen.calls.Load(), "provider unavailability must never start individual quality retries")
			}
		})
	}
}

type routedPeopleMock struct{ *mockGenerator }

func (routedPeopleMock) RoutingPreflight(context.Context) error { return nil }

type resumablePeopleGenerator struct {
	calls    int
	failAt   int
	response string
	batches  []string
}

func (g *resumablePeopleGenerator) RoutingPreflight(context.Context) error { return nil }
func (g *resumablePeopleGenerator) Generate(ctx context.Context, system, user, _ string) (string, *digest.Usage, string, error) {
	source, _ := digest.SourceFromContext(ctx)
	if source != "people.batch" {
		return `{"summary":"team"}`, nil, "", nil
	}
	g.calls++
	g.batches = append(g.batches, system+user)
	if g.calls == g.failAt {
		return "", nil, "", &providerrouting.Deferred{Provider: "claude", Attempts: 1}
	}
	return g.response, nil, "", nil
}

func TestScheduledPeopleRetryRestartKeepsWindowAndCommittedUsers(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()
	t.Setenv("HOME", t.TempDir())
	require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o700))
	seedChannel(t, database, "C1", "general")
	// A first-run window ending before yesterday's midnight crosses both a
	// restart and a calendar boundary before the remaining batch is attempted.
	to := float64(time.Now().AddDate(0, 0, -2).Unix())
	from := to - 7*86400
	var results []BatchCardResult
	for u := range 11 {
		id := fmt.Sprintf("U%02d", u)
		seedUser(t, database, id, id)
		for i := range 4 {
			seedMessage(t, database, "C1", fmt.Sprintf("%.6f", to-3600+float64(u*10+i)), id, "message")
		}
		results = append(results, BatchCardResult{UserID: id, Summary: "summary"})
	}
	seedDigestWithSituations(t, database, "C1", from, to, "[]", `[{"topic":"work","type":"collaboration","participants":[{"user_id":"U00","role":"lead"}],"dynamic":"worked","outcome":"done"}]`)
	response, err := json.Marshal(results)
	require.NoError(t, err)
	first := &resumablePeopleGenerator{response: string(response), failAt: 2}
	p := New(database, cfg, first, testLogger())
	p.FirstRun = true
	p.DeferredSchedule = true
	started := time.Unix(int64(to), 0)
	data, err := json.Marshal(peopleWindow{from, to, started})
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(p.windowPath(), data, 0o600))
	n, err := p.Run(context.Background())
	require.True(t, digest.ProviderDeferred(err))
	require.Equal(t, 10, n)
	require.Equal(t, OutcomeDeferred, p.LastOutcome())
	var count int
	require.NoError(t, database.QueryRow("SELECT count(*) FROM people_cards").Scan(&count))
	require.Equal(t, 10, count)
	second := &resumablePeopleGenerator{response: string(response)}
	resumed := New(database, cfg, second, testLogger())
	resumed.FirstRun = true
	resumed.DeferredSchedule = true
	n, err = resumed.Run(context.Background())
	require.NoError(t, err)
	require.Equal(t, 1, n)
	require.Equal(t, 1, second.calls)
	require.Equal(t, started, resumed.RunStartedAt)
	require.NoError(t, database.QueryRow("SELECT count(*) FROM people_cards WHERE period_from=? AND period_to=?", from, to).Scan(&count))
	require.Equal(t, 11, count)
	// Crash after the final card but before the daemon's success stamp/ack:
	// the descriptor still exists and a fresh pipeline makes no more AI call.
	third := &resumablePeopleGenerator{response: string(response)}
	crashed := New(database, cfg, third, testLogger())
	crashed.DeferredSchedule = true
	n, err = crashed.Run(context.Background())
	require.NoError(t, err)
	require.Zero(t, n)
	require.Equal(t, OutcomeCovered, crashed.LastOutcome())
	require.Zero(t, third.calls)
	require.NoError(t, crashed.AcknowledgeWindow())
	_, err = os.Stat(crashed.windowPath())
	require.ErrorIs(t, err, os.ErrNotExist)
	nextFrom, nextTo, _, err := crashed.scheduledWindow(false)
	require.NoError(t, err)
	require.Greater(t, nextFrom, from)
	require.Greater(t, nextTo, to)
}

func TestLegacyPeopleUnavailableKeepsIndividualFallback(t *testing.T) {
	database := testDB(t)
	seedUser(t, database, "U1", "member")
	seedChannel(t, database, "C1", "general")
	now := time.Now()
	for i := range 12 {
		seedMessage(t, database, "C1", fmt.Sprintf("%d.000000", now.Add(time.Duration(i-20)*time.Minute).Unix()), "U1", "message")
	}
	gen := &mockGenerator{err: digest.ErrAICall}
	p := New(database, testConfig(), gen, testLogger())
	p.ForceRegenerate = true
	_, err := p.RunForWindow(context.Background(), float64(now.Add(-time.Hour).Unix()), float64(now.Unix()))
	require.Error(t, err)
	require.EqualValues(t, 2, gen.calls.Load(), "off/pinned legacy batch-to-individual cadence stays unchanged")
}

type mixedPeopleFailures struct {
	calls    int
	material error
}

func (g *mixedPeopleFailures) Generate(context.Context, string, string, string) (string, *digest.Usage, string, error) {
	g.calls++
	if g.calls == 1 {
		return "", nil, "", g.material
	}
	return "", nil, "", &providerrouting.Deferred{Provider: "claude", Attempts: 1}
}
func TestPeopleMixedMaterialAndQuotaPreservesOriginalFailure(t *testing.T) {
	database := testDB(t)
	seedChannel(t, database, "C1", "general")
	now := time.Now()
	for u := range 11 {
		id := fmt.Sprintf("U%02d", u)
		seedUser(t, database, id, id)
		for i := range 4 {
			seedMessage(t, database, "C1", fmt.Sprintf("%d.000000", now.Add(time.Duration(u*4+i-100)*time.Minute).Unix()), id, "message")
		}
	}
	material := errors.New("invalid material")
	gen := &mixedPeopleFailures{material: material}
	p := New(database, testConfig(), gen, testLogger())
	p.ForceRegenerate = true
	_, err := p.RunForWindow(context.Background(), float64(now.Add(-24*time.Hour).Unix()), float64(now.Unix()))
	require.ErrorIs(t, err, material, "an ordinary failure must survive a later quota")
	require.False(t, digest.ProviderDeferred(err), "mixed input failure must retain ordinary attempt policy")
	var deferred *providerrouting.Deferred
	require.ErrorAs(t, err, &deferred)
	require.Equal(t, 2, gen.calls)
}

func TestPeopleInvalidPendingBoundsRemainErrorsAndPreserveDescriptor(t *testing.T) {
	for _, bounds := range []string{`"To":2000000000`, `"From":-1,"To":2000000000`, `"From":0,"To":2000000000`, `"From":1,"To":0`, `"From":-2,"To":-1`} {
		t.Run(bounds, func(t *testing.T) {
			database := testDB(t)
			cfg := testConfig()
			t.Setenv("HOME", t.TempDir())
			require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o700))
			gen := &resumablePeopleGenerator{}
			p := New(database, cfg, gen, testLogger())
			p.DeferredSchedule = true
			data := []byte(`{` + bounds + `,"StartedAt":"2030-01-01T00:00:00Z"}`)
			require.NoError(t, os.WriteFile(p.windowPath(), data, 0o600))
			_, err := p.HasData()
			require.Error(t, err, "invalid bounds must not become benign no-data that the daemon acknowledges")
			_, err = p.Run(context.Background())
			require.Error(t, err)
			require.Zero(t, gen.calls)
			after, err := os.ReadFile(p.windowPath())
			require.NoError(t, err)
			require.Equal(t, data, after)
		})
	}
}

func TestPeoplePendingFutureStartedAtIsNotRejectedForClockSkew(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()
	t.Setenv("HOME", t.TempDir())
	require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o700))
	p := New(database, cfg, &resumablePeopleGenerator{}, testLogger())
	p.DeferredSchedule = true
	future := time.Now().AddDate(1, 0, 0)
	data, err := json.Marshal(peopleWindow{From: 1, To: 2, StartedAt: future})
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(p.windowPath(), data, 0o600))
	from, to, started, err := p.scheduledWindow(false)
	require.NoError(t, err)
	require.EqualValues(t, 1, from)
	require.EqualValues(t, 2, to)
	require.True(t, started.Equal(future))
}
