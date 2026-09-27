package chat

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// attachmentFailBackend always rejects the turn with an *AttachmentError,
// ignoring ctx entirely — it stands in for a real backend's BuildContentBlocks
// (or InlineTextAttachments) failure, which is returned before any provider
// call is made.
type attachmentFailBackend struct{}

func (attachmentFailBackend) Start(context.Context) (string, error) { return "s1", nil }
func (attachmentFailBackend) Turn(context.Context, Command, func(Event)) error {
	return &AttachmentError{Name: "x.zip", Reason: `unsupported file type "application/zip"`}
}
func (attachmentFailBackend) Cancel() error { return nil }
func (attachmentFailBackend) Close() error  { return nil }

// TestSession_AttachmentErrorMapsToAttachmentUnsupported pins A21: stdin
// stays open (the harness's pipe, not an EOF-on-send reader) so the turn
// runs to completion instead of racing the session's own shutdown-on-EOF
// path into emitting turn_done{interrupted} first.
func TestSession_AttachmentErrorMapsToAttachmentUnsupported(t *testing.T) {
	h := startSession(t, attachmentFailBackend{}, nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "hi",
		Attachments: []Attachment{{Path: "/x.zip", Mime: "application/zip", Name: "x.zip"}}})

	e := h.next(EventError)
	assert.Equal(t, "t1", e.TurnID)
	assert.Equal(t, "attachment_unsupported", e.Code)
	assert.False(t, e.Retryable)
	assert.Contains(t, e.Message, "x.zip")
	require.NoError(t, h.finish())
}

// TestFallbackTerminal_AttachmentErrorWinsOverCancelledCtx pins A21/M4
// directly at the unit level: an already-cancelled ctx must not shadow an
// *AttachmentError into "interrupted" (or, absent this ordering, into the
// generic ClassifyClaudeError "internal" fallback — see the task-20 report).
func TestFallbackTerminal_AttachmentErrorWinsOverCancelledCtx(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	e := fallbackTerminal(ctx, "t9", &AttachmentError{Name: "x.zip", Reason: "unsupported file type"})
	assert.Equal(t, EventError, e.Type)
	assert.Equal(t, "attachment_unsupported", e.Code)
	assert.False(t, e.Retryable)
}
