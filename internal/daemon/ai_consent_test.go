package daemon

import (
	"bytes"
	"context"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	gosync "sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/aiconsent"
	"watchtower/internal/briefing"
	"watchtower/internal/config"
	"watchtower/internal/dayplan"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/ideas"
	"watchtower/internal/reactioncmd"
	"watchtower/internal/tracks"
)

// fakeConsent is an aiconsent.Reader whose state a test flips.
type fakeConsent struct {
	mu gosync.Mutex
	s  aiconsent.State
}

func newFakeConsent(s aiconsent.State) *fakeConsent { return &fakeConsent{s: s} }

func (f *fakeConsent) set(s aiconsent.State) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.s = s
}

func (f *fakeConsent) read() aiconsent.State {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.s
}

var (
	consentAllowed          = aiconsent.Resolve(aiconsent.AnswerAllowed, nil)
	consentPausedUnanswered = aiconsent.Resolve(aiconsent.AnswerNone, nil)
	consentPausedByOwner    = aiconsent.Resolve(aiconsent.AnswerPaused, nil)
)

// channelFlipGen is a digest generator that counts the channel-digest calls,
// records whether each ran under an admitted background ctx, and runs onFirst
// on the first one.
type channelFlipGen struct {
	mu       gosync.Mutex
	calls    int
	admitted []bool
	onFirst  func()
}

func (g *channelFlipGen) Generate(ctx context.Context, _, _, _ string) (string, *digest.Usage, string, error) {
	const body = `{"summary":"s","topics":[{"title":"t","summary":"s","decisions":[],"action_items":[],"situations":[],"key_messages":[]}]}`
	src, _ := digest.SourceFromContext(ctx)
	if !strings.HasPrefix(src, "digest.channel") {
		return body, nil, "", nil // the rollup and friends: not this phase
	}
	g.mu.Lock()
	g.calls++
	first := g.calls == 1
	_, admitted := aiconsent.OriginOf(ctx)
	g.admitted = append(g.admitted, admitted)
	g.mu.Unlock()
	if first && g.onFirst != nil {
		g.onFirst()
	}
	return body, nil, "", nil
}

// countingJiraSyncer counts the Jira sync passes.
type countingJiraSyncer struct {
	stubJiraSyncer
	syncs atomic.Int32
}

func (s *countingJiraSyncer) Sync(ctx context.Context) (int, error) {
	s.syncs.Add(1)
	return s.stubJiraSyncer.Sync(ctx)
}

// newConsentCycleDaemon is a daemon with a counting Slack orchestrator, a
// counting Jira syncer and a test DB, consent read from fc.
func newConsentCycleDaemon(t *testing.T, fc *fakeConsent) (*Daemon, *db.DB, *atomic.Int32, *countingJiraSyncer) {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	require.NoError(t, os.MkdirAll(dir+"/.local/share/watchtower/test-ws", 0o755))
	slackCalls := new(atomic.Int32)
	orch, _ := newTestOrchestrator(t, slackCalls)
	cfg := &config.Config{
		ActiveWorkspace: "test-ws",
		Workspaces:      map[string]*config.WorkspaceConfig{"test-ws": {SlackToken: "xoxp-test"}},
		Sync:            config.SyncConfig{PollInterval: time.Second},
	}
	database := db.OpenTestDB(t)
	d := newDaemon(orch, cfg)
	d.SetLogger(log.New(os.Stderr, "[test-consent] ", 0))
	d.SetDB(database)
	d.SetConsent(fc.read)
	jira := &countingJiraSyncer{stubJiraSyncer: stubJiraSyncer{accountID: 1}}
	d.jiraSyncers = []jiraAccountSyncer{jira}
	return d, database, slackCalls, jira
}

// seedThreeDigestChannels seeds three medium-activity channels (the
// digest's low-activity threshold of recent messages each): with
// BatchMaxChannels = 1, three channel-digest calls.
func seedThreeDigestChannels(t *testing.T, database *db.DB) {
	t.Helper()
	require.NoError(t, database.UpsertUser(db.User{ID: "U1", Name: "alice", DisplayName: "Alice"}))
	now := time.Now().Unix()
	for c := range 3 {
		id := fmt.Sprintf("1:C%d", c)
		require.NoError(t, database.UpsertChannel(db.Channel{ID: id, Name: fmt.Sprintf("chan-%d", c), Type: "public"}))
		for i := range config.DefaultBatchLowActivityThreshold {
			require.NoError(t, database.UpsertMessage(db.Message{
				ChannelID: id, TS: fmt.Sprintf("%d.%06d", now-3600+int64(i*60), i),
				UserID: "U1", Text: fmt.Sprintf("message %d in %s", i, id),
			}))
		}
	}
}

// BGAI-01 / D12: a pause written while the digest phase runs lets that
// phase finish every call, skips the next AI phase (media: no call, no
// pipeline_runs row) and never stops the sync phases of the next cycle.
func TestBGAI01_PauseMidCycleFinishesPhaseSkipsNext(t *testing.T) {
	fc := newFakeConsent(consentAllowed)
	d, database, slackCalls, jira := newConsentCycleDaemon(t, fc)
	d.config.Digest = config.DigestConfig{Enabled: true, MinMessages: 3, BatchMaxChannels: 1, Language: "English"}
	gen := &channelFlipGen{onFirst: func() { fc.set(consentPausedByOwner) }}
	d.SetDigestPipeline(digest.New(database, d.config, gen, d.logger))
	seedThreeDigestChannels(t, database)

	d.config.Knowledge.Enabled = true
	seedPendingMedia(t, database)
	mediaGen, op := &mediaTestGen{}, &mediaTestOpener{}
	newMediaTestPipeline(d, database, mediaGen, op)

	d.runSync(context.Background(), context.Background())

	assert.Equal(t, 3, gen.calls, "the started phase finishes all its calls")
	assert.Equal(t, []bool{true, true, true}, gen.admitted, "the phase runs as an admitted background unit")
	assert.Zero(t, mediaGen.calls.Load(), "the next AI phase is skipped")
	assert.Zero(t, op.opens.Load())
	assert.Zero(t, countPipelineRuns(t, database, "media-describe"))
	assert.Zero(t, countPipelineRuns(t, database, "media"))
	slackFirst, jiraFirst := slackCalls.Load(), jira.syncs.Load()
	require.Positive(t, slackFirst)
	require.Equal(t, int32(1), jiraFirst)

	d.lastJira = time.Time{} // past the Jira interval
	d.runSync(context.Background(), context.Background())

	assert.Greater(t, slackCalls.Load(), slackFirst, "Slack still syncs while paused")
	assert.Equal(t, int32(2), jira.syncs.Load(), "Jira still syncs while paused")
	assert.Equal(t, 3, gen.calls, "no channel-digest call while paused")
}

// BGAI-01: a phase refused by the backstop is a skip, not a failure: its
// pipeline_runs row carries no error text.
func TestBGAI01_PauseMidCycleSkipsWithoutErrorRow(t *testing.T) {
	d, database, _, _ := newConsentCycleDaemon(t, newFakeConsent(consentAllowed))
	var logs bytes.Buffer
	d.SetLogger(log.New(&logs, "", 0))
	d.config.Digest = config.DigestConfig{Enabled: true, Language: "English"}
	gen := &preflightFailureGenerator{err: fmt.Errorf("digest: %w", aiconsent.ErrPaused)}
	d.SetDigestPipeline(digest.New(database, d.config, gen, d.logger))

	d.phaseChannelDigests(context.Background())

	var status, errMsg string
	require.NoError(t, database.QueryRow(`SELECT status, error_msg FROM pipeline_runs WHERE pipeline = 'digests'`).
		Scan(&status, &errMsg))
	assert.Empty(t, errMsg)
	assert.Equal(t, "done", status)
	assert.Contains(t, logs.String(), "digests: skipped: background AI is paused")
}

// historyBackfillDump is every column of every history_backfill row.
func historyBackfillDump(t *testing.T, database *db.DB) string {
	t.Helper()
	rows, err := database.Query(`SELECT * FROM history_backfill ORDER BY id`)
	require.NoError(t, err)
	defer rows.Close()
	cols, err := rows.Columns()
	require.NoError(t, err)
	var b strings.Builder
	for rows.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		require.NoError(t, rows.Scan(ptrs...))
		fmt.Fprintf(&b, "%v\n", vals)
	}
	require.NoError(t, rows.Err())
	return b.String()
}

// BGAI-01 / D12: while paused the history backfill holds whole: no fetch,
// no row change, no hold strike, no pipeline_runs row. Allowed again, the
// same row is fetched.
func TestBGAI01_PausedHoldsBackfillWhole(t *testing.T) {
	fc := newFakeConsent(consentPausedUnanswered)
	d, database, _ := newBackfillDaemon(t)
	d.SetConsent(fc.read)
	acct, err := database.CreateEmailAccount(db.EmailAccount{Provider: "imap", EmailAddress: "me@example.com",
		Host: "imap.example.com", Port: 993, Security: "ssl", Folder: "INBOX"})
	require.NoError(t, err)
	now := time.Now()
	_, err = database.StartHistoryBackfill("imap", acct, float64(now.AddDate(0, 0, -30).Unix()),
		float64(now.AddDate(0, 0, -3).Unix()), now)
	require.NoError(t, err)
	var fetches atomic.Int32
	probe := newCycleProbe()
	probe.fetchRange = func(context.Context) error { fetches.Add(1); return nil }
	d.imapSyncers = []mailSyncer{probe}

	before := historyBackfillDump(t, database)
	rows, err := database.ListHistoryBackfills()
	require.NoError(t, err)
	require.Len(t, rows, 1)
	strikes := rows[0].ChunkFailures

	d.runSync(context.Background(), context.Background())

	assert.Zero(t, fetches.Load(), "no backfill fetch while paused")
	assert.Equal(t, before, historyBackfillDump(t, database), "the rows are untouched")
	rows, err = database.ListHistoryBackfills()
	require.NoError(t, err)
	assert.Equal(t, strikes, rows[0].ChunkFailures, "no hold strike")
	assert.Zero(t, countPipelineRuns(t, database, "history-backfill"))

	fc.set(consentAllowed)
	d.runSync(context.Background(), context.Background())
	assert.Positive(t, fetches.Load(), "allowed: the backfill fetches")
}

// BGAI-02 / D3: a reaction command is the owner's gesture: while paused the
// poll still runs, once, on an owner-started ctx (the fetch ctx's own
// background mark does not leak into it).
func TestDaemon_ReactionCommandsRunWhilePaused(t *testing.T) {
	cfg := &config.Config{ReactionCommands: config.ReactionCommandsConfig{
		Enabled:       true,
		IntervalHours: config.DefaultReactionCommandsIntervalHours,
	}}
	d, _ := newReactionTestDaemon(t, cfg)
	d.SetConsent(newFakeConsent(consentPausedByOwner).read)
	var origins []aiconsent.Origin
	accountsFn := func(ctx context.Context) ([]reactioncmd.Account, error) {
		o, _ := aiconsent.OriginOf(ctx)
		origins = append(origins, o)
		return nil, nil
	}
	d.SetReactionCommandsPipeline(reactioncmd.New(d.db, cfg, nil, nil, accountsFn, nil))

	fetchCtx := aiconsent.WithAdmitted(context.Background(), "phase:test")
	d.runSync(context.Background(), fetchCtx)

	assert.Equal(t, []aiconsent.Origin{aiconsent.OriginOwner}, origins)
}

// The paused line is logged once per state change, not once per cycle.
func TestDaemon_ConsentLogOncePerChange(t *testing.T) {
	fc := newFakeConsent(consentPausedUnanswered)
	d, _, _, _ := newConsentCycleDaemon(t, fc)
	var logs bytes.Buffer
	d.SetLogger(log.New(&logs, "", 0))
	pausedLines := func() []string {
		var out []string
		for _, l := range strings.Split(logs.String(), "\n") {
			if strings.HasPrefix(l, "background AI:") {
				out = append(out, l)
			}
		}
		return out
	}

	for range 3 {
		d.runSync(context.Background(), context.Background())
	}
	assert.Equal(t, []string{aiconsent.LogLine(consentPausedUnanswered)}, pausedLines())

	fc.set(consentAllowed)
	d.runSync(context.Background(), context.Background())
	fc.set(consentPausedByOwner)
	d.runSync(context.Background(), context.Background())
	d.runSync(context.Background(), context.Background())
	lines := pausedLines()
	require.Len(t, lines, 2)
	assert.Contains(t, lines[1], "paused by you")
}

// pausedGenerator refuses every call as the per-call backstop would.
type pausedGenerator struct{ calls int }

func (g *pausedGenerator) Generate(context.Context, string, string, string) (string, *digest.Usage, string, error) {
	g.calls++
	return "", nil, "", fmt.Errorf("generate: %w", aiconsent.ErrPaused)
}

// pausedDayPlanRunner refuses every day-plan run with ErrPaused.
type pausedDayPlanRunner struct{ fakeDayPlanRunner }

func (f *pausedDayPlanRunner) Run(context.Context, dayplan.RunOptions) (*db.DayPlan, error) {
	f.runCalls++
	return nil, fmt.Errorf("dayplan: %w", aiconsent.ErrPaused)
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// BGAI-01: while paused the Track my threads group (built-in not active)
// runs neither the legacy tracks phase nor the rollups: no model call, no
// tracks row or stamp, no rollup attempt, no pending daily-digest file.
// Allowed again, the rollup reaches the model.
func TestBGAI01_PausedTrackGroupSkipsLegacyTracksAndRollups(t *testing.T) {
	d, database, gen := rollupBackoffTestSetup(t)
	fc := newFakeConsent(consentPausedByOwner)
	d.SetConsent(fc.read)
	d.config.Tracks.Enabled = true
	d.SetTracksPipeline(tracks.New(database, d.config, gen, d.logger))

	d.runSync(context.Background(), context.Background())

	assert.Zero(t, gen.calls, "no tracks or rollup model call")
	assert.Zero(t, d.rollupAttempts)
	assert.False(t, fileExists(d.rollupAttemptsPath()), "no rollup attempt marker")
	assert.False(t, fileExists(filepath.Join(d.config.WorkspaceDir(), "digest_pending_daily.json")))
	assert.Zero(t, countPipelineRuns(t, database, "tracks"))
	assert.True(t, d.tracksRanAt.IsZero(), "no tracks stamp")

	fc.set(consentAllowed)
	d.runSync(context.Background(), context.Background())
	assert.Positive(t, gen.calls, "allowed: the group reaches the model")
}

// BGAI-01: the legacy Morning brief (built-in not active) holds while
// paused: no briefing or day-plan call, no attempt spent.
func TestBGAI01_PausedLegacyMorningBriefSpendsNothing(t *testing.T) {
	d, _, gen := briefingBackoffTestSetup(t)
	fc := newFakeConsent(consentPausedUnanswered)
	d.SetConsent(fc.read)
	d.config.DayPlan.Enabled = true
	fp := &fakeDayPlanRunner{alwaysFail: true}
	d.SetDayPlanPipeline(fp)

	for range 3 {
		d.phaseMorningBrief(context.Background(), time.Now())
	}
	assert.Zero(t, gen.calls)
	assert.Zero(t, fp.runCalls)
	assert.Zero(t, d.briefingAttempts)
	assert.Zero(t, d.dayPlanAttempts)

	fc.set(consentAllowed)
	d.phaseMorningBrief(context.Background(), time.Now())
	assert.Equal(t, 1, gen.calls, "allowed: the briefing reaches the model")
}

// BGAI-01: the legacy Idea finder (built-in not active) holds while paused:
// no ideas row and no lastIdeas stamp.
func TestBGAI01_PausedLegacyIdeaFinderStampsNothing(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	fc := newFakeConsent(consentPausedUnanswered)
	d.SetConsent(fc.read)
	d.config.Ideas.Enabled = true
	d.SetIdeasPipeline(ideas.New(database, d.config, &mockGenerator{}, d.logger))

	d.phaseIdeaFinder(context.Background())
	assert.Zero(t, countPipelineRuns(t, database, "ideas"))
	assert.True(t, d.lastIdeas.IsZero(), "no throttle stamp")

	fc.set(consentAllowed)
	d.phaseIdeaFinder(context.Background())
	assert.Equal(t, 1, countPipelineRuns(t, database, "ideas"), "allowed: the legacy phase runs")
}

// BGAI-01: the legacy custom-track scan (built-in not active) holds while
// paused: no model call, no custom_tracks row. Allowed again, it scans.
func TestBGAI01_PausedLegacyCustomTrackScanWritesNothing(t *testing.T) {
	f := newSlotFixture(t, nil)
	fc := newFakeConsent(consentPausedUnanswered)
	f.d.SetConsent(fc.read)
	f.d.builtinActive[customTracksID] = false
	_, err := f.db.CreateCustomTrack(db.Track{AssigneeUserID: f.owner.ID, Text: "unbound", Instruction: "watch the unbound sentinel"})
	require.NoError(t, err)

	f.d.phaseWatchSlot(context.Background())
	assert.Zero(t, f.gen.callsWith("watch the unbound sentinel"))
	assert.Zero(t, pipelineRunCount(t, f.db, "custom_tracks"))

	fc.set(consentAllowed)
	f.d.phaseWatchSlot(context.Background())
	assert.Equal(t, 1, pipelineRunCount(t, f.db, "custom_tracks"), "allowed: the legacy scan runs")
}

// A refusal with ErrPaused (the per-call backstop) is deferred, not an
// attempt: the rollup, briefing and day-plan budgets stay whole.
func TestBGAI01_ErrPausedSpendsNoAttempt(t *testing.T) {
	t.Run("rollup", func(t *testing.T) {
		d, database, _ := rollupBackoffTestSetup(t)
		gen := &pausedGenerator{}
		d.SetDigestPipeline(digest.New(database, d.config, gen, d.logger))
		for range maxDailyAIAttempts + 1 {
			d.phaseTrackMyThreads(context.Background(), rollupFixedNow, true)
		}
		assert.Equal(t, maxDailyAIAttempts+1, gen.calls, "never given up for the day")
		assert.Zero(t, d.rollupAttempts)
	})
	t.Run("briefing", func(t *testing.T) {
		d, database, _ := briefingBackoffTestSetup(t)
		gen := &pausedGenerator{}
		d.SetBriefingPipeline(briefing.New(database, d.config, gen, d.logger))
		for range maxDailyAIAttempts + 1 {
			d.phaseBriefing(context.Background())
		}
		assert.Equal(t, maxDailyAIAttempts+1, gen.calls)
		assert.Zero(t, d.briefingAttempts)
	})
	t.Run("day plan", func(t *testing.T) {
		d, _, _ := dayPlanBackoffTestSetup(t)
		fp := &pausedDayPlanRunner{}
		d.SetDayPlanPipeline(fp)
		at := time.Date(2026, 4, 23, 8, 0, 0, 0, time.Local)
		for i := range maxDailyAIAttempts + 1 {
			now := at.Add(time.Duration(i) * time.Hour)
			d.runDayPlanPhase(context.Background(), now, d.dayPlanOwner(now))
		}
		assert.Equal(t, maxDailyAIAttempts+1, fp.runCalls)
		assert.Zero(t, d.dayPlanAttempts)
	})
}
