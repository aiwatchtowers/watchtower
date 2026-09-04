package catchup

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// mockGenerator returns canned output and records that it was called. When fn is
// set it is used to compute the response from the (system, user) messages so a
// test can assert on what the pipeline actually sent; otherwise the static out
// is returned. err, when set, fails the call instead. source records the tier
// tag the pipeline attached to the context.
type mockGenerator struct {
	out    string
	err    error
	fn     func(system, user string) string
	called bool
	calls  int
	source string
	mu     sync.Mutex
}

func (m *mockGenerator) Generate(ctx context.Context, system, user, _ string) (string, *digest.Usage, string, error) {
	m.mu.Lock()
	m.called = true
	m.calls++
	m.source, _ = digest.SourceFromContext(ctx)
	fn := m.fn
	out := m.out
	err := m.err
	m.mu.Unlock()
	if err != nil {
		return "", nil, "", err
	}
	if fn != nil {
		out = fn(system, user)
	}
	return out, &digest.Usage{}, "", nil
}

func testLogger() *log.Logger {
	return log.New(log.Writer(), "", 0)
}

type fakeTopUp struct {
	channelCalls, streamCalls int
	channelErr, streamErr     error
}

func (f *fakeTopUp) ChannelDigests(context.Context) error { f.channelCalls++; return f.channelErr }
func (f *fakeTopUp) StreamDigests(context.Context) error  { f.streamCalls++; return f.streamErr }

func newCfg() *config.Config {
	c := &config.Config{}
	c.Catchup.Caps = config.CatchupCaps{Digests: 40, Streams: 10, Meetings: 10, Decisions: 10, Inbox: 30, Tracks: 20, Targets: 10}
	c.Catchup.MaxPromptChars = 120000
	c.Digest.Enabled = true
	c.Streams.Enabled = true
	c.Digest.Language = "Russian"
	return c
}

func newPipeline(t *testing.T, gen *mockGenerator, top *fakeTopUp) (*Pipeline, *db.DB) {
	d := db.OpenTestDB(t)
	p := New(d, newCfg(), gen, testLogger())
	p.SetTopUp(top)
	p.now = func() time.Time { return time.Unix(2000, 0) }
	return p, d
}

func seedDigest(t *testing.T, d *db.DB, from, to float64) int64 {
	res, err := d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary) VALUES ('1:C1', ?, ?, 'channel', 'shipped v2')`, from, to)
	require.NoError(t, err)
	id, _ := res.LastInsertId()
	return id
}

const composeOK = `{"tldr":"quiet day","topics":[{"title":"Ship","narrative":"v2 shipped","priority":"high","refs":["digests#%d"]}],"decisions":[],"meetings":[],"needs_you":[]}`

func TestRun_EmptyWindowMakesNoAICall(t *testing.T) {
	gen := &mockGenerator{out: "{}"}
	p, d := newPipeline(t, gen, &fakeTopUp{})
	res, err := p.Run(context.Background(), RunOptions{Spec: WindowSpec{From: time.Unix(1000, 0), To: time.Unix(1500, 0)}})
	require.NoError(t, err)
	assert.Equal(t, "ready", res.Status)
	assert.False(t, gen.called)
	r, _ := d.GetCatchupRecap(res.RecapID)
	assert.Equal(t, "ready", r.Status)
	assert.Contains(t, r.BodyJSON, `"topics":[]`, "an empty recap still persists a well-formed body")
	assert.Equal(t, "skipped", res.Coverage.Topup, "window in the past → no top-up")
}

func TestRun_ComposesAndPersists(t *testing.T) {
	top := &fakeTopUp{}
	gen := &mockGenerator{}
	p, d := newPipeline(t, gen, top)
	id := seedDigest(t, d, 1500, 1900)
	gen.out = fmt.Sprintf(composeOK, id)
	res, err := p.Run(context.Background(), RunOptions{Spec: WindowSpec{From: time.Unix(1000, 0)}}) // To = now(2000) → fresh → top-up runs
	require.NoError(t, err)
	assert.Equal(t, "ready", res.Status)
	assert.Equal(t, 1, top.channelCalls)
	assert.Equal(t, 1, top.streamCalls)
	assert.Equal(t, "ok", res.Coverage.Topup)
	assert.Equal(t, 1900.0, res.Coverage.SlackTo)
	assert.Equal(t, "catchup.compose", gen.source, "the compose call must carry its tier tag")
	r, _ := d.GetCatchupRecap(res.RecapID)
	assert.Equal(t, "quiet day", r.TLDR)
	var body Body
	require.NoError(t, json.Unmarshal([]byte(r.BodyJSON), &body))
	require.Len(t, body.Topics, 1)
	assert.Equal(t, "1:C1", body.Topics[0].Refs[0].Label, "no channels row → the id is the title")
}

func TestRun_AutoWindowStartsAtLastAck(t *testing.T) {
	gen := &mockGenerator{out: `{"tldr":"","topics":[]}`}
	p, d := newPipeline(t, gen, &fakeTopUp{})
	prev, _ := d.InsertCatchupRecap(100, 1700, 0)
	require.NoError(t, d.AcknowledgeCatchupWindow(prev, 100, 1700))
	res, err := p.Run(context.Background(), RunOptions{})
	require.NoError(t, err)
	assert.Equal(t, int64(1700), res.Window.From.Unix())
	assert.Equal(t, int64(2000), res.Window.To.Unix())
	assert.Equal(t, "auto", res.Window.Source)
	r, _ := d.GetCatchupRecap(res.RecapID)
	assert.Equal(t, 1700.0, r.PeriodFrom, "the resolved window is what the row records")
	assert.Equal(t, 2000.0, r.PeriodTo)
}

// BEHAVIOR CATCHUP-02 — see docs/inventory/catchup.md
func TestCatchup02_ComposePromptCarriesLanguageDirective(t *testing.T) {
	var system string
	gen := &mockGenerator{fn: func(s, _ string) string { system = s; return `{"tldr":"","topics":[]}` }}
	p, d := newPipeline(t, gen, &fakeTopUp{})
	seedDigest(t, d, 1500, 1900)
	_, err := p.Run(context.Background(), RunOptions{Spec: WindowSpec{From: time.Unix(1000, 0)}})
	require.NoError(t, err)
	assert.Contains(t, system, prompts.Directive("Russian"))
}

// BEHAVIOR CATCHUP-03 — see docs/inventory/catchup.md
func TestCatchup03_TopUpFailureStillProducesRecap(t *testing.T) {
	top := &fakeTopUp{channelErr: errors.New("digest lock held")}
	gen := &mockGenerator{}
	p, d := newPipeline(t, gen, top)
	id := seedDigest(t, d, 1500, 1900)
	gen.out = fmt.Sprintf(composeOK, id)
	res, err := p.Run(context.Background(), RunOptions{Spec: WindowSpec{From: time.Unix(1000, 0)}})
	require.NoError(t, err)
	assert.Equal(t, "ready", res.Status)
	assert.Equal(t, "failed", res.Coverage.Topup)
	assert.Contains(t, res.Coverage.TopupError, "digest lock held")
	assert.Equal(t, 1, top.streamCalls, "stream top-up still attempted after the channel failure")
	r, _ := d.GetCatchupRecap(res.RecapID)
	assert.Equal(t, "ready", r.Status, "the recap itself still lands ready")
	assert.Contains(t, r.CoverageJSON, `"topup":"failed"`)
}

func TestRun_TopUpRespectsFeatureGates(t *testing.T) {
	top := &fakeTopUp{}
	gen := &mockGenerator{out: `{"tldr":"","topics":[]}`}
	p, d := newPipeline(t, gen, top)
	p.cfg.Digest.Enabled = false
	p.cfg.Streams.Enabled = false
	seedDigest(t, d, 1500, 1900)
	res, err := p.Run(context.Background(), RunOptions{Spec: WindowSpec{From: time.Unix(1000, 0)}})
	require.NoError(t, err)
	assert.Equal(t, 0, top.channelCalls+top.streamCalls)
	assert.Equal(t, "skipped", res.Coverage.Topup)
}

// BEHAVIOR CATCHUP-04 — see docs/inventory/catchup.md
func TestCatchup04_InventedRefsAreDroppedNotPersisted(t *testing.T) {
	gen := &mockGenerator{}
	p, d := newPipeline(t, gen, &fakeTopUp{})
	id := seedDigest(t, d, 1500, 1900)
	gen.out = fmt.Sprintf(`{"tldr":"x","topics":[{"title":"real","narrative":"n","priority":"low","refs":["digests#%d","digests#4242"]},{"title":"ghost","narrative":"n","priority":"low","refs":["inbox#77"]}],"decisions":[{"text":"d","refs":["decisions#1"]}]}`, id)
	res, err := p.Run(context.Background(), RunOptions{Spec: WindowSpec{From: time.Unix(1000, 0)}})
	require.NoError(t, err)
	assert.Equal(t, 3, res.RefsRejected)
	r, _ := d.GetCatchupRecap(res.RecapID)
	assert.NotContains(t, r.BodyJSON, "4242")
	assert.NotContains(t, r.BodyJSON, "ghost")
	assert.Contains(t, r.BodyJSON, `"decisions":[]`)
}

func TestRun_AIFailureMarksRecapFailed(t *testing.T) {
	gen := &mockGenerator{out: "not json"}
	p, d := newPipeline(t, gen, &fakeTopUp{})
	seedDigest(t, d, 1500, 1900)
	res, err := p.Run(context.Background(), RunOptions{Spec: WindowSpec{From: time.Unix(1000, 0)}})
	require.NoError(t, err, "a failed recap is a row, not an error")
	assert.Equal(t, "failed", res.Status)
	r, _ := d.GetCatchupRecap(res.RecapID)
	assert.Equal(t, "failed", r.Status)
	assert.NotEmpty(t, r.Error)
}

func TestRun_GeneratorErrorMarksRecapFailed(t *testing.T) {
	gen := &mockGenerator{err: errors.New("claude exited 1")}
	p, d := newPipeline(t, gen, &fakeTopUp{})
	seedDigest(t, d, 1500, 1900)
	res, err := p.Run(context.Background(), RunOptions{Spec: WindowSpec{From: time.Unix(1000, 0)}})
	require.NoError(t, err, "an AI failure is a row, not an error")
	assert.Equal(t, "failed", res.Status)
	assert.Contains(t, res.Error, "claude exited 1")
	r, _ := d.GetCatchupRecap(res.RecapID)
	assert.Equal(t, "failed", r.Status)
	assert.Contains(t, r.Error, "claude exited 1")
}

// The window read has two error branches — the seven gather queries and the
// coverage read — handled identically. Only gather is reachable in a test: every
// table and column CatchupCoverage reads is also read by gather, which runs
// first, so breaking one breaks both.
func TestRun_GatherErrorMarksRecapFailed(t *testing.T) {
	gen := &mockGenerator{out: `{"tldr":"","topics":[]}`}
	p, d := newPipeline(t, gen, &fakeTopUp{})
	seedDigest(t, d, 1500, 1900)
	_, err := d.Exec(`DROP TABLE stream_digests`)
	require.NoError(t, err)
	res, err := p.Run(context.Background(), RunOptions{Spec: WindowSpec{From: time.Unix(1000, 0)}})
	require.NoError(t, err, "an unreadable window is a row, not an error")
	assert.Equal(t, "failed", res.Status)
	assert.False(t, gen.called, "no AI call on material we could not read")
	r, _ := d.GetCatchupRecap(res.RecapID)
	assert.Equal(t, "failed", r.Status)
	assert.NotEmpty(t, r.Error)
}

// A recap that could not be written down is not a recap: Run reports the write
// failure instead of a "ready" result nothing backs.
func TestRun_FinishWriteFailureIsAnError(t *testing.T) {
	gen := &mockGenerator{}
	p, d := newPipeline(t, gen, &fakeTopUp{})
	id := seedDigest(t, d, 1500, 1900)
	gen.out = fmt.Sprintf(composeOK, id)
	// tldr is written only by FinishCatchupRecap — the insert does not name it.
	_, err := d.Exec(`ALTER TABLE catchup_recaps RENAME COLUMN tldr TO tldr_x`)
	require.NoError(t, err)
	res, err := p.Run(context.Background(), RunOptions{Spec: WindowSpec{From: time.Unix(1000, 0)}})
	require.Error(t, err)
	assert.Empty(t, res.Status, "no status is claimed for a recap that was never persisted")
	var status string
	require.NoError(t, d.QueryRow(`SELECT status FROM catchup_recaps WHERE id=?`, res.RecapID).Scan(&status))
	assert.Equal(t, "building", status, "the row is stuck, and the caller is told")
}

// Same rule on the failure path: if the row cannot even be marked failed, the
// caller hears about it rather than being handed a "failed" result.
func TestRun_FailWriteFailureIsAnError(t *testing.T) {
	gen := &mockGenerator{err: errors.New("claude exited 1")}
	p, d := newPipeline(t, gen, &fakeTopUp{})
	seedDigest(t, d, 1500, 1900)
	_, err := d.Exec(`ALTER TABLE catchup_recaps RENAME COLUMN error TO error_x`)
	require.NoError(t, err)
	res, err := p.Run(context.Background(), RunOptions{Spec: WindowSpec{From: time.Unix(1000, 0)}})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "claude exited 1", "the cause survives in the write error")
	assert.Empty(t, res.Status)
	var status string
	require.NoError(t, d.QueryRow(`SELECT status FROM catchup_recaps WHERE id=?`, res.RecapID).Scan(&status))
	assert.Equal(t, "building", status)
}

func TestRun_RecapRowInsertFailureIsAnError(t *testing.T) {
	gen := &mockGenerator{}
	p, d := newPipeline(t, gen, &fakeTopUp{})
	_, err := d.Exec(`ALTER TABLE catchup_recaps RENAME COLUMN period_from TO period_from_x`)
	require.NoError(t, err)
	res, err := p.Run(context.Background(), RunOptions{Spec: WindowSpec{From: time.Unix(1000, 0)}})
	require.Error(t, err, "no row to record the failure on → the caller is told")
	assert.Zero(t, res.RecapID)
	assert.False(t, gen.called)
}

// The profile and the learned rules only personalise the recap; losing them
// costs personalisation, not the recap.
func TestRun_ProfileAndPrefsReadFailuresStillCompose(t *testing.T) {
	gen := &mockGenerator{}
	p, d := newPipeline(t, gen, &fakeTopUp{})
	id := seedDigest(t, d, 1500, 1900)
	gen.out = fmt.Sprintf(composeOK, id)
	_, err := d.Exec(`DROP TABLE workspace`)
	require.NoError(t, err)
	_, err = d.Exec(`DROP TABLE inbox_learned_rules`)
	require.NoError(t, err)
	res, err := p.Run(context.Background(), RunOptions{Spec: WindowSpec{From: time.Unix(1000, 0)}})
	require.NoError(t, err)
	assert.Equal(t, "ready", res.Status)
	assert.True(t, gen.called)
	r, _ := d.GetCatchupRecap(res.RecapID)
	assert.Equal(t, "quiet day", r.TLDR)
}

func TestRun_RegenMissingSourceIsAnError(t *testing.T) {
	p, d := newPipeline(t, &mockGenerator{}, &fakeTopUp{})
	_, err := p.Run(context.Background(), RunOptions{RegenOfID: 999})
	require.Error(t, err)
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM catchup_recaps`).Scan(&n))
	assert.Equal(t, 0, n, "no row for a regen of a recap that does not exist")
}

func TestRun_RegenRejectsAnExplicitWindow(t *testing.T) {
	p, d := newPipeline(t, &mockGenerator{}, &fakeTopUp{})
	_, err := p.Run(context.Background(), RunOptions{RegenOfID: 999, Spec: WindowSpec{Preset: "today"}})
	assert.ErrorIs(t, err, ErrWindow, "a regen reuses its source window; an explicit one is rejected, not ignored")
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM catchup_recaps`).Scan(&n))
	assert.Equal(t, 0, n)
}

func TestRun_RegenReusesWindowAndSkipsTopUp(t *testing.T) {
	top := &fakeTopUp{}
	var user string
	gen := &mockGenerator{fn: func(_, u string) string { user = u; return `{"tldr":"","topics":[]}` }}
	p, d := newPipeline(t, gen, top)
	seedDigest(t, d, 1500, 1900)
	orig, _ := d.InsertCatchupRecap(1200, 1950, 0)
	res, err := p.Run(context.Background(), RunOptions{RegenOfID: orig, Correction: "less about deploys"})
	require.NoError(t, err)
	assert.Equal(t, int64(1200), res.Window.From.Unix())
	assert.Equal(t, int64(1950), res.Window.To.Unix())
	assert.Equal(t, 0, top.channelCalls)
	assert.Contains(t, user, "OPERATOR CORRECTION: less about deploys")
	r, _ := d.GetCatchupRecap(res.RecapID)
	assert.Equal(t, orig, r.RegenOfID)
}

func TestRun_InvalidWindowIsAnError(t *testing.T) {
	p, _ := newPipeline(t, &mockGenerator{}, &fakeTopUp{})
	_, err := p.Run(context.Background(), RunOptions{Spec: WindowSpec{Preset: "fortnight"}})
	assert.ErrorIs(t, err, ErrWindow)
}

func TestAcknowledge_UsesRecapWindow(t *testing.T) {
	p, d := newPipeline(t, &mockGenerator{}, &fakeTopUp{})
	seedDigest(t, d, 1500, 1900)
	id, _ := d.InsertCatchupRecap(1000, 2000, 0)
	require.NoError(t, d.FinishCatchupRecap(id, "tl", `{"topics":[]}`, `{}`, "", 0, 0, 0))
	require.NoError(t, p.Acknowledge(id))
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM digests WHERE read_at IS NOT NULL`).Scan(&n))
	assert.Equal(t, 1, n)
	assert.Error(t, p.Acknowledge(999))
}

// "I'm caught up" on a recap that never finished would mark its whole window
// read without ever having told the operator what was in it.
func TestAcknowledge_RefusesUnfinishedRecap(t *testing.T) {
	p, d := newPipeline(t, &mockGenerator{}, &fakeTopUp{})
	seedDigest(t, d, 1500, 1900)

	building, err := d.InsertCatchupRecap(1000, 2000, 0)
	require.NoError(t, err)
	assert.ErrorContains(t, p.Acknowledge(building), "not ready")

	failed, err := d.InsertCatchupRecap(1000, 2000, 0)
	require.NoError(t, err)
	require.NoError(t, d.FailCatchupRecap(failed, `{}`, "boom"))
	assert.ErrorContains(t, p.Acknowledge(failed), "not ready")

	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM digests WHERE read_at IS NOT NULL`).Scan(&n))
	assert.Zero(t, n, "a refused acknowledge marks nothing read")
	r, err := d.GetCatchupRecap(building)
	require.NoError(t, err)
	assert.Empty(t, r.AcknowledgedAt, "and never stamps the recap")
}
