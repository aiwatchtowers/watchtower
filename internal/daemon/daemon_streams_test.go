package daemon

import (
	"context"
	"fmt"
	"log"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/ideas"
)

// TestDaemon_PhaseStreamDigests_RunsIndependentlyOfIdeasEnabled pins the core
// Task 6 contract: with ideas.enabled=false and streams.enabled=true,
// phaseStreamDigests still runs RunStreamDigests — the stage-1 stream
// digests are decoupled from the registry consolidator's own switch.
func TestDaemon_PhaseStreamDigests_RunsIndependentlyOfIdeasEnabled(t *testing.T) {
	orch, cfg, wsDir := testDaemonWithTempHome(t)
	cfg.Ideas.Enabled = false
	cfg.Streams.Enabled = true
	cfg.Streams.IntervalHours = 6

	database, err := db.Open(wsDir + "/watchtower.db")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })

	d := newDaemon(orch, cfg)
	d.SetLogger(log.New(os.Stderr, "[test-streams] ", 0))
	d.SetDB(database)
	d.SetIdeasPipeline(ideas.New(database, cfg, nil, log.New(os.Stderr, "[test-streams-pipe] ", 0)))

	d.phaseStreamDigests(context.Background())

	assert.False(t, d.lastStreams.IsZero(),
		"phaseStreamDigests must run (and advance its own throttle) when streams.enabled=true, regardless of ideas.enabled")

	runs, err := database.GetPipelineRuns(10)
	require.NoError(t, err)
	found := false
	for _, r := range runs {
		if r.Pipeline == "stream-digests" {
			found = true
		}
	}
	assert.True(t, found, "expected a pipeline_runs row labeled stream-digests")
}

// TestDaemon_PhaseStreamDigests_DisabledNeverRuns is the gate control:
// streams.enabled=false must never run the phase, even with a wired
// pipeline.
func TestDaemon_PhaseStreamDigests_DisabledNeverRuns(t *testing.T) {
	orch, cfg, wsDir := testDaemonWithTempHome(t)
	cfg.Streams.Enabled = false

	database, err := db.Open(wsDir + "/watchtower.db")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })

	d := newDaemon(orch, cfg)
	d.SetLogger(log.New(os.Stderr, "[test-streams] ", 0))
	d.SetDB(database)
	d.SetIdeasPipeline(ideas.New(database, cfg, nil, log.New(os.Stderr, "[test-streams-pipe] ", 0)))

	d.phaseStreamDigests(context.Background())

	assert.True(t, d.lastStreams.IsZero(), "phaseStreamDigests must not run at all when streams.enabled=false")
}

// TestDaemon_PhaseStreamDigests_SkipsWhileBackfillLockFresh applies the
// phaseIdeas GB7 precedent to the streams phase: a fresh CLI
// `ideas mine --from` backfill lock must make phaseStreamDigests skip
// entirely, not even far enough to advance its own throttle timestamp.
func TestDaemon_PhaseStreamDigests_SkipsWhileBackfillLockFresh(t *testing.T) {
	orch, cfg, wsDir := testDaemonWithTempHome(t)
	cfg.Streams.Enabled = true

	database, err := db.Open(wsDir + "/watchtower.db")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })

	d := newDaemon(orch, cfg)
	d.SetLogger(log.New(os.Stderr, "[test-streams] ", 0))
	d.SetDB(database)
	d.SetIdeasPipeline(ideas.New(database, cfg, nil, log.New(os.Stderr, "[test-streams-pipe] ", 0)))

	release, err := ideas.AcquireBackfillLock(cfg.WorkspaceDir(), "CLI backfill")
	require.NoError(t, err)
	defer release()

	d.phaseStreamDigests(context.Background())

	assert.True(t, d.lastStreams.IsZero(),
		"phaseStreamDigests must skip entirely — never even run the pipeline — while a fresh CLI backfill lock exists")
}

// TestDaemon_PhaseStreamDigests_NilPipeIsNoop is the nil-pipe guard control:
// with no ideas.Pipeline wired at all (e.g. both ideas.enabled and
// streams.enabled were false at wiring time), the phase must not panic and
// must not advance the throttle.
func TestDaemon_PhaseStreamDigests_NilPipeIsNoop(t *testing.T) {
	orch, cfg, _ := testDaemonWithTempHome(t)
	cfg.Streams.Enabled = true

	d := newDaemon(orch, cfg)
	d.SetLogger(log.New(os.Stderr, "[test-streams] ", 0))

	d.phaseStreamDigests(context.Background())

	assert.True(t, d.lastStreams.IsZero())
}

// usageFakeGen is a digest.Generator test double that reports a fixed usage
// tuple per Generate call (10 in / 5 out / 15 total-API), routing the reply
// content by a substring match on the user message — the fakeGen pattern
// from internal/ideas' own tests, duplicated here since it is unexported
// there and daemon needs its own copy to drive a real *ideas.Pipeline.
type usageFakeGen struct {
	reply func(user string) (string, error)
	calls int
}

func (g *usageFakeGen) Generate(_ context.Context, _, user, _ string) (string, *digest.Usage, string, error) {
	g.calls++
	out, err := g.reply(user)
	if err != nil {
		return "", nil, "", err
	}
	return out, &digest.Usage{InputTokens: 10, OutputTokens: 5, TotalAPITokens: 15}, "sess", nil
}

// TestDaemon_PhaseStreamDigestsThenPhaseIdeas_UsageDeltaNotDoubleCounted pins
// the fix-wave item: phaseStreamDigests and phaseIdeas share one
// ideas.Pipeline instance, so AccumulatedUsage() is a LIFETIME total across
// both phases. Run them in the real runSync order (streams, then ideas) and
// assert each phase's recorded pipeline_runs usage reflects only its own
// Generate calls — not the running sum — proving stage-1 (stream digest)
// tokens are never double-counted into phaseIdeas' reported stats.
func TestDaemon_PhaseStreamDigestsThenPhaseIdeas_UsageDeltaNotDoubleCounted(t *testing.T) {
	orch, cfg, wsDir := testDaemonWithTempHome(t)
	cfg.Ideas.Enabled = true
	cfg.Ideas.MineIntervalHours = 6
	cfg.Streams.Enabled = true
	cfg.Streams.IntervalHours = 6
	cfg.Digest.Language = "English"

	database, err := db.Open(wsDir + "/watchtower.db")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })

	// Seed the singleton workspace row (SetIdeasFloorsTx precedent) plus one
	// Gmail account/message so stage 1's email pass has exactly one thing to
	// digest — one Generate call.
	_, err = database.Exec(`INSERT INTO workspace (id, name) VALUES ('T1', 'Test')`)
	require.NoError(t, err)

	base := time.Now().Add(-time.Hour).Unix()
	res, err := database.Exec(`INSERT INTO google_accounts (email, label, gmail_enabled, gmail_last_internal_date)
		VALUES ('acct@example.com', 'Test', 1, ?)`, float64(base))
	require.NoError(t, err)
	acctID, err := res.LastInsertId()
	require.NoError(t, err)
	_, err = database.Exec(`UPDATE google_accounts SET ideas_email_floor = ? WHERE id = ?`, float64(base-10), acctID)
	require.NoError(t, err)
	iso := time.Unix(base+10, 0).UTC().Format(time.RFC3339)
	_, err = database.Exec(`INSERT INTO gmail_messages
		(account_id, id, thread_id, from_email, from_name, subject, body_text, internal_date)
		VALUES (?, 'm1', 'thr-1', 'a@example.com', 'Ann', 'Subj', 'an idea about X', ?)`, acctID, iso)
	require.NoError(t, err)
	emailTag := fmt.Sprintf("gmail:%d:thr-1", acctID)

	gen := &usageFakeGen{reply: func(user string) (string, error) {
		if strings.Contains(user, "=== NEW MATERIAL ===") {
			// Stage 2 (consolidate): mint one idea from the stage-1 mention.
			return fmt.Sprintf(`{"ops":[{"op":"new_idea","title":"Idea from email","essence":"e",
				"mentions":[{"source":"gmail","ref":%q,"quote":"idea","author":"Ann","said_at":"2026-08-01T00:00:00Z"}]}]}`, emailTag), nil
		}
		// Stage 1 (email pre-digest).
		return fmt.Sprintf(`{"topics":[{"title":"t","summary":"s","ideas":[{"text":"idea","author":"Ann","ref":%q}],"decisions":[]}]}`, emailTag), nil
	}}

	pipe := ideas.New(database, cfg, gen, log.New(os.Stderr, "[test-usage-pipe] ", 0))
	d := newDaemon(orch, cfg)
	d.SetLogger(log.New(os.Stderr, "[test-usage] ", 0))
	d.SetDB(database)
	d.SetIdeasPipeline(pipe)

	// runSync order: streams before ideas (daemon.go:898-899).
	d.phaseStreamDigests(context.Background())
	callsAfterStreams := gen.calls
	require.Positive(t, callsAfterStreams, "stage-1 email pass must have called Generate at least once")

	d.phaseIdeas(context.Background())
	callsAfterIdeas := gen.calls
	require.Greater(t, callsAfterIdeas, callsAfterStreams, "stage-2 consolidate must have made at least one more Generate call, or this test can't distinguish delta from lifetime-total reporting")

	runs, err := database.GetPipelineRuns(10)
	require.NoError(t, err)

	var streamsRun, ideasRun *db.PipelineRun
	for i := range runs {
		switch runs[i].Pipeline {
		case "stream-digests":
			streamsRun = &runs[i]
		case "ideas":
			ideasRun = &runs[i]
		}
	}
	require.NotNil(t, streamsRun, "expected a pipeline_runs row for stream-digests")
	require.NotNil(t, ideasRun, "expected a pipeline_runs row for ideas")

	wantStreamsIn := callsAfterStreams * 10
	wantStreamsOut := callsAfterStreams * 5
	wantStreamsAPI := callsAfterStreams * 15
	assert.Equal(t, wantStreamsIn, streamsRun.InputTokens, "stream-digests must report only its own stage-1 usage")
	assert.Equal(t, wantStreamsOut, streamsRun.OutputTokens)
	assert.Equal(t, wantStreamsAPI, streamsRun.TotalAPITokens)

	ideasCalls := callsAfterIdeas - callsAfterStreams
	wantIdeasIn := ideasCalls * 10
	wantIdeasOut := ideasCalls * 5
	wantIdeasAPI := ideasCalls * 15
	assert.Equal(t, wantIdeasIn, ideasRun.InputTokens,
		"ideas must report only its own stage-2 delta, not the lifetime sum shared with stream-digests")
	assert.Equal(t, wantIdeasOut, ideasRun.OutputTokens)
	assert.Equal(t, wantIdeasAPI, ideasRun.TotalAPITokens)

	// The bug this test guards against: without the delta fix, ideasRun would
	// report the pipeline's LIFETIME totals (callsAfterIdeas*10, etc.),
	// double-counting stage-1's tokens into stage-2's reported stats.
	assert.NotEqual(t, callsAfterIdeas*10, ideasRun.InputTokens,
		"ideas' reported input tokens must not equal the lifetime total across both phases")
}
