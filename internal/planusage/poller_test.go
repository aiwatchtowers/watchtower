package planusage

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/claude"
	"watchtower/internal/db"
)

// scriptedRead is a Poller.Read that returns the next scripted result; the
// last one repeats.
type scriptedRead struct {
	snaps []claude.UsageSnapshot
	errs  []error
	calls int
}

func (s *scriptedRead) push(snap claude.UsageSnapshot, err error) {
	s.snaps, s.errs = append(s.snaps, snap), append(s.errs, err)
}

func (s *scriptedRead) Read(context.Context) (claude.UsageSnapshot, error) {
	i := min(s.calls, len(s.snaps)-1)
	s.calls++
	return s.snaps[i], s.errs[i]
}

func usageErr(code string) error { return &claude.UsageError{Code: code} }

func newPoller(t *testing.T, read *scriptedRead, now time.Time) (*Poller, *db.DB) {
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { d.Close() })
	return &Poller{Store: d, Read: read.Read, Now: func() time.Time { return now }, Logger: log.New(io.Discard, "", 0)}, d
}

func okRead() *scriptedRead {
	r := &scriptedRead{}
	r.push(testClaudeSnapshot("max", 100), nil)
	return r
}

func TestPollOnce_OK(t *testing.T) {
	p, d := newPoller(t, okRead(), at(10, 0))
	next, err := p.PollOnce(context.Background())
	require.NoError(t, err)
	assert.Equal(t, pollInterval, next)
	st, err := d.GetPlanUsageStatus()
	require.NoError(t, err)
	assert.Equal(t, "ok", st.State)
	assert.Equal(t, "max", st.Plan)
	var limits []Limit
	require.NoError(t, json.Unmarshal([]byte(st.LimitsJSON), &limits))
	require.Len(t, limits, 3)
	assert.Equal(t, "collecting", limits[1].Projection.State)
	assert.Equal(t, "hit", limits[2].Projection.State)
	var count int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM plan_usage_samples`).Scan(&count))
	assert.Equal(t, 3, count)
}

func TestPollOnce_BackoffKeepsLastNumbers(t *testing.T) {
	read := okRead()
	read.push(claude.UsageSnapshot{}, usageErr("network"))
	p, d := newPoller(t, read, at(10, 0))
	_, err := p.PollOnce(context.Background())
	require.NoError(t, err)
	var delays []time.Duration
	for range 5 {
		next, err := p.PollOnce(context.Background())
		require.Error(t, err)
		assert.Equal(t, "network", ErrorCode(err))
		delays = append(delays, next)
	}
	assert.Equal(t, []time.Duration{5 * time.Minute, 10 * time.Minute, 20 * time.Minute, 30 * time.Minute, 30 * time.Minute}, delays)
	st, _ := d.GetPlanUsageStatus()
	assert.Equal(t, "error", st.State)
	assert.Equal(t, "network", st.Reason)
	assert.Equal(t, "Claude usage: network", st.LastError)
	assert.Equal(t, "max", st.Plan)
	assert.Contains(t, st.LimitsJSON, "weekly_all", "last good numbers kept")
	require.NotNil(t, st.FetchedAt)
}

func TestPollOnce_CLIMissingIsUnavailable(t *testing.T) {
	read := okRead()
	read.push(claude.UsageSnapshot{}, usageErr("cli_missing"))
	p, d := newPoller(t, read, at(10, 0))
	_, err := p.PollOnce(context.Background())
	require.NoError(t, err)
	p.failures = 2
	next, err := p.PollOnce(context.Background())
	require.Error(t, err)
	assert.Equal(t, "cli_missing", ErrorCode(err))
	assert.Equal(t, pollInterval, next)
	assert.Zero(t, p.failures)
	st, _ := d.GetPlanUsageStatus()
	assert.Equal(t, "unavailable", st.State)
	assert.Equal(t, "cli_missing", st.Reason)
	assert.Equal(t, "max", st.Plan)
	assert.Contains(t, st.LimitsJSON, "weekly_all")
}

func TestPollOnce_PrunesOldSamples(t *testing.T) {
	p, d := newPoller(t, okRead(), at(10, 0))
	require.NoError(t, d.InsertPlanUsageSamples([]db.PlanUsageSample{{LimitKey: "session", TakenAt: at(10, 0).Add(-9 * 24 * time.Hour), Percent: 1}}))
	_, err := p.PollOnce(context.Background())
	require.NoError(t, err)
	old, _ := d.PlanUsageSamplesSince("session", at(10, 0).Add(-10*24*time.Hour))
	assert.Len(t, old, 1, "only the new sample is left")
}

func TestMarkDisabled_KeepsNumbers(t *testing.T) {
	p, d := newPoller(t, okRead(), at(10, 0))
	_, _ = p.PollOnce(context.Background())
	require.NoError(t, MarkDisabled(d, at(10, 5)))
	st, _ := d.GetPlanUsageStatus()
	assert.Equal(t, "disabled", st.State)
	assert.Contains(t, st.LimitsJSON, "weekly_all")
}

// A cancelled poll (daemon shutdown) writes nothing and counts no failure.
func TestPollOnce_CancelledWritesNothing(t *testing.T) {
	read := okRead()
	p, d := newPoller(t, read, at(10, 0))
	_, err := p.PollOnce(context.Background())
	require.NoError(t, err)
	before, _ := d.GetPlanUsageStatus()

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err = p.PollOnce(ctx)
	require.ErrorIs(t, err, context.Canceled)
	calls := read.calls
	assert.Equal(t, 1, calls, "an already-cancelled poll does not read")

	// Cancelled while reading: the reader answers cancelled, or even a snapshot.
	for _, step := range []struct {
		snap claude.UsageSnapshot
		err  error
	}{{claude.UsageSnapshot{}, usageErr("cancelled")}, {testClaudeSnapshot("pro", 5), nil}} {
		ctx, cancel := context.WithCancel(context.Background())
		p.Read = func(context.Context) (claude.UsageSnapshot, error) { cancel(); return step.snap, step.err }
		_, err = p.PollOnce(ctx)
		require.ErrorIs(t, err, context.Canceled)
	}

	after, _ := d.GetPlanUsageStatus()
	assert.Equal(t, before, after)
	assert.Zero(t, p.failures)
}

type failingStore struct {
	*db.DB
	err error
}

func (f failingStore) UpsertPlanUsageStatus(db.PlanUsageStatus) error { return f.err }
func (f failingStore) UpsertPlanUsageStatusContext(context.Context, db.PlanUsageStatus) error {
	return f.err
}

// A status-write failure in the no-credentials branch is reported as a
// storage failure, not hidden behind the quiet no_credentials code.
func TestPollOnce_NoCredentialsWriteFailureIsReported(t *testing.T) {
	read := &scriptedRead{}
	read.push(claude.UsageSnapshot{}, usageErr("no_credentials"))
	p, d := newPoller(t, read, at(10, 0))
	p.Store = failingStore{DB: d, err: errors.New("disk full")}
	_, err := p.PollOnce(context.Background())
	require.Error(t, err)
	assert.Equal(t, "storage", ErrorCode(err))
	assert.ErrorContains(t, err, "disk full")
}

func TestPollOnce_Reasons(t *testing.T) {
	cases := []struct {
		name        string
		err         error
		state, want string
		code        string
		delay       time.Duration
	}{
		{"cli_missing", usageErr("cli_missing"), "unavailable", "cli_missing", "cli_missing", pollInterval},
		{"unsupported_cli", usageErr("unsupported_cli"), "unavailable", "unsupported_cli", "unsupported_cli", pollInterval},
		{"no_credentials", usageErr("no_credentials"), "unavailable", "no_credentials", "no_credentials", pollInterval},
		{"unsupported_auth", usageErr("unsupported_auth"), "unavailable", "unsupported_auth", "unsupported_auth", pollInterval},
		{"cloud_bedrock", usageErr("cloud_bedrock"), "unavailable", "cloud_bedrock", "cloud_bedrock", pollInterval},
		{"cloud_vertex", usageErr("cloud_vertex"), "unavailable", "cloud_vertex", "cloud_vertex", pollInterval},
		{"cloud_foundry", usageErr("cloud_foundry"), "unavailable", "cloud_foundry", "cloud_foundry", pollInterval},
		{"network", usageErr("network"), "error", "network", "network", 10 * time.Minute},
		{"parse", usageErr("parse"), "error", "parse", "parse", 10 * time.Minute},
		{"timeout", usageErr("timeout"), "error", "timeout", "timeout", 10 * time.Minute},
		{"no window", nil, "error", "parse", "parse", 10 * time.Minute},
		{"config", &OperationError{Code: "storage", Cause: errors.New("bad config")}, "error", "network", "storage", 10 * time.Minute},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			read := &scriptedRead{}
			read.push(claude.UsageSnapshot{Plan: "max"}, c.err)
			p, d := newPoller(t, read, at(10, 0))
			p.failures = 1
			next, err := p.PollOnce(context.Background())
			require.Error(t, err)
			var op *OperationError
			require.ErrorAs(t, err, &op)
			assert.Equal(t, c.code, op.Code)
			assert.Equal(t, c.delay, next)
			st, _ := d.GetPlanUsageStatus()
			assert.Equal(t, c.state, st.State)
			assert.Equal(t, c.want, st.Reason)
			assert.Equal(t, "Claude usage: "+c.code, st.LastError)
			require.NotNil(t, st.LastErrorAt)
		})
	}
}

func TestPollOnce_StoresBreakdownOrEmpty(t *testing.T) {
	snap := testClaudeSnapshot("max", 10)
	snap.Breakdown = []claude.BreakdownRow{{Key: "claude_code", Label: "Claude Code", Percent: 80}, {Key: "chat", Label: "Chats", Percent: 20}}
	read := &scriptedRead{}
	read.push(snap, nil)
	read.push(testClaudeSnapshot("max", 10), nil)
	p, d := newPoller(t, read, at(10, 0))
	_, err := p.PollOnce(context.Background())
	require.NoError(t, err)
	st, _ := d.GetPlanUsageStatus()
	var rows []BreakdownRow
	require.NoError(t, json.Unmarshal([]byte(st.BreakdownJSON), &rows))
	assert.Equal(t, []BreakdownRow{{Key: "claude_code", Label: "Claude Code", Percent: 80}, {Key: "chat", Label: "Chats", Percent: 20}}, rows)

	p.Now = func() time.Time { return at(10, 5) }
	_, err = p.PollOnce(context.Background())
	require.NoError(t, err)
	st, _ = d.GetPlanUsageStatus()
	assert.Equal(t, "[]", st.BreakdownJSON)
}

const childSecret = "CHILD-SECRET-41"

// writeClaudeScript writes a fake claude that appends its PID (= its process
// group: the reader starts it with Setpgid) on every start, writes the secret to stderr and
// as a malformed stdout line, then prints answer; cleanup kills every recorded group.
func writeClaudeScript(t *testing.T, answer string) string {
	t.Helper()
	dir := t.TempDir()
	pidFile := filepath.Join(dir, "pid")
	quote := func(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }
	body := strings.Join([]string{
		"#!/bin/sh",
		"echo $$ >> " + quote(pidFile),
		"IFS= read -r line",
		"printf '%s\\n' " + quote(childSecret+" on stderr") + " >&2",
		"printf '%s\\n' " + quote("{not json "+childSecret),
		"printf '%s\\n' " + quote(answer),
		"/bin/cat >/dev/null",
	}, "\n") + "\n"
	script := filepath.Join(dir, "claude")
	require.NoError(t, os.WriteFile(script, []byte(body), 0o700))
	t.Cleanup(func() {
		b, err := os.ReadFile(pidFile)
		if err != nil {
			return
		}
		for _, line := range strings.Fields(string(b)) {
			if pid, err := strconv.Atoi(line); err == nil && pid > 0 {
				_ = syscall.Kill(-pid, syscall.SIGKILL)
			}
		}
	})
	return script
}

func claudeAnswer(payload string) string {
	return `{"type":"control_response","response":{"subtype":"success","request_id":"wt-usage","response":` + payload + `}}`
}

// PLANUSAGE-02 guard: whatever the usage child prints (stderr, unknown answer
// fields, malformed lines, error text) never reaches the status row, the
// samples, the log or a returned error.
func TestPlanUsage02_ChildOutputNeverPersisted(t *testing.T) {
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { d.Close() })
	var logs bytes.Buffer
	logger := log.New(&logs, "", 0)
	var bin string
	poller := &Poller{Store: d, Now: func() time.Time { return at(10, 0) }, Logger: logger,
		Read: func(ctx context.Context) (claude.UsageSnapshot, error) {
			return claude.ReadUsage(ctx, bin, []string{"PATH=/usr/bin:/bin", "HOME=" + t.TempDir()})
		}}
	requested := make(chan time.Duration, 1)
	ticks := make(chan time.Time)
	prov := &Provider{Name: "claude", Workspace: t.TempDir(), Logger: logger, Poll: poller.PollOnce,
		After: func(d time.Duration) <-chan time.Time { requested <- d; return ticks }}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { defer close(done); _ = prov.Run(ctx) }()
	t.Cleanup(func() { cancel(); <-done })
	<-requested

	runs := []struct {
		name, answer, state string
	}{
		{"success", claudeAnswer(`{"subscription_type":"max","rate_limits_available":true,"unknown_field":"` + childSecret +
			`","rate_limits":{"five_hour":{"utilization":12,"resets_at":null},"seven_day":{"utilization":40,"resets_at":null}}}`), "ok"},
		{"parse", claudeAnswer(`{"subscription_type":"max","rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":"` +
			childSecret + `","resets_at":null}}}`), "error"},
		{"network", `{"type":"control_response","response":{"subtype":"error","request_id":"wt-usage","error":"` + childSecret + `"}}`, "error"},
	}
	for _, run := range runs {
		bin = writeClaudeScript(t, run.answer)
		ticks <- time.Time{}
		<-requested
		st, err := d.GetPlanUsageStatus()
		require.NoError(t, err)
		require.NotNil(t, st)
		require.Equal(t, run.state, st.State, run.name)
		if run.state == "error" {
			require.Equal(t, run.name, st.Reason, "the run reached the failure it names")
		}
		assert.NotContains(t, fmt.Sprintf("%+v", *st), childSecret, run.name+": status row")
		samples := dumpSamples(t, d)
		assert.NotEmpty(t, samples, run.name)
		assert.NotContains(t, samples, childSecret, run.name+": samples")
		assert.NotContains(t, logs.String(), childSecret, run.name+": log")
		_, err = poller.PollOnce(context.Background())
		if run.state == "ok" {
			require.NoError(t, err)
		} else {
			require.Error(t, err)
			assert.NotContains(t, err.Error(), childSecret, run.name+": error")
			assert.NotContains(t, fmt.Sprintf("%+v %#v", err, errors.Unwrap(err)), childSecret, run.name+": error cause")
		}
	}
	assert.NotEmpty(t, logs.String(), "failures were logged")
}

func dumpSamples(t *testing.T, d *db.DB) string {
	t.Helper()
	rows, err := d.Query(`SELECT taken_at, limit_key, percent, resets_at FROM plan_usage_samples`)
	require.NoError(t, err)
	defer rows.Close()
	var b strings.Builder
	for rows.Next() {
		var taken, key, reset string
		var pct float64
		require.NoError(t, rows.Scan(&taken, &key, &pct, &reset))
		fmt.Fprintf(&b, "%s %s %v %s\n", taken, key, pct, reset)
	}
	require.NoError(t, rows.Err())
	return b.String()
}
