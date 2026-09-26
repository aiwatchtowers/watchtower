package memory

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
)

// calendarPipelineConfig is pipelineTestConfig with the calendar memory source ON.
func calendarPipelineConfig() config.MemoryConfig {
	cfg := pipelineTestConfig()
	cfg.Sources.Calendar = true
	return cfg
}

// attendeeSpec is a compact attendee for calAttendeesJSON.
type attendeeSpec struct {
	email, name, slackID string
}

// calAttendeesJSON renders the calendar_events.attendees JSON the sync stores.
func calAttendeesJSON(t *testing.T, atts ...attendeeSpec) string {
	t.Helper()
	type a struct {
		Email       string `json:"email"`
		DisplayName string `json:"display_name"`
		SlackUserID string `json:"slack_user_id"`
	}
	arr := make([]a, 0, len(atts))
	for _, x := range atts {
		arr = append(arr, a{Email: x.email, DisplayName: x.name, SlackUserID: x.slackID})
	}
	b, err := json.Marshal(arr)
	require.NoError(t, err)
	return string(b)
}

// endedEvent returns a calEvent that ended `agoHours` hours ago (1h duration),
// with its end-time unix for watermark assertions.
func endedEvent(id string, agoHours int) (calEvent, int64) {
	now := time.Now().UTC()
	end := now.Add(-time.Duration(agoHours) * time.Hour).Truncate(time.Second)
	start := end.Add(-time.Hour)
	return calEvent{
		id:    id,
		title: id,
		start: start.Format(time.RFC3339),
		end:   end.Format(time.RFC3339),
	}, end.Unix()
}

// noCallGen fails the test if the generator is ever invoked — the calendar
// builder is mechanical and must make NO AI call.
func noCallGen(t *testing.T) *fakeGen {
	return &fakeGen{reply: func(string) (string, error) {
		t.Fatal("calendar ingest must not call the generator")
		return "", nil
	}}
}

// TestRunCalendarIngestHappyPath: an ended event becomes one episode aliased
// calevent:<id> with a cal: provenance ref and back-links on the resolved
// participant entities; the generator is never called; the watermark advances.
func TestRunCalendarIngestHappyPath(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	bobID := "ent_00000000000000000000000001"
	carolID := "ent_00000000000000000000000002"
	writeAndIndex(t, v, d, bareEntity(bobID, "U2BOB"))
	writeAndIndex(t, v, d, bareEntity(carolID, "carol@example.com"))

	ev, endUnix := endedEvent("evt-1", 2)
	ev.title = "Budget sync"
	ev.description = "Discuss the Q3 budget."
	ev.location = "Room 4"
	ev.organizer = "ann@example.com"
	ev.attendeesJSON = calAttendeesJSON(t,
		attendeeSpec{email: "bob@example.com", name: "Bob", slackID: "U2BOB"},
		attendeeSpec{email: "carol@example.com", name: "Carol"},
	)
	seedCalendarEvent(t, d, ev)

	gen := noCallGen(t)
	p := NewPipeline(d, v, gen, calendarPipelineConfig(), t.Logf)

	var stats RunStats
	recorded, err := p.runCalendarIngest(1, 0, &stats)
	require.NoError(t, err)
	assert.Equal(t, 1, recorded, "one pipeline_steps row recorded")
	assert.Equal(t, 1, stats.CalendarEpisodes)
	assert.Zero(t, stats.CalendarEventsFailed)
	assert.Empty(t, gen.calls, "no AI call")

	ep, err := Resolve(v, d, "calevent:evt-1")
	require.NoError(t, err)
	assert.Equal(t, "episode", ep.Type)
	assert.Equal(t, "Budget sync", ep.Title)
	assert.Contains(t, ep.Body, "## Provenance\n- cal:evt-1 ", "single cal: ref")
	assert.Contains(t, ep.Body, "Room 4")
	assert.Contains(t, ep.Body, "Discuss the Q3 budget.")
	assert.Contains(t, ep.Body, "Bob", "participant label in the story/participants")

	// Both participant entities carry a back-link to the episode.
	bob, err := v.ReadNode(bobID)
	require.NoError(t, err)
	assert.Contains(t, bob.Body, "[["+ep.ID+"|", "Bob's entity links the episode")
	carol, err := v.ReadNode(carolID)
	require.NoError(t, err)
	assert.Contains(t, carol.Body, "[["+ep.ID+"|", "Carol's entity links the episode")

	wm, err := d.MemoryCalendarWatermark()
	require.NoError(t, err)
	assert.Equal(t, float64(endUnix), wm, "watermark advances to the event's end unix")
}

// TestRunCalendarIngestRecapEnrichment: where a meeting_recaps row exists, its
// summary folds into Story and its decisions/actions/questions into Outcome.
func TestRunCalendarIngestRecapEnrichment(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	ev, _ := endedEvent("evt-1", 2)
	ev.title = "Planning"
	seedCalendarEvent(t, d, ev)
	recapJSON, err := json.Marshal(map[string]any{
		"summary":        "Agreed on the roadmap.",
		"key_decisions":  []string{"Ship v2 in August"},
		"action_items":   []string{"Ann to draft the spec"},
		"open_questions": []string{"Who owns QA?"},
	})
	require.NoError(t, err)
	require.NoError(t, d.UpsertMeetingRecap("evt-1", "raw notes", string(recapJSON), 0))

	p := NewPipeline(d, v, noCallGen(t), calendarPipelineConfig(), t.Logf)
	var stats RunStats
	_, err = p.runCalendarIngest(1, 0, &stats)
	require.NoError(t, err)

	ep, err := Resolve(v, d, "calevent:evt-1")
	require.NoError(t, err)
	assert.Contains(t, ep.Body, "Agreed on the roadmap.", "recap summary folded into Story")
	assert.Contains(t, ep.Body, "Ship v2 in August", "key decision folded into Outcome")
	assert.Contains(t, ep.Body, "Ann to draft the spec", "action item folded into Outcome")
	assert.Contains(t, ep.Body, "Who owns QA?", "open question folded into Outcome")
}

// TestRunCalendarIngestRecurringLinksSeries: a recurring instance additionally
// links to its calseries:<recurringEventId> series entity.
func TestRunCalendarIngestRecurringLinksSeries(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	seriesID := "ent_00000000000000000000000009"
	writeAndIndex(t, v, d, bareEntity(seriesID, "calseries:series-A"))

	ev, _ := endedEvent("evt-1", 2)
	ev.isRecurring = true
	ev.rawJSON = `{"recurringEventId":"series-A"}`
	seedCalendarEvent(t, d, ev)

	p := NewPipeline(d, v, noCallGen(t), calendarPipelineConfig(), t.Logf)
	var stats RunStats
	_, err := p.runCalendarIngest(1, 0, &stats)
	require.NoError(t, err)

	ep, err := Resolve(v, d, "calevent:evt-1")
	require.NoError(t, err)
	series, err := v.ReadNode(seriesID)
	require.NoError(t, err)
	assert.Contains(t, series.Body, "[["+ep.ID+"|", "the series entity links its instance episode")
}

// TestRunCalendarIngestIdempotent: a re-scan with no change commits nothing (no
// empty git commit) and reports zero new episodes.
func TestRunCalendarIngestIdempotent(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	ev, _ := endedEvent("evt-1", 2)
	seedCalendarEvent(t, d, ev)

	p := NewPipeline(d, v, noCallGen(t), calendarPipelineConfig(), t.Logf)
	var stats RunStats
	_, err := p.runCalendarIngest(1, 0, &stats)
	require.NoError(t, err)
	require.Equal(t, 1, stats.CalendarEpisodes)

	repo := openTestRepo(t, v.path)
	commitsAfterFirst := commitCount(t, repo)

	var stats2 RunStats
	_, err = p.runCalendarIngest(2, 0, &stats2)
	require.NoError(t, err)
	assert.Zero(t, stats2.CalendarEpisodes, "re-scan builds nothing new")
	assert.Equal(t, commitsAfterFirst, commitCount(t, repo), "no empty commit on an unchanged re-scan")
}

// TestRunCalendarIngestLateRecapRefresh: a recap landing after the first build
// (within the lookback re-scan window) refreshes the episode Outcome in place.
func TestRunCalendarIngestLateRecapRefresh(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	ev, _ := endedEvent("evt-1", 2)
	seedCalendarEvent(t, d, ev)

	p := NewPipeline(d, v, noCallGen(t), calendarPipelineConfig(), t.Logf)
	var stats RunStats
	_, err := p.runCalendarIngest(1, 0, &stats)
	require.NoError(t, err)
	ep1, err := Resolve(v, d, "calevent:evt-1")
	require.NoError(t, err)
	assert.NotContains(t, ep1.Body, "Ship it", "no recap content yet")

	// Recap lands after the first build.
	recapJSON, _ := json.Marshal(map[string]any{"summary": "Wrapped up.", "key_decisions": []string{"Ship it"}})
	require.NoError(t, d.UpsertMeetingRecap("evt-1", "notes", string(recapJSON), 0))

	var stats2 RunStats
	_, err = p.runCalendarIngest(2, 0, &stats2)
	require.NoError(t, err)
	assert.Equal(t, 1, stats2.CalendarEpisodes, "the episode is refreshed")

	ep2, err := Resolve(v, d, "calevent:evt-1")
	require.NoError(t, err)
	assert.Equal(t, ep1.ID, ep2.ID, "same node id — updated in place")
	assert.Contains(t, ep2.Body, "Ship it", "the late recap now folds into Outcome")
}

// TestBuildCalendarEpisodesDropsUnresolvedRef: an event whose cal: ref no
// longer resolves (swept between load and validate) is dropped and counted, its
// episode discarded.
func TestBuildCalendarEpisodesDropsUnresolvedRef(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	ev, _ := endedEvent("evt-1", 2)
	seedCalendarEvent(t, d, ev)

	p := NewPipeline(d, v, noCallGen(t), calendarPipelineConfig(), t.Logf)
	events, err := d.ListCalendarEventsForExtract(0, calendarReprocessLookbackDays, 100)
	require.NoError(t, err)
	require.Len(t, events, 1)

	// A cal-only registry whose checker reports the event as gone.
	reg := newProvenanceRegistry(calResolver{sweptCalChecker{}})
	built, failed, _, err := p.buildCalendarEpisodes(1, reg, events)
	require.NoError(t, err, "a positive non-resolution is a clean drop, not a freeze")
	assert.Zero(t, built, "the ref-less episode is discarded")
	assert.Equal(t, 1, failed, "the dropped event is counted")

	_, err = Resolve(v, d, "calevent:evt-1")
	require.Error(t, err, "no episode was written")
}

// sweptCalChecker reports every event as gone — the swept-row drop path.
type sweptCalChecker struct{}

func (sweptCalChecker) CalendarEventExists(string) (bool, error) { return false, nil }

// TestRunCalendarIngestFreezeOnError: a lookup failure during the build (here,
// GetMeetingRecap erroring) freezes the whole step — no episode committed, the
// watermark unmoved.
func TestRunCalendarIngestFreezeOnError(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	ev, _ := endedEvent("evt-1", 2)
	seedCalendarEvent(t, d, ev)
	_, err := d.Exec(`DROP TABLE meeting_recaps`)
	require.NoError(t, err)

	p := NewPipeline(d, v, noCallGen(t), calendarPipelineConfig(), t.Logf)
	var stats RunStats
	_, err = p.runCalendarIngest(1, 0, &stats)
	require.NoError(t, err, "a build error is logged, not fatal to the run")
	assert.Zero(t, stats.CalendarEpisodes)

	_, err = Resolve(v, d, "calevent:evt-1")
	require.Error(t, err, "nothing committed on a frozen step")

	wm, err := d.MemoryCalendarWatermark()
	require.NoError(t, err)
	assert.Zero(t, wm, "the watermark is frozen on error")
}

// TestRunGateOffNoCalendarWork: with memory.sources.calendar off, a full Run
// does no calendar work and leaves the calendar watermark unmoved; flipping the
// gate on then builds the episode.
func TestRunGateOffNoCalendarWork(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	ev, _ := endedEvent("evt-1", 2)
	seedCalendarEvent(t, d, ev)

	cfg := calendarPipelineConfig()
	cfg.Sources.Calendar = false
	// nil generator so extraction is skipped; the run is otherwise a mechanical no-op.
	p := NewPipeline(d, v, nil, cfg, t.Logf)
	_, err := p.Run(context.Background())
	require.NoError(t, err)

	_, err = Resolve(v, d, "calevent:evt-1")
	require.Error(t, err, "gate off → no calendar episode")
	wm, err := d.MemoryCalendarWatermark()
	require.NoError(t, err)
	assert.Zero(t, wm, "gate off → calendar watermark unmoved")

	cfg.Sources.Calendar = true
	p2 := NewPipeline(d, v, nil, cfg, t.Logf)
	_, err = p2.Run(context.Background())
	require.NoError(t, err)
	_, err = Resolve(v, d, "calevent:evt-1")
	require.NoError(t, err, "gate on → the episode is built")
}
