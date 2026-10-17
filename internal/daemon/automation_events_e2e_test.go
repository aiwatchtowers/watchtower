package daemon

import (
	"context"
	"io"
	"log"
	"testing"
	"time"

	"github.com/slack-go/slack"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/reactioncmd"
)

// e2eEventRecipe is a confirmed event automation on new #releases messages
// that reports the first event's channel and count to the Inbox.
const e2eEventRecipe = "---\nname: Releases watch\ntrigger:\n  event:\n    type: slack.new_messages\n" +
	"    where: {channel: releases}\npermissions:\n  - llm:light\noutputs: [inbox]\n---\n" +
	"Tell me about new messages in #releases.\n\n```js\n" +
	`output.inbox({title: "New in #" + trigger.events[0].channel, body: String(trigger.events[0].count)})` +
	"\n```\n"

// e2eSlackCycle runs one cycle's event half the way runSync does: begin the
// bus, the Slack phase observed by SlackSource (phase writes the messages),
// then the cycle's single Flush keyed by syncStart. runSync's own step order
// is pinned by TestRunSync_FlushOncePerCycleAfterSources.
func e2eSlackCycle(d *Daemon, syncStart time.Time, phase func()) {
	d.cycleEvents = d.beginAutomationEvents()
	d.observePhase(context.Background(), automations.SlackSource(d.db), phase)
	d.flushAutomationEvents(syncStart)
}

func TestEventAutomation_EndToEnd(t *testing.T) {
	d, database, _ := newEventsTestDaemon(t, nil)
	a := automationstest.SeedAutomation(t, database, e2eEventRecipe, automationstest.SeedOptions{Slug: "releases-watch"})

	clock := automations.RealClock{}
	quiet := log.New(io.Discard, "", 0)
	d.SetAutomationEvents(automations.NewBus(database, clock, func() {}, quiet))
	exec := automations.NewExecutor(database, automations.Backends{
		DB:        database,
		Generator: &automationstest.FakeGenerator{Replies: []string{"done"}},
		Registry:  &automationstest.FakeRegistry{},
		Clock:     clock,
	}, automations.ExecutorOptions{Logger: quiet})

	_, err := database.CreateSlackAccount(db.SlackAccount{TeamDomain: "acme", Label: "work", CurrentUserID: "1:UOWNER"})
	require.NoError(t, err)
	require.NoError(t, database.UpsertChannel(db.Channel{ID: "1:C1", Name: "releases", Type: "public"}))
	// One stored message: #releases is not a first sync. No sync_state row —
	// search sync, the default path, never writes one.
	require.NoError(t, database.UpsertMessage(db.Message{ChannelID: "1:C1", TS: "1700000100.000000", UserID: "1:UA", Text: "earlier"}))

	// Cycle 1: two new messages in #releases → one queued event run.
	e2eSlackCycle(d, time.Date(2026, 10, 14, 12, 0, 0, 0, time.UTC), func() {
		for _, ts := range []string{"1700000101.000000", "1700000102.000000"} {
			require.NoError(t, database.UpsertMessage(db.Message{ChannelID: "1:C1", TS: ts, UserID: "1:UA", Text: "shipped"}))
		}
	})
	runs, err := database.ListAutomationRuns(a.ID, 0)
	require.NoError(t, err)
	require.Len(t, runs, 1)
	assert.Equal(t, db.RunQueued, runs[0].Status)
	assert.Equal(t, db.TriggerEvent, runs[0].Trigger)
	assert.Equal(t, "2026-10-14T12:00:00Z", runs[0].EventCycle)

	started, err := exec.Step(context.Background())
	require.NoError(t, err)
	require.Equal(t, 1, started)
	exec.Wait()

	run, err := database.GetAutomationRun(runs[0].ID)
	require.NoError(t, err)
	require.Equal(t, db.RunSucceeded, run.Status, "run error: %s", run.Error)
	outs, err := database.ListAutomationOutputs("inbox", 0)
	require.NoError(t, err)
	require.Len(t, outs, 1)
	assert.Equal(t, run.ID, outs[0].RunID)
	assert.Equal(t, "New in #releases", outs[0].Title)
	assert.Equal(t, "2", outs[0].Body)

	// Cycle 2: the Slack phase brings nothing new → no run.
	e2eSlackCycle(d, time.Date(2026, 10, 14, 12, 15, 0, 0, time.UTC), func() {})
	runs, err = database.ListAutomationRuns(a.ID, 0)
	require.NoError(t, err)
	assert.Len(t, runs, 1)
}

const e2eReactionRecipe = "---\nname: Eyes watch\ntrigger:\n  event:\n    type: slack.reaction_added\n" +
	"    where: {emoji: eyes}\npermissions:\n  - llm:light\noutputs: [inbox]\n---\n" +
	"Tell me about eyes reactions.\n\n```js\n" +
	`output.inbox({title: "Reaction " + trigger.events[0].emoji, body: trigger.events[0].channel_id})` +
	"\n```\n"

// reactionLister serves a fixed reactions.list answer.
type reactionLister struct{ items []slack.ReactedItem }

func (l *reactionLister) ListUserReactions(context.Context, string) ([]slack.ReactedItem, error) {
	return l.items, nil
}

func TestEventAutomation_ReactionEndToEnd(t *testing.T) {
	d, database, _ := newEventsTestDaemon(t, nil)
	a := automationstest.SeedAutomation(t, database, e2eReactionRecipe, automationstest.SeedOptions{Slug: "eyes-watch"})
	clock := automations.RealClock{}
	quiet := log.New(io.Discard, "", 0)
	d.SetAutomationEvents(automations.NewBus(database, clock, func() {}, quiet))
	exec := automations.NewExecutor(database, automations.Backends{
		DB:        database,
		Generator: &automationstest.FakeGenerator{Replies: []string{"done"}},
		Registry:  &automationstest.FakeRegistry{},
		Clock:     clock,
	}, automations.ExecutorOptions{Logger: quiet})

	id, err := database.CreateSlackAccount(db.SlackAccount{TeamDomain: "acme", Label: "work", CurrentUserID: "1:UOWNER"})
	require.NoError(t, err)
	require.NoError(t, database.MarkReactionCommandsSeeded(id))
	// An empty dictionary: eyes is a plain, subscribed reaction.
	_, err = database.Exec(`DELETE FROM reaction_command_map`)
	require.NoError(t, err)
	lister := &reactionLister{}
	d.config.ReactionCommands.Enabled = true
	d.SetReactionCommandsPipeline(reactioncmd.New(database, &config.Config{}, nil, nil,
		func(context.Context) ([]reactioncmd.Account, error) {
			return []reactioncmd.Account{{AccountID: id, OwnerID: "1:UOWNER", Lister: lister}}, nil
		}, nil))

	cycle := func(at time.Time) {
		d.cycleEvents = d.beginAutomationEvents()
		d.phaseReactionCommands(context.Background())
		d.flushAutomationEvents(at)
	}

	// Cycle 1 seeds: nothing fires. Then the owner reacts.
	cycle(time.Date(2026, 10, 14, 12, 0, 0, 0, time.UTC))
	runs, err := database.ListAutomationRuns(a.ID, 0)
	require.NoError(t, err)
	require.Empty(t, runs)

	lister.items = []slack.ReactedItem{{
		Item:      slack.Item{Type: "message", Channel: "C1", Message: &slack.Message{Msg: slack.Msg{Timestamp: "1700000101.000100", User: "UAUTHOR"}}},
		Reactions: []slack.ItemReaction{{Name: "eyes", Users: []string{"UOWNER"}}},
	}}
	cycle(time.Date(2026, 10, 14, 12, 15, 0, 0, time.UTC))
	runs, err = database.ListAutomationRuns(a.ID, 0)
	require.NoError(t, err)
	require.Len(t, runs, 1)
	assert.Equal(t, db.TriggerEvent, runs[0].Trigger)
	assert.Contains(t, runs[0].EventJSON, `"emoji":"eyes"`)

	started, err := exec.Step(context.Background())
	require.NoError(t, err)
	require.Equal(t, 1, started)
	exec.Wait()
	run, err := database.GetAutomationRun(runs[0].ID)
	require.NoError(t, err)
	require.Equal(t, db.RunSucceeded, run.Status, "run error: %s", run.Error)
	outs, err := database.ListAutomationOutputs("inbox", 0)
	require.NoError(t, err)
	require.Len(t, outs, 1)
	assert.Equal(t, "Reaction eyes", outs[0].Title)
	assert.Equal(t, "1:C1", outs[0].Body)

	// Next cycle, same reaction: no new run.
	cycle(time.Date(2026, 10, 14, 12, 30, 0, 0, time.UTC))
	runs, err = database.ListAutomationRuns(a.ID, 0)
	require.NoError(t, err)
	assert.Len(t, runs, 1)
}
