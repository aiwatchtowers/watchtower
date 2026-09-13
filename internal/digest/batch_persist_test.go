package digest

import (
	"bytes"
	"log"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// These tests cover C1: the batch digest prompt echoes the channel_id back
// from its own JSON example, which is written in bare form ("C123ABC"), but
// since migration 00048 every channelID inside a batchEntry is namespaced
// ("1:C123ABC"). persistBatchResults must resolve a model result against its
// batch entry by either form — namespaced (exact) or bare (via
// slack.SplitAccountID) — without ever matching a bare id that is ambiguous
// across two accounts in the same batch.

func newBatchTestPipeline(t *testing.T, logBuf *bytes.Buffer) (*Pipeline, *db.DB) {
	t.Helper()
	database := testDB(t)
	logger := testLogger()
	if logBuf != nil {
		logger = log.New(logBuf, "", 0)
	}
	p := New(database, testConfig(), &mockGenerator{}, logger)
	return p, database
}

func TestPersistBatchResults_BareChannelIDMatchesNamespacedEntry(t *testing.T) {
	var logBuf bytes.Buffer
	p, database := newBatchTestPipeline(t, &logBuf)
	seedChannel(t, database, "1:C1", "general")
	seedChannel(t, database, "1:C2", "random")

	batch := []batchEntry{
		{channelID: "1:C1", channelName: "general", since: 900, msgs: []db.Message{{TS: "1000.000100", TSUnix: 1000}}},
		{channelID: "1:C2", channelName: "random", since: 900, msgs: []db.Message{{TS: "1000.000200", TSUnix: 1000}}},
	}
	results := []BatchChannelResult{
		{ChannelID: "C1", Summary: "s1"},
		{ChannelID: "C2", Summary: "s2"},
	}

	agg := &batchAggregator{}
	saved := p.persistBatchResults(batch, results, nil, 0, agg)

	assert.Equal(t, 2, saved, "both bare-id results should resolve to their namespaced entry")
	digests, err := database.GetDigests(db.DigestFilter{Type: "channel"})
	require.NoError(t, err)
	assert.Len(t, digests, 2)
	assert.NotContains(t, logBuf.String(), "unknown channel")
}

func TestPersistBatchResults_NamespacedChannelIDStillMatches(t *testing.T) {
	p, database := newBatchTestPipeline(t, nil)
	seedChannel(t, database, "1:C1", "general")
	seedChannel(t, database, "1:C2", "random")

	batch := []batchEntry{
		{channelID: "1:C1", channelName: "general", since: 900, msgs: []db.Message{{TS: "1000.000100", TSUnix: 1000}}},
		{channelID: "1:C2", channelName: "random", since: 900, msgs: []db.Message{{TS: "1000.000200", TSUnix: 1000}}},
	}
	results := []BatchChannelResult{
		{ChannelID: "1:C1", Summary: "s1"},
		{ChannelID: "1:C2", Summary: "s2"},
	}

	agg := &batchAggregator{}
	saved := p.persistBatchResults(batch, results, nil, 0, agg)

	assert.Equal(t, 2, saved, "namespaced results should keep matching, as before")
	digests, err := database.GetDigests(db.DigestFilter{Type: "channel"})
	require.NoError(t, err)
	assert.Len(t, digests, 2)
}

func TestPersistBatchResults_AmbiguousBareIDAcrossAccountsSkipsBoth(t *testing.T) {
	var logBuf bytes.Buffer
	p, database := newBatchTestPipeline(t, &logBuf)
	seedChannel(t, database, "1:C1", "acct1-general")
	seedChannel(t, database, "2:C1", "acct2-general")

	batch := []batchEntry{
		{channelID: "1:C1", channelName: "acct1-general", since: 900, msgs: []db.Message{{TS: "1000.000100", TSUnix: 1000}}},
		{channelID: "2:C1", channelName: "acct2-general", since: 900, msgs: []db.Message{{TS: "1000.000200", TSUnix: 1000}}},
	}
	results := []BatchChannelResult{
		{ChannelID: "C1", Summary: "s1"},
	}

	agg := &batchAggregator{}

	require.NotPanics(t, func() {
		saved := p.persistBatchResults(batch, results, nil, 0, agg)
		assert.Equal(t, 0, saved, "an ambiguous bare id must not be matched to either account's entry")
	})

	digests, err := database.GetDigests(db.DigestFilter{Type: "channel"})
	require.NoError(t, err)
	assert.Len(t, digests, 0)

	logLines := strings.Count(logBuf.String(), "ambiguous")
	assert.Equal(t, 1, logLines, "exactly one ambiguity log line, not one per duplicate entry")
}

func TestPersistBatchResults_UnknownChannelIDSkipped(t *testing.T) {
	var logBuf bytes.Buffer
	p, database := newBatchTestPipeline(t, &logBuf)
	seedChannel(t, database, "1:C1", "general")

	batch := []batchEntry{
		{channelID: "1:C1", channelName: "general", since: 900, msgs: []db.Message{{TS: "1000.000100", TSUnix: 1000}}},
	}
	results := []BatchChannelResult{
		{ChannelID: "C_NOPE", Summary: "s1"},
	}

	agg := &batchAggregator{}
	saved := p.persistBatchResults(batch, results, nil, 0, agg)

	assert.Equal(t, 0, saved)
	digests, err := database.GetDigests(db.DigestFilter{Type: "channel"})
	require.NoError(t, err)
	assert.Len(t, digests, 0)
	assert.Contains(t, logBuf.String(), "unknown channel")
}
