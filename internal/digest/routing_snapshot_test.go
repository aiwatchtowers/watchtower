package digest

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

type snapshotTestKey struct{}
type snapshotTestGenerator struct{ current Generator }

func (g *snapshotTestGenerator) GeneratorForContext(ctx context.Context) Generator {
	if selected, ok := ctx.Value(snapshotTestKey{}).(Generator); ok {
		return selected
	}
	return g.current
}
func (g *snapshotTestGenerator) Generate(ctx context.Context, system, user, session string) (string, *Usage, string, error) {
	return g.GeneratorForContext(ctx).Generate(ctx, system, user, session)
}

func TestRoutingSnapshotPreservesDeferredCompletionAcrossDisableAndEnable(t *testing.T) {
	database := testDB(t)
	seedUser(t, database, "U1", "alice", "Alice")
	seedChannel(t, database, "1:C1", "alpha")
	seedChannel(t, database, "1:C2", "beta")
	from, to := backfillRange()
	seedRangeMessages(t, database, "1:C1", "declined", from+3600, 4)
	seedRangeMessages(t, database, "1:C2", "declined", from+7200, 4)
	enabled := &historyDecliningGenerator{}
	disabled := &promptCapturingGenerator{responses: map[string]string{"digest.channel_batch": "[]", "digest.channel": validDigestJSON()}}
	dispatcher := &snapshotTestGenerator{current: enabled}
	old := context.WithValue(context.Background(), snapshotTestKey{}, Generator(enabled))
	off := context.WithValue(context.Background(), snapshotTestKey{}, Generator(disabled))
	nested := WithCallTimeout(NewPooledGenerator(dispatcher, nil), time.Second)
	// The nested pooled wrapper is only inspected, never invoked with a nil pool.
	require.True(t, RoutingEnabled(nested, old))
	require.False(t, RoutingEnabled(nested, off))
	dispatcher.current = disabled
	p := backfillPipeline(t, database, dispatcher)
	result, _, err := p.RunBackfillWindow(old, 1, from, to)
	require.NoError(t, err)
	require.True(t, result.Complete)
	marks, err := database.HistoryBackfillConsidered(1, from, to)
	require.NoError(t, err)
	require.NotEmpty(t, marks, "old enabled job must commit its declined completion receipt after disable")
	require.Len(t, enabled.prompts, 1)
	result, _, err = p.RunBackfillWindow(old, 1, from, to)
	require.NoError(t, err)
	require.True(t, result.Complete)
	require.Len(t, enabled.prompts, 1, "receipt prevents already committed AI work from replaying")
	dispatcher.current = enabled
	require.False(t, RoutingEnabled(dispatcher, off), "a captured off job cannot gain durable semantics after enable")
	_, _, err = p.RunBackfillWindow(off, 1, from, to)
	require.NoError(t, err)
	require.NotEmpty(t, disabled.prompts, "off preserves its legacy path instead of claiming old enabled receipts")
	enabled.waiting = true
	require.True(t, ProviderDeferred(Preflight(old, dispatcher)))
	require.NoError(t, Preflight(off, dispatcher))
}
