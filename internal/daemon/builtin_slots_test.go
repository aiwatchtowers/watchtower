package daemon

import (
	"context"
	"errors"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"log"
	"os"
	"path/filepath"
	"strings"
	gosync "sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/automations/builtin"
	"watchtower/internal/automations/watch"
	"watchtower/internal/config"
	"watchtower/internal/customtracks"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/ideas"
	"watchtower/internal/tracks"
)

// slotGenerator answers the tracks batch call with tracksReply and every
// other call (a custom-track scan) with no events, recording each user
// message.
type slotGenerator struct {
	mu          gosync.Mutex
	tracksReply string
	users       []string
}

func (g *slotGenerator) Generate(_ context.Context, _, user, _ string) (string, *digest.Usage, string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.users = append(g.users, user)
	usage := &digest.Usage{InputTokens: 10, OutputTokens: 5, TotalAPITokens: 15}
	if strings.Contains(user, "=== CHANNEL DIGESTS ===") {
		return g.tracksReply, usage, "", nil
	}
	return `{"events":[]}`, usage, "", nil
}

// callsWith counts the recorded user messages containing s.
func (g *slotGenerator) callsWith(s string) int {
	g.mu.Lock()
	defer g.mu.Unlock()
	n := 0
	for _, u := range g.users {
		if strings.Contains(u, s) {
			n++
		}
	}
	return n
}

// slotFixture is a daemon over a real database with an owner (U1), a
// channel digest the tracks pipeline can mine, tracks, digests and ideas
// on, real tracks/custom-track/ideas pipelines over gen, and the built-ins
// wired with the C3 built-ins and the custom-tracks move active.
type slotFixture struct {
	d     *Daemon
	db    *db.DB
	cfg   *config.Config
	gen   *slotGenerator
	owner db.Owner
}

func newSlotFixture(t *testing.T, edit func(cfg *config.Config)) *slotFixture {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	cfg, err := config.Load(filepath.Join(t.TempDir(), "absent.yaml"))
	require.NoError(t, err)
	cfg.ActiveWorkspace = "test-ws"
	cfg.Digest.Enabled, cfg.Digest.Language = true, "English"
	cfg.Tracks.Enabled = true
	cfg.Ideas.Enabled = true
	cfg.AI.Workers = 1
	if edit != nil {
		edit(cfg)
	}
	require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o755))

	database := db.OpenTestDB(t)
	gen := &slotGenerator{tracksReply: seedTracksMaterial(t, database)}
	owner, err := database.ResolveOwner()
	require.NoError(t, err)
	require.True(t, owner.Known())

	l := log.New(os.Stderr, "[test-slots] ", 0)
	d := newDaemon(nil, cfg)
	d.SetLogger(l)
	d.SetDB(database)
	d.SetTracksPipeline(tracks.New(database, cfg, gen, l))
	d.SetCustomTracksPipeline(customtracks.New(database, gen, "", l))
	d.SetIdeasPipeline(ideas.New(database, cfg, nil, l))
	wireTestBuiltins(t, d, database, cfg, automations.RealClock{})
	for _, id := range []string{trackMyThreadsID, ideaFinderID, customTracksID} {
		d.builtinActive[id] = true
	}
	return &slotFixture{d: d, db: database, cfg: cfg, gen: gen, owner: owner}
}

// seedTracksMaterial seeds the owner (U1), a requester (U2) and one channel
// digest whose topic asks the owner for a review, created an hour ago; it
// returns the tracks batch reply for it.
func seedTracksMaterial(t *testing.T, database *db.DB) string {
	t.Helper()
	require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "T1", Name: "test-ws", Domain: "test-ws"}))
	_, err := database.CreateSlackAccount(db.SlackAccount{CurrentUserID: "U1"})
	require.NoError(t, err)
	require.NoError(t, database.UpsertUser(db.User{ID: "U1", Name: "alice", DisplayName: "Alice"}))
	require.NoError(t, database.UpsertUser(db.User{ID: "U2", Name: "bob", DisplayName: "Bob"}))
	require.NoError(t, database.UpsertChannel(db.Channel{ID: "C1", Name: "backend", Type: "public"}))
	now := time.Now()
	digestID, err := database.UpsertDigest(db.Digest{
		ChannelID: "C1", Type: "channel",
		PeriodFrom: float64(now.Add(-2 * time.Hour).Unix()), PeriodTo: float64(now.Unix()),
		Summary: "Discussion about API PR review", MessageCount: 5, Model: "test",
	})
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO digest_topics (digest_id, idx, title, summary, decisions, action_items, situations, key_messages)
		VALUES (?, 0, 'API PR Review', 'Bob asked Alice to review the API pull request.', '[]',
		'[{"text":"Review API PR","assignee":"@alice","status":"open"}]', '[]', '[]')`, digestID)
	require.NoError(t, err)
	_, err = database.Exec(`UPDATE digests SET created_at = ? WHERE id = ?`,
		now.Add(-time.Hour).UTC().Format("2006-01-02T15:04:05Z"), digestID)
	require.NoError(t, err)
	ts := fmt.Sprintf("%d.000000", now.Add(-30*time.Minute).Unix())
	return `[{"channel_id": "C1", "items": [{
		"text": "Review API PR", "context": "Bob asked Alice to review the API pull request.",
		"category": "code_review", "ownership": "mine", "priority": "medium",
		"requester": {"name": "@bob", "user_id": "U2"},
		"participants": [{"name":"Bob","user_id":"U2","stance":"requester"}],
		"source_refs": [{"ts":"` + ts + `","author":"@bob","text":"can you review the API PR?"}],
		"tags": ["api"]}]}]`
}

// quiet makes the next Track my threads cycle find no material: the owner
// has a track and a done tracks run started after the digest was created.
func (f *slotFixture) quiet(t *testing.T) {
	t.Helper()
	_, err := f.db.UpsertTrack(db.Track{AssigneeUserID: f.owner.ID, Text: "Ship the launch", Priority: "high",
		ChannelIDs: `["C1"]`, SourceRefs: `[]`, Tags: `[]`})
	require.NoError(t, err)
	runID, err := f.db.CreatePipelineRun("tracks", "daemon", "auto")
	require.NoError(t, err)
	require.NoError(t, f.db.CompletePipelineRun(runID, 0, 0, 0, 0, 0, nil, nil, ""))
}

func (f *slotFixture) tracksCycle() {
	f.d.phaseTrackMyThreads(context.Background(), time.Now())
}

// builtinRuns is built-in id's automation runs.
func (f *slotFixture) builtinRuns(t *testing.T, id string) []db.AutomationRun {
	t.Helper()
	a, err := f.db.GetBuiltinAutomation(id)
	require.NoError(t, err)
	runs, err := f.db.ListAutomationRuns(a.ID, 0)
	require.NoError(t, err)
	return runs
}

func pipelineRunCount(t *testing.T, database *db.DB, pipeline string) int {
	t.Helper()
	return countRows(t, database, `SELECT COUNT(*) FROM pipeline_runs WHERE pipeline = ?`, pipeline)
}

// addWatchRecipe writes, indexes, confirms and enables the watch recipe
// slug with instruction in cfg's workspace.
func addWatchRecipe(t *testing.T, database *db.DB, cfg *config.Config, slug, instruction string) *db.Automation {
	t.Helper()
	clock := automations.RealClock{}
	ws := cfg.WorkspaceDir()
	data, err := watch.Render("Watch "+slug, instruction)
	require.NoError(t, err)
	dir, err := automations.CanonicalDir(automations.PersonalDir(ws))
	require.NoError(t, err)
	a, err := automations.NewIndexer(database, ws, clock).WriteRecipe(context.Background(),
		automations.Scope{Kind: automations.ScopePersonal}, dir, filepath.Join(dir, slug+".md"), data)
	require.NoError(t, err)
	require.NoError(t, database.ConfirmAutomation(a.ID, a.ApprovalHash, clock.Now()))
	require.NoError(t, database.SetAutomationEnabled(a.ID, true, clock.Now()))
	a, err = database.GetAutomation(a.ID)
	require.NoError(t, err)
	return a
}

func TestBuiltinPrimitives_HoldsC3Primitives(t *testing.T) {
	d := New(&config.Config{})
	prims := d.BuiltinPrimitives()
	for _, name := range []string{"tracks.extract", "ideas.consolidate", "reaction.compose", "track.scan"} {
		assert.NotNil(t, prims[name], "primitive %s has no implementation", name)
	}
	assert.NotNil(t, d.reactionSlot, "the daemon holds one reaction slot")
}

func TestTrackMyThreads_DueRunMakesTracksAndOneRun(t *testing.T) {
	f := newSlotFixture(t, nil)
	f.tracksCycle()

	runs := f.builtinRuns(t, trackMyThreadsID)
	require.Len(t, runs, 1)
	assert.Equal(t, db.TriggerSync, runs[0].Trigger)
	assert.Equal(t, db.RunSucceeded, runs[0].Status, runs[0].Error)
	assert.Positive(t, runs[0].InputTokens, "the run's meter saw the pipeline's usage")
	assert.Equal(t, 1, pipelineRunCount(t, f.db, "tracks"))
	assert.Equal(t, 1, countRows(t, f.db,
		`SELECT COUNT(*) FROM pipeline_runs WHERE pipeline = 'tracks' AND period_from > 0 AND period_to > period_from`),
		"the tracks row keeps the run's window")
	active, err := f.db.GetAllActiveTracks()
	require.NoError(t, err)
	assert.NotEmpty(t, active, "the run made tracks")
}

func TestTrackMyThreads_QuietCycleWritesNoRun(t *testing.T) {
	f := newSlotFixture(t, nil)
	f.quiet(t)
	f.tracksCycle()

	assertNoAutomationRuns(t, f.db)
	assert.Equal(t, 1, pipelineRunCount(t, f.db, "tracks"), "only the seeded earlier run: the quiet cycle wrote none")
	assert.Zero(t, f.gen.callsWith("=== CHANNEL DIGESTS ==="), "no extraction call")
}

func TestTrackMyThreads_RetryDigestsMakeItDue(t *testing.T) {
	f := newSlotFixture(t, nil)
	f.quiet(t)
	_, err := f.db.Exec(`INSERT INTO track_retry_digests (digest_id, attempts) SELECT id, 1 FROM digests`)
	require.NoError(t, err)
	f.tracksCycle()

	runs := f.builtinRuns(t, trackMyThreadsID)
	require.Len(t, runs, 1, "an owed retry digest is material")
	assert.Equal(t, db.TriggerSync, runs[0].Trigger)
	assert.Equal(t, 2, pipelineRunCount(t, f.db, "tracks"))
}

func TestTrackMyThreads_TrackContextInjectedEvenWhenNotDue(t *testing.T) {
	f := newSlotFixture(t, nil)
	f.d.SetDigestPipeline(digest.New(f.db, f.cfg, &erroringGenerator{}, f.d.logger))
	f.quiet(t)
	f.tracksCycle()

	assertNoAutomationRuns(t, f.db)
	assert.Contains(t, f.d.digestPipe.TrackContext, "Ship the launch", "the active tracks reach the rollups")
}

func TestTrackMyThreads_UnconfirmedCopyStopsExtractionNotRollups(t *testing.T) {
	f := newSlotFixture(t, nil)
	e, ok := builtin.Lookup(trackMyThreadsID)
	require.True(t, ok)
	prompt, err := e.DefaultPrompt("extract", "")
	require.NoError(t, err)
	data, err := builtin.RenderOwnerCopy(e, map[string]string{"extract": prompt + "\nAlso note deadlines."})
	require.NoError(t, err)
	path := builtin.OwnerCopyPath(f.cfg.WorkspaceDir(), trackMyThreadsID)
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o700))
	require.NoError(t, os.WriteFile(path, data, 0o600))
	a, err := builtin.SyncOne(context.Background(), f.db, f.cfg.WorkspaceDir(), f.cfg, trackMyThreadsID, time.Now())
	require.NoError(t, err)
	require.False(t, a.Confirmed(), "the edited copy waits for the owner")

	seedTwoChannelDigests(t, f.db)
	rollupGen := &erroringGenerator{}
	f.d.SetDigestPipeline(digest.New(f.db, f.cfg, rollupGen, f.d.logger))
	f.tracksCycle()

	assertNoAutomationRuns(t, f.db)
	assert.Zero(t, pipelineRunCount(t, f.db, "tracks"), "no extraction")
	assert.Zero(t, f.gen.callsWith("=== CHANNEL DIGESTS ==="))
	assert.Positive(t, rollupGen.calls, "the rollups still ran")
}

func TestTrackMyThreads_LegacyPathWhenNotActive(t *testing.T) {
	f := newSlotFixture(t, nil)
	f.d.builtinActive[trackMyThreadsID] = false
	f.tracksCycle()

	assertNoAutomationRuns(t, f.db)
	assert.Equal(t, 1, pipelineRunCount(t, f.db, "tracks"))
	active, err := f.db.GetAllActiveTracks()
	require.NoError(t, err)
	assert.NotEmpty(t, active)
}

// The watch slot runs before Track my threads in runSync, so a watch's
// events (and its track's folds) land before auto extraction dedups against
// them. Pinned statically (the repo's go/parser scan precedent:
// TestDaemon_RunSync_PollsReactionsBeforeAIPipelines) because runSync has no
// seam to record the phase order at run time.
func TestWatchSlot_RunsBeforeTrackMyThreads(t *testing.T) {
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
	watchSlot, ok := order["phaseWatchSlot"]
	require.True(t, ok, "runSync must call phaseWatchSlot")
	threads, ok := order["phaseTrackMyThreads"]
	require.True(t, ok, "runSync must call phaseTrackMyThreads")
	ideaFinder, ok := order["phaseIdeaFinder"]
	require.True(t, ok, "runSync must call phaseIdeaFinder")
	assert.Less(t, watchSlot, threads)
	assert.Less(t, threads, ideaFinder)
	for _, gone := range []string{"phaseCustomTrackScan", "phaseTracksAndRollups", "phaseIdeas"} {
		_, called := order[gone]
		assert.False(t, called, "runSync calls %s only through its slot", gone)
	}
}

func TestWatchSlot_LegacyScansOnlyUnboundTracks(t *testing.T) {
	f := newSlotFixture(t, nil)
	f.d.builtinActive[customTracksID] = false
	_, err := f.db.CreateCustomTrack(db.Track{AssigneeUserID: f.owner.ID, Text: "unbound", Instruction: "watch the unbound sentinel"})
	require.NoError(t, err)
	addWatchRecipe(t, f.db, f.cfg, "bound", "watch the bound sentinel")

	f.d.phaseWatchSlot(context.Background())

	assert.Equal(t, 1, f.gen.callsWith("watch the unbound sentinel"), "the legacy scan scans the unbound track")
	assert.Equal(t, 1, f.gen.callsWith("watch the bound sentinel"), "the bound track is scanned once, by its recipe")
	assert.Equal(t, 1, pipelineRunCount(t, f.db, "custom_tracks"), "the legacy scan's row")
	assert.Equal(t, 1, countRows(t, f.db, `SELECT COUNT(*) FROM automation_runs WHERE trigger = 'sync'`), "the recipe's run")
}

func TestIdeaFinder_ThrottleAndLockAsToday(t *testing.T) {
	f := newSlotFixture(t, nil)
	cycle := func() { f.d.phaseIdeaFinder(context.Background()) }

	cycle()
	require.Len(t, f.builtinRuns(t, ideaFinderID), 1)
	assert.False(t, f.d.lastIdeas.IsZero(), "the run stamps the throttle")
	cycle()
	assert.Len(t, f.builtinRuns(t, ideaFinderID), 1, "the throttle holds the next cycle")

	f.d.lastIdeas = time.Time{}
	release, err := ideas.AcquireBackfillLock(f.cfg.WorkspaceDir(), "CLI backfill")
	require.NoError(t, err)
	cycle()
	assert.Len(t, f.builtinRuns(t, ideaFinderID), 1, "a fresh backfill lock holds the cycle")
	assert.True(t, f.d.lastIdeas.IsZero(), "a held lock does not stamp the throttle")
	release()

	cycle()
	runs := f.builtinRuns(t, ideaFinderID)
	require.Len(t, runs, 2, "the lock released, the slot runs again")
	assert.Equal(t, db.RunSucceeded, runs[0].Status, runs[0].Error)
	assert.Equal(t, 2, pipelineRunCount(t, f.db, "ideas"))
}

func TestIdeaFinder_ErrorStillStampsThrottle(t *testing.T) {
	orch, cfg, _ := testDaemonWithTempHome(t)
	cfg.Ideas.Enabled, cfg.Ideas.MineIntervalHours = true, 6
	cfg.Streams.Enabled, cfg.Streams.IntervalHours = true, 6
	cfg.Digest.Language = "English"
	database := db.OpenTestDB(t)
	emailTag := seedIdeasEmailMaterial(t, database)
	gen := &usageFakeGen{reply: func(user string) (string, error) {
		if strings.Contains(user, "=== NEW MATERIAL ===") {
			return "", errors.New("model down")
		}
		return fmt.Sprintf(`{"topics":[{"title":"t","summary":"s","ideas":[{"text":"idea","author":"Ann","ref":%q}],"decisions":[]}]}`, emailTag), nil
	}}
	d := newDaemon(orch, cfg)
	d.SetLogger(log.New(os.Stderr, "[test-idea-finder] ", 0))
	d.SetDB(database)
	d.SetIdeasPipeline(ideas.New(database, cfg, gen, d.logger))
	wireTestBuiltins(t, d, database, cfg, automations.RealClock{})
	d.builtinActive[ideaFinderID] = true

	d.phaseStreamDigests(context.Background())
	d.phaseIdeaFinder(context.Background())

	a, err := database.GetBuiltinAutomation(ideaFinderID)
	require.NoError(t, err)
	runs, err := database.ListAutomationRuns(a.ID, 0)
	require.NoError(t, err)
	require.Len(t, runs, 1)
	assert.Equal(t, db.RunFailed, runs[0].Status)
	assert.False(t, d.lastIdeas.IsZero(), "an erroring run still advances the throttle")
	assert.Equal(t, 1, countRows(t, database, `SELECT COUNT(*) FROM pipeline_runs WHERE pipeline = 'ideas' AND status = 'error'`))

	d.phaseIdeaFinder(context.Background())
	runs, err = database.ListAutomationRuns(a.ID, 0)
	require.NoError(t, err)
	assert.Len(t, runs, 1, "the next cycle waits for the interval, as today")
}

// The watches stop with Track my threads (FEAT-01): with tracks or digests
// off a due watch recipe writes no run and makes no call.
func TestWatchSlot_StopsWithTracksOrDigestsOff(t *testing.T) {
	for name, off := range map[string]func(cfg *config.Config){
		"tracks_off":  func(cfg *config.Config) { cfg.Tracks.Enabled = false },
		"digests_off": func(cfg *config.Config) { cfg.Digest.Enabled = false },
	} {
		t.Run(name, func(t *testing.T) {
			f := newSlotFixture(t, nil)
			addWatchRecipe(t, f.db, f.cfg, "launch", "watch the launch sentinel")
			off(f.cfg)
			f.d.phaseWatchSlot(context.Background())
			assertNoAutomationRuns(t, f.db)
			assert.Zero(t, f.gen.callsWith("watch the launch sentinel"))
		})
	}
}

// TestWatchSlot_GatesOffCancelQueuedManualRuns: a manual watch run queued
// before tracks or digests went off is cancelled not_runnable by the slot
// that does not run, so it never waits forever.
func TestWatchSlot_GatesOffCancelQueuedManualRuns(t *testing.T) {
	for name, off := range map[string]func(cfg *config.Config){
		"tracks_off":  func(cfg *config.Config) { cfg.Tracks.Enabled = false },
		"digests_off": func(cfg *config.Config) { cfg.Digest.Enabled = false },
	} {
		t.Run(name, func(t *testing.T) {
			f := newSlotFixture(t, nil)
			a := addWatchRecipe(t, f.db, f.cfg, "launch", "watch the launch sentinel")
			runID, _, err := builtin.EnqueueManual(f.db, a.ID, automations.BuiltinInput{}, time.Now())
			require.NoError(t, err)
			off(f.cfg)
			f.d.phaseWatchSlot(context.Background())
			run, err := f.db.GetAutomationRun(runID)
			require.NoError(t, err)
			assert.Equal(t, db.RunCancelled, run.Status)
			assert.Equal(t, db.ErrKindNotRunnable, run.ErrorKind)
			assert.Zero(t, f.gen.callsWith("watch the launch sentinel"))
		})
	}
}

// brokenOwnerCopy installs a confirmed owner copy of built-in id whose
// script throws before its primitive runs.
func (f *slotFixture) brokenOwnerCopy(t *testing.T, id string) {
	t.Helper()
	e, ok := builtin.Lookup(id)
	require.True(t, ok)
	name := e.Prompts[0].Name
	prompt, err := e.DefaultPrompt(name, "")
	require.NoError(t, err)
	data, err := builtin.RenderOwnerCopy(e, map[string]string{name: prompt})
	require.NoError(t, err)
	broken := strings.Replace(string(data), "```js\n", "```js\nthrow new Error(\"broken copy\");\n", 1)
	require.NotEqual(t, string(data), broken)
	path := builtin.OwnerCopyPath(f.cfg.WorkspaceDir(), id)
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o700))
	require.NoError(t, os.WriteFile(path, []byte(broken), 0o600))
	a, err := builtin.SyncOne(context.Background(), f.db, f.cfg.WorkspaceDir(), f.cfg, id, time.Now())
	require.NoError(t, err)
	require.NoError(t, f.db.ConfirmAutomation(a.ID, a.ApprovalHash, time.Now()))
}

// TestIdeaFinder_FailedCopyStampsThrottle: an owner's copy that throws
// before ideas.consolidate still stamps the throttle, so the next cycle is
// not due until ideas.mine_interval_hours elapsed.
func TestIdeaFinder_FailedCopyStampsThrottle(t *testing.T) {
	f := newSlotFixture(t, nil)
	f.brokenOwnerCopy(t, ideaFinderID)
	f.d.phaseIdeaFinder(context.Background())
	runs := f.builtinRuns(t, ideaFinderID)
	require.Len(t, runs, 1)
	assert.Equal(t, db.RunFailed, runs[0].Status)
	assert.Zero(t, pipelineRunCount(t, f.db, "ideas"), "the primitive never ran")
	assert.False(t, f.d.lastIdeas.IsZero(), "the failed run stamps the throttle")

	f.d.phaseIdeaFinder(context.Background())
	assert.Len(t, f.builtinRuns(t, ideaFinderID), 1, "the throttle holds the next cycle")
}

// TestTrackMyThreads_FailedCopyWaitsForNewDigests: an owner's copy that
// throws before tracks.extract is not due again on the same material; a
// digest newer than the failed attempt makes it due.
func TestTrackMyThreads_FailedCopyWaitsForNewDigests(t *testing.T) {
	f := newSlotFixture(t, nil)
	f.brokenOwnerCopy(t, trackMyThreadsID)
	f.tracksCycle()
	runs := f.builtinRuns(t, trackMyThreadsID)
	require.Len(t, runs, 1)
	assert.Equal(t, db.RunFailed, runs[0].Status)
	assert.Zero(t, pipelineRunCount(t, f.db, "tracks"), "the primitive never ran")

	f.tracksCycle()
	assert.Len(t, f.builtinRuns(t, trackMyThreadsID), 1, "the same material is not due again")

	now := time.Now()
	digestID, err := f.db.UpsertDigest(db.Digest{ChannelID: "C1", Type: "channel",
		PeriodFrom: float64(now.Add(-time.Hour).Unix()), PeriodTo: float64(now.Add(time.Hour).Unix()),
		Summary: "new talk", MessageCount: 2, Model: "test"})
	require.NoError(t, err)
	_, err = f.db.Exec(`UPDATE digests SET created_at = ? WHERE id = ?`,
		now.Add(time.Minute).UTC().Format("2006-01-02T15:04:05Z"), digestID)
	require.NoError(t, err)
	f.tracksCycle()
	assert.Len(t, f.builtinRuns(t, trackMyThreadsID), 2, "a newer digest makes it due")
}
