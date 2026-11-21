package cmd

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"watchtower/internal/askanswer"
	"watchtower/internal/db"
	"watchtower/internal/watchmanact"
)

// stallCodexPort is a session host with one live Codex run that takes every
// line (submitted).
type stallCodexPort struct {
	mu        sync.Mutex
	session   int64
	startedAt time.Time
	lines     int
}

func (p *stallCodexPort) Live(_ context.Context, id int64) (askanswer.LiveRun, bool, error) {
	if id != p.session {
		return askanswer.LiveRun{}, false, nil
	}
	return askanswer.LiveRun{SessionID: id, Run: 1, Agent: "codex", StartedAt: p.startedAt}, true, nil
}

func (p *stallCodexPort) Deliver(context.Context, askanswer.DeliverRequest) (askanswer.DeliverResult, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.lines++
	return askanswer.DeliverResult{Outcome: askanswer.DeliverSubmitted}, nil
}

func (p *stallCodexPort) delivered() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.lines
}

// The stall watch reads a Codex session's sub-agents from its own hooks
// (spec 2026-11-21-watchman-tuning §4b): the SubagentStart fixture through
// `workbench session-state --agent codex`, then the Stop, leave the count
// above zero — agents working, never pinged; after the SubagentStop the
// count drops to zero, and once its 120 s grace has passed the session is
// stopped and pinged 3 minutes later.
func TestStall_CodexSubagentNotPinged(t *testing.T) {
	database, pid, row := codexRowFixture(t, codexExecSession)
	storeCodexState(t, database, pid, row, codexExecSession, agentStateWorking)
	base := time.Now().UTC().Truncate(time.Millisecond)
	orig := hookNow
	t.Cleanup(func() { hookNow = orig })
	at := func(d time.Duration) { hookNow = func() time.Time { return base.Add(d) } }

	at(time.Second)
	runCodexState(t, string(codexHookFixture(t, "subagent_start")))
	at(2 * time.Second)
	_, errOut := runCodexStop(t, codexPayload(t, "stop", map[string]any{"session_id": codexExecSession}))
	require.Empty(t, errOut)
	s := codexRow(t, database, row)
	require.Equal(t, agentStateWaiting, s.AgentState.String)
	require.Greater(t, s.Background.Int64, int64(0), "the open sub-agent turn is counted")

	require.NoError(t, database.UpsertWatchmanArming(db.WatchmanArming{Scope: "session", RefID: row, ArmedAt: base, ArmedBy: "cli"}))
	port := &stallCodexPort{session: row, startedAt: base.Add(-time.Hour)}
	var mu sync.Mutex
	now := base
	clock := func() time.Time { mu.Lock(); defer mu.Unlock(); return now }
	twin := watchmanact.NewTwin(watchmanact.TwinDeps{
		DB: database, Answerer: askanswer.New(askanswer.Deps{DB: database, Sessions: port, Clock: clock}),
		Live: port.Live, Clock: clock,
		Head: func(context.Context, string) (string, error) { return "c0ffee", nil },
	})
	check := func(t2 time.Time) int {
		mu.Lock()
		now = t2
		mu.Unlock()
		twin.CheckStalls(context.Background())
		return port.delivered()
	}

	for _, d := range []time.Duration{watchmanact.StallAfter, 10 * time.Minute, time.Hour} {
		require.Zero(t, check(base.Add(d)), "pinged %v after the Stop while the sub-agent runs", d)
	}

	stop := time.Hour + time.Minute
	at(stop)
	runCodexState(t, string(codexHookFixture(t, "subagent_stop")))
	s = codexRow(t, database, row)
	require.Equal(t, int64(0), s.Background.Int64, "the sub-agent's turn closed")
	stopped := base.Add(stop + 120*time.Second)
	require.Zero(t, check(stopped.Add(-time.Second)), "pinged inside the 120 s grace")
	require.Zero(t, check(stopped.Add(watchmanact.StallAfter-time.Second)), "pinged before 3 minutes stopped")
	require.Equal(t, 1, check(stopped.Add(watchmanact.StallAfter)), "pinged 3 minutes after the grace ended")
}
