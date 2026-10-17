package daemon

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"log"
	"path/filepath"
	"slices"
	"strings"
	gosync "sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/db"
	"watchtower/internal/extsync"
)

// recordingEvents is an AutomationEvents that wants the types in wants and
// records every call in order ("begin", "wants:<type>", "flush:<cycle>").
type recordingEvents struct {
	mu        gosync.Mutex
	wants     map[string]bool
	beginErr  error
	calls     []string
	published []automations.Event
}

func newRecordingEvents(types ...string) *recordingEvents {
	r := &recordingEvents{wants: map[string]bool{}}
	for _, t := range types {
		r.wants[t] = true
	}
	return r
}

func (r *recordingEvents) record(call string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.calls = append(r.calls, call)
}

func (r *recordingEvents) Begin() error {
	r.record("begin")
	return r.beginErr
}

func (r *recordingEvents) Wants(eventType string) bool {
	r.record("wants:" + eventType)
	return r.wants[eventType]
}

func (r *recordingEvents) Publish(events ...automations.Event) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.published = append(r.published, events...)
}

func (r *recordingEvents) Flush(cycleID string) (automations.FlushReport, error) {
	r.record("flush:" + cycleID)
	return automations.FlushReport{}, nil
}

func (r *recordingEvents) callList() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return slices.Clone(r.calls)
}

// countingSource is an EventSource that counts its snapshots and diffs and
// reports one event per diff, or the scripted errors.
type countingSource struct {
	typ                 string
	beforeErr, afterErr error
	befores, afters     int
}

func (s *countingSource) Type() string { return s.typ }

func (s *countingSource) Before(context.Context) (automations.EventDiff, error) {
	s.befores++
	if s.beforeErr != nil {
		return nil, s.beforeErr
	}
	return countingDiff{s}, nil
}

type countingDiff struct{ s *countingSource }

func (d countingDiff) After(context.Context) ([]automations.Event, error) {
	d.s.afters++
	if d.s.afterErr != nil {
		return nil, d.s.afterErr
	}
	return []automations.Event{{Type: d.s.typ, Fields: map[string]any{"count": 1}}}, nil
}

// newEventsTestDaemon is a quiet daemon over a file database whose cycle
// publishes into ev.
func newEventsTestDaemon(t *testing.T, ev *recordingEvents) (*Daemon, *db.DB, *bytes.Buffer) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	database, err := db.Open(filepath.Join(t.TempDir(), "watchtower.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	logs := &bytes.Buffer{}
	d := newQuietDaemon(t)
	d.SetLogger(log.New(logs, "", 0))
	d.SetDB(database)
	if ev != nil {
		d.SetAutomationEvents(ev)
		d.cycleEvents = d.beginAutomationEvents()
	}
	return d, database, logs
}

func TestPhaseSlackSync_PublishesNewMessages(t *testing.T) {
	ev := newRecordingEvents("slack.new_messages")
	d, database, _ := newEventsTestDaemon(t, ev)
	_, err := database.CreateSlackAccount(db.SlackAccount{TeamDomain: "acme", Label: "work", CurrentUserID: "1:UOWNER"})
	require.NoError(t, err)
	require.NoError(t, database.UpsertChannel(db.Channel{ID: "1:C1", Name: "releases", Type: "public"}))
	// One stored message: #releases is not a first sync. No sync_state row —
	// search sync, the default path, never writes one.
	require.NoError(t, database.UpsertMessage(db.Message{ChannelID: "1:C1", TS: "1700000100.000000", UserID: "1:UA", Text: "earlier"}))

	d.observePhase(context.Background(), automations.SlackSource(database), func() {
		for _, ts := range []string{"1700000101.000000", "1700000102.000000"} {
			require.NoError(t, database.UpsertMessage(db.Message{ChannelID: "1:C1", TS: ts, UserID: "1:UA", Text: "hello"}))
		}
	})

	require.Len(t, ev.published, 1)
	assert.Equal(t, automations.Event{Type: "slack.new_messages", Fields: map[string]any{
		"account": "work", "channel": "releases", "channel_id": "1:C1", "count": 2,
	}}, ev.published[0])
}

// countMailSyncer is a mailSyncer whose Sync runs store (when set), then
// returns a scripted count and error.
type countMailSyncer struct {
	accountID int64
	n         int
	err       error
	store     func()
}

func (s *countMailSyncer) Sync(context.Context) (int, error) {
	if s.store != nil {
		s.store()
	}
	return s.n, s.err
}
func (s *countMailSyncer) FetchRange(context.Context, time.Time, time.Time) (int, error) {
	return 0, nil
}
func (s *countMailSyncer) AccountID() int64                 { return s.accountID }
func (s *countMailSyncer) FirstSyncFrom() (time.Time, bool) { return time.Time{}, false }

var errPartial = errors.New("partial fetch")

// mailProvider is one mail provider's test wiring: account creation, the
// watermark a sync leaves, how its syncer stores message i of an account
// dated date, and the daemon's syncer slot and phase.
type mailProvider struct {
	name         string
	newAccount   func(t *testing.T, d *db.DB, email string) int64
	setWatermark func(t *testing.T, d *db.DB, accountID int64)
	store        func(t *testing.T, d *db.DB, accountID int64, i int, date string)
	wire         func(*Daemon, []mailSyncer)
	run          func(*Daemon)
}

// mailPublishCase runs one mail phase over four accounts whose syncers store
// 3 messages (nil), 2 (errPartial), 0 (nil) and a first sync of 5 (watermark
// unset), all dated after the accounts were connected, and returns the
// published counts.
func mailPublishCase(t *testing.T, p mailProvider) []any {
	t.Helper()
	ev := newRecordingEvents("gmail.new_messages")
	d, database, _ := newEventsTestDaemon(t, ev)
	date := time.Now().Add(time.Hour).UTC().Format(time.RFC3339)
	var syncers []mailSyncer
	for i, sc := range []struct {
		n      int
		err    error
		synced bool
	}{{3, nil, true}, {2, errPartial, true}, {0, nil, true}, {5, nil, false}} {
		id := p.newAccount(t, database, string(rune('a'+i))+"@example.com")
		if sc.synced {
			p.setWatermark(t, database, id)
		}
		store := func() {
			for m := range sc.n {
				p.store(t, database, id, m+1, date)
			}
		}
		syncers = append(syncers, &countMailSyncer{accountID: id, n: sc.n, err: sc.err, store: store})
	}
	p.wire(d, syncers)
	p.run(d)
	var counts []any
	for _, e := range ev.published {
		assert.Equal(t, "gmail.new_messages", e.Type)
		assert.Equal(t, p.name, e.Fields["provider"])
		counts = append(counts, e.Fields["count"])
	}
	return counts
}

var gmailProvider = mailProvider{
	name: "gmail",
	newAccount: func(t *testing.T, database *db.DB, email string) int64 {
		id, err := database.CreateGoogleAccount(db.GoogleAccount{Email: email, GmailEnabled: true})
		require.NoError(t, err)
		return id
	},
	setWatermark: func(t *testing.T, database *db.DB, id int64) {
		require.NoError(t, database.SetGmailAccountWatermark(id, 1700000000))
	},
	store: func(t *testing.T, database *db.DB, id int64, i int, date string) {
		require.NoError(t, database.UpsertGmailMessage(id, db.GmailMessage{ID: fmt.Sprintf("m%d", i), InternalDate: date}))
	},
	wire: func(d *Daemon, s []mailSyncer) { d.gmailSyncers = s },
	run:  func(d *Daemon) { d.phaseGmailSync(context.Background()) },
}

var imapProvider = mailProvider{
	name: "imap",
	newAccount: func(t *testing.T, database *db.DB, email string) int64 {
		id, err := database.CreateEmailAccount(db.EmailAccount{Provider: "imap", EmailAddress: email,
			Host: "imap.example.com", Security: "ssl", Folder: "INBOX"})
		require.NoError(t, err)
		return id
	},
	setWatermark: func(t *testing.T, database *db.DB, id int64) {
		require.NoError(t, database.SetImapWatermark(id, 1, 1))
	},
	store: func(t *testing.T, database *db.DB, id int64, i int, date string) {
		require.NoError(t, database.UpsertImapMessage(db.ImapMessage{AccountID: id, UID: int64(i), UIDValidity: 1, InternalDate: date}, date))
	},
	wire: func(d *Daemon, s []mailSyncer) { d.imapSyncers = s },
	run:  func(d *Daemon) { d.phaseImapSync(context.Background()) },
}

func TestPhaseGmailSync_PublishesNewMessages(t *testing.T) {
	counts := mailPublishCase(t, gmailProvider)
	assert.Equal(t, []any{3, 2}, counts, "nothing stored and the first sync publish nothing")
}

func TestPhaseImapSync_PublishesNewMessages(t *testing.T) {
	counts := mailPublishCase(t, imapProvider)
	assert.Equal(t, []any{3, 2}, counts, "nothing stored and the first sync publish nothing")
}

// writingJiraSyncer is a stubJiraSyncer whose Sync runs write first.
type writingJiraSyncer struct {
	stubJiraSyncer
	write func()
}

func (s *writingJiraSyncer) Sync(ctx context.Context) (int, error) {
	s.write()
	return s.stubJiraSyncer.Sync(ctx)
}

func TestPhaseJiraSync_PublishesIssueChanged(t *testing.T) {
	ev := newRecordingEvents("jira.issue_changed")
	d, database, _ := newEventsTestDaemon(t, ev)
	d.config.Jira.SyncIntervalMins = 60
	acct, err := database.CreateJiraAccount(db.JiraAccount{CloudID: "c1", SiteURL: "https://acme.example.com", SiteName: "acme", Label: "work"})
	require.NoError(t, err)
	issue := db.JiraIssue{AccountID: acct, Key: "PAY-1", ProjectKey: "PAY", Summary: "s", Status: "Open",
		StatusCategory: "new", Priority: "High", CreatedAt: "2026-10-01T00:00:00Z",
		UpdatedAt: "2026-10-02T00:00:00Z", SyncedAt: "2026-10-02T00:00:00Z"}
	require.NoError(t, database.UpsertJiraIssue(issue))
	writes := 0
	d.jiraSyncers = []jiraAccountSyncer{&writingJiraSyncer{stubJiraSyncer: stubJiraSyncer{accountID: acct}, write: func() {
		writes++
		issue.Status, issue.UpdatedAt = "Done", "2026-10-03T00:00:00Z"
		require.NoError(t, database.UpsertJiraIssue(issue))
	}}}

	jira := func() { d.phaseJiraSync(context.Background()) }
	d.observePhase(context.Background(), automations.JiraSource(database), jira)
	require.Len(t, ev.published, 1)
	assert.Equal(t, automations.Event{Type: "jira.issue_changed", Fields: map[string]any{
		"account": "work", "key": "PAY-1", "project": "PAY", "field": "status",
	}}, ev.published[0])

	// The interval gate returns early: nothing synced, nothing published.
	d.observePhase(context.Background(), automations.JiraSource(database), jira)
	assert.Equal(t, 1, writes, "the second pass is throttled")
	assert.Len(t, ev.published, 1)
}

func TestPhaseCalendarSync_PublishesEventChanged(t *testing.T) {
	ev := newRecordingEvents("calendar.event_changed")
	d, database, _ := newEventsTestDaemon(t, ev)
	g, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "owner@example.com", Label: "work", CalendarEnabled: true})
	require.NoError(t, err)
	require.NoError(t, database.UpsertCalendar(g, db.CalendarCalendar{ID: "primary@example.com", Name: "Work", IsSelected: true}))
	dav, err := database.CreateCalendarAccount(db.CalendarAccount{Provider: "caldav", URL: "https://dav.example.com", Username: "owner", Label: "home"})
	require.NoError(t, err)
	davCal := db.CalendarAccountCalendarID("caldav", dav)
	require.NoError(t, database.UpsertCalendar(0, db.CalendarCalendar{ID: davCal, Name: "Home", IsSelected: true}))
	start := time.Now().Add(48 * time.Hour).UTC()
	event := func(id, cal string) db.CalendarEvent {
		return db.CalendarEvent{ID: id, CalendarID: cal, Title: "t", StartTime: start.Format(time.RFC3339),
			EndTime: start.Add(time.Hour).Format(time.RFC3339), EventStatus: "confirmed", UpdatedAt: "2026-10-01T00:00:00Z"}
	}
	// Each calendar already holds an event, so neither account is a backfill.
	require.NoError(t, database.UpsertCalendarEvent(event("g-0", "primary@example.com")))
	require.NoError(t, database.UpsertCalendarEvent(event("d-0", davCal)))

	// One snapshot around both calendar phases, the runSync shape.
	src := &countingSource{typ: "calendar.event_changed"}
	d.observePhase(context.Background(), src, func() {})
	assert.Equal(t, 1, src.befores)
	ev.published = nil
	d.observePhase(context.Background(), automations.CalendarSource(database, automations.RealClock{}), func() {
		require.NoError(t, database.UpsertCalendarEvent(event("g-1", "primary@example.com"))) // phaseCalendarSync
		require.NoError(t, database.UpsertCalendarEvent(event("d-1", davCal)))                // phaseCalDAVSync
	})
	assert.ElementsMatch(t, []automations.Event{
		{Type: "calendar.event_changed", Fields: map[string]any{"account": "work", "event_id": "g-1", "change": "created"}},
		{Type: "calendar.event_changed", Fields: map[string]any{"account": "home", "event_id": "d-1", "change": "created"}},
	}, ev.published)

	// runSync observes both calendar phases through one observePhase.
	order := runSyncObservedPhases(t)
	assert.Equal(t, []string{"phaseCalendarSync", "phaseCalDAVSync"}, order["CalendarSource"])
}

// pageBumpingSync is an ExternalSyncRunner whose Run bumps page 100.
type pageBumpingSync struct {
	fakeExternalSync
	database *db.DB
	src      int64
}

func (f *pageBumpingSync) Run(ctx context.Context) (extsync.Stats, error) {
	if _, err := f.database.Exec(`UPDATE ext_documents SET version = version + 1 WHERE source_id = ? AND ext_id = '100'`, f.src); err != nil {
		return extsync.Stats{}, err
	}
	return f.fakeExternalSync.Run(ctx)
}

func TestPhaseExternalSync_PublishesPageChanged(t *testing.T) {
	ev := newRecordingEvents("confluence.page_changed")
	d, database, _ := newEventsTestDaemon(t, ev)
	d.config.Knowledge.Connectors.Enabled = true
	acct, err := database.CreateJiraAccount(db.JiraAccount{CloudID: "c1", SiteURL: "https://acme.example.com", SiteName: "acme", Label: "work"})
	require.NoError(t, err)
	src, err := database.CreateExtSource("confluence", acct, "ENG", "1", "Engineering")
	require.NoError(t, err)
	_, err = database.Exec(`UPDATE ext_sources SET backfill_done = 1 WHERE id = ?`, src)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO ext_documents (source_id, ext_id, kind, title, version, sections_json)
        VALUES (?, '100', 'page', 't', 1, '[]')`, src)
	require.NoError(t, err)
	runner := &pageBumpingSync{database: database, src: src}
	d.SetExternalSync(runner)

	d.observePhase(context.Background(), automations.ConfluenceSource(database), func() { d.phaseExternalSync(context.Background()) })

	assert.Equal(t, 1, runner.calls)
	assert.Equal(t, []automations.Event{{Type: "confluence.page_changed", Fields: map[string]any{"space": "ENG", "page_id": "100"}}},
		ev.published)
}

// runSyncCycle runs one cycle with one watched mail account, so every
// observed source asks the bus.
func runSyncCycle(t *testing.T, ctx context.Context) (*recordingEvents, time.Time, time.Time) {
	t.Helper()
	ev := newRecordingEvents()
	d, database, _ := newEventsTestDaemon(t, nil)
	d.SetAutomationEvents(ev)
	id, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "owner@example.com", GmailEnabled: true})
	require.NoError(t, err)
	d.gmailSyncers = []mailSyncer{&countMailSyncer{accountID: id}}
	before := time.Now()
	d.runSync(ctx)
	return ev, before, time.Now()
}

func TestRunSync_FlushOncePerCycleAfterSources(t *testing.T) {
	ev, before, after := runSyncCycle(t, context.Background())
	calls := ev.callList()
	require.Len(t, calls, 7, "calls: %v", calls)
	assert.Equal(t, []string{"begin", "wants:slack.new_messages", "wants:calendar.event_changed",
		"wants:gmail.new_messages", "wants:jira.issue_changed", "wants:confluence.page_changed"}, calls[:6])
	cycle, ok := strings.CutPrefix(calls[6], "flush:")
	require.True(t, ok, "the last call flushes: %v", calls)
	at, err := time.Parse(time.RFC3339Nano, cycle)
	require.NoError(t, err)
	assert.True(t, strings.HasSuffix(cycle, "Z"), "cycle id %q is UTC", cycle)
	assert.False(t, at.Before(before) || at.After(after), "cycle id %q is the cycle's sync start", cycle)

	// Statically: the flush follows the last observed source and precedes
	// the pipelines.
	order := runSyncCallOrder(t)
	assert.Greater(t, order["flushAutomationEvents"], order["phaseExternalSync"])
	assert.Less(t, order["flushAutomationEvents"], order["phaseAgentAnalytics"])
	assert.Less(t, order["flushAutomationEvents"], order["phaseChannelDigests"])
}

func TestFlushAutomationEvents_CycleIDsWithinOneSecondDiffer(t *testing.T) {
	ev := newRecordingEvents()
	d, _, _ := newEventsTestDaemon(t, nil)
	d.SetAutomationEvents(ev)
	at := time.Date(2026, 10, 14, 12, 0, 0, 0, time.UTC)
	for _, start := range []time.Time{at, at.Add(250 * time.Millisecond)} {
		d.cycleEvents = d.beginAutomationEvents()
		d.flushAutomationEvents(start)
	}
	assert.Equal(t, []string{"begin", "flush:2026-10-14T12:00:00Z", "begin", "flush:2026-10-14T12:00:00.25Z"}, ev.callList())
}

func TestRunSync_FlushRunsOnCancelledContext(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	ev, _, _ := runSyncCycle(t, ctx)
	flushes := 0
	for _, c := range ev.callList() {
		if strings.HasPrefix(c, "flush:") {
			flushes++
		}
	}
	assert.Equal(t, 1, flushes, "calls: %v", ev.callList())
}

// A real bus over a subscribed automation: one cycle queues one event run
// carrying the cycle id, and wakes the executor.
func TestRunSync_RealBusQueuesOneRun(t *testing.T) {
	d, database, _ := newEventsTestDaemon(t, nil)
	recipe := "---\nname: Mail watch\ntrigger:\n  event:\n    type: gmail.new_messages\n" +
		"permissions:\n  - llm:light\noutputs: [inbox]\n---\nReacts to mail.\n\n```js\nlog(\"mail\")\n```\n"
	a := automationstest.SeedAutomation(t, database, recipe, automationstest.SeedOptions{Slug: "mail-watch"})
	wakes := 0
	d.SetAutomationEvents(automations.NewBus(database, automations.RealClock{}, func() { wakes++ }, d.logger))
	id, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "owner@example.com", Label: "work", GmailEnabled: true})
	require.NoError(t, err)
	require.NoError(t, database.SetGmailAccountWatermark(id, 1700000000))
	// Messages first..last, dated a minute apart after the connect.
	store := func(first, last int) func() {
		return func() {
			for i := first; i <= last; i++ {
				at := time.Now().Add(time.Hour + time.Duration(i)*time.Minute).UTC().Format(time.RFC3339)
				require.NoError(t, database.UpsertGmailMessage(id, db.GmailMessage{ID: fmt.Sprintf("m%d", i), InternalDate: at}))
			}
		}
	}
	d.gmailSyncers = []mailSyncer{&countMailSyncer{accountID: id, n: 3, store: store(1, 3)},
		&countMailSyncer{accountID: id, n: 1, store: store(4, 4)}}

	d.runSync(context.Background())

	runs, err := database.ListAutomationRuns(a.ID, 10)
	require.NoError(t, err)
	require.Len(t, runs, 1, "two matching events, one run per automation per cycle")
	assert.Equal(t, db.TriggerEvent, runs[0].Trigger)
	_, err = time.Parse(time.RFC3339Nano, runs[0].EventCycle)
	assert.NoError(t, err, "event_cycle %q", runs[0].EventCycle)
	assert.Contains(t, runs[0].EventJSON, `"count":2`)
	assert.Equal(t, 1, wakes)
}

func TestDaemon_NoSubscribersTakesNoSnapshots(t *testing.T) {
	ev := newRecordingEvents()
	d, _, _ := newEventsTestDaemon(t, ev)
	src := &countingSource{typ: "slack.new_messages"}
	ran := false
	d.observePhase(context.Background(), src, func() { ran = true })
	assert.True(t, ran)
	assert.Zero(t, src.befores+src.afters, "no subscriber, no snapshot")
	assert.Empty(t, ev.published)

	// No mail subscriber: the mail source takes no snapshot (a nil database
	// would panic) and nothing is published.
	d.db = nil
	d.gmailSyncers = []mailSyncer{&countMailSyncer{accountID: 1, n: 3}}
	assert.NotPanics(t, func() { d.phaseGmailSync(context.Background()) })
	assert.Empty(t, ev.published)
}

func TestDaemon_NilOrFailingBusLeavesRunSyncUnchanged(t *testing.T) {
	d, _, _ := newEventsTestDaemon(t, nil)
	d.SetAutomationEvents(nil)
	assert.False(t, d.HasAutomationEvents())
	d.runSync(context.Background())
	assert.Nil(t, d.cycleEvents)

	// A bus whose Begin fails is off for the cycle: no Wants, no Flush.
	ev := newRecordingEvents("slack.new_messages")
	ev.beginErr = errors.New("db locked")
	d.SetAutomationEvents(ev)
	d.runSync(context.Background())
	assert.Equal(t, []string{"begin"}, ev.callList())
}

func TestDaemon_ReactionCommandsUnchangedByBus(t *testing.T) {
	// Statically: phaseReactionCommands(ctx) is the statement right after
	// the observed phaseSlackSync, guarded by ctx.Err() == nil as before.
	file, err := parser.ParseFile(token.NewFileSet(), "daemon.go", nil, 0)
	require.NoError(t, err)
	body := runSyncBody(t, file)
	order := runSyncCallOrder(t)
	slack, reactions := order["phaseSlackSync"], order["phaseReactionCommands"]
	assert.Equal(t, slack+1, reactions, "the poll still follows the Slack sync directly")
	guard, ok := body.List[reactions].(*ast.IfStmt)
	require.True(t, ok, "the poll keeps its ctx.Err() guard")
	stmt, ok := guard.Body.List[0].(*ast.ExprStmt)
	require.True(t, ok, "the guard's first statement is the poll call")
	call, ok := stmt.X.(*ast.CallExpr)
	require.True(t, ok, "the guard's first statement is the poll call")
	require.Len(t, call.Args, 1)
	arg, ok := call.Args[0].(*ast.Ident)
	require.True(t, ok, "the poll is passed ctx")
	assert.Equal(t, "ctx", arg.Name)

	// At run time: the bus is asked only about event types of EventTypes.
	ev := newRecordingEvents("slack.new_messages")
	d, _, _ := newEventsTestDaemon(t, nil)
	d.SetAutomationEvents(ev)
	d.config.ReactionCommands.Enabled = true
	d.runSync(context.Background())
	for _, c := range ev.callList() {
		if typ, ok := strings.CutPrefix(c, "wants:"); ok {
			assert.Contains(t, automations.EventTypes, typ)
			assert.False(t, strings.HasPrefix(typ, "reaction."))
		}
	}
	for _, e := range ev.published {
		assert.Contains(t, automations.EventTypes, e.Type)
	}
}

func TestDaemon_SnapshotErrorDoesNotSkipPhase(t *testing.T) {
	ev := newRecordingEvents("slack.new_messages")
	d, _, logs := newEventsTestDaemon(t, ev)
	for _, src := range []*countingSource{
		{typ: "slack.new_messages", beforeErr: errors.New("snapshot failed")},
		{typ: "slack.new_messages", afterErr: errors.New("diff failed")},
	} {
		ran := false
		d.observePhase(context.Background(), src, func() { ran = true })
		assert.True(t, ran, "the phase runs despite %v / %v", src.beforeErr, src.afterErr)
	}
	assert.Empty(t, ev.published)
	assert.Contains(t, logs.String(), "snapshot failed")
	assert.Contains(t, logs.String(), "diff failed")
}

// runSyncBody returns runSync's body from daemon.go.
func runSyncBody(t *testing.T, file *ast.File) *ast.BlockStmt {
	t.Helper()
	for _, decl := range file.Decls {
		if fd, ok := decl.(*ast.FuncDecl); ok && fd.Name.Name == "runSync" {
			return fd.Body
		}
	}
	t.Fatal("runSync not found in daemon.go")
	return nil
}

// runSyncCallOrder maps each method or function called in runSync to the
// index of the first top-level statement calling it (the
// TestDaemon_RunSync_PollsReactionsBeforeAIPipelines scan).
func runSyncCallOrder(t *testing.T) map[string]int {
	t.Helper()
	file, err := parser.ParseFile(token.NewFileSet(), "daemon.go", nil, 0)
	require.NoError(t, err)
	order := map[string]int{}
	for i, stmt := range runSyncBody(t, file).List {
		ast.Inspect(stmt, func(n ast.Node) bool {
			if call, ok := n.(*ast.CallExpr); ok {
				if sel, ok := call.Fun.(*ast.SelectorExpr); ok {
					if _, seen := order[sel.Sel.Name]; !seen {
						order[sel.Sel.Name] = i
					}
				}
			}
			return true
		})
	}
	return order
}

// runSyncObservedPhases maps each event source runSync observes (the
// automations.<X>Source passed to observePhase) to the phases its closure
// calls, in order.
func runSyncObservedPhases(t *testing.T) map[string][]string {
	t.Helper()
	file, err := parser.ParseFile(token.NewFileSet(), "daemon.go", nil, 0)
	require.NoError(t, err)
	out := map[string][]string{}
	ast.Inspect(runSyncBody(t, file), func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		if sel, ok := call.Fun.(*ast.SelectorExpr); !ok || sel.Sel.Name != "observePhase" || len(call.Args) != 3 {
			return true
		}
		srcCall, ok := call.Args[1].(*ast.CallExpr)
		if !ok {
			return true
		}
		srcSel, ok := srcCall.Fun.(*ast.SelectorExpr)
		require.True(t, ok, "observePhase's source is a constructor call")
		src := srcSel.Sel.Name
		ast.Inspect(call.Args[2], func(m ast.Node) bool {
			if c, ok := m.(*ast.CallExpr); ok {
				if s, ok := c.Fun.(*ast.SelectorExpr); ok && strings.HasPrefix(s.Sel.Name, "phase") {
					out[src] = append(out[src], s.Sel.Name)
				}
			}
			return true
		})
		return true
	})
	return out
}

// Compile-time: *automations.Bus is an AutomationEvents.
var _ AutomationEvents = (*automations.Bus)(nil)
