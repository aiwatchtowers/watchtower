package daemon

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"watchtower/internal/digest"
	"watchtower/internal/historybackfill"
	"watchtower/internal/ideas"

	"github.com/stretchr/testify/require"
)

type historyProviderWait struct{}

func (historyProviderWait) Error() string          { return "provider cooldown" }
func (historyProviderWait) ProviderDeferred() bool { return true }
func (historyProviderWait) Unwrap() error          { return digest.ErrAICall }

type deferredHistoryGen struct {
	calls     int
	knownWait bool
	quota     bool
}

func (g *deferredHistoryGen) RoutingPreflight(context.Context) error {
	if g.knownWait {
		return historyProviderWait{}
	}
	return nil
}
func (g *deferredHistoryGen) Generate(context.Context, string, string, string) (string, *digest.Usage, string, error) {
	g.calls++
	if g.quota {
		return "", nil, "", historyProviderWait{}
	}
	return `{"topics":[]}`, nil, "", nil
}

func TestHistoryBackfillProviderDeferredDBState(t *testing.T) {
	for _, known := range []bool{true, false} {
		t.Run(fmt.Sprint(known), func(t *testing.T) {
			d, database, _ := newBackfillDaemon(t)
			d.config.Streams.Enabled = true
			now := time.Now().UTC().Truncate(time.Second)
			from, to := now.Add(-48*time.Hour), now.Add(-24*time.Hour)
			acct := seedGmailAccountForIdeas(t, database, "a@example.com")
			seedGmailMail(t, database, acct, "m1", "mail", from.Add(time.Hour))
			_, err := database.StartHistoryBackfill("gmail", acct, float64(from.Unix()), float64(to.Unix()), now)
			require.NoError(t, err)
			_, err = database.RecordHistoryBackfillFailure(1, "ordinary prior failure", now)
			require.NoError(t, err)
			require.NoError(t, database.HoldHistoryBackfill(1, "older transport hold", now.Add(-2*historybackfill.MaxHold)))
			g := &deferredHistoryGen{knownWait: known, quota: true}
			d.ideasPipe = ideas.New(database, d.config, g, d.logger)
			r := &historybackfill.Runner{Store: database, Sources: []historybackfill.Source{gmailSource{id: acct, d: d}}, Account: func(string, int64) historybackfill.AccountState { return historybackfill.AccountOK }, Budget: time.Minute, Now: func() time.Time { return now }}
			// The test source fetches independently; only Process needs a provider.
			r.Sources = []historybackfill.Source{historyProcessOnly{source: gmailSource{id: acct, d: d}}}
			before, err := database.ListHistoryBackfills()
			require.NoError(t, err)
			for range 4 {
				require.NoError(t, r.Step(context.Background()))
			}
			after, err := database.ListHistoryBackfills()
			require.NoError(t, err)
			require.Equal(t, before[0].ReachedTS, after[0].ReachedTS)
			require.Equal(t, before[0].ChunkFailures, after[0].ChunkFailures)
			require.True(t, before[0].HeldSince.Equal(*after[0].HeldSince))
			require.Equal(t, before[0].LastError, after[0].LastError)
			if known {
				require.Zero(t, g.calls)
			} else {
				require.Equal(t, 4, g.calls)
			}
			g.knownWait, g.quota = false, false
			require.NoError(t, r.Step(context.Background()))
			after, err = database.ListHistoryBackfills()
			require.NoError(t, err)
			require.Equal(t, "done", after[0].Status)
			require.Zero(t, after[0].ChunkFailures)
		})
	}
}

type historyProcessOnly struct{ source gmailSource }

func (s historyProcessOnly) Kind() string                                    { return s.source.Kind() }
func (s historyProcessOnly) AccountID() int64                                { return s.source.AccountID() }
func (historyProcessOnly) Fetch(context.Context, time.Time, time.Time) error { return nil }
func (s historyProcessOnly) Process(ctx context.Context, from, to time.Time) (bool, error) {
	return s.source.Process(ctx, from, to)
}

func TestBackfillMixedDeferredRetainsOrdinaryCause(t *testing.T) {
	material := errors.New("invalid material")
	wait := fmt.Errorf("deferred: %w", historyProviderWait{})
	for _, err := range []error{errors.Join(wait, material), fmt.Errorf("wrapped: %w", errors.Join(material, wait)), &digest.ChunkErrors{Errs: []error{wait, material}}} {
		got := backfillErr(err)
		require.ErrorIs(t, got, material)
		require.False(t, digest.ProviderDeferred(got))
		require.False(t, errors.Is(got, historybackfill.ErrHold), "%v", got)
	}
	require.True(t, digest.ProviderDeferred(backfillErr(wait)))
}

func TestStreamsProviderDeferredPreservesDueStamp(t *testing.T) {
	for _, known := range []bool{true, false} {
		t.Run(fmt.Sprint(known), func(t *testing.T) {
			d, database, _ := newBackfillDaemon(t)
			d.config.Streams.Enabled = true
			now := time.Now().UTC().Truncate(time.Second)
			acct := seedGmailAccountForIdeas(t, database, "a@example.com")
			seedGmailMail(t, database, acct, "m1", "mail", now.Add(-time.Hour))
			_, err := database.Exec(`UPDATE google_accounts SET ideas_email_floor=? WHERE id=?`, now.Add(-2*time.Hour).Unix(), acct)
			require.NoError(t, err)
			g := &deferredHistoryGen{knownWait: known, quota: true}
			d.ideasPipe = ideas.New(database, d.config, g, d.logger)
			old := now.Add(-48 * time.Hour)
			d.lastStreams = old
			d.saveLastStreams()
			prior, err := os.ReadFile(d.lastStreamsPath())
			require.NoError(t, err)
			d.phaseStreamDigests(context.Background())
			require.True(t, d.lastStreams.Equal(old))
			after, err := os.ReadFile(d.lastStreamsPath())
			require.NoError(t, err)
			require.Equal(t, string(prior), string(after))
			if known {
				require.Zero(t, g.calls)
			} else {
				require.Equal(t, 1, g.calls)
			}
			g.knownWait, g.quota = false, false
			d.phaseStreamDigests(context.Background())
			require.True(t, d.lastStreams.After(old))
		})
	}
}

type mixedStreamGen struct{}

func (mixedStreamGen) RoutingPreflight(context.Context) error { return nil }
func (mixedStreamGen) Generate(_ context.Context, _, user, _ string) (string, *digest.Usage, string, error) {
	if strings.Contains(user, "material-failure") {
		return "", nil, "", errors.New("invalid material retained")
	}
	return "", nil, "", historyProviderWait{}
}
func TestStreamsMixedDeferredRetainsOrdinaryThrottle(t *testing.T) {
	d, database, logs := newBackfillDaemon(t)
	d.config.Streams.Enabled = true
	now := time.Now().UTC()
	for _, body := range []string{"provider-wait", "material-failure"} {
		acct := seedGmailAccountForIdeas(t, database, body+"@example.com")
		_, err := database.Exec(`UPDATE google_accounts SET ideas_email_floor=? WHERE id=?`, now.Add(-2*time.Hour).Unix(), acct)
		require.NoError(t, err)
		seedGmailMail(t, database, acct, "m1", body, now.Add(-time.Hour))
	}
	old := now.Add(-48 * time.Hour)
	d.lastStreams = old
	d.ideasPipe = ideas.New(database, d.config, mixedStreamGen{}, d.logger)
	d.phaseStreamDigests(context.Background())
	require.True(t, d.lastStreams.After(old))
	require.Contains(t, logs.String(), "invalid material retained")
}
