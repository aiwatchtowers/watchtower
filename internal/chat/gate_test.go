package chat

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/chat/connectorpolicy"
	"watchtower/internal/tools"
)

// fakeSink is an ActionSink with the registry's transitions: a row moves by
// conditional steps only, so a test sees exactly what a session could do.
type fakeSink struct {
	mu         sync.Mutex
	rows       map[int64]*fakeRow
	next       int64
	proposeErr error
	statusErr  error // ActionStatus fails with it for every row
	// beforeCancel runs (under no lock) when CancelCall is entered: a test
	// lands the owner's Approve between the timeout and the cancel.
	beforeCancel func(id int64)
	// onExpireOrphans runs when ExpireOrphans is called.
	onExpireOrphans func()
	// beforePropose and beforeStatus run (under no lock) when the call is
	// entered: a test holds the gate there.
	beforePropose func()
	beforeStatus  func(id int64)
	afterClaim    func(id int64)
}

type fakeRow struct {
	call     ConnectorCall
	status   string
	input    json.RawMessage
	result   string
	callErr  string
	reason   string
	finishes int
}

func newFakeSink() *fakeSink { return &fakeSink{rows: map[int64]*fakeRow{}} }

func (s *fakeSink) ProposeConnectorCall(_ context.Context, c ConnectorCall) (int64, error) {
	if s.beforePropose != nil {
		s.beforePropose()
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.proposeErr != nil {
		return 0, s.proposeErr
	}
	s.next++
	s.rows[s.next] = &fakeRow{call: c, status: "pending", input: append(json.RawMessage(nil), c.Input...)}
	return s.next, nil
}

func (s *fakeSink) ActionStatus(_ context.Context, id int64) (string, error) {
	s.mu.Lock()
	hook := s.beforeStatus // set while the gate runs: read under the lock
	s.mu.Unlock()
	if hook != nil {
		hook(id)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.statusErr != nil {
		return "", s.statusErr
	}
	r, ok := s.rows[id]
	if !ok {
		return "", errors.New("no such row")
	}
	return r.status, nil
}

func (s *fakeSink) ClaimApproved(_ context.Context, id int64) (json.RawMessage, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r := s.rows[id]
	if r == nil || r.status != "approved" {
		return nil, false, nil
	}
	r.status = "executing"
	if s.afterClaim != nil {
		s.mu.Unlock()
		s.afterClaim(id)
		s.mu.Lock()
	}
	return r.input, true, nil
}

func (s *fakeSink) FinishCall(_ context.Context, id int64, result, callErr string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	r := s.rows[id]
	if r == nil || r.status != "executing" {
		return errors.New("not executing")
	}
	r.finishes++
	r.result, r.callErr, r.status = result, callErr, "applied"
	if callErr != "" {
		r.status = "failed"
	}
	return nil
}

func (s *fakeSink) CancelCall(_ context.Context, id int64, reason string) (bool, error) {
	if s.beforeCancel != nil {
		s.beforeCancel(id)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	r := s.rows[id]
	if r == nil || r.status != "pending" {
		return false, nil
	}
	r.status, r.reason = "rejected", reason
	return true, nil
}

func (s *fakeSink) ExpireCall(_ context.Context, id int64, reason string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r := s.rows[id]
	if r == nil || (r.status != "pending" && r.status != "approved") {
		return false, nil
	}
	r.status, r.reason = "failed", reason
	return true, nil
}

func (s *fakeSink) ExpireOrphans(context.Context) error {
	if s.onExpireOrphans != nil {
		s.onExpireOrphans()
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, r := range s.rows {
		if r.status == "pending" || r.status == "approved" || r.status == "executing" {
			r.status, r.reason = "failed", "session ended before approval"
		}
	}
	return nil
}

// approve is the owner's Approve: pending → approved, with an edited input
// when one is given.
func (s *fakeSink) approve(id int64, input string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	r := s.rows[id]
	if r == nil || r.status != "pending" {
		return false
	}
	r.status = "approved"
	if input != "" {
		r.input = json.RawMessage(input)
	}
	return true
}

func (s *fakeSink) reject(id int64) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	r := s.rows[id]
	if r == nil || r.status != "pending" {
		return false
	}
	r.status = "rejected"
	return true
}

// row returns a copy of row id.
func (s *fakeSink) row(id int64) fakeRow {
	s.mu.Lock()
	defer s.mu.Unlock()
	if r := s.rows[id]; r != nil {
		return *r
	}
	return fakeRow{}
}

func (s *fakeSink) count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.rows)
}

// waitRows waits until n rows were proposed.
func (s *fakeSink) waitRows(t *testing.T, n int) {
	t.Helper()
	waitUntil(t, fmt.Sprintf("%d proposed rows", n), func() bool { return s.count() >= n })
}

func waitUntil(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

const gmailSendInput = `{"to":"someone@example.com","body":"hello"}`

// canUseTool builds a can_use_tool request line; server "" is a built-in.
func canUseTool(requestID, toolUseID, tool, server, input string) string {
	srv := ""
	if server != "" {
		srv = `,"mcp_server":{"name":"` + server + `","source":"claudeai"}`
	}
	return `{"type":"control_request","request_id":"` + requestID + `","request":{"subtype":"can_use_tool","tool_name":"` +
		tool + `","display_name":"Send"` + srv + `,"input":` + input + `,"tool_use_id":"` + toolUseID + `"}}`
}

func gmailSend(requestID, toolUseID string) string {
	return canUseTool(requestID, toolUseID, "mcp__claude_ai_Gmail__send", "claude.ai Gmail", gmailSendInput)
}

// testConnectors is the mcp_status list the gate tests' fake CLI answers:
// Gmail (send unannotated) and Claude Docs, as the probe recorded them.
const testConnectors = `[` +
	`{"name":"claude.ai Gmail","status":"connected","source":"claudeai","config":{"type":"claudeai-proxy"},` +
	`"tools":[{"name":"send","annotations":{}},{"name":"search","annotations":{"readOnly":true}}]},` +
	`{"name":"claude.ai Claude Docs","status":"connected","source":"claudeai","config":{"type":"claudeai-proxy"},` +
	`"tools":[{"name":"read","annotations":{"readOnly":true}},{"name":"create","annotations":{}},` +
	`{"name":"update","annotations":{}},{"name":"batch","annotations":{}},{"name":"delete","annotations":{"destructive":true}}]}]`

// testCatalog is testConnectors as a snapshot.
func testCatalog(t *testing.T) ConnectorSnapshot {
	t.Helper()
	line := `{"type":"control_response","response":{"subtype":"success","request_id":"s","response":{"mcpServers":` + testConnectors + `}}}`
	servers, ok, err := parseMCPStatusResponse([]byte(line), "s")
	require.True(t, ok)
	require.NoError(t, err)
	return newConnectorSnapshot(time.Now(), servers, nil)
}

type gateFixture struct {
	opts     ClaudeOptions
	files    fakeFiles
	sink     *fakeSink
	pub      *PublishDir
	requests string
	status   string // the fake's mcp_status answers, one list per line
}

// setStatus makes the fake answer its k-th mcp_status with lists[k-1] (the
// last one repeating).
func (fx *gateFixture) setStatus(t *testing.T, lists ...string) {
	t.Helper()
	require.NoError(t, os.WriteFile(fx.status, []byte(strings.Join(lists, "\n")+"\n"), 0o600))
}

// gateFake runs the fake CLI in gate mode with requests as each turn's
// permission requests, behind a gate over a fake sink.
func gateFake(t *testing.T, requests ...string) *gateFixture {
	t.Helper()
	opts, f := fakeClaude(t, "gate")
	fx := &gateFixture{files: f, sink: newFakeSink(), requests: filepath.Join(filepath.Dir(f.argv), "requests")}
	fx.setRequests(t, requests...)
	pub, err := NewPublishDir(f.workDir, 7)
	require.NoError(t, err)
	fx.pub = pub
	fx.status = filepath.Join(filepath.Dir(f.argv), "mcp_status")
	fx.setStatus(t, testConnectors)
	opts.Env = append(opts.Env, "FAKE_CLAUDE_GATE_REQUESTS="+fx.requests, "FAKE_MCP_STATUS="+fx.status)
	opts.ClaudeAI = ClaudeAIMode{On: true, Connectors: true}
	opts.Gate = &GateOptions{Sink: fx.sink, Publish: pub,
		Policy: connectorpolicy.Policy{Disabled: map[string]bool{}}, PollInterval: 10 * time.Millisecond}
	fx.opts = opts
	return fx
}

func (fx *gateFixture) setRequests(t *testing.T, requests ...string) {
	t.Helper()
	body := strings.Join(requests, "\n")
	if body != "" {
		body += "\n"
	}
	require.NoError(t, os.WriteFile(fx.requests, []byte(body), 0o600))
}

// controlAnswers returns the control_response lines the gate wrote to the
// CLI, by request id, in order.
func (fx *gateFixture) controlAnswers(t *testing.T) map[string][]map[string]json.RawMessage {
	t.Helper()
	data, err := os.ReadFile(fx.files.stdin)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	require.NoError(t, err)
	out := map[string][]map[string]json.RawMessage{}
	for _, line := range strings.Split(string(data), "\n") {
		var l struct {
			Type     string `json:"type"`
			Response struct {
				Subtype   string                     `json:"subtype"`
				RequestID string                     `json:"request_id"`
				Response  map[string]json.RawMessage `json:"response"`
			} `json:"response"`
		}
		if json.Unmarshal([]byte(line), &l) != nil || l.Type != "control_response" {
			continue
		}
		out[l.Response.RequestID] = append(out[l.Response.RequestID], l.Response.Response)
	}
	return out
}

func behavior(t *testing.T, answer map[string]json.RawMessage) string {
	t.Helper()
	var b string
	require.NoError(t, json.Unmarshal(answer["behavior"], &b))
	return b
}

func denyMessage(t *testing.T, answer map[string]json.RawMessage) string {
	t.Helper()
	var m string
	require.NoError(t, json.Unmarshal(answer["message"], &m))
	return m
}

// until reads h's events up to and including the first one of type want.
func (h *harness) until(want string) []Event {
	h.t.Helper()
	var out []Event
	deadline := time.After(10 * time.Second)
	for {
		select {
		case e, ok := <-h.events:
			require.True(h.t, ok, "session ended before a %s event", want)
			out = append(out, e)
			if e.Type == want {
				return out
			}
		case <-deadline:
			h.t.Fatalf("no %s event within 10s", want)
		}
	}
}

func findEvent(evs []Event, typ, id string) (Event, int) {
	for i, e := range evs {
		if e.Type == typ && e.ID == id {
			return e, i
		}
	}
	return Event{}, -1
}

func TestChat05_ConnectorWriteWaitsForApproval(t *testing.T) {
	fx := gateFake(t, gmailSend("r1", "tu1"))
	h := startSession(t, NewClaudeBackend(fx.opts), nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "send it"})

	evs := h.until(EventToolWait)
	wait := evs[len(evs)-1]
	assert.Equal(t, "t1", wait.TurnID)
	assert.Equal(t, "tu1", wait.ID)
	assert.Equal(t, ToolWaitMessage, wait.Message)
	assert.EqualValues(t, 1, wait.ActionID)
	row := fx.sink.row(1)
	assert.Equal(t, "pending", row.status)
	assert.Equal(t, ConnectorCall{TurnID: "t1", Server: "claude.ai Gmail", Tool: "mcp__claude_ai_Gmail__send",
		Reason: "Send", Input: json.RawMessage(gmailSendInput)}, row.call)

	time.Sleep(100 * time.Millisecond) // ten polls
	assert.Empty(t, fx.controlAnswers(t)["r1"], "nothing reaches the CLI while the row is pending")

	edited := `{"to":"someone@example.com","body":"edited by the owner"}`
	require.True(t, fx.sink.approve(1, edited))
	end := h.next(EventToolEnd)
	require.NotNil(t, end.OK)
	assert.True(t, *end.OK)
	h.next(EventTurnDone)

	answers := fx.controlAnswers(t)["r1"]
	require.Len(t, answers, 1, "exactly one answer")
	assert.Equal(t, "allow", behavior(t, answers[0]))
	assert.JSONEq(t, edited, string(answers[0]["updatedInput"]), "the approved input runs, the owner's edit included")
	row = fx.sink.row(1)
	assert.Equal(t, "applied", row.status)
	assert.Equal(t, 1, row.finishes)
	assert.Equal(t, "ran", row.result)
	require.NoError(t, h.finish())
}

func TestChat05_PublishOnlyFromThePublishDir(t *testing.T) {
	outside := filepath.Join(t.TempDir(), "page.html")
	fx := gateFake(t)
	inside := filepath.Join(fx.pub.Path(), "page.html")
	// The CLI's own __artifact* keys ride the request input: the allow must
	// carry them back byte for byte.
	insideInput := `{"action":"publish","file_path":"` + inside + `","icon":"code","__artifactPublishSourcePin":{"path":"` +
		inside + `","sha256":"0f0f"}}`
	fx.setRequests(t,
		canUseTool("r1", "tu1", "Artifact", "", `{"action":"publish","file_path":"`+outside+`"}`),
		canUseTool("r2", "tu2", "Artifact", "", insideInput),
		canUseTool("r3", "tu3", "Write", "", `{"file_path":"`+outside+`","content":"x"}`),
	)
	h := startSession(t, NewClaudeBackend(fx.opts), nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "publish"})
	h.next(EventTurnDone)
	require.NoError(t, h.finish())

	answers := fx.controlAnswers(t)
	require.Len(t, answers["r1"], 1)
	assert.Equal(t, "deny", behavior(t, answers["r1"][0]))
	assert.Contains(t, denyMessage(t, answers["r1"][0]), "may only publish files inside "+fx.pub.Path())
	require.Len(t, answers["r2"], 1)
	assert.Equal(t, "allow", behavior(t, answers["r2"][0]))
	assert.Equal(t, insideInput, string(answers["r2"][0]["updatedInput"]), "the request's input echoed")
	require.Len(t, answers["r3"], 1)
	assert.Equal(t, "deny", behavior(t, answers["r3"][0]))
	assert.Contains(t, denyMessage(t, answers["r3"][0]), "Write may only use files inside")
	assert.Zero(t, fx.sink.count(), "no approval row for a publish or a Write")
	_, err := os.Lstat(outside)
	assert.ErrorIs(t, err, os.ErrNotExist)
}

func TestChat05_DeadSessionNeverRunsAnApprovedCall(t *testing.T) {
	fx := gateFake(t, gmailSend("r1", "tu1"))
	fx.opts.Gate.PollInterval = time.Hour // the approval is read only when the child's exit wakes the wait
	b := NewClaudeBackend(fx.opts)
	t.Cleanup(func() { _ = b.Close() })
	_, err := b.Start(context.Background())
	require.NoError(t, err)
	turnDone := make(chan error, 1)
	go func() { turnDone <- b.Turn(context.Background(), Command{TurnID: "t1", Text: "send"}, func(Event) {}) }()
	fx.sink.waitRows(t, 1)

	// The owner approves; the child dies before the session claims it.
	require.True(t, fx.sink.approve(1, ""))
	require.NoError(t, syscall.Kill(-readPIDFile(t, fx.files.pid), syscall.SIGKILL))
	select {
	case <-turnDone:
	case <-time.After(10 * time.Second):
		t.Fatal("the turn did not end after the child died")
	}
	require.NoError(t, b.Close())
	row := fx.sink.row(1)
	assert.Equal(t, "failed", row.status, "an approved call of a dead child never runs")
	assert.Equal(t, "session ended before approval", row.reason)

	// A row a whole dead process left behind (no gate alive to expire it),
	// approved later: the next session start fails it before it spawns.
	orphan, err := fx.sink.ProposeConnectorCall(context.Background(), ConnectorCall{Server: "claude.ai Gmail", Tool: "send"})
	require.NoError(t, err)
	require.True(t, fx.sink.approve(orphan, ""))
	spawnedAtExpire := -1
	fx.sink.onExpireOrphans = func() { spawnedAtExpire = len(argvRuns(t, fx.files.argv)) }
	fx.setRequests(t)
	b2 := NewClaudeBackend(fx.opts)
	t.Cleanup(func() { _ = b2.Close() })
	_, err = b2.Start(context.Background())
	require.NoError(t, err)
	require.NoError(t, b2.Close())
	assert.Equal(t, 1, spawnedAtExpire, "ExpireOrphans runs before the new child spawns")
	_, claimed, err := fx.sink.ClaimApproved(context.Background(), orphan)
	require.NoError(t, err)
	assert.False(t, claimed)
	assert.Equal(t, "failed", fx.sink.row(orphan).status)
	assert.Empty(t, fx.controlAnswers(t)["r1"], "no answer at all reached either child")
}

func TestChat02_GateDecisionsAreSteps(t *testing.T) {
	fx := gateFake(t)
	fx.setRequests(t,
		canUseTool("r1", "tu1", "Write", "", `{"file_path":"/etc/passwd","content":"x"}`),
		gmailSend("r2", "tu2"),
	)
	h := startSession(t, NewClaudeBackend(fx.opts), nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "go"})
	evs := h.until(EventToolWait)
	fx.sink.waitRows(t, 1)
	require.True(t, fx.sink.reject(1))
	evs = append(evs, h.until(EventTurnDone)...)
	require.NoError(t, h.finish())

	for _, e := range evs {
		assert.NotEqual(t, "reset", e.Type)
	}
	denied, _ := findEvent(evs, EventToolEnd, "tu1")
	require.NotNil(t, denied.OK)
	assert.False(t, *denied.OK, "a denied call is a red step")
	assert.Contains(t, denied.Summary, "Write may only use files inside")

	_, start := findEvent(evs, EventToolStart, "tu2")
	_, wait := findEvent(evs, EventToolWait, "tu2")
	asked, end := findEvent(evs, EventToolEnd, "tu2")
	require.True(t, start >= 0 && wait > start && end > wait, "tool_start → tool_wait → tool_end (%d, %d, %d)", start, wait, end)
	require.NotNil(t, asked.OK)
	assert.False(t, *asked.OK)
	assert.Contains(t, asked.Summary, "The owner rejected this call")
}

func TestChat03_CloseWhileWaitingForApprovalRejectsAndReaps(t *testing.T) {
	fx := gateFake(t, gmailSend("r1", "tu1"))
	b := NewClaudeBackend(fx.opts)
	t.Cleanup(func() { _ = b.Close() })
	_, err := b.Start(context.Background())
	require.NoError(t, err)
	pid := readPIDFile(t, fx.files.pid)
	turnDone := make(chan error, 1)
	go func() { turnDone <- b.Turn(context.Background(), Command{TurnID: "t1", Text: "send"}, func(Event) {}) }()
	fx.sink.waitRows(t, 1)

	require.NoError(t, b.Close())
	select {
	case <-turnDone:
	case <-time.After(10 * time.Second):
		t.Fatal("the turn did not end after Close")
	}
	row := fx.sink.row(1)
	assert.Equal(t, "rejected", row.status)
	assert.Equal(t, "stopped", row.reason)
	answers := fx.controlAnswers(t)["r1"]
	require.Len(t, answers, 1)
	assert.Equal(t, denyStopped, denyMessage(t, answers[0]))
	waitGone(t, pid, "claude")
	_, err = os.Stat(fx.pub.Path())
	assert.ErrorIs(t, err, os.ErrNotExist, "Close removes the publish dir")
}

func TestGate_TimeoutCancelsAndTellsTheModel(t *testing.T) {
	fx := gateFake(t, gmailSend("r1", "tu1"))
	fx.opts.Gate.ApprovalTimeout = 50 * time.Millisecond
	h := startSession(t, NewClaudeBackend(fx.opts), nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "send"})
	end := h.next(EventToolEnd)
	h.next(EventTurnDone)
	require.NoError(t, h.finish())

	require.NotNil(t, end.OK)
	assert.False(t, *end.OK)
	assert.Contains(t, end.Summary, "did not approve within 50ms")
	row := fx.sink.row(1)
	assert.Equal(t, "rejected", row.status)
	assert.Equal(t, "not approved within 50ms", row.reason)
}

func TestGate_ApprovalWindowIsFifteenMinutes(t *testing.T) {
	assert.Equal(t, "15 minutes", approvalWindow(GateApprovalTimeout))
	assert.Contains(t, claudeAIConnectorsOn, "up to "+approvalWindow(GateApprovalTimeout)+", then it is cancelled",
		"the prompt names the gate's own timeout")
	assert.Equal(t, "1 minute", approvalWindow(time.Minute))
	assert.Equal(t, "1m30s", approvalWindow(90*time.Second))
}

func TestGate_ApproveRacingTimeoutHasOneOutcome(t *testing.T) {
	fx := gateFake(t, gmailSend("r1", "tu1"))
	fx.opts.Gate.ApprovalTimeout = 50 * time.Millisecond
	// The owner's Approve lands after the timeout fired, before the cancel.
	fx.sink.beforeCancel = func(id int64) { fx.sink.approve(id, "") }
	h := startSession(t, NewClaudeBackend(fx.opts), nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "send"})
	end := h.next(EventToolEnd)
	h.next(EventTurnDone)
	require.NoError(t, h.finish())

	require.NotNil(t, end.OK)
	assert.True(t, *end.OK, "the approved call ran")
	answers := fx.controlAnswers(t)["r1"]
	require.Len(t, answers, 1, "one outcome: never both an allow and a deny")
	assert.Equal(t, "allow", behavior(t, answers[0]))
	row := fx.sink.row(1)
	assert.Equal(t, "applied", row.status)
	assert.Equal(t, 1, row.finishes)
}

func TestGate_TwoParallelAsksAreIndependent(t *testing.T) {
	fx := gateFake(t, gmailSend("r1", "tu1"), gmailSend("r2", "tu2"))
	h := startSession(t, NewClaudeBackend(fx.opts), nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "send both"})
	// The rows are proposed concurrently: find which is which by the
	// tool_wait events.
	waits := map[string]int64{}
	for len(waits) < 2 {
		e := h.next(EventToolWait)
		waits[e.ID] = e.ActionID
	}
	require.True(t, fx.sink.reject(waits["tu1"]))
	end := h.next(EventToolEnd)
	assert.Equal(t, "tu1", end.ID)
	time.Sleep(50 * time.Millisecond)
	assert.Equal(t, "pending", fx.sink.row(waits["tu2"]).status, "rejecting one leaves the other waiting")
	assert.Empty(t, fx.controlAnswers(t)["r2"])

	require.True(t, fx.sink.approve(waits["tu2"], ""))
	end = h.next(EventToolEnd)
	assert.Equal(t, "tu2", end.ID)
	require.NotNil(t, end.OK)
	assert.True(t, *end.OK)
	h.next(EventTurnDone)
	require.NoError(t, h.finish())
	assert.Equal(t, "rejected", fx.sink.row(waits["tu1"]).status)
	assert.Equal(t, "applied", fx.sink.row(waits["tu2"]).status)
}

func TestGate_StopDeniesWaitingCall(t *testing.T) {
	t.Run("pending row is rejected", func(t *testing.T) {
		fx := gateFake(t, gmailSend("r1", "tu1"))
		h := startSession(t, NewClaudeBackend(fx.opts), nil)
		h.next(EventSessionReady)
		h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "send"})
		h.next(EventToolWait)
		h.send(Command{Type: CommandCancel})
		h.next(EventTurnDone)
		require.NoError(t, h.finish())

		row := fx.sink.row(1)
		assert.Equal(t, "rejected", row.status)
		assert.Equal(t, "stopped", row.reason)
		answers := fx.controlAnswers(t)["r1"]
		require.Len(t, answers, 1)
		assert.Equal(t, denyStopped, denyMessage(t, answers[0]))
		stdin, err := os.ReadFile(fx.files.stdin)
		require.NoError(t, err)
		deny, interrupt := strings.Index(string(stdin), denyStopped), strings.Index(string(stdin), `"subtype":"interrupt"`)
		assert.True(t, deny >= 0 && interrupt > deny, "the deny precedes the interrupt")
	})
	t.Run("approved but unclaimed row is expired", func(t *testing.T) {
		fx := gateFake(t, gmailSend("r1", "tu1"))
		fx.opts.Gate.PollInterval = time.Hour // the approval is never read before Stop
		h := startSession(t, NewClaudeBackend(fx.opts), nil)
		h.next(EventSessionReady)
		h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "send"})
		h.next(EventToolWait)
		require.True(t, fx.sink.approve(1, ""))
		h.send(Command{Type: CommandCancel})
		h.next(EventTurnDone)
		require.NoError(t, h.finish())

		row := fx.sink.row(1)
		assert.Equal(t, "failed", row.status)
		assert.Equal(t, reasonStopped, row.reason, "the card reads it as Chat stopped — not sent")
		answers := fx.controlAnswers(t)["r1"]
		require.Len(t, answers, 1)
		assert.Equal(t, "deny", behavior(t, answers[0]))
	})
}

func TestGate_ReadOnlyConnectorCallWritesNoRow(t *testing.T) {
	docsRead := `{"ref":{"object":"project","id":"some-doc"}}`
	fx := gateFake(t, canUseTool("r1", "tu1", "mcp__claude_ai_Claude_Docs__read", "claude.ai Claude Docs", docsRead))
	h := startSession(t, NewClaudeBackend(fx.opts), nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "read"})
	h.next(EventTurnDone)
	require.NoError(t, h.finish())

	answers := fx.controlAnswers(t)["r1"]
	require.Len(t, answers, 1)
	assert.Equal(t, "allow", behavior(t, answers[0]))
	assert.Equal(t, docsRead, string(answers[0]["updatedInput"]))
	assert.Zero(t, fx.sink.count())
}

func TestGate_OffDeniesEveryRequest(t *testing.T) {
	fx := gateFake(t, canUseTool("r1", "tu1", "Write", "", `{"file_path":"/tmp/x","content":"x"}`))
	fx.opts.Gate = nil
	h := startSession(t, NewClaudeBackend(fx.opts), nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "write"})
	end := h.next(EventToolEnd)
	h.next(EventTurnDone)
	require.NoError(t, h.finish())

	require.NotNil(t, end.OK)
	assert.False(t, *end.OK)
	answers := fx.controlAnswers(t)["r1"]
	require.Len(t, answers, 1, "answered, never left waiting")
	assert.Equal(t, "Write is not available in this chat", denyMessage(t, answers[0]))
}

func TestGate_ProposeErrorDenies(t *testing.T) {
	fx := gateFake(t, gmailSend("r1", "tu1"))
	fx.sink.proposeErr = errors.New("database is locked")
	h := startSession(t, NewClaudeBackend(fx.opts), nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "send"})
	h.next(EventTurnDone)
	require.NoError(t, h.finish())

	answers := fx.controlAnswers(t)["r1"]
	require.Len(t, answers, 1)
	assert.Equal(t, "deny", behavior(t, answers[0]))
	assert.Contains(t, denyMessage(t, answers[0]), "database is locked")
}

// A row that vanished or belongs to another session process can never be
// approved for this one: the call is denied at once, not after the window.
func TestGate_PermanentStatusErrorDeniesAtOnce(t *testing.T) {
	for name, statusErr := range map[string]error{
		"not found":        fmt.Errorf("#1: %w", tools.ErrNotFound),
		"not this session": fmt.Errorf("#1: %w", tools.ErrNotThisSession),
	} {
		t.Run(name, func(t *testing.T) {
			fx := gateFake(t, gmailSend("r1", "tu1"))
			fx.sink.statusErr = statusErr
			fx.opts.Gate.ApprovalTimeout = time.Minute
			h := startSession(t, NewClaudeBackend(fx.opts), nil)
			h.next(EventSessionReady)
			start := time.Now()
			h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "send"})
			h.next(EventTurnDone)
			require.NoError(t, h.finish())

			assert.Less(t, time.Since(start), 10*time.Second, "denied at once, not after the approval window")
			answers := fx.controlAnswers(t)["r1"]
			require.Len(t, answers, 1)
			assert.Equal(t, "deny", behavior(t, answers[0]))
			assert.Equal(t, denyRowGone, denyMessage(t, answers[0]))
			assert.Equal(t, "pending", fx.sink.row(1).status, "nothing claimed")
		})
	}
}

func TestGate_InvalidOptionsRefuseToStart(t *testing.T) {
	for name, mutate := range map[string]func(*GateOptions){
		"nil Disabled": func(o *GateOptions) { o.Policy.Disabled = nil },
		"nil sink":     func(o *GateOptions) { o.Sink = nil },
	} {
		t.Run(name, func(t *testing.T) {
			fx := gateFake(t)
			mutate(fx.opts.Gate)
			b := NewClaudeBackend(fx.opts)
			t.Cleanup(func() { _ = b.Close() })
			_, err := b.Start(context.Background())
			require.Error(t, err)
			require.NoError(t, b.Close())
			_, statErr := os.Stat(fx.files.argv)
			assert.ErrorIs(t, statErr, os.ErrNotExist, "no child was spawned")
		})
	}
}

func TestGate_DocsWritesAreFreeOnlyOnTheDocTheSessionCreated(t *testing.T) {
	const newDoc = "3f2a9c1e-5b7d-4e8a-9c21-7d4e5f6a8b90"
	birth := `{"container":{"kind":"project","create":{"name":"Plan","doc":{"markdown":"# Plan"}}},"batch":[]}`
	fx := gateFake(t, canUseTool("r1", "tu1", "mcp__claude_ai_Claude_Docs__batch", "claude.ai Claude Docs", birth))
	fx.opts.Env = append(fx.opts.Env, "FAKE_GATE_RESULT=created https://claude.ai/artifact/Plan-"+newDoc)
	h := startSession(t, NewClaudeBackend(fx.opts), nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "make a doc"})
	end := h.next(EventToolEnd)
	h.next(EventTurnDone)
	require.Len(t, end.Sources, 1)
	assert.Equal(t, SourceKindPublished, end.Sources[0].Kind)
	assert.Equal(t, "Plan", end.Sources[0].Title)

	own := `{"ref":{"object":"node","id":"n1"},"container":{"kind":"project","id":"` + newDoc + `"},"payload":{"ops":[]}}`
	foreign := `{"ref":{"object":"node","id":"n1"},"container":{"kind":"project","id":"another-doc"},"payload":{"ops":[]}}`
	fx.setRequests(t,
		canUseTool("r2", "tu2", "mcp__claude_ai_Claude_Docs__update", "claude.ai Claude Docs", own),
		canUseTool("r3", "tu3", "mcp__claude_ai_Claude_Docs__update", "claude.ai Claude Docs", foreign),
	)
	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "edit both"})
	wait := h.next(EventToolWait)
	assert.Equal(t, "tu3", wait.ID, "only the foreign doc's edit waits")
	require.True(t, fx.sink.reject(wait.ActionID))
	h.next(EventTurnDone)
	require.NoError(t, h.finish())

	answers := fx.controlAnswers(t)
	assert.Equal(t, "allow", behavior(t, answers["r1"][0]))
	assert.Equal(t, "allow", behavior(t, answers["r2"][0]))
	assert.Equal(t, "deny", behavior(t, answers["r3"][0]))
	assert.Equal(t, 1, fx.sink.count())
}

// pipeProc is a claudeProc whose stdin is a pipe the test reads.
func pipeProc(t *testing.T) (*claudeProc, *os.File) {
	t.Helper()
	r, w, err := os.Pipe()
	require.NoError(t, err)
	t.Cleanup(func() { _ = r.Close(); _ = w.Close() })
	return &claudeProc{stdin: w, events: make(chan Event, 16), exited: make(chan struct{}), stop: make(chan struct{})}, r
}

func readLine(t *testing.T, r *os.File) string {
	t.Helper()
	done := make(chan string, 1)
	go func() {
		buf := make([]byte, 64<<10)
		n, _ := r.Read(buf)
		done <- string(buf[:n])
	}()
	select {
	case s := <-done:
		return s
	case <-time.After(5 * time.Second):
		t.Fatal("no line written to the CLI")
		return ""
	}
}

func TestGate_RouteControlAnswersEveryRequest(t *testing.T) {
	b := NewClaudeBackend(ClaudeOptions{Binary: "claude"}).(*claudeBackend)

	p, r := pipeProc(t)
	assert.True(t, b.routeControl(p, []byte(`{"type":"control_request","request_id":"h1","request":{"subtype":"hook_callback"}}`)))
	assert.JSONEq(t, `{"type":"control_response","response":{"subtype":"error","request_id":"h1","error":"unsupported control request \"hook_callback\""}}`,
		readLine(t, r), "an unknown control request is answered with an error")

	assert.True(t, b.routeControl(p, []byte(`{"type":"control_request","request_id":"m1","request":{"subtype":"can_use_tool","tool_name":"Write","input":{}}}`)))
	assert.Contains(t, readLine(t, r), `"behavior":"deny"`, "a malformed request is denied")

	assert.True(t, b.routeControl(p, []byte(`{"type":"control_cancel_request","request_id":"x"}`)))
	assert.False(t, b.routeControl(p, []byte(`{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"\"control_request\""}}}`)),
		"a text line mentioning a control type goes to the translator")
}

func TestGate_StopDuringAStatusReadNeverClaims(t *testing.T) {
	fx := gateFake(t, gmailSend("r1", "tu1"))
	entered, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	b := NewClaudeBackend(fx.opts)
	t.Cleanup(func() { _ = b.Close() })
	_, err := b.Start(context.Background())
	require.NoError(t, err)
	turnDone := make(chan error, 1)
	go func() { turnDone <- b.Turn(context.Background(), Command{TurnID: "t1", Text: "send"}, func(Event) {}) }()
	fx.sink.waitRows(t, 1)

	// The owner approves; the read that sees it is still in flight when the
	// owner presses Stop.
	fx.sink.mu.Lock()
	fx.sink.beforeStatus = func(int64) {
		once.Do(func() {
			close(entered)
			<-release
		})
	}
	fx.sink.mu.Unlock()
	require.True(t, fx.sink.approve(1, ""))
	<-entered
	cancelled := make(chan struct{})
	go func() { _ = b.Cancel(); close(cancelled) }()
	waitUntil(t, "the stop to reach the gate", func() bool {
		g := b.(*claudeBackend).gate
		g.mu.Lock()
		defer g.mu.Unlock()
		return g.halted
	})
	close(release)
	<-cancelled
	select {
	case <-turnDone:
	case <-time.After(10 * time.Second):
		t.Fatal("the turn did not end after Stop")
	}
	require.NoError(t, b.Close())

	row := fx.sink.row(1)
	assert.Equal(t, "failed", row.status, "approved but stopped: expired, never claimed")
	assert.Equal(t, reasonStopped, row.reason, "the card reads it as Chat stopped — not sent")
	answers := fx.controlAnswers(t)["r1"]
	require.Len(t, answers, 1)
	assert.Equal(t, denyStopped, denyMessage(t, answers[0]))
}

func TestGate_WithdrawnBeforeTheRowExistsNeverWaits(t *testing.T) {
	sink := newFakeSink()
	entered, release := make(chan struct{}), make(chan struct{})
	sink.beforePropose = func() { close(entered); <-release }
	g, err := newGate(GateOptions{Sink: sink, Policy: connectorpolicy.Policy{Disabled: map[string]bool{}},
		PollInterval: 10 * time.Millisecond}, func() string { return "t1" }, io.Discard)
	require.NoError(t, err)
	g.catalog.set(testCatalog(t))
	p, r := pipeProc(t)
	req, ok := parseControlRequest([]byte(gmailSend("r1", "tu1")))
	require.True(t, ok)

	g.dispatch(p, req)
	<-entered
	g.withdraw("r1") // the CLI withdrew it while the row was being written
	close(release)
	waitUntil(t, "the row to settle", func() bool { return sink.row(1).status == "rejected" })
	assert.Equal(t, "stopped", sink.row(1).reason)
	require.NoError(t, p.stdin.Close())
	rest, _ := io.ReadAll(r)
	assert.Empty(t, string(rest), "a withdrawn request gets no answer")
}

func TestGate_ApprovedForeignUpdateIsNoStandingGrant(t *testing.T) {
	const foreign = "https://claude.ai/artifact/ForeignQQQQQQQQQQQQQQQ"
	fx := gateFake(t)
	update := `{"action":"publish","url":"` + foreign + `","file_path":"` + filepath.Join(fx.pub.Path(), "p.html") + `"}`
	fx.setRequests(t, canUseTool("r1", "tu1", "Artifact", "", update))
	fx.opts.Env = append(fx.opts.Env, "FAKE_GATE_RESULT=Updated "+foreign)
	h := startSession(t, NewClaudeBackend(fx.opts), nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "update it"})
	wait := h.next(EventToolWait)
	require.True(t, fx.sink.approve(wait.ActionID, ""))
	end := h.next(EventToolEnd)
	require.NotNil(t, end.OK)
	assert.True(t, *end.OK)
	h.next(EventTurnDone)

	fx.setRequests(t, canUseTool("r2", "tu2", "Artifact", "", update))
	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "update it again"})
	again := h.next(EventToolWait)
	assert.Equal(t, "tu2", again.ID, "the second update of a page this chat did not publish asks again")
	require.True(t, fx.sink.reject(again.ActionID))
	h.next(EventTurnDone)
	require.NoError(t, h.finish())
}

// unitGate is a gate over sink answering on a pipe the test reads.
func unitGate(t *testing.T, sink *fakeSink) (*gate, *claudeProc, *os.File) {
	t.Helper()
	g, err := newGate(GateOptions{Sink: sink, Policy: connectorpolicy.Policy{Disabled: map[string]bool{}},
		PollInterval: 10 * time.Millisecond}, func() string { return "t1" }, io.Discard)
	require.NoError(t, err)
	g.catalog.set(testCatalog(t))
	p, r := pipeProc(t)
	return g, p, r
}

func TestGate_ApprovedFreshDocIsNotTheSessionsOwn(t *testing.T) {
	const newDoc = "3f2a9c1e-5b7d-4e8a-9c21-7d4e5f6a8b90"
	// A birth that mentions someone asks; the owner approves it.
	birth := `{"container":{"kind":"project","create":{"name":"Plan","doc":{"blocks":{"m":{"type":"mention","user":"someone@example.com"}},"markdown":"# Plan"}}},"batch":[]}`
	fx := gateFake(t, canUseTool("r1", "tu1", "mcp__claude_ai_Claude_Docs__batch", "claude.ai Claude Docs", birth))
	fx.opts.Env = append(fx.opts.Env, "FAKE_GATE_RESULT=created https://claude.ai/artifact/Plan-"+newDoc)
	h := startSession(t, NewClaudeBackend(fx.opts), nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "make a doc"})
	wait := h.next(EventToolWait)
	require.True(t, fx.sink.approve(wait.ActionID, ""))
	h.next(EventTurnDone)

	update := `{"ref":{"object":"node","id":"n1"},"container":{"kind":"project","id":"` + newDoc + `"},"payload":{"ops":[]}}`
	fx.setRequests(t, canUseTool("r2", "tu2", "mcp__claude_ai_Claude_Docs__update", "claude.ai Claude Docs", update))
	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "edit it"})
	again := h.next(EventToolWait)
	assert.Equal(t, "tu2", again.ID, "a doc an approved call made is not free to edit")
	require.True(t, fx.sink.reject(again.ActionID))
	h.next(EventTurnDone)
	require.NoError(t, h.finish())
}

func TestGate_ClaimedCallOfAGoneChildIsOfUnknownOutcome(t *testing.T) {
	sink := newFakeSink()
	g, p, _ := unitGate(t, sink)
	req, ok := parseControlRequest([]byte(gmailSend("r1", "tu1")))
	require.True(t, ok)
	g.dispatch(p, req)
	sink.waitRows(t, 1)
	require.True(t, sink.approve(1, ""))
	waitUntil(t, "the claim", func() bool { return sink.row(1).status == "executing" })

	g.procGone(p) // the child died before its tool_result
	row := sink.row(1)
	assert.Equal(t, "failed", row.status)
	assert.Equal(t, "session ended while the call ran; outcome unknown", row.callErr)
	assert.Equal(t, 1, row.finishes)
	g.onResult(toolResult{toolUseID: "tu1", text: "late"})
	assert.Equal(t, 1, sink.row(1).finishes, "a late result records nothing twice")
}

func TestGate_StopRightAfterTheClaimSendsNothing(t *testing.T) {
	sink := newFakeSink()
	g, p, r := unitGate(t, sink)
	sink.afterClaim = func(int64) { g.withdraw("r1") }
	req, ok := parseControlRequest([]byte(gmailSend("r1", "tu1")))
	require.True(t, ok)
	g.dispatch(p, req)
	sink.waitRows(t, 1)
	require.True(t, sink.approve(1, ""))
	waitUntil(t, "the claimed call to settle", func() bool { return sink.row(1).finishes == 1 })

	row := sink.row(1)
	assert.Equal(t, "failed", row.status)
	assert.Equal(t, reasonStopped, row.callErr, "the card reads it as Chat stopped — not sent")
	require.NoError(t, p.stdin.Close())
	rest, _ := io.ReadAll(r)
	assert.NotContains(t, string(rest), `"allow"`, "no allow after the stop")
}

// A child gone right after the claim is a session end, not a Stop: the card
// says the chat session ended.
func TestGate_ChildGoneRightAfterTheClaimIsASessionEnd(t *testing.T) {
	sink := newFakeSink()
	g, p, _ := unitGate(t, sink)
	sink.afterClaim = func(int64) { close(p.exited) }
	req, ok := parseControlRequest([]byte(gmailSend("r1", "tu1")))
	require.True(t, ok)
	g.dispatch(p, req)
	sink.waitRows(t, 1)
	require.True(t, sink.approve(1, ""))
	waitUntil(t, "the claimed call to settle", func() bool { return sink.row(1).finishes == 1 })

	row := sink.row(1)
	assert.Equal(t, "failed", row.status)
	assert.Equal(t, reasonSessionEnded, row.callErr)
}

func TestGate_DuplicateRequestIDIsDenied(t *testing.T) {
	sink := newFakeSink()
	g, p, r := unitGate(t, sink)
	req, ok := parseControlRequest([]byte(gmailSend("r1", "tu1")))
	require.True(t, ok)
	g.dispatch(p, req)
	sink.waitRows(t, 1)
	g.dispatch(p, req)
	line := readLine(t, r)
	assert.Contains(t, line, `"behavior":"deny"`)
	assert.Contains(t, line, "already being answered")
	assert.Equal(t, 1, sink.count(), "the duplicate proposes nothing")
	g.halt(true)
}

func TestGate_ChildDyingAfterTheClaimLeavesNoRowExecuting(t *testing.T) {
	fx := gateFake(t, gmailSend("r1", "tu1"))
	fx.opts.Env = append(fx.opts.Env, "FAKE_GATE_DIE_ON_ALLOW=1")
	h := startSession(t, NewClaudeBackend(fx.opts), nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "send"})
	wait := h.next(EventToolWait)
	require.True(t, fx.sink.approve(wait.ActionID, ""))
	h.next(EventError) // the child died mid-turn

	// The warm session lives on; the call is settled without waiting for Close.
	row := fx.sink.row(wait.ActionID)
	assert.Equal(t, "failed", row.status)
	assert.Equal(t, "session ended while the call ran; outcome unknown", row.callErr)
	require.NoError(t, h.finish())
}

// The card (WatchtowerCore ConnectorCallProposal) matches these texts
// exactly; the registry's ExpireSessionCalls writes the last two too.
func TestGate_RowReasonTextsMatchTheCard(t *testing.T) {
	assert.Equal(t, "not approved within 15 minutes", reasonNotApproved(GateApprovalTimeout))
	assert.Equal(t, "stopped", reasonStopped)
	assert.Equal(t, "session ended before approval", reasonSessionEnded)
	assert.Equal(t, "session ended while the call ran; outcome unknown", reasonOutcomeUnknown)
}

// The Desktop refreshes its action feed once, when the wait starts: the row
// must be committed before tool_wait goes out, and carry the protocol turn
// id the Desktop sent.
func TestGate_RowIsCommittedBeforeToolWait(t *testing.T) {
	fx := gateFake(t, gmailSend("r1", "tu1"))
	fx.sink.beforePropose = func() { time.Sleep(100 * time.Millisecond) } // a slow write
	h := startSession(t, NewClaudeBackend(fx.opts), nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "turn-from-desktop", Text: "send"})
	wait := h.next(EventToolWait)
	row := fx.sink.row(wait.ActionID)
	assert.Equal(t, "pending", row.status, "the row exists when tool_wait arrives")
	assert.Equal(t, "turn-from-desktop", row.call.TurnID)
	require.True(t, fx.sink.reject(wait.ActionID))
	h.next(EventTurnDone)
	require.NoError(t, h.finish())
}
