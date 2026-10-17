package reactioncmd

import (
	"context"
	"encoding/json"
	"sync"
	"testing"

	"github.com/slack-go/slack"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/config"
	"watchtower/internal/db"
)

// recordingSink is an EventSink that records every published event.
type recordingSink struct {
	wants  bool
	events []automations.Event
}

func (s *recordingSink) Wants(eventType string) bool {
	return s.wants && eventType == automations.SlackReactionAdded
}

func (s *recordingSink) Publish(events ...automations.Event) {
	s.events = append(s.events, events...)
}

// countingLister is a lister whose items can change between polls and that
// counts its reactions.list calls.
type countingLister struct {
	mu    sync.Mutex
	items []slack.ReactedItem
	calls int
}

func (l *countingLister) ListUserReactions(context.Context, string) ([]slack.ReactedItem, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.calls++
	return l.items, nil
}

func (l *countingLister) set(items ...slack.ReactedItem) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.items = items
}

// eventTestPipeline builds a pipeline over account 1 (label "acme") reading
// from lister, with the reaction-commands ledger already seeded.
func eventTestPipeline(t *testing.T, lister *countingLister, gen *mockGenerator) (*Pipeline, *db.DB) {
	t.Helper()
	database := seededPipelineDB(t, 1)
	_, err := database.Exec(`UPDATE slack_accounts SET label = 'acme' WHERE id = 1`)
	require.NoError(t, err)
	// eyes is a default dictionary emoji; these tests use it as a plain,
	// non-dictionary reaction.
	_, err = database.Exec(`DELETE FROM reaction_command_map WHERE emoji = 'eyes'`)
	require.NoError(t, err)
	if gen == nil {
		gen = &mockGenerator{}
	}
	accountsFn := func(context.Context) ([]Account, error) {
		return []Account{{AccountID: 1, OwnerID: "1:UOWNER", Lister: lister}}, nil
	}
	return New(database, &config.Config{}, gen, newTestRegistry(t, database), accountsFn, nil), database
}

func clearDictionary(t *testing.T, database *db.DB) {
	t.Helper()
	_, err := database.Exec(`DELETE FROM reaction_command_map`)
	require.NoError(t, err)
}

func eyesItem(ts string) slack.ReactedItem {
	return msgItem("C1", ts, "UAUTHOR", "look at this", "",
		slack.ItemReaction{Name: "eyes", Users: []string{"UOWNER"}})
}

// seedEvents runs one wanted poll over the current items, which seeds the
// event ledger without publishing.
func seedEvents(t *testing.T, p *Pipeline) {
	t.Helper()
	sink := &recordingSink{wants: true}
	_, err := p.Run(context.Background(), sink)
	require.NoError(t, err)
	require.Empty(t, sink.events, "the seeding poll publishes nothing")
}

func TestRun_PublishesNewOwnerReaction(t *testing.T) {
	lister := &countingLister{}
	p, database := eventTestPipeline(t, lister, nil)
	seedEvents(t, p)

	lister.set(eyesItem("111.1"))
	sink := &recordingSink{wants: true}
	n, err := p.Run(context.Background(), sink)
	require.NoError(t, err)
	assert.Zero(t, n, "an event is not a tool dispatch")
	require.Len(t, sink.events, 1)
	assert.Equal(t, automations.ReactionEvent("acme", "1:C1", "111.1", "eyes"), sink.events[0])
	assert.Equal(t, 0, countRows(t, database, "reaction_commands"))
}

func TestRun_SecondPollPublishesNothing(t *testing.T) {
	lister := &countingLister{}
	p, _ := eventTestPipeline(t, lister, nil)
	seedEvents(t, p)

	lister.set(eyesItem("111.1"))
	first := &recordingSink{wants: true}
	_, err := p.Run(context.Background(), first)
	require.NoError(t, err)
	require.Len(t, first.events, 1)

	second := &recordingSink{wants: true}
	_, err = p.Run(context.Background(), second)
	require.NoError(t, err)
	assert.Empty(t, second.events)
}

func TestRun_ReReactSameMessageDoesNotFireAgain(t *testing.T) {
	lister := &countingLister{}
	p, _ := eventTestPipeline(t, lister, nil)
	seedEvents(t, p)

	lister.set(eyesItem("111.1"))
	sink := &recordingSink{wants: true}
	_, err := p.Run(context.Background(), sink)
	require.NoError(t, err)
	require.Len(t, sink.events, 1)

	lister.set() // the owner removed the reaction
	_, err = p.Run(context.Background(), sink)
	require.NoError(t, err)

	lister.set(eyesItem("111.1")) // and placed it again
	_, err = p.Run(context.Background(), sink)
	require.NoError(t, err)
	assert.Len(t, sink.events, 1, "re-reacting the same message does not fire again")
}

func TestRun_FirstWantedPollSeedsWithoutPublishing(t *testing.T) {
	lister := &countingLister{}
	lister.set(eyesItem("111.1"), eyesItem("222.2"))
	p, database := eventTestPipeline(t, lister, nil)

	sink := &recordingSink{wants: true}
	_, err := p.Run(context.Background(), sink)
	require.NoError(t, err)
	assert.Empty(t, sink.events)
	seeded, err := database.ReactionEventsSeeded(1)
	require.NoError(t, err)
	assert.True(t, seeded)
	assert.Equal(t, 2, countRows(t, database, "reaction_events"))

	_, err = p.Run(context.Background(), sink)
	require.NoError(t, err)
	assert.Empty(t, sink.events, "the seeded reactions never fire")
}

func TestRun_ResetWhileNobodyListensThenReseeds(t *testing.T) {
	lister := &countingLister{}
	p, database := eventTestPipeline(t, lister, nil)
	seedEvents(t, p)

	_, err := p.Run(context.Background(), &recordingSink{wants: false})
	require.NoError(t, err)
	seeded, err := database.ReactionEventsSeeded(1)
	require.NoError(t, err)
	assert.False(t, seeded, "a poll nobody listens to clears the stamp")

	lister.set(eyesItem("111.1")) // placed while nobody listened
	sink := &recordingSink{wants: true}
	_, err = p.Run(context.Background(), sink)
	require.NoError(t, err)
	assert.Empty(t, sink.events, "the next wanted poll reseeds instead of firing")

	_, err = p.Run(context.Background(), sink)
	require.NoError(t, err)
	assert.Empty(t, sink.events)
}

type commandRow struct {
	ChannelID, MessageTS, Emoji, Status, Error string
	ActionTool                                 string
}

func readCommandRows(t *testing.T, database *db.DB) []commandRow {
	t.Helper()
	rows, err := database.Query(`SELECT r.channel_id, r.message_ts, r.emoji, r.status, r.error, COALESCE(a.tool, '')
		FROM reaction_commands r LEFT JOIN agent_actions a ON a.id = r.action_id ORDER BY r.id`)
	require.NoError(t, err)
	defer rows.Close()
	var out []commandRow
	for rows.Next() {
		var r commandRow
		require.NoError(t, rows.Scan(&r.ChannelID, &r.MessageTS, &r.Emoji, &r.Status, &r.Error, &r.ActionTool))
		out = append(out, r)
	}
	require.NoError(t, rows.Err())
	return out
}

func TestRun_DictionaryEmojiAlsoSubscribed(t *testing.T) {
	item := msgItem("C1", "111.1", "UAUTHOR", "please handle the deploy", "",
		slack.ItemReaction{Name: "white_check_mark", Users: []string{"UOWNER"}})
	out := `{"text":"Handle the deploy","reason":"owner flagged it"}`

	// The dictionary-only run.
	baseLister := &countingLister{}
	baseLister.set(item)
	baseGen := &mockGenerator{out: out}
	base, baseDB := eventTestPipeline(t, baseLister, baseGen)
	n, err := base.Run(context.Background(), nil)
	require.NoError(t, err)
	require.Equal(t, 1, n)
	want := readCommandRows(t, baseDB)

	// The same reaction with a subscriber.
	lister := &countingLister{}
	gen := &mockGenerator{out: out}
	p, database := eventTestPipeline(t, lister, gen)
	seedEvents(t, p)
	before := lister.calls
	lister.set(item)
	sink := &recordingSink{wants: true}
	n, err = p.Run(context.Background(), sink)
	require.NoError(t, err)
	assert.Equal(t, 1, n, "the tool is dispatched exactly once")
	assert.Equal(t, 1, gen.calls)
	assert.Equal(t, want, readCommandRows(t, database), "the ledger row equals the dictionary-only run's")
	require.Len(t, sink.events, 1)
	assert.Equal(t, automations.ReactionEvent("acme", "1:C1", "111.1", "white_check_mark"), sink.events[0])
	assert.Equal(t, 1, lister.calls-before, "one reactions.list call per poll, shared by both paths")
}

func TestRun_NoSubscriberEmptyDictionaryNoListCall(t *testing.T) {
	lister := &countingLister{}
	lister.set(eyesItem("111.1"))
	p, database := eventTestPipeline(t, lister, nil)
	clearDictionary(t, database)

	_, err := p.Run(context.Background(), &recordingSink{wants: false})
	require.NoError(t, err)
	_, err = p.Run(context.Background(), nil)
	require.NoError(t, err)
	assert.Zero(t, lister.calls)
}

func TestRun_EmptyDictionaryStillPublishes(t *testing.T) {
	lister := &countingLister{}
	p, database := eventTestPipeline(t, lister, nil)
	clearDictionary(t, database)
	seedEvents(t, p)

	lister.set(eyesItem("111.1"))
	sink := &recordingSink{wants: true}
	_, err := p.Run(context.Background(), sink)
	require.NoError(t, err)
	assert.Len(t, sink.events, 1)
}

func TestRun_NilSinkKeepsTodayBehaviour(t *testing.T) {
	lister := &countingLister{}
	lister.set(eyesItem("111.1"))
	p, database := eventTestPipeline(t, lister, nil)

	n, err := p.Run(context.Background(), nil)
	require.NoError(t, err)
	assert.Zero(t, n)
	assert.Equal(t, 0, countRows(t, database, "reaction_events"), "no subscriber, no event ledger writes")
	seeded, err := database.ReactionEventsSeeded(1)
	require.NoError(t, err)
	assert.False(t, seeded)
}

func TestRun_EventCarriesNoText(t *testing.T) {
	const marker = "SECRET-MARKER-7f3a"
	lister := &countingLister{}
	p, _ := eventTestPipeline(t, lister, nil)
	seedEvents(t, p)

	lister.set(msgItem("C1", "111.1", "UAUTHOR", "text "+marker, "",
		slack.ItemReaction{Name: "eyes", Users: []string{"UOWNER"}}))
	sink := &recordingSink{wants: true}
	_, err := p.Run(context.Background(), sink)
	require.NoError(t, err)
	require.Len(t, sink.events, 1)
	raw, err := json.Marshal(sink.events)
	require.NoError(t, err)
	assert.NotContains(t, string(raw), marker)
	assert.NotContains(t, string(raw), "UAUTHOR")
}

func TestOwnerMessageReactions_SkipsOthersAndNonMessages(t *testing.T) {
	got := ownerMessageReactions(seedFixture(), "UOWNER", 1)
	keys := make([]string, 0, len(got))
	for _, r := range got {
		assert.Equal(t, int64(1), r.AccountID)
		keys = append(keys, ledgerKey(r.ChannelID, r.MessageTS, r.Emoji))
	}
	assert.Equal(t, seedFixtureKeys(), keys)
}
