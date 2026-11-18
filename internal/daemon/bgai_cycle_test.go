package daemon

import (
	"context"
	"io"
	"log"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/aiconsent"
	"watchtower/internal/aiconsent/aiconsenttest"
	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/automations/builtin"
	"watchtower/internal/briefing"
	"watchtower/internal/config"
	"watchtower/internal/customtracks"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/guide"
	"watchtower/internal/ideas"
	"watchtower/internal/memory"
	"watchtower/internal/sessionfeed"
	"watchtower/internal/targets"
	"watchtower/internal/tracks"
)

// TestBGAI01_NilReaderFailsClosed (BGAI-01, Decision 9), the daemon's twin
// of the automations one: a daemon built without a consent reader reads
// aiconsent.Current, and an install whose owner has not answered reads
// paused there, so aiPhase does not run its phase.
func TestBGAI01_NilReaderFailsClosed(t *testing.T) {
	aiconsenttest.Unanswered(t)
	d := New(&config.Config{ActiveWorkspace: "test-ws"})
	d.SetLogger(log.New(io.Discard, "", 0))

	ran := false
	d.aiPhase(context.Background(), "digests", func(context.Context) { ran = true })

	assert.False(t, ran, "a nil reader must not run an AI phase before the owner answers")
	assert.Equal(t, aiconsent.ReasonUnanswered, d.consentNow().Reason)
}

// cycleGen is every model leaf of the full-cycle test: it counts each call
// that reaches it, whatever its origin, and answers with a digest body.
type cycleGen struct{ calls atomic.Int32 }

func (g *cycleGen) Generate(context.Context, string, string, string) (string, *digest.Usage, string, error) {
	g.calls.Add(1)
	return `{"summary":"s","topics":[{"title":"t","summary":"s","decisions":[],"action_items":[],"situations":[],"key_messages":[]}]}`,
		nil, "", nil
}

// overrideConsent makes aiconsent.Current — the default of every component
// built without a reader — read fc for this test.
func overrideConsent(t *testing.T, fc *fakeConsent) {
	t.Helper()
	aiconsent.SetCurrentOverrideForTest(fc.read)
	t.Cleanup(aiconsenttest.AllowByDefault)
}

// daemonOrigin makes this test process's default origin background, as in
// the daemon, so only a ctx mark makes a call the owner's.
func daemonOrigin(t *testing.T) {
	t.Helper()
	none := func(string) string { return "" }
	aiconsent.InitProcess("daemon", none)
	t.Cleanup(func() { aiconsent.InitProcess("", none) })
}

// aiPipelines are the pipeline_runs names of the phases that call a model.
var aiPipelines = []string{
	"briefing", "coach", "custom_tracks", "day_plan", "digests", "history-backfill", "ideas",
	"jira-boards", "media", "media-describe", "memory", "next_step", "people", "people-backfill",
	"stream-digests", "tracks",
}

const (
	bgaiSchedRecipe = "---\nname: Hourly sum-up\ntrigger:\n  schedule: \"0 * * * *\"\nmissed: run_once\n" +
		"permissions:\n  - llm:light\n---\nSums up every hour.\n\n```js\nreturn llm(\"sum up\")\n```\n"
	bgaiEventRecipe = "---\nname: Jira watch\ntrigger:\n  event:\n    type: jira.issue_changed\n    where: {}\n" +
		"permissions:\n  - llm:light\n---\nSums up a Jira change.\n\n```js\nreturn llm(\"sum up\")\n```\n"
)

// TestBGAI01_PausedCycleMakesNoModelCall (BGAI-01): with every feature on,
// Slack, mail and Jira fakes with data, one AI schedule recipe due and one
// AI event recipe matching, a paused cycle (runSync, a scheduler Tick, an
// executor Step) makes no model call, writes no AI pipeline_runs row and no
// running or succeeded automation run, still runs every sync and leaves the
// history backfill untouched. Allowed, the same sequence calls the model.
func TestBGAI01_PausedCycleMakesNoModelCall(t *testing.T) {
	daemonOrigin(t)
	fc := newFakeConsent(consentPausedUnanswered)
	overrideConsent(t, fc)
	d, database, slackCalls, _ := newConsentCycleDaemon(t, fc)
	d.SetConsent(nil) // the production default: aiconsent.Current
	quiet := log.New(io.Discard, "", 0)
	d.SetLogger(quiet)
	gen := &cycleGen{}

	// Every feature on, each pipeline on the counting leaf.
	cfg := d.config
	cfg.Digest = config.DigestConfig{Enabled: true, MinMessages: 3, BatchMaxChannels: 1, Language: "English"}
	cfg.Knowledge.Enabled = true
	cfg.Tracks.Enabled = true
	cfg.People.Enabled = true
	cfg.Streams.Enabled = true
	cfg.Ideas.Enabled = true
	cfg.Memory.Enabled = true
	cfg.Targets.NextStep.Enabled = true
	cfg.Briefing.Enabled = true
	cfg.DayPlan.Enabled = true
	cfg.Sync.BackfillDays = 30
	d.SetDigestPipeline(digest.New(database, cfg, gen, quiet))
	seedThreeDigestChannels(t, database)
	seedPendingMedia(t, database)
	newMediaTestPipeline(d, database, gen, &mediaTestOpener{})
	d.SetTracksPipeline(tracks.New(database, cfg, gen, quiet))
	d.SetCustomTracksPipeline(customtracks.New(database, gen, cfg.Digest.Language, quiet))
	d.SetPeoplePipeline(guide.New(database, cfg, gen, quiet))
	d.SetIdeasPipeline(ideas.New(database, cfg, gen, quiet))
	d.SetBriefingPipeline(briefing.New(database, cfg, gen, quiet))
	d.SetNextStepPipeline(targets.New(database, &cfg.Targets, gen, nil, cfg.Digest.Language, quiet))
	dayPlan := &fakeDayPlanRunner{}
	d.SetDayPlanPipeline(dayPlan)
	vault, err := memory.OpenVault(filepath.Join(cfg.WorkspaceDir(), "memory"))
	require.NoError(t, err)
	d.SetMemoryPipeline(memory.NewPipeline(database, vault, gen, cfg.Memory, quiet.Printf))
	oldCoachGen, oldCoachDirs := coachGeneratorFactory, coachSessionDirs
	coachGeneratorFactory = func(*config.Config) digest.Generator { return gen }
	coachDir := t.TempDir()
	coachSessionDirs = func() sessionfeed.Dirs {
		return sessionfeed.Dirs{ClaudeProjects: coachDir, CodexHome: coachDir}
	}
	t.Cleanup(func() { coachGeneratorFactory, coachSessionDirs = oldCoachGen, oldCoachDirs })

	// The AI built-ins active at their slots, on their own executor.
	clock := automationstest.NewFakeClock(time.Date(2026, 10, 14, 8, 30, 0, 0, time.Local))
	slotExec := automations.NewExecutor(database, automations.Backends{DB: database, Clock: clock,
		Primitives: d.BuiltinPrimitives(), DefaultPrompt: builtin.DefaultPromptFunc}, automations.ExecutorOptions{Logger: quiet})
	gates := map[string]builtin.Gate{morningBriefID: d.MorningBriefGate(), trackMyThreadsID: d.TrackMyThreadsGate(),
		ideaFinderID: d.IdeaFinderGate(), waitingForMeID: d.WaitingForMeGate()}
	_, err = builtin.Sync(context.Background(), database, cfg.WorkspaceDir(), cfg, clock.Now())
	require.NoError(t, err)
	d.SetBuiltins(builtin.NewRunner(database, slotExec, gates, cfg, clock, quiet),
		map[string]bool{morningBriefID: true, trackMyThreadsID: true, ideaFinderID: true, customTracksID: true})

	// Mail: a sync fake, and a history backfill row on its account.
	acct, err := database.CreateEmailAccount(db.EmailAccount{Provider: "imap", EmailAddress: "me@example.com",
		Host: "imap.example.com", Port: 993, Security: "ssl", Folder: "INBOX"})
	require.NoError(t, err)
	now := time.Now()
	_, err = database.StartHistoryBackfill("imap", acct, float64(now.AddDate(0, 0, -30).Unix()),
		float64(now.AddDate(0, 0, -3).Unix()), now)
	require.NoError(t, err)
	var mailSyncs, fetches atomic.Int32
	mail := newCycleProbe()
	mail.onSync = func() { mailSyncs.Add(1) }
	mail.fetchRange = func(context.Context) error { fetches.Add(1); return nil }
	d.imapSyncers = []mailSyncer{mail}

	// Jira: each sync moves one issue, so the event source sees a change.
	jiraAcct, err := database.CreateJiraAccount(db.JiraAccount{CloudID: "c1", SiteURL: "https://acme.example.com",
		SiteName: "acme", Label: "work"})
	require.NoError(t, err)
	issue := db.JiraIssue{AccountID: jiraAcct, Key: "PAY-1", ProjectKey: "PAY", Summary: "s", Status: "Open",
		StatusCategory: "new", Priority: "High", CreatedAt: "2026-10-01T00:00:00Z",
		UpdatedAt: "2026-10-02T00:00:00Z", SyncedAt: "2026-10-02T00:00:00Z"}
	require.NoError(t, database.UpsertJiraIssue(issue))
	var jiraSyncs atomic.Int32
	d.jiraSyncers = []jiraAccountSyncer{&writingJiraSyncer{stubJiraSyncer: stubJiraSyncer{accountID: jiraAcct}, write: func() {
		n := jiraSyncs.Add(1)
		issue.Status, issue.UpdatedAt = []string{"Done", "Open"}[n%2], time.Date(2026, 10, 2, int(n), 0, 0, 0, time.UTC).Format(time.RFC3339)
		require.NoError(t, database.UpsertJiraIssue(issue))
	}}}

	// Automations: one AI schedule recipe due at 09:00, one AI event recipe
	// on any Jira change.
	sched := automationstest.SeedAutomation(t, database, bgaiSchedRecipe,
		automationstest.SeedOptions{Slug: "hourly", Now: clock.Now()})
	event := automationstest.SeedAutomation(t, database, bgaiEventRecipe,
		automationstest.SeedOptions{Slug: "jira-watch", Now: clock.Now()})
	d.SetAutomationEvents(automations.NewBus(database, clock, func() {}, quiet))
	scheduler := automations.NewScheduler(database, nil, clock, func() {})
	exec := automations.NewExecutor(database, automations.Backends{DB: database, Generator: gen,
		Registry: &automationstest.FakeRegistry{}, Clock: clock}, automations.ExecutorOptions{Logger: quiet})

	sequence := func(at time.Time) {
		t.Helper()
		clock.Set(at)
		d.lastJira = time.Time{} // past the Jira interval
		d.runSync(context.Background(), context.Background())
		require.NoError(t, scheduler.Tick(context.Background(), at))
		_, err := exec.Step(context.Background())
		require.NoError(t, err)
		exec.Wait()
	}
	runsOf := func(a db.Automation) []db.AutomationRun {
		t.Helper()
		runs, err := database.ListAutomationRuns(a.ID, 0)
		require.NoError(t, err)
		return runs
	}

	backfillBefore := historyBackfillDump(t, database)
	sequence(time.Date(2026, 10, 14, 9, 0, 0, 0, time.Local))

	assert.Zero(t, gen.calls.Load(), "paused: no model call")
	assert.Zero(t, dayPlan.runCalls, "paused: no day-plan generation")
	for _, name := range pipelineRunNames(t, database) {
		assert.NotContains(t, aiPipelines, name, "paused: an AI pipeline_runs row")
	}
	assert.Zero(t, countRows(t, database,
		`SELECT COUNT(*) FROM automation_runs WHERE status IN ('running', 'succeeded')`), "paused: no started run")
	for _, id := range []string{morningBriefID, trackMyThreadsID, ideaFinderID} {
		a, err := database.GetBuiltinAutomation(id)
		require.NoError(t, err)
		assert.Empty(t, runsOf(*a), "paused: AI built-in %s gets no run row in any status", id)
	}
	assert.Empty(t, runsOf(sched), "paused: the due schedule recipe gets no run")
	assert.Empty(t, runsOf(event), "paused: the matching event recipe gets no run")
	assert.Positive(t, slackCalls.Load(), "Slack syncs while paused")
	assert.Equal(t, int32(1), jiraSyncs.Load(), "Jira syncs while paused")
	assert.Equal(t, int32(1), mailSyncs.Load(), "mail syncs while paused")
	assert.Zero(t, fetches.Load(), "no backfill fetch while paused")
	// The existing rows are untouched. Slack's first sync may record its own
	// range as a new row: a sync-side write that the held phase never works.
	assert.True(t, strings.HasPrefix(historyBackfillDump(t, database), backfillBefore),
		"the history_backfill rows are untouched")

	fc.set(consentAllowed)
	sequence(time.Date(2026, 10, 14, 10, 0, 0, 0, time.Local))

	assert.Positive(t, gen.calls.Load(), "allowed: the same sequence calls the model")
	names := pipelineRunNames(t, database)
	assert.True(t, slices.Contains(names, "digests"), "allowed: the digest phase ran (%v)", names)
	assert.Equal(t, int32(2), jiraSyncs.Load())
	assert.NotEmpty(t, runsOf(sched), "allowed: the schedule recipe runs")
	assert.NotEmpty(t, runsOf(event), "allowed: the event recipe runs")
}

// TestBGAI01_RunStartedBeforePauseFinishes (BGAI-01, D12): a background
// run claimed while allowed keeps calling the model after a pause written
// by its own first step; the next due run is cancelled at its claim.
func TestBGAI01_RunStartedBeforePauseFinishes(t *testing.T) {
	daemonOrigin(t)
	fc := newFakeConsent(consentAllowed)
	overrideConsent(t, fc)
	database := db.OpenTestDB(t)
	clock := automationstest.NewFakeClock(time.Date(2026, 10, 14, 9, 0, 0, 0, time.UTC))
	var calls, refused atomic.Int32
	gen := generatorFunc(func(ctx context.Context) error {
		if err := aiconsent.Check(ctx); err != nil { // the per-call backstop
			refused.Add(1)
			return err
		}
		if calls.Add(1) == 1 {
			fc.set(consentPausedByOwner)
		}
		return nil
	})
	exec := automations.NewExecutor(database, automations.Backends{DB: database, Generator: gen,
		Registry: &automationstest.FakeRegistry{}, Clock: clock}, automations.ExecutorOptions{Logger: log.New(io.Discard, "", 0)})
	recipe := "---\nname: Two steps\ntrigger:\n  schedule: \"0 * * * *\"\nmissed: run_once\npermissions:\n  - llm:light\n" +
		"---\nTwo model steps.\n\n```js\nllm(\"first\"); return llm(\"second\")\n```\n"
	a := automationstest.SeedAutomation(t, database, recipe, automationstest.SeedOptions{Slug: "two-steps", Now: clock.Now()})
	enqueue := func() int64 {
		t.Helper()
		id, coalesced, err := database.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: a.ID,
			Trigger: db.TriggerSchedule, Now: clock.Now()})
		require.NoError(t, err)
		require.False(t, coalesced)
		return id
	}

	first := enqueue()
	started, err := exec.Step(context.Background())
	require.NoError(t, err)
	require.Equal(t, 1, started)
	exec.Wait()
	run, err := database.GetAutomationRun(first)
	require.NoError(t, err)
	assert.Equal(t, db.RunSucceeded, run.Status, "run error: %s", run.Error)
	assert.Equal(t, int32(2), calls.Load(), "both steps reached the model")
	assert.Zero(t, refused.Load())
	require.False(t, fc.read().Allowed(), "the first step paused background AI")

	clock.Set(clock.Now().Add(time.Hour))
	second := enqueue()
	started, err = exec.Step(context.Background())
	require.NoError(t, err)
	assert.Zero(t, started)
	run, err = database.GetAutomationRun(second)
	require.NoError(t, err)
	assert.Equal(t, db.RunCancelled, run.Status)
	assert.Equal(t, db.ErrKindCancelled, run.ErrorKind)
	assert.Equal(t, "Background AI is paused", run.Error)
	assert.Equal(t, int32(2), calls.Load(), "the cancelled run made no call")
}

// generatorFunc is a digest.Generator whose every call runs f and answers
// "done" when f returns nil.
type generatorFunc func(ctx context.Context) error

func (f generatorFunc) Generate(ctx context.Context, _, _, sessionID string) (string, *digest.Usage, string, error) {
	if err := f(ctx); err != nil {
		return "", nil, sessionID, err
	}
	return "done", nil, sessionID, nil
}

// TestBGAI01_PausedCycleSkipsMemory (BGAI-01): with memory on, messages to
// extract from and no history backfill to wait for, a paused cycle writes
// no memory pipeline_runs row and makes no call; allowed, the same cycle
// runs the memory phase.
func TestBGAI01_PausedCycleSkipsMemory(t *testing.T) {
	fc := newFakeConsent(consentPausedByOwner)
	d, database, _, _ := newConsentCycleDaemon(t, fc)
	quiet := log.New(io.Discard, "", 0)
	d.SetLogger(quiet)
	d.config.Memory.Enabled = true
	seedThreeDigestChannels(t, database)
	gen := &cycleGen{}
	vault, err := memory.OpenVault(filepath.Join(d.config.WorkspaceDir(), "memory"))
	require.NoError(t, err)
	d.SetMemoryPipeline(memory.NewPipeline(database, vault, gen, d.config.Memory, quiet.Printf))

	d.runSync(context.Background(), context.Background())
	require.Empty(t, historyBackfillDump(t, database), "no backfill for memory to wait on")
	assert.NotContains(t, pipelineRunNames(t, database), "memory", "paused: no memory run")
	assert.Zero(t, gen.calls.Load(), "paused: no memory call")

	fc.set(consentAllowed)
	d.runSync(context.Background(), context.Background())
	assert.Contains(t, pipelineRunNames(t, database), "memory", "allowed: the memory phase runs")
	assert.Positive(t, gen.calls.Load(), "allowed: memory calls the model")
}
