package cmd

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/chat"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/hub/chatrun"
	"watchtower/internal/policy/policytest"
)

// persistBackend is the provider behind `ai session --persist` in these
// tests (in process, so there is no child to reap): each turn streams one
// delta, then either completes or — with hang — waits for Cancel.
type persistBackend struct {
	hang         bool
	hangTurn     string             // when set, only this turn id hangs
	ignoreCancel bool               // a hanging turn never answers Cancel (it waits for the session's end)
	onTurn       func(chat.Command) // runs when the provider gets the turn

	mu        sync.Mutex
	turns     []chat.Command
	cancels   int
	cancelled chan struct{}
	// delta closes once the first delta's Emit returned: the persister's
	// queue holds it, so the next handled tick has applied it.
	delta     chan struct{}
	deltaOnce sync.Once
}

func newPersistBackend() *persistBackend {
	return &persistBackend{cancelled: make(chan struct{}), delta: make(chan struct{})}
}

func (b *persistBackend) Start(context.Context) (string, error) { return "", nil }

func (b *persistBackend) Turn(ctx context.Context, c chat.Command, emit func(chat.Event)) error {
	b.mu.Lock()
	b.turns = append(b.turns, c)
	b.mu.Unlock()
	if b.onTurn != nil {
		b.onTurn(c)
	}
	emit(chat.Event{Type: chat.EventTextDelta, Text: "partial "})
	b.deltaOnce.Do(func() { close(b.delta) })
	if b.hang && (b.hangTurn == "" || b.hangTurn == c.TurnID) {
		cancelled := b.cancelled
		if b.ignoreCancel {
			cancelled = nil
		}
		select {
		case <-cancelled:
			emit(chat.Event{Type: chat.EventTurnDone, Status: chat.StatusInterrupted})
		case <-ctx.Done():
		}
		return nil
	}
	emit(chat.Event{Type: chat.EventTextDelta, Text: "answer"})
	emit(chat.Event{Type: chat.EventTurnDone, Status: chat.StatusComplete})
	return nil
}

func (b *persistBackend) Cancel() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.cancels == 0 {
		close(b.cancelled)
	}
	b.cancels++
	return nil
}

func (b *persistBackend) Close() error { return nil }

func (b *persistBackend) counts() (turns, cancels int) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return len(b.turns), b.cancels
}

// testClock is the persister's clock in these tests: it moves only when the
// test advances it.
type testClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *testClock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *testClock) advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(d)
}

// settle delivers one tick and waits until the persister has handled it: the
// second send is taken only once the loop is back from the first.
func settle(tick chan<- time.Time, clock *testClock) {
	tick <- clock.now()
	tick <- clock.now()
}

// startPersistSession runs `ai session --persist --lease-owner desktop
// --lease-owner-id launch-1` over backend, with the persister's 1 s tick
// driven by the returned channel and its clock by the returned testClock.
func startPersistSession(t *testing.T, backend *persistBackend) (*aiSessionRun, chan time.Time) {
	r, tick, _ := startPersistSessionClock(t, backend)
	return r, tick
}

func startPersistSessionClock(t *testing.T, backend *persistBackend) (*aiSessionRun, chan time.Time, *testClock) {
	t.Helper()
	tick := make(chan time.Time)
	clock := &testClock{t: time.Now()} // a fresh lease is fresh against the real clock too
	prevBackend, prevTick, prevNow := aiSessionBackend, aiSessionPersistTick, aiSessionPersistNow
	aiSessionPersistNow = clock.now
	aiSessionBackend = func(*cobra.Command, *config.Config, *db.DB, string, *db.ChatConversation, string,
		*db.ChatProjectContext, int64, []string, context.CancelFunc) (chat.Backend, error) {
		return backend, nil
	}
	aiSessionPersistTick = func() (<-chan time.Time, func()) { return tick, func() {} }
	aiSessionFlagPersist, aiSessionFlagLeaseOwner, aiSessionFlagLeaseOwnerID = true, "desktop", "launch-1"
	t.Cleanup(func() {
		aiSessionBackend, aiSessionPersistTick, aiSessionPersistNow = prevBackend, prevTick, prevNow
		aiSessionFlagPersist, aiSessionFlagLeaseOwner, aiSessionFlagLeaseOwnerID = false, "desktop", ""
	})
	// The fake claude path is never run: the backend seam replaces it.
	return startAISession(t, filepath.Join(t.TempDir(), "claude"), "main"), tick, clock
}

// untilTurnEnd returns the events up to and including the first turn_done,
// turn error or refused.
func (r *aiSessionRun) untilTurnEnd() []chat.Event {
	r.t.Helper()
	var out []chat.Event
	for {
		e, ok := <-r.events
		require.True(r.t, ok, "stream ended before the turn ended; got %v", out)
		out = append(out, e)
		if e.Type == chat.EventTurnDone || e.Type == chat.EventRefused || (e.Type == chat.EventError && e.TurnID != "") {
			return out
		}
	}
}

func openRunDB(t *testing.T, r *aiSessionRun) *db.DB {
	t.Helper()
	d, err := db.Open(r.dbPath)
	require.NoError(t, err)
	t.Cleanup(func() { d.Close() })
	return d
}

type persistedRow struct {
	ID                 int64
	Role, Text, Status string
	TurnID             string
	ParentID           sql.NullInt64
	ErrorCode          sql.NullString
}

func persistedRows(t *testing.T, d *db.DB, conv int64) []persistedRow {
	t.Helper()
	rows, err := d.Query(`SELECT id, role, text, status, turn_id, parent_id, error_code FROM chat_messages WHERE conversation_id = ? ORDER BY id`, conv)
	require.NoError(t, err)
	defer rows.Close()
	var out []persistedRow
	for rows.Next() {
		var m persistedRow
		require.NoError(t, rows.Scan(&m.ID, &m.Role, &m.Text, &m.Status, &m.TurnID, &m.ParentID, &m.ErrorCode))
		out = append(out, m)
	}
	require.NoError(t, rows.Err())
	return out
}

func indexOf(evs []chat.Event, typ string) int {
	for i, e := range evs {
		if e.Type == typ {
			return i
		}
	}
	return -1
}

// TestPersist_StartedBeforeTheFirstDelta: `started` names the rows Start
// wrote and comes before the turn's first delta; the turn ends complete
// with its whole text on disk and the lease released.
func TestPersist_StartedBeforeTheFirstDelta(t *testing.T) {
	backend := newPersistBackend()
	r, _ := startPersistSession(t, backend)
	r.next(chat.EventSessionReady)
	r.send(chat.Command{Type: chat.CommandTurn, TurnID: "t1", Text: "What changed?"})
	evs := r.untilTurnEnd()
	started, delta := indexOf(evs, chat.EventStarted), indexOf(evs, chat.EventTextDelta)
	require.GreaterOrEqual(t, started, 0, "no started event in %v", evs)
	require.Greater(t, delta, started, "started must precede the first delta")
	st := evs[started]
	assert.Equal(t, r.convID, st.ConversationID)
	assert.Equal(t, "t1", st.TurnID)
	r.close()

	d := openRunDB(t, r)
	rows := persistedRows(t, d, r.convID)
	require.Len(t, rows, 2)
	assert.Equal(t, st.OwnerMessageID, rows[0].ID)
	assert.Equal(t, st.AssistantMessageID, rows[1].ID)
	assert.Equal(t, []string{"user", "What changed?", "complete"}, []string{rows[0].Role, rows[0].Text, rows[0].Status})
	assert.Equal(t, []string{"assistant", "partial answer", "complete", "t1"}, []string{rows[1].Role, rows[1].Text, rows[1].Status, rows[1].TurnID})
	lease, err := d.GetChatLease(r.convID)
	require.NoError(t, err)
	assert.Nil(t, lease, "the finalize releases the lease")
}

// TestPersist_OwnerRowCommitsBeforeTheProvider: when the provider gets the
// turn, the owner's row and the empty partial reply are already committed
// (BEHAVIOR CHAT-01 — see docs/inventory/chat.md), and the provider is sent
// the stored text.
func TestPersist_OwnerRowCommitsBeforeTheProvider(t *testing.T) {
	backend := newPersistBackend()
	var seen []persistedRow
	r, _ := startPersistSession(t, backend)
	d := openRunDB(t, r)
	backend.onTurn = func(chat.Command) { seen = persistedRows(t, d, r.convID) }
	r.next(chat.EventSessionReady)
	r.send(chat.Command{Type: chat.CommandTurn, TurnID: "t1", Text: "Keep this"})
	r.untilTurnEnd()
	r.close()
	require.Len(t, seen, 2, "both rows exist before the provider runs")
	assert.Equal(t, "Keep this", seen[0].Text)
	assert.Equal(t, []string{"assistant", "", "partial"}, []string{seen[1].Role, seen[1].Text, seen[1].Status})
	backend.mu.Lock()
	defer backend.mu.Unlock()
	require.Len(t, backend.turns, 1)
	assert.Contains(t, backend.turns[0].Text, "Keep this")
}

// TestPersist_RefusedWhileTheHubHoldsTheLease: a live hub lease refuses the
// turn: `refused {conversation_busy, holder}`, nothing written, nothing
// sent to the provider.
func TestPersist_RefusedWhileTheHubHoldsTheLease(t *testing.T) {
	backend := newPersistBackend()
	r, _ := startPersistSession(t, backend)
	d := openRunDB(t, r)
	nowMS := time.Now().UnixMilli()
	require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
		ok, err := db.ClaimChatLeaseTx(tx, db.ChatLease{ConversationID: r.convID, Owner: db.ChatLeaseHub, OwnerID: "hub-1",
			TurnID: "phone-turn", StartedAtMS: nowMS, HeartbeatAtMS: nowMS}, nowMS)
		if err == nil && !ok {
			err = fmt.Errorf("claim refused")
		}
		return err
	}))
	r.next(chat.EventSessionReady)
	r.send(chat.Command{Type: chat.CommandTurn, TurnID: "t1", Text: "Mine"})
	evs := r.untilTurnEnd()
	last := evs[len(evs)-1]
	require.Equal(t, chat.EventRefused, last.Type, "%v", evs)
	assert.Equal(t, "conversation_busy", last.Reason)
	assert.Equal(t, "hub", last.Holder)
	assert.Equal(t, "t1", last.TurnID)
	r.close()
	assert.Empty(t, persistedRows(t, d, r.convID))
	turns, _ := backend.counts()
	assert.Zero(t, turns, "a refused turn never reaches the provider")
}

// TestPersist_LeaseOwnerIsDesktopWithTheLaunchID: the turn's lease is
// claimed as --lease-owner / --lease-owner-id, exactly as the Mac's
// persistTurnStart claims it.
func TestPersist_LeaseOwnerIsDesktopWithTheLaunchID(t *testing.T) {
	backend := newPersistBackend()
	var lease *db.ChatLease
	r, _ := startPersistSession(t, backend)
	d := openRunDB(t, r)
	backend.onTurn = func(chat.Command) {
		var err error
		lease, err = d.GetChatLease(r.convID)
		require.NoError(t, err)
	}
	r.next(chat.EventSessionReady)
	r.send(chat.Command{Type: chat.CommandTurn, TurnID: "t1", Text: "hi"})
	r.untilTurnEnd()
	r.close()
	require.NotNil(t, lease)
	assert.Equal(t, db.ChatLeaseDesktop, lease.Owner)
	assert.Equal(t, "launch-1", lease.OwnerID)
	assert.Equal(t, "t1", lease.TurnID)
}

// TestPersist_RemoteStopEndsTheTurnWithPartial: a Stop from the phone
// (cancel_requested_at_ms on the lease, as the hub's runner reads it) is read
// on the next tick and cancels the provider; the streamed text stays as a
// `partial` reply and the lease is released.
func TestPersist_RemoteStopEndsTheTurnWithPartial(t *testing.T) {
	backend := newPersistBackend()
	backend.hang = true
	r, tick := startPersistSession(t, backend)
	d := openRunDB(t, r)
	r.next(chat.EventSessionReady)
	r.send(chat.Command{Type: chat.CommandTurn, TurnID: "t1", Text: "Long one"})
	r.next(chat.EventTextDelta)
	tick <- time.Now() // no cancel yet: the turn keeps running
	_, cancels := backend.counts()
	assert.Zero(t, cancels)
	_, err := d.Exec(`UPDATE chat_turn_leases SET cancel_requested_at_ms = ? WHERE conversation_id = ?`, time.Now().UnixMilli(), r.convID)
	require.NoError(t, err)
	tick <- time.Now()
	done := r.next(chat.EventTurnDone)
	assert.Equal(t, chat.StatusInterrupted, done.Status)
	r.close()
	_, cancels = backend.counts()
	assert.Equal(t, 1, cancels)
	rows := persistedRows(t, d, r.convID)
	require.Len(t, rows, 2)
	assert.Equal(t, []string{"partial ", "partial"}, []string{rows[1].Text, rows[1].Status})
	assert.False(t, rows[1].ErrorCode.Valid)
	lease, err := d.GetChatLease(r.convID)
	require.NoError(t, err)
	assert.Nil(t, lease)
}

// TestPersist_StdinCancelStops: the Desktop's own Stop (stdin `cancel`)
// still goes to the provider; the reply ends `partial` with its text.
func TestPersist_StdinCancelStops(t *testing.T) {
	backend := newPersistBackend()
	backend.hang = true
	r, _ := startPersistSession(t, backend)
	r.next(chat.EventSessionReady)
	r.send(chat.Command{Type: chat.CommandTurn, TurnID: "t1", Text: "Long one"})
	r.next(chat.EventTextDelta)
	r.send(chat.Command{Type: chat.CommandCancel})
	assert.Equal(t, chat.StatusInterrupted, r.next(chat.EventTurnDone).Status)
	r.close()
	_, cancels := backend.counts()
	assert.Equal(t, 1, cancels)
	rows := persistedRows(t, openRunDB(t, r), r.convID)
	require.Len(t, rows, 2)
	assert.Equal(t, []string{"partial ", "partial"}, []string{rows[1].Text, rows[1].Status})
}

// TestPersist_RegenerateAndQuotesOverStdin: the turn command's starting
// fields reach the store — a regenerate names its owner message (parent_id)
// and reuses it; a send carries its quote batch and client-composed text.
func TestPersist_RegenerateAndQuotesOverStdin(t *testing.T) {
	backend := newPersistBackend()
	r, _ := startPersistSession(t, backend)
	d := openRunDB(t, r)
	res, err := d.Exec(`INSERT INTO chat_artifact_comments (conversation_id, artifact_key, artifact_version, body, anchor_quote, created_at)
		VALUES (?, 'doc', 1, 'why?', 'a passage', 1)`, r.convID)
	require.NoError(t, err)
	comment, err := res.LastInsertId()
	require.NoError(t, err)
	r.next(chat.EventSessionReady)
	title := "why?"
	r.send(chat.Command{Type: chat.CommandTurn, TurnID: "t1", Text: "> a passage\n\nwhy?", TitleText: &title, Quotes: []int64{comment}})
	first := r.untilTurnEnd()
	owner := first[indexOf(first, chat.EventStarted)].OwnerMessageID
	r.send(chat.Command{Type: chat.CommandTurn, TurnID: "t2", Mode: "regenerate", ParentID: owner})
	second := r.untilTurnEnd()
	require.GreaterOrEqual(t, indexOf(second, chat.EventStarted), 0, "%v", second)
	assert.Equal(t, owner, second[indexOf(second, chat.EventStarted)].OwnerMessageID)
	r.close()

	var status string
	require.NoError(t, d.QueryRow(`SELECT status FROM chat_artifact_comments WHERE id = ?`, comment).Scan(&status))
	assert.Equal(t, "sent", status)
	rows := persistedRows(t, d, r.convID)
	require.Len(t, rows, 3, "the regenerate wrote only its reply")
	assert.Equal(t, "> a passage\n\nwhy?", rows[0].Text)
	assert.Equal(t, owner, rows[2].ParentID.Int64)
	backend.mu.Lock()
	defer backend.mu.Unlock()
	require.Len(t, backend.turns, 2)
	assert.True(t, backend.turns[1].Replay, "a regenerate replays")
}

// TestQueryPersist_EmbeddedChatTurnWritesItsRows: `ai query --events v2
// --persist` (an embedded chat's turn) writes what EmbeddedChatStore
// writes: the owner row and the reply's partial placeholder before the
// provider runs, the steps, and the end — text, status, tokens, model.
func TestQueryPersist_EmbeddedChatTurnWritesItsRows(t *testing.T) {
	policytest.Set(t, nil)
	t.Setenv("HOME", t.TempDir())
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "wt.db")
	d, err := db.Open(dbPath)
	require.NoError(t, err)
	t.Cleanup(func() { d.Close() })
	res, err := d.Exec(`INSERT INTO chat_conversations (title, context_type, context_id, created_at, updated_at)
		VALUES ('Track', 'track', '7', 1, 1)`)
	require.NoError(t, err)
	conv, err := res.LastInsertId()
	require.NoError(t, err)
	cfg := filepath.Join(dir, "config.yaml")
	require.NoError(t, os.WriteFile(cfg, fmt.Appendf(nil, `active_workspace: test-ws
workspaces:
  test-ws:
    slack_token: "xoxp-test-token"
claude_path: %q
ai:
  provider: claude
`, v2ClaudeStub(t)), 0o600))
	p := startCLI(t, "ai", "query", "--config", cfg, "--db-path", dbPath, "--events", "v2", "--prompt-stdin",
		"--persist", "--conversation", fmt.Sprint(conv), "--turn", "q1")
	query, err := json.Marshal(map[string]any{"prompt": "context + What next?", "owner_text": "What next?"})
	require.NoError(t, err)
	_, err = p.stdin.Write(query)
	require.NoError(t, err)
	require.NoError(t, p.stdin.Close())
	var types []string
	var started chat.Event
	for line := range p.lines {
		var e chat.Event
		require.NoError(t, json.Unmarshal([]byte(line), &e), line)
		types = append(types, e.Type)
		if e.Type == chat.EventStarted {
			started = e
		}
	}
	require.NoError(t, p.wait(), p.stderr.String())
	require.NotEmpty(t, types)
	assert.Equal(t, chat.EventStarted, types[0], "the rows are on disk before anything streams: %v", types)
	assert.Equal(t, conv, started.ConversationID)

	rows := persistedRows(t, d, conv)
	require.Len(t, rows, 2)
	assert.Equal(t, started.OwnerMessageID, rows[0].ID)
	assert.Equal(t, []string{"user", "What next?", "q1"}, []string{rows[0].Role, rows[0].Text, rows[0].TurnID})
	assert.False(t, rows[0].ParentID.Valid, "an embedded chat is linear")
	assert.Equal(t, started.AssistantMessageID, rows[1].ID)
	assert.Equal(t, []string{"assistant", "Let me check.\n\nFound it.", "complete", "q1"},
		[]string{rows[1].Role, rows[1].Text, rows[1].Status, rows[1].TurnID})
	var in, out sql.NullInt64
	var model, provider sql.NullString
	require.NoError(t, d.QueryRow(`SELECT tokens_in, tokens_out, model, provider FROM chat_messages WHERE id = ?`, rows[1].ID).
		Scan(&in, &out, &model, &provider))
	assert.Equal(t, int64(50), in.Int64)
	assert.Equal(t, int64(7), out.Int64)
	assert.Equal(t, "claude-x", model.String)
	assert.Equal(t, "claude", provider.String)
	var steps int
	var name string
	var ended sql.NullFloat64
	require.NoError(t, d.QueryRow(`SELECT COUNT(*), MAX(name), MAX(ended_at) FROM chat_turn_steps WHERE message_id = ?`, rows[1].ID).
		Scan(&steps, &name, &ended))
	assert.Equal(t, 1, steps)
	assert.Equal(t, "list_targets", name)
	assert.True(t, ended.Valid)
	var updated float64
	require.NoError(t, d.QueryRow(`SELECT updated_at FROM chat_conversations WHERE id = ?`, conv).Scan(&updated))
	assert.Greater(t, updated, 1.0, "a complete reply touches the conversation")
}

// TestPersist_TurnWithoutIDIsRefusedAndLeavesTheOthersAlone: a turn with no
// turn_id is refused up front (no rows, no provider), so no event of it can
// read as a session-level error; the running turn and the one queued behind
// it end as they would have.
func TestPersist_TurnWithoutIDIsRefusedAndLeavesTheOthersAlone(t *testing.T) {
	backend := newPersistBackend()
	backend.hang, backend.hangTurn = true, "t1"
	r, _ := startPersistSession(t, backend)
	d := openRunDB(t, r)
	r.next(chat.EventSessionReady)
	r.send(chat.Command{Type: chat.CommandTurn, TurnID: "t1", Text: "first"})
	r.next(chat.EventTextDelta)
	r.send(chat.Command{Type: chat.CommandTurn, Text: "no id"})
	refused := r.next(chat.EventRefused)
	assert.Equal(t, "turn_id_required", refused.Reason)
	assert.Empty(t, refused.TurnID)
	r.send(chat.Command{Type: chat.CommandTurn, TurnID: "t2", Text: "queued"}) // waits for t1's end
	r.send(chat.Command{Type: chat.CommandCancel})
	assert.Equal(t, "t1", r.next(chat.EventTurnDone).TurnID)
	done := r.next(chat.EventTurnDone)
	assert.Equal(t, "t2", done.TurnID)
	assert.Equal(t, chat.StatusComplete, done.Status)
	r.close()

	rows := persistedRows(t, d, r.convID)
	require.Len(t, rows, 4, "t1 and t2 only: the refused turn wrote nothing")
	assert.Equal(t, []string{"partial", "t1"}, []string{rows[1].Status, rows[1].TurnID})
	assert.Equal(t, []string{"queued", "complete", "t2"}, []string{rows[2].Text, rows[3].Status, rows[3].TurnID})
	for _, m := range rows {
		assert.False(t, m.ErrorCode.Valid, "no turn ends as an error: %+v", m)
	}
	turns, _ := backend.counts()
	assert.Equal(t, 2, turns)
}

// TestPersist_RemoteStopWithoutAnswerFinalizesAfterGrace: a provider that
// never answers a remote Stop has its reply finalized `partial` (and the
// lease released) once chatrun.CancelGrace has passed on the persister's
// clock — and not a tick before.
func TestPersist_RemoteStopWithoutAnswerFinalizesAfterGrace(t *testing.T) {
	backend := newPersistBackend()
	backend.hang, backend.ignoreCancel = true, true
	r, tick, clock := startPersistSessionClock(t, backend)
	d := openRunDB(t, r)
	r.next(chat.EventSessionReady)
	r.send(chat.Command{Type: chat.CommandTurn, TurnID: "t1", Text: "Long one"})
	<-backend.delta
	_, err := d.Exec(`UPDATE chat_turn_leases SET cancel_requested_at_ms = ? WHERE conversation_id = ?`, clock.now().UnixMilli(), r.convID)
	require.NoError(t, err)
	settle(tick, clock) // the cancel goes out
	clock.advance(chatrun.CancelGrace - time.Second)
	settle(tick, clock) // still inside the grace
	lease, err := d.GetChatLease(r.convID)
	require.NoError(t, err)
	require.NotNil(t, lease, "inside the grace the turn still holds its lease")
	clock.advance(time.Second)
	settle(tick, clock) // the grace is over: finalized here
	lease, err = d.GetChatLease(r.convID)
	require.NoError(t, err)
	assert.Nil(t, lease, "the finalize released the lease")
	_, cancels := backend.counts()
	assert.Equal(t, 1, cancels)
	rows := persistedRows(t, d, r.convID)
	require.Len(t, rows, 2)
	assert.Equal(t, []string{"partial ", "partial"}, []string{rows[1].Text, rows[1].Status})
	assert.False(t, rows[1].ErrorCode.Valid)
	r.close()
}

// TestPersist_LostLeaseStopsWritingAndCancels: once another owner has taken
// the lease over, the next heartbeat (HeartbeatEvery on the persister's
// clock) finds it lost: the provider is cancelled and nothing more of the
// turn is written — its interrupted end leaves the row as last flushed.
func TestPersist_LostLeaseStopsWritingAndCancels(t *testing.T) {
	backend := newPersistBackend()
	backend.hang = true
	r, tick, clock := startPersistSessionClock(t, backend)
	d := openRunDB(t, r)
	r.next(chat.EventSessionReady)
	r.send(chat.Command{Type: chat.CommandTurn, TurnID: "t1", Text: "Long one"})
	<-backend.delta
	settle(tick, clock) // the first delta is flushed, the lease is ours
	_, cancels := backend.counts()
	require.Zero(t, cancels)
	_, err := d.Exec(`UPDATE chat_turn_leases SET owner = 'hub', owner_id = 'hub-1', turn_id = 'phone' WHERE conversation_id = ?`, r.convID)
	require.NoError(t, err)
	clock.advance(chatrun.HeartbeatEvery)
	settle(tick, clock)
	assert.Equal(t, chat.StatusInterrupted, r.next(chat.EventTurnDone).Status)
	r.close()
	_, cancels = backend.counts()
	assert.Equal(t, 1, cancels)
	rows := persistedRows(t, d, r.convID)
	require.Len(t, rows, 2)
	assert.Equal(t, []string{"partial ", "partial"}, []string{rows[1].Text, rows[1].Status}, "the interrupted end is not written")
	lease, err := d.GetChatLease(r.convID)
	require.NoError(t, err)
	require.NotNil(t, lease)
	assert.Equal(t, db.ChatLeaseHub, lease.Owner, "the new holder's lease is left alone")
}

// TestPersist_StartedCarriesThePrefixResults: `started` tells the client
// what the Mac's RememberCenter / ChatKnowledgeCenter show under the owner's
// message — a remembered line (with its id, for Undo) and a chat-born idea.
func TestPersist_StartedCarriesThePrefixResults(t *testing.T) {
	backend := newPersistBackend()
	r, _ := startPersistSession(t, backend)
	d := openRunDB(t, r)
	r.next(chat.EventSessionReady)
	r.send(chat.Command{Type: chat.CommandTurn, TurnID: "t1", Text: "remember: answer in short bullets"})
	evs := r.untilTurnEnd()
	st := evs[indexOf(evs, chat.EventStarted)]
	assert.Equal(t, string(db.RememberAdded), st.RememberOutcome)
	require.NotZero(t, st.RememberLineID)
	var messageID int64
	require.NoError(t, d.QueryRow(`SELECT message_id FROM instruction_chat_lines WHERE id = ?`, st.RememberLineID).Scan(&messageID))
	assert.Equal(t, st.OwnerMessageID, messageID)
	assert.Empty(t, st.PrefixError)

	r.send(chat.Command{Type: chat.CommandTurn, TurnID: "t2", Text: "decided: ship on Monday"})
	evs = r.untilTurnEnd()
	st = evs[indexOf(evs, chat.EventStarted)]
	require.NotZero(t, st.IdeaID)
	assert.Equal(t, "decision", st.IdeaKind)
	assert.Empty(t, st.RememberOutcome)
	r.close()
}

// TestPersist_ScreenBlockIsSentButNotStored: the help popup's screen block
// goes to the provider ahead of the text and is never stored (the Mac's
// ChatTurnText.compose).
func TestPersist_ScreenBlockIsSentButNotStored(t *testing.T) {
	backend := newPersistBackend()
	r, _ := startPersistSession(t, backend)
	r.next(chat.EventSessionReady)
	r.send(chat.Command{Type: chat.CommandTurn, TurnID: "t1", Text: "What is this?", Screen: "[SCREEN] Inbox"})
	r.untilTurnEnd()
	r.close()
	backend.mu.Lock()
	sent := backend.turns[0].Text
	backend.mu.Unlock()
	// The session puts its time line first, as for every turn.
	assert.True(t, strings.HasSuffix(sent, "[SCREEN] Inbox\n\nWhat is this?"), "sent: %q", sent)
	rows := persistedRows(t, openRunDB(t, r), r.convID)
	require.NotEmpty(t, rows)
	assert.Equal(t, "What is this?", rows[0].Text)
}

// TestStubSessionBackend_AnswersAtOnce: the hidden --test-stub-reply backend
// (the Desktop's chat timing test) answers each turn with its text.
func TestStubSessionBackend_AnswersAtOnce(t *testing.T) {
	var evs []chat.Event
	err := stubSessionBackend{reply: "ok"}.Turn(context.Background(), chat.Command{TurnID: "t1"},
		func(e chat.Event) { evs = append(evs, e) })
	require.NoError(t, err)
	require.Len(t, evs, 3)
	assert.Equal(t, chat.Event{Type: chat.EventTextDelta, TurnID: "t1", Text: "ok"}, evs[1])
	assert.Equal(t, chat.StatusComplete, evs[2].Status)
}
