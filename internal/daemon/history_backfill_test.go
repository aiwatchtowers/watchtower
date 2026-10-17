package daemon

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http/httptest"
	"net/url"
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
	"watchtower/internal/gmail"
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

// F3: a failing backfill query must not fail open — memory skips the cycle
// and the error is logged.
func TestPhaseMemory_SkipsWhenBackfillQueryFails(t *testing.T) {
	d, database, buf := newBackfillDaemon(t)
	d.config.Memory = enabledMemoryConfig()
	opens := 0
	d.SetMemoryPipelineOpener(func() (*memory.Pipeline, error) {
		opens++
		return nil, fmt.Errorf("vault unavailable in test")
	})
	_, err := database.Exec(`ALTER TABLE history_backfill RENAME TO history_backfill_gone`)
	require.NoError(t, err)

	d.phaseMemory(context.Background())
	assert.Equal(t, 0, opens, "memory does not run when the backfill state is unknown")
	assert.Contains(t, buf.String(), "memory: skipping cycle, history backfill check failed")
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
	require.NoError(t, database.UpsertChannel(db.Channel{ID: "1:C1", Name: "alpha", Type: "public"}))
	require.NoError(t, database.UpsertUser(db.User{ID: "U1", Name: "alice", DisplayName: "Alice"}))
	for i := range 5 {
		require.NoError(t, database.UpsertMessage(db.Message{
			ChannelID: "1:C1", TS: fmt.Sprintf("%d.%06d", from.Unix()+3600+int64(i*60), i),
			UserID: "U1", Text: fmt.Sprintf("alpha-%d", i),
		}))
	}
	_, err := database.UpsertDigest(db.Digest{
		ChannelID: "1:C2", Type: "channel", PeriodFrom: float64(from.Unix()) + 7200,
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

	src := slackSource{id: 1, d: d}
	complete, err := src.Process(context.Background(), from, to)
	require.NoError(t, err)
	assert.True(t, complete)

	ch, err := database.GetDigests(db.DigestFilter{ChannelID: "1:C1", Type: "channel"})
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

// R23, F8, #580: transient failures map to the runner's hold (retried, no
// strike); anything else, such as a reply that cannot be parsed, passes
// through as a strike.
func TestHistoryBackfill_TransientErrorsAreHolds(t *testing.T) {
	holds := map[string]error{
		"slack rate limit": fmt.Errorf("x: %w", sync.ErrBackfillIncomplete),
		"digest lock":      fmt.Errorf("x: %w", digest.ErrDigestLocked),
		"ai call":          fmt.Errorf("digest backfill: 3 channel(s) failed: %w", aiCallFailure(t)),
		"timeout":          fmt.Errorf("x: %w", context.DeadlineExceeded),
		"network down":     fmt.Errorf("listing: %w", &net.OpError{Op: "dial", Net: "tcp", Err: errors.New("no route to host")}),
		"dns":              fmt.Errorf("x: %w", &net.DNSError{Err: "no such host", Name: "imap.example.com"}),
		"url error":        fmt.Errorf("x: %w", &url.Error{Op: "Get", URL: "https://example.com", Err: errors.New("connection reset")}),
		"gmail 503":        fmt.Errorf("x: %w", &gmail.StatusError{Path: "/users/me/messages", Code: 503}),
		"gmail 429":        fmt.Errorf("x: %w", &gmail.StatusError{Path: "/users/me/messages", Code: 429}),
		"already a hold":   fmt.Errorf("x: %w", historybackfill.ErrHold),
	}
	for name, err := range holds {
		assert.ErrorIs(t, backfillErr(err), historybackfill.ErrHold, name)
	}
	strikes := map[string]error{
		"parse":       errors.New("parsing ideas.digest_email JSON: unexpected end"),
		"lock file":   errors.New("opening digest lock: boom"),
		"gmail 400":   &gmail.StatusError{Path: "/users/me/messages", Code: 400},
		"no progress": errors.New("digest backfill: no progress in [1,2]"),
	}
	for name, err := range strikes {
		assert.Equal(t, err, backfillErr(err), name)
	}
	assert.NoError(t, backfillErr(nil))
}

// aiCallFailure returns what a failed AI call looks like to its callers.
func aiCallFailure(t *testing.T) error {
	t.Helper()
	gen := digest.WithCallTimeout(failingGenerator{}, time.Minute)
	_, _, _, err := gen.Generate(context.Background(), "sys", "user", "")
	require.Error(t, err)
	return err
}

type failingGenerator struct{}

func (failingGenerator) Generate(context.Context, string, string, string) (string, *digest.Usage, string, error) {
	return "", nil, "", errors.New("claude CLI failed (exit 1): API Error: Connection error")
}
