package daemon

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	gosync "sync"
	"testing"
	"time"

	goslack "github.com/slack-go/slack"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/guide"
	"watchtower/internal/historybackfill"
	"watchtower/internal/ideas"
	"watchtower/internal/memory"
	watchtowerslack "watchtower/internal/slack"
	"watchtower/internal/sync"
)

// newBackfillDaemon is a daemon over a test DB with a temp HOME and an
// existing workspace dir (the stamp file and the digest lock live there).
func newBackfillDaemon(t *testing.T) (*Daemon, *db.DB, *bytes.Buffer) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "test-ws"}
	cfg.Sync.BackfillDays = 30
	require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o755))
	database := db.OpenTestDB(t)
	d := New(cfg)
	var buf bytes.Buffer
	d.SetLogger(log.New(&buf, "", 0))
	d.SetDB(database)
	return d, database, &buf
}

func pipelineRunNames(t *testing.T, database *db.DB) []string {
	t.Helper()
	rows, err := database.Query(`SELECT pipeline FROM pipeline_runs ORDER BY id`)
	require.NoError(t, err)
	defer rows.Close()
	var out []string
	for rows.Next() {
		var name string
		require.NoError(t, rows.Scan(&name))
		out = append(out, name)
	}
	require.NoError(t, rows.Err())
	return out
}

func TestStartHistoryBackfill_FromFirstSync(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	from := time.Now().Add(-3 * 24 * time.Hour).Truncate(time.Second)

	before := time.Now()
	d.startHistoryBackfill("slack", 1, from)

	rows, err := database.ListHistoryBackfills()
	require.NoError(t, err)
	require.Len(t, rows, 1)
	r := rows[0]
	assert.Equal(t, "slack", r.SourceKind)
	assert.Equal(t, int64(1), r.AccountID)
	assert.Equal(t, float64(from.Unix()), r.UpperTS)
	assert.Equal(t, float64(from.Unix()), r.ReachedTS)
	assert.Equal(t, "running", r.Status)
	wantFloor := float64(before.AddDate(0, 0, -30).Unix())
	assert.InDelta(t, wantFloor, r.FloorTS, 5, "floor is now − backfill_days")

	// A repeat (R13: every first-sync report) is harmless.
	d.startHistoryBackfill("slack", 1, from.Add(time.Hour))
	rows, err = database.ListHistoryBackfills()
	require.NoError(t, err)
	require.Len(t, rows, 1)
	assert.Equal(t, float64(from.Unix()), rows[0].UpperTS)
}

func TestStartHistoryBackfill_OffOrAlreadyDeep(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)

	d.config.Sync.BackfillDays = 0
	d.startHistoryBackfill("slack", 1, time.Now().Add(-3*24*time.Hour))

	d.config.Sync.BackfillDays = 30
	d.startHistoryBackfill("gmail", 2, time.Now().AddDate(0, 0, -31))

	rows, err := database.ListHistoryBackfills()
	require.NoError(t, err)
	assert.Empty(t, rows)
}

func TestPhaseMemory_SkipsWhileBackfillActive(t *testing.T) {
	d, database, buf := newBackfillDaemon(t)
	d.config.Memory = enabledMemoryConfig()
	opens := 0
	d.SetMemoryPipelineOpener(func() (*memory.Pipeline, error) {
		opens++
		return nil, fmt.Errorf("vault unavailable in test")
	})
	_, err := database.StartHistoryBackfill("slack", 1, 0, 100, time.Now())
	require.NoError(t, err)

	d.phaseMemory(context.Background())
	assert.Equal(t, 0, opens, "memory waits while a backfill runs")
	assert.Equal(t, 1, strings.Count(buf.String(), "memory: waiting for the history backfill"))

	rows, err := database.ListHistoryBackfills()
	require.NoError(t, err)
	require.NoError(t, database.SetHistoryBackfillStatus(rows[0].ID, "paused", time.Now()))
	d.phaseMemory(context.Background())
	assert.Equal(t, 0, opens, "a paused backfill still holds memory")

	require.NoError(t, database.AdvanceHistoryBackfill(rows[0].ID, 0, time.Now()))
	d.phaseMemory(context.Background())
	assert.Equal(t, 1, opens, "a done backfill lets memory run")
}

// countingGenerator answers every call with a valid digest and counts calls.
type countingGenerator struct {
	mu    gosync.Mutex
	calls int
}

func (g *countingGenerator) Generate(_ context.Context, _, _, _ string) (string, *digest.Usage, string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.calls++
	return `{"summary":"s","topics":[{"title":"t","summary":"s","decisions":[],"action_items":[],"situations":[],"key_messages":[]}]}`,
		&digest.Usage{Model: "m", InputTokens: 1, OutputTokens: 1}, "", nil
}

func (g *countingGenerator) count() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.calls
}

// seedBackfillChunk seeds a two-day chunk 20 days back: five C1 messages for
// the window to digest and a C2 channel digest so the day's rollup has two.
func seedBackfillChunk(t *testing.T, database *db.DB) (from, to time.Time) {
	t.Helper()
	from = time.Now().UTC().AddDate(0, 0, -20).Truncate(24 * time.Hour)
	to = from.Add(48 * time.Hour)
	require.NoError(t, database.UpsertChannel(db.Channel{ID: "C1", Name: "alpha", Type: "public"}))
	require.NoError(t, database.UpsertUser(db.User{ID: "U1", Name: "alice", DisplayName: "Alice"}))
	for i := range 5 {
		require.NoError(t, database.UpsertMessage(db.Message{
			ChannelID: "C1", TS: fmt.Sprintf("%d.%06d", from.Unix()+3600+int64(i*60), i),
			UserID: "U1", Text: fmt.Sprintf("alpha-%d", i),
		}))
	}
	_, err := database.UpsertDigest(db.Digest{
		ChannelID: "C2", Type: "channel", PeriodFrom: float64(from.Unix()) + 7200,
		PeriodTo: float64(from.Unix()) + 7300, Summary: "s", MessageCount: 3, Model: "m",
	})
	require.NoError(t, err)
	return from, to
}

func TestHistoryBackfill_SlackSourceProcess(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	d.config.Digest = config.DigestConfig{Enabled: true, MinMessages: 3}
	gen := &countingGenerator{}
	d.SetDigestPipeline(digest.New(database, d.config, gen, d.logger))
	from, to := seedBackfillChunk(t, database)

	src := slackSource{d: d}
	complete, err := src.Process(context.Background(), from, to)
	require.NoError(t, err)
	assert.True(t, complete)

	ch, err := database.GetDigests(db.DigestFilter{ChannelID: "C1", Type: "channel"})
	require.NoError(t, err)
	require.Len(t, ch, 1, "the window digested C1")
	daily, err := database.GetDigests(db.DigestFilter{Type: "daily"})
	require.NoError(t, err)
	assert.NotEmpty(t, daily, "the rollups ran after the window")
	calls := gen.count()

	d.config.Digest.Enabled = false
	complete, err = src.Process(context.Background(), from, to)
	require.NoError(t, err)
	assert.True(t, complete)
	assert.Equal(t, calls, gen.count(), "digests off: no AI call")
}

// A held ideas lock holds the chunk for the next cycle; any other lock
// error is a chunk failure.
func TestHistoryBackfill_GmailSourceLockErrors(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	d.config.Streams.Enabled = true
	d.SetIdeasPipeline(ideas.New(database, d.config, &mockGenerator{}, d.logger))
	src := gmailSource{d: d}
	from := time.Now().AddDate(0, 0, -20)

	release, err := ideas.AcquireBackfillLock(d.config.WorkspaceDir(), "CLI backfill")
	require.NoError(t, err)
	complete, err := src.Process(context.Background(), from, from.Add(48*time.Hour))
	require.NoError(t, err, "held lock: no failure")
	assert.False(t, complete, "held lock: retry the chunk")
	release()

	require.NoError(t, os.RemoveAll(d.config.WorkspaceDir())) // the lock file cannot be written
	complete, err = src.Process(context.Background(), from, from.Add(48*time.Hour))
	require.Error(t, err)
	assert.False(t, complete)
}

func TestHistoryBackfill_AccountState(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)

	ok, err := database.CreateSlackAccount(db.SlackAccount{TeamID: "T1"})
	require.NoError(t, err)
	revoked, err := database.CreateSlackAccount(db.SlackAccount{TeamID: "T2"})
	require.NoError(t, err)
	require.NoError(t, database.SetSlackAccountAuthState(revoked, "revoked", "token revoked"))
	removed, err := database.CreateSlackAccount(db.SlackAccount{TeamID: "T3"})
	require.NoError(t, err)
	require.NoError(t, database.SetSlackAccountRemoved(removed))

	assert.Equal(t, historybackfill.AccountOK, d.accountState("slack", ok))
	assert.Equal(t, historybackfill.AccountRevoked, d.accountState("slack", revoked))
	assert.Equal(t, historybackfill.AccountGone, d.accountState("slack", removed))
	assert.Equal(t, historybackfill.AccountGone, d.accountState("slack", 999))

	d.config.Gmail.Enabled = true
	g, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@example.com", GmailEnabled: true})
	require.NoError(t, err)
	assert.Equal(t, historybackfill.AccountOK, d.accountState("gmail", g))
	require.NoError(t, database.SetGoogleAccountAuthState(g, "revoked", "grant gone"))
	assert.Equal(t, historybackfill.AccountRevoked, d.accountState("gmail", g))
	assert.Equal(t, historybackfill.AccountGone, d.accountState("gmail", 999))

	m, err := database.CreateEmailAccount(db.EmailAccount{Provider: "imap", EmailAddress: "b@example.com", Host: "imap.example.com", Port: 993, Security: "ssl", Folder: "INBOX"})
	require.NoError(t, err)
	assert.Equal(t, historybackfill.AccountOK, d.accountState("imap", m))
	assert.Equal(t, historybackfill.AccountGone, d.accountState("imap", 999))
}

// R15: an account whose source is turned off is never wired, so its row
// would otherwise stay running forever and hold memory back.
func TestHistoryBackfill_AccountStateSourceTurnedOff(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	d.config.Gmail.Enabled = true

	s, err := database.CreateSlackAccount(db.SlackAccount{TeamID: "T1"})
	require.NoError(t, err)
	require.NoError(t, database.SetSlackAccountEnabled(s, false))
	assert.Equal(t, historybackfill.AccountGone, d.accountState("slack", s), "a disabled slack account")

	g, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@example.com", GmailEnabled: true})
	require.NoError(t, err)
	assert.Equal(t, historybackfill.AccountOK, d.accountState("gmail", g))
	d.config.Gmail.Enabled = false
	assert.Equal(t, historybackfill.AccountGone, d.accountState("gmail", g), "gmail.enabled=false")

	d.config.Gmail.Enabled = true
	g2, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "b@example.com", CalendarEnabled: true})
	require.NoError(t, err)
	assert.Equal(t, historybackfill.AccountGone, d.accountState("gmail", g2), "the account's gmail_enabled=0")
}

func TestPhaseHistoryBackfill_TurnedOffGmailRowStopsAndMemoryRuns(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	d.config.Gmail.Enabled = false
	d.config.Memory = enabledMemoryConfig()
	opens := 0
	d.SetMemoryPipelineOpener(func() (*memory.Pipeline, error) {
		opens++
		return nil, fmt.Errorf("vault unavailable in test")
	})
	g, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@example.com", GmailEnabled: true})
	require.NoError(t, err)
	_, err = database.StartHistoryBackfill("gmail", g, 0, 3*86400, time.Now())
	require.NoError(t, err)

	d.phaseHistoryBackfill(context.Background()) // no gmail syncer is wired
	rows, err := database.ListHistoryBackfills()
	require.NoError(t, err)
	require.Len(t, rows, 1)
	assert.Equal(t, "off", rows[0].Status)

	d.phaseMemory(context.Background())
	assert.Equal(t, 1, opens, "memory runs once the row is off")
}

// newBackfillOrchestrator is a Slack orchestrator for account 1 over
// database, against the test Slack API (search returns no matches).
func newBackfillOrchestrator(t *testing.T, database *db.DB, cfg *config.Config) *sync.Orchestrator {
	t.Helper()
	_, err := database.CreateSlackAccount(db.SlackAccount{TeamID: "T1", TeamName: "acme", TeamDomain: "acme"})
	require.NoError(t, err)
	srv := httptest.NewServer(testMux())
	t.Cleanup(srv.Close)
	api := goslack.New("xoxp-test-token", goslack.OptionAPIURL(srv.URL+"/"))
	o := sync.NewOrchestrator(database, watchtowerslack.NewClientWithAPIUnlimited(api), cfg, 1)
	o.SetLogger(log.New(io.Discard, "", 0))
	return o
}

// R16: the phase's AI usage lands on its pipeline_runs row.
func TestPhaseHistoryBackfill_RecordsUsage(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	d.config.Digest = config.DigestConfig{Enabled: true, MinMessages: 3}
	gen := &countingGenerator{}
	d.SetDigestPipeline(digest.New(database, d.config, gen, d.logger))
	d.SetOrchestrators([]*sync.Orchestrator{newBackfillOrchestrator(t, database, d.config)})
	from, to := seedBackfillChunk(t, database)
	_, err := database.StartHistoryBackfill("slack", 1, float64(from.Unix()), float64(to.Unix()), time.Now())
	require.NoError(t, err)

	d.phaseHistoryBackfill(context.Background())
	require.Positive(t, gen.count(), "the chunk was digested")

	var inTok, outTok int
	var status string
	require.NoError(t, database.QueryRow(`SELECT input_tokens, output_tokens, status FROM pipeline_runs
		WHERE pipeline = 'history-backfill'`).Scan(&inTok, &outTok, &status))
	assert.Equal(t, "done", status)
	assert.Equal(t, gen.count(), inTok, "one input token per AI call")
	assert.Equal(t, gen.count(), outTok)
}

// wirePeopleBackfill turns people cards on with a real pipeline, so the
// one-time hook's people run is observable as a "people-backfill" row.
func wirePeopleBackfill(t *testing.T, d *Daemon, database *db.DB) {
	t.Helper()
	d.config.People.Enabled = true
	d.config.Digest.Enabled = true
	d.SetPeoplePipeline(guide.New(database, d.config, &mockGenerator{}, d.logger))
}

func TestOnSlackBackfillDone_RunsOnceThenStamp(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	wirePeopleBackfill(t, d, database)
	floor := time.Now().AddDate(0, 0, -30)

	require.NoError(t, d.onSlackBackfillDone(context.Background(), floor))
	assert.Equal(t, []string{"people-backfill"}, pipelineRunNames(t, database))
	_, err := os.Stat(d.historyBackfillHooksStampPath())
	require.NoError(t, err, "both hooks succeeded: stamp written")

	require.NoError(t, d.onSlackBackfillDone(context.Background(), floor))
	assert.Equal(t, []string{"people-backfill"}, pipelineRunNames(t, database), "the stamp blocks a rerun")
}

func TestOnSlackBackfillDone_FailedPeopleRunLeavesNoStamp(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	wirePeopleBackfill(t, d, database)
	floor := time.Now().AddDate(0, 0, -30)

	_, err := database.Exec(`ALTER TABLE people_cards RENAME TO people_cards_hidden`)
	require.NoError(t, err)
	require.Error(t, d.onSlackBackfillDone(context.Background(), floor))
	_, err = os.Stat(d.historyBackfillHooksStampPath())
	assert.True(t, os.IsNotExist(err), "a failed people run writes no stamp")

	_, err = database.Exec(`ALTER TABLE people_cards_hidden RENAME TO people_cards`)
	require.NoError(t, err)
	require.NoError(t, d.onSlackBackfillDone(context.Background(), floor), "the next Step retries")
	assert.Equal(t, []string{"people-backfill", "people-backfill"}, pipelineRunNames(t, database))
	_, err = os.Stat(d.historyBackfillHooksStampPath())
	require.NoError(t, err)
}

func TestPhaseHistoryBackfill_DoneSlackRowsRunUntilStamped(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	_, err := database.StartHistoryBackfill("slack", 1, 0, 100, time.Now())
	require.NoError(t, err)
	rows, err := database.ListHistoryBackfills()
	require.NoError(t, err)
	require.NoError(t, database.AdvanceHistoryBackfill(rows[0].ID, 0, time.Now()))

	d.phaseHistoryBackfill(context.Background())
	assert.Equal(t, []string{"history-backfill"}, pipelineRunNames(t, database), "done slack rows, no stamp: the phase runs")
	_, err = os.Stat(d.historyBackfillHooksStampPath())
	require.NoError(t, err, "nothing wired: the hooks have nothing to do and stamp")

	d.phaseHistoryBackfill(context.Background())
	assert.Equal(t, []string{"history-backfill"}, pipelineRunNames(t, database), "stamped and nothing active: skipped")
}

func TestPhaseHistoryBackfill_NoRowsNoRun(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	d.phaseHistoryBackfill(context.Background())
	assert.Empty(t, pipelineRunNames(t, database))
	_, err := os.Stat(filepath.Join(d.config.WorkspaceDir(), "history_backfill_hooks_done.txt"))
	assert.True(t, os.IsNotExist(err))
}

// R20: sync.backfill_days <= 0 pauses running backfills — the phase does
// not run and the rows stay as they are; setting it back resumes them.
func TestPhaseHistoryBackfill_BackfillDaysZeroPauses(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	_, err := database.StartHistoryBackfill("slack", 7, 0, 3*86400, time.Now()) // no such account: Gone once it runs
	require.NoError(t, err)

	d.config.Sync.BackfillDays = 0
	d.phaseHistoryBackfill(context.Background())
	assert.Empty(t, pipelineRunNames(t, database), "paused: no Step")
	rows, err := database.ListHistoryBackfills()
	require.NoError(t, err)
	assert.Equal(t, "running", rows[0].Status, "the row is left as it is")

	d.config.Sync.BackfillDays = 30
	d.phaseHistoryBackfill(context.Background())
	assert.Equal(t, []string{"history-backfill"}, pipelineRunNames(t, database), "resumed")
}

// R24: slack rows that are all off (none done) leave the hooks nothing to
// do, so the phase is not due.
func TestPhaseHistoryBackfill_OnlyOffSlackRowsNotDue(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	_, err := database.StartHistoryBackfill("slack", 1, 0, 100, time.Now())
	require.NoError(t, err)
	rows, err := database.ListHistoryBackfills()
	require.NoError(t, err)
	require.NoError(t, database.SetHistoryBackfillStatus(rows[0].ID, "off", time.Now()))

	d.phaseHistoryBackfill(context.Background())
	assert.Empty(t, pipelineRunNames(t, database))
}

// setNearLimit writes a plan status whose 5-hour limit is projected to hit.
func setNearLimit(t *testing.T, database *db.DB, near bool) {
	t.Helper()
	state := "ok"
	if near {
		state = "will_hit"
	}
	require.NoError(t, database.UpsertPlanUsageStatus(db.PlanUsageStatus{State: "ok", UpdatedAt: time.Now(),
		LimitsJSON: fmt.Sprintf(`[{"key":"session","group":"x","percent":90,"projection":{"state":%q}}]`, state)}))
}

// R21: the one-time hooks wait while the plan limit is near — no people
// run, no stamp — and run once the gate opens.
func TestOnSlackBackfillDone_HeldByPlanGate(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	wirePeopleBackfill(t, d, database)
	floor := time.Now().AddDate(0, 0, -30)

	setNearLimit(t, database, true)
	require.NoError(t, d.onSlackBackfillDone(context.Background(), floor), "held, not failed")
	assert.Empty(t, pipelineRunNames(t, database), "no people run near the limit")
	_, err := os.Stat(d.historyBackfillHooksStampPath())
	assert.True(t, os.IsNotExist(err), "held: no stamp")

	setNearLimit(t, database, false)
	require.NoError(t, d.onSlackBackfillDone(context.Background(), floor))
	assert.Equal(t, []string{"people-backfill"}, pipelineRunNames(t, database))
	_, err = os.Stat(d.historyBackfillHooksStampPath())
	require.NoError(t, err)
}

// R23: an incomplete Slack search (rate limit) maps to the runner's hold.
func TestHistoryBackfill_SlackSourceIncompleteIsHold(t *testing.T) {
	assert.ErrorIs(t, slackFetchErr(fmt.Errorf("x: %w", sync.ErrBackfillIncomplete)), historybackfill.ErrHold)
	other := fmt.Errorf("boom")
	assert.Equal(t, other, slackFetchErr(other))
	assert.NoError(t, slackFetchErr(nil))
}

// stageGen answers stage-1 stream digest calls and stage-2 consolidator
// calls, counting each. acct is the seeded Gmail account the stage-1 idea
// cites, so stage 1 writes a stream digest for stage 2 to read.
type stageGen struct {
	mu             gosync.Mutex
	acct           int64
	stage1, stage2 int
}

func (g *stageGen) Generate(_ context.Context, _, user, _ string) (string, *digest.Usage, string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if strings.Contains(user, "=== REGISTRY ===") {
		g.stage2++
		return `{"ops":[]}`, &digest.Usage{}, "", nil
	}
	g.stage1++
	return fmt.Sprintf(`{"topics":[{"title":"t","summary":"s","ideas":[{"text":"try X","author":"Ann","ref":"gmail:%d:thr-1"}],"decisions":[]}]}`, g.acct),
		&digest.Usage{}, "", nil
}

// seedGmailForIdeas seeds one Gmail account with a message inside [from, to]
// and an initialized ideas floor below it, and returns the account id.
func seedGmailForIdeas(t *testing.T, database *db.DB, from time.Time) int64 {
	t.Helper()
	_, err := database.Exec(`INSERT INTO workspace (id, name) VALUES ('T1', 'acme')`)
	require.NoError(t, err)
	res, err := database.Exec(`INSERT INTO google_accounts (email, label, gmail_enabled, gmail_last_internal_date, ideas_email_floor)
		VALUES ('a@example.com', 'Test', 1, ?, ?)`, float64(time.Now().Unix()), float64(from.Add(-time.Hour).Unix()))
	require.NoError(t, err)
	acct, err := res.LastInsertId()
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO gmail_messages (account_id, id, thread_id, from_email, from_name, subject, body_text, internal_date)
		VALUES (?, 'm1', 'thr-1', 'b@example.com', 'Ann', 'Subj', 'we should try X', ?)`,
		acct, from.Add(time.Hour).UTC().Format(time.RFC3339))
	require.NoError(t, err)
	return acct
}

// R17: the Gmail chunk's AI is gated per flag — streams.enabled gates the
// stage-1 stream digests, ideas.enabled the consolidator.
func TestHistoryBackfill_GmailSourceFlags(t *testing.T) {
	cases := []struct {
		name              string
		streams, ideasOn  bool
		wantStage1, want2 bool
	}{
		{"streams off", false, true, false, false},
		{"ideas off", true, false, true, false},
		{"both on", true, true, true, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			d, database, _ := newBackfillDaemon(t)
			d.config.Streams.Enabled = tc.streams
			d.config.Ideas.Enabled = tc.ideasOn
			gen := &stageGen{}
			d.SetIdeasPipeline(ideas.New(database, d.config, gen, d.logger))
			from := time.Now().AddDate(0, 0, -20)
			gen.acct = seedGmailForIdeas(t, database, from)

			complete, err := gmailSource{d: d}.Process(context.Background(), from, from.Add(48*time.Hour))
			require.NoError(t, err)
			assert.True(t, complete)
			assert.Equal(t, tc.wantStage1, gen.stage1 > 0, "stage 1")
			assert.Equal(t, tc.want2, gen.stage2 > 0, "stage 2")
		})
	}
}

// M4: N Gmail rows walking the same window pay for its ideas drain once.
func TestHistoryBackfill_GmailWindowDrainedOnce(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	d.config.Streams.Enabled = true
	d.config.Ideas.Enabled = true
	gen := &stageGen{}
	d.SetIdeasPipeline(ideas.New(database, d.config, gen, d.logger))
	from := time.Now().AddDate(0, 0, -20)
	to := from.Add(48 * time.Hour)
	gen.acct = seedGmailForIdeas(t, database, from)

	complete, err := gmailSource{d: d}.Process(context.Background(), from, to)
	require.NoError(t, err)
	require.True(t, complete)
	calls := gen.stage1 + gen.stage2
	require.Positive(t, calls)

	complete, err = gmailSource{d: d}.Process(context.Background(), from, to) // a second account's row
	require.NoError(t, err)
	assert.True(t, complete)
	assert.Equal(t, calls, gen.stage1+gen.stage2, "the window was already drained: no AI")
}

func TestUncoveredSpan(t *testing.T) {
	at := func(h int) time.Time { return time.Unix(int64(h)*3600, 0).UTC() }
	spans := []timeSpan{{at(10), at(20)}}
	cases := []struct {
		name             string
		from, to         int
		wantFrom, wantTo int
		ok               bool
	}{
		{"inside", 12, 18, 0, 0, false},
		{"same", 10, 20, 0, 0, false},
		{"below", 0, 5, 0, 5, true},
		{"overlaps top", 15, 25, 20, 25, true},
		{"overlaps bottom", 5, 15, 5, 10, true},
		{"spans it", 5, 25, 5, 25, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f, to, ok := uncoveredSpan(spans, at(tc.from), at(tc.to))
			assert.Equal(t, tc.ok, ok)
			if ok {
				assert.Equal(t, at(tc.wantFrom), f)
				assert.Equal(t, at(tc.wantTo), to)
			}
		})
	}
	f, to, ok := uncoveredSpan([]timeSpan{{at(10), at(20)}, {at(20), at(30)}}, at(15), at(35))
	assert.True(t, ok)
	assert.Equal(t, at(30), f, "adjacent spans clip in turn")
	assert.Equal(t, at(35), to)
}
