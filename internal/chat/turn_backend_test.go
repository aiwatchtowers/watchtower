package chat

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/ai"
	"watchtower/internal/db"
)

type fakeQuerier struct {
	mu         sync.Mutex
	chunks     []ai.StreamChunk
	err        error
	block      bool
	calls      int
	gotSystem  string
	gotUser    string
	toolEvents bool
}

func (f *fakeQuerier) EmitToolEvents() { f.toolEvents = true }

func (f *fakeQuerier) Query(ctx context.Context, system, user, _ string) (<-chan ai.StreamChunk, <-chan error, <-chan string) {
	f.mu.Lock()
	f.calls++
	f.gotSystem, f.gotUser = system, user
	f.mu.Unlock()
	textCh := make(chan ai.StreamChunk)
	errCh := make(chan error, 1)
	sidCh := make(chan string, 1)
	go func() {
		defer close(textCh)
		defer close(errCh)
		defer close(sidCh)
		for _, c := range f.chunks {
			select {
			case textCh <- c:
			case <-ctx.Done():
				errCh <- ctx.Err()
				return
			}
		}
		if f.block {
			<-ctx.Done()
			errCh <- ctx.Err()
			return
		}
		if f.err != nil {
			errCh <- f.err
		}
	}()
	return textCh, errCh, sidCh
}

func (f *fakeQuerier) seen() (int, string, string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls, f.gotSystem, f.gotUser
}

// seedConversation: t1 = a finished exchange, t2 = the owner message of the
// running turn (persisted before the turn is sent, CHAT-01).
func seedConversation(t *testing.T) (*db.DB, int64) {
	t.Helper()
	d := db.OpenTestDB(t)
	res, err := d.Exec(`INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('', 1, 1)`)
	require.NoError(t, err)
	conv, err := res.LastInsertId()
	require.NoError(t, err)
	var parent any
	for _, m := range []struct{ role, text, turn string }{
		{"user", "what slipped?", "t1"}, {"assistant", "the refunds launch", "t1"}, {"user", "why?", "t2"},
	} {
		r, err := d.Exec(`INSERT INTO chat_messages (conversation_id, parent_id, role, text, turn_id, created_at)
			VALUES (?, ?, ?, ?, ?, 1)`, conv, parent, m.role, m.text, m.turn)
		require.NoError(t, err)
		id, err := r.LastInsertId()
		require.NoError(t, err)
		parent = id
	}
	return d, conv
}

func TestTurnBackend_ReplaysHistoryAndStreams(t *testing.T) {
	d, conv := seedConversation(t)
	fq := &fakeQuerier{chunks: []ai.StreamChunk{{Text: "Because "}, {Text: "QA found a bug."}}}
	h := startSession(t, NewTurnBackend(fq, d, conv, WithSystemPrompt("SYS")), nil)
	assert.Empty(t, h.next(EventSessionReady).SessionID, "a stateless provider has no session id")

	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "why?"})
	assert.Equal(t, "Because ", h.next(EventTextDelta).Text)
	assert.Equal(t, "QA found a bug.", h.next(EventTextDelta).Text)
	assert.Equal(t, StatusComplete, h.next(EventTurnDone).Status)
	require.NoError(t, h.finish())

	_, system, user := fq.seen()
	assert.Equal(t, "SYS", system)
	assert.True(t, strings.HasPrefix(user, replayHeader), "every turn carries the replayed history")
	assert.Contains(t, user, "Owner: what slipped?")
	assert.Contains(t, user, "Assistant: the refunds launch")
	assert.True(t, strings.HasSuffix(user, "why?"))
	assert.Equal(t, 1, strings.Count(user, "why?"), "the running turn is not replayed as history")
}

func TestTurnBackend_ToolChunksBecomeSteps(t *testing.T) {
	d, conv := seedConversation(t)
	fq := &fakeQuerier{chunks: []ai.StreamChunk{
		{ToolBoundary: true},
		{Tool: &ai.ToolEvent{ID: "c1", Name: "list_targets", Args: []byte(`{}`)}},
		{Tool: &ai.ToolEvent{ID: "c1", Name: "list_targets", Done: true, OK: true, Result: `[]`}},
		{Text: "No open targets."},
	}}
	b := NewTurnBackend(fq, d, conv)
	assert.True(t, fq.toolEvents, "the backend switches the loop's tool events on")
	h := startSession(t, b, nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "why?"})

	start := h.next(EventToolStart)
	assert.Equal(t, "list_targets", start.Name)
	assert.JSONEq(t, `{}`, string(start.Args))
	end := h.next(EventToolEnd)
	require.NotNil(t, end.OK)
	assert.True(t, *end.OK)
	assert.Equal(t, "No open targets.", h.next(EventTextDelta).Text)
	h.next(EventTurnDone)
	require.NoError(t, h.finish())
}

func TestTurnBackend_ErrorIsClassified(t *testing.T) {
	d, conv := seedConversation(t)
	fq := &fakeQuerier{err: errors.New("codex CLI failed (exit 1): 429 Too Many Requests")}
	h := startSession(t, NewTurnBackend(fq, d, conv), nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "why?"})
	e := h.next(EventError)
	assert.Equal(t, "t2", e.TurnID)
	assert.Equal(t, CodeRateLimit, e.Code)
	require.NoError(t, h.finish())
}

func TestTurnBackend_CancelEndsInterrupted(t *testing.T) {
	d, conv := seedConversation(t)
	fq := &fakeQuerier{chunks: []ai.StreamChunk{{Text: "partial"}}, block: true}
	h := startSession(t, NewTurnBackend(fq, d, conv), nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "why?"})
	h.next(EventTextDelta)
	h.send(Command{Type: CommandCancel})
	assert.Equal(t, StatusInterrupted, h.next(EventTurnDone).Status)
	require.NoError(t, h.finish())
}

// TestTurnBackend_AttachmentRejectedBeforeTheCall uses a real (existing) PNG
// so the rejection exercises the "images/PDFs need Claude" textOnly branch,
// not a "file not found" short-circuit (task-20-review.md Important I1 item 5).
func TestTurnBackend_AttachmentRejectedBeforeTheCall(t *testing.T) {
	d, conv := seedConversation(t)
	fq := &fakeQuerier{}
	h := startSession(t, NewTurnBackend(fq, d, conv), nil)
	h.next(EventSessionReady)
	p := writeAttachmentFixture(t, "x.png", fixturePNG)
	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "see this",
		Attachments: []Attachment{{Path: p, Mime: "image/png", Name: "x.png"}}})
	e := h.next(EventError)
	assert.Equal(t, CodeAttachmentUnsupported, e.Code)
	assert.False(t, e.Retryable)
	assert.Contains(t, e.Message, "Claude", "rejected via the textOnly branch, not a file-not-found error")
	require.NoError(t, h.finish())
	calls, _, _ := fq.seen()
	assert.Zero(t, calls, "nothing reaches the provider")
}

// TestTurnBackend_InlinesRealTextAttachment: the success-path companion
// (task-20-review.md Important I1 item 4) — a real text-like attachment's
// <file> block must reach the Querier's user message, ahead of the replay
// and the owner's own text.
func TestTurnBackend_InlinesRealTextAttachment(t *testing.T) {
	d, conv := seedConversation(t)
	fq := &fakeQuerier{chunks: []ai.StreamChunk{{Text: "summed"}}}
	h := startSession(t, NewTurnBackend(fq, d, conv), nil)
	h.next(EventSessionReady)
	p := writeAttachmentFixture(t, "a.csv", []byte("a,b\n1,2"))
	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "sum column b",
		Attachments: []Attachment{{Path: p, Mime: "text/csv", Name: "a.csv"}}})
	assert.Equal(t, "summed", h.next(EventTextDelta).Text)
	assert.Equal(t, StatusComplete, h.next(EventTurnDone).Status)
	require.NoError(t, h.finish())

	calls, _, user := fq.seen()
	assert.Equal(t, 1, calls)
	assert.Contains(t, user, "<file name=\"a.csv\">\na,b\n1,2\n</file>")
	inlineIdx := strings.Index(user, "<file name=\"a.csv\">")
	textIdx := strings.Index(user, "sum column b")
	require.NotEqual(t, -1, inlineIdx)
	require.NotEqual(t, -1, textIdx)
	assert.Less(t, inlineIdx, textIdx, "the inlined file precedes the owner's own text")
}

func TestChunkEvents(t *testing.T) {
	assert.Nil(t, ChunkEvents("t", ai.StreamChunk{ToolBoundary: true}), "v2 never wipes text")
	assert.Equal(t, []Event{{Type: EventTextDelta, TurnID: "t", Text: "x"}}, ChunkEvents("t", ai.StreamChunk{Text: "x"}))
	failed := ChunkEvents("t", ai.StreamChunk{Tool: &ai.ToolEvent{ID: "a", Name: "get_target", Done: true, Result: `{"error":"no target"}`}})
	require.Len(t, failed, 1)
	require.NotNil(t, failed[0].OK)
	assert.False(t, *failed[0].OK)
	assert.Contains(t, failed[0].Summary, "no target")
}
