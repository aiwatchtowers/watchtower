package chat

import (
	"bytes"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestClaudeBackend_ProjectBlocksOnlyWhilePending(t *testing.T) {
	att, marker := projectFixture(t)
	b := &claudeBackend{opts: ClaudeOptions{ProjectAttachments: []Attachment{att}}}
	b.projectPending = initialProjectPending(b.opts)

	first := b.projectBlocks()
	require.Len(t, first, 1)
	assert.Contains(t, string(first[0]), marker)
	// Not cleared until the turn was actually written to the child.
	require.Len(t, b.projectBlocks(), 1, "an unsent first turn still carries the project file")
	b.projectSent()
	assert.Empty(t, b.projectBlocks(), "later turns carry no project files")
	// A replay / session_lost restart is a fresh provider session again.
	b.markFreshSession()
	assert.Len(t, b.projectBlocks(), 1, "after a fresh restart the project file is re-attached")
}

// A project file that is gone or no longer valid at turn time is skipped
// with a warning; the others still load.
func TestClaudeBackend_ProjectBlocksSkipMissingAndInvalid(t *testing.T) {
	att, marker := projectFixture(t)
	bad := filepath.Join(t.TempDir(), "notreally.png")
	require.NoError(t, os.WriteFile(bad, []byte("not an image"), 0o600))
	var warn bytes.Buffer
	b := &claudeBackend{opts: ClaudeOptions{Warn: &warn, ProjectAttachments: []Attachment{
		{Path: filepath.Join(t.TempDir(), "gone.pdf"), Mime: "application/pdf", Name: "gone.pdf"},
		{Path: bad, Mime: "image/png", Name: "notreally.png"},
		att,
	}}}
	b.markFreshSession()
	blocks := b.projectBlocks()
	require.Len(t, blocks, 1)
	assert.Contains(t, string(blocks[0]), marker)
	assert.Contains(t, warn.String(), "gone.pdf")
	assert.Contains(t, warn.String(), "notreally.png")
}

func TestClaudeBackend_ResumedSessionDoesNotReattachProjectFiles(t *testing.T) {
	opts := ClaudeOptions{
		ProjectAttachments: []Attachment{{Path: "/p/spec.pdf", Mime: "application/pdf", Name: "spec.pdf"}},
		ResumeSessionID:    "sid-1",
	}
	if initialProjectPending(opts) {
		t.Fatal("a --resume'd session already holds the project files in its history")
	}
	opts.ResumeSessionID = ""
	if !initialProjectPending(opts) {
		t.Fatal("a fresh session with project files must attach them")
	}
	opts.ProjectAttachments = nil
	if initialProjectPending(opts) {
		t.Fatal("no project files, nothing pending")
	}
}

// projectFixture writes a PDF project file and returns its attachment and the
// base64 content that marks it on the fake child's stdin.
func projectFixture(t *testing.T) (Attachment, string) {
	t.Helper()
	p := filepath.Join(t.TempDir(), "spec.pdf")
	require.NoError(t, os.WriteFile(p, fixturePDF, 0o600))
	return Attachment{Path: p, Mime: "application/pdf", Name: "spec.pdf"},
		base64.StdEncoding.EncodeToString(fixturePDF)
}

func stdinLines(t *testing.T, path string) []string {
	t.Helper()
	data, err := os.ReadFile(path)
	require.NoError(t, err)
	return strings.Split(strings.TrimRight(string(data), "\n"), "\n")
}

// End to end through the fake child: a fresh session's first message carries
// the project file, the next message on the same child does not.
func TestClaudeBackend_FreshSessionSendsProjectFilesOnFirstTurnOnly(t *testing.T) {
	opts, f := fakeClaude(t, "normal")
	att, marker := projectFixture(t)
	opts.ProjectAttachments = []Attachment{att}
	h := startSession(t, NewClaudeBackend(opts), nil)
	h.next(EventSessionReady)

	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "first"})
	assert.Equal(t, StatusComplete, h.next(EventTurnDone).Status)
	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "second"})
	assert.Equal(t, StatusComplete, h.next(EventTurnDone).Status)
	require.NoError(t, h.finish())

	lines := stdinLines(t, f.stdin)
	require.Len(t, lines, 2)
	assert.Contains(t, lines[0], marker, "the first turn carries the project file")
	assert.Contains(t, lines[0], `"type":"document"`)
	assert.NotContains(t, lines[1], marker, "the second turn on the same child does not")
}

// A resumed session never re-attaches: its history already holds the files.
func TestClaudeBackend_ResumedStartSendsNoProjectFiles(t *testing.T) {
	opts, f := fakeClaude(t, "normal")
	att, marker := projectFixture(t)
	opts.ProjectAttachments = []Attachment{att}
	opts.ResumeSessionID = "sess-0"
	h := startSession(t, NewClaudeBackend(opts), nil)
	h.next(EventSessionReady)

	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "first"})
	assert.Equal(t, StatusComplete, h.next(EventTurnDone).Status)
	require.NoError(t, h.finish())

	lines := stdinLines(t, f.stdin)
	require.Len(t, lines, 1)
	assert.NotContains(t, lines[0], marker)
}

// The session_lost retry after a rejected --resume is a fresh session again
// and carries the files. (The fake's resumed child exits before reading
// stdin, so the only logged line is the retry's.)
func TestClaudeBackend_SessionLostRetryReattachesProjectFiles(t *testing.T) {
	opts, f := fakeClaude(t, "lost")
	att, marker := projectFixture(t)
	opts.ProjectAttachments = []Attachment{att}
	opts.ResumeSessionID = "gone"
	opts.Replay = func(string) (string, error) { return "", nil }
	h := startSession(t, NewClaudeBackend(opts), nil)
	h.next(EventSessionReady)

	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "hello"})
	assert.Equal(t, StatusComplete, h.next(EventTurnDone).Status)
	require.NoError(t, h.finish())
	assertOneFreshRetryWithProject(t, f, marker)
}

// The warm --resume child started at session open usually dies of the
// rejection before the owner's first turn arrives. That dead child must not
// be respawned with the same doomed --resume: the turn goes straight to the
// fresh retry (one rejected run, one fresh run). Both rejection shapes.
func TestClaudeBackend_ResumeRejectedBeforeFirstTurnIsNotRespawned(t *testing.T) {
	for _, mode := range []string{"lost", "lost_result"} {
		t.Run(mode, func(t *testing.T) {
			opts, f := fakeClaude(t, mode)
			att, marker := projectFixture(t)
			opts.ProjectAttachments = []Attachment{att}
			opts.ResumeSessionID = "gone"
			opts.Replay = func(string) (string, error) { return "", nil }
			be := NewClaudeBackend(opts).(*claudeBackend)
			h := startSession(t, be, nil)
			h.next(EventSessionReady)
			be.mu.Lock()
			p := be.proc
			be.mu.Unlock()
			require.NotNil(t, p)
			require.True(t, waitClosed(p.exited, 5*time.Second), "the rejected --resume child exits on its own")

			h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "hello"})
			assert.Equal(t, StatusComplete, h.next(EventTurnDone).Status)
			require.NoError(t, h.finish())
			assertOneFreshRetryWithProject(t, f, marker)
		})
	}
}

// assertOneFreshRetryWithProject: exactly one rejected --resume run, then one
// fresh run whose first (and only logged) message carries the project file.
func assertOneFreshRetryWithProject(t *testing.T, f fakeFiles, marker string) {
	t.Helper()
	runs := argvRuns(t, f.argv)
	require.Len(t, runs, 2)
	assert.True(t, contains(runs[0], "--resume"))
	assert.False(t, contains(runs[1], "--resume"))
	lines := stdinLines(t, f.stdin)
	require.Len(t, lines, 1)
	assert.Contains(t, lines[0], marker, "the fresh retry carries the project file")
}

// A Replay command replaces the warm child with a fresh session: its first
// message carries the files again even though an earlier turn sent them.
func TestClaudeBackend_ReplayRestartReattachesProjectFiles(t *testing.T) {
	opts, f := fakeClaude(t, "normal")
	att, marker := projectFixture(t)
	opts.ProjectAttachments = []Attachment{att}
	h := startSession(t, NewClaudeBackend(opts), nil)
	h.next(EventSessionReady)

	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "first"})
	h.next(EventTurnDone)
	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "second"})
	h.next(EventTurnDone)
	h.send(Command{Type: CommandTurn, TurnID: "t3", Text: "edited", Replay: true})
	h.next(EventTurnDone)
	require.NoError(t, h.finish())

	lines := stdinLines(t, f.stdin)
	require.Len(t, lines, 3)
	assert.Contains(t, lines[0], marker)
	assert.NotContains(t, lines[1], marker)
	assert.Contains(t, lines[2], marker, "the replay restart is a fresh session")
}

// The review case (I1): a project file removed after the session started
// never fails the turn. The first turn completes with the remaining file and
// a warning; the next turn does not retry the skipped one.
func TestClaudeBackend_ProjectFileRemovedAfterStartNeverFailsTheTurn(t *testing.T) {
	opts, f := fakeClaude(t, "normal")
	keep, keepMarker := projectFixture(t)
	gonePath := filepath.Join(t.TempDir(), "diagram.png")
	require.NoError(t, os.WriteFile(gonePath, fixturePNG, 0o600))
	goneMarker := base64.StdEncoding.EncodeToString(fixturePNG)
	var warn bytes.Buffer
	opts.Warn = &warn
	opts.ProjectAttachments = []Attachment{{Path: gonePath, Mime: "image/png", Name: "diagram.png"}, keep}
	h := startSession(t, NewClaudeBackend(opts), nil)
	h.next(EventSessionReady)
	require.NoError(t, os.Remove(gonePath))

	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "first"})
	assert.Equal(t, StatusComplete, h.next(EventTurnDone).Status)
	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "second"})
	assert.Equal(t, StatusComplete, h.next(EventTurnDone).Status)
	require.NoError(t, h.finish())

	lines := stdinLines(t, f.stdin)
	require.Len(t, lines, 2)
	assert.Contains(t, lines[0], keepMarker, "the remaining project file is attached")
	assert.NotContains(t, lines[0], goneMarker)
	assert.NotContains(t, lines[1], keepMarker, "the next turn carries no project files")
	assert.Contains(t, warn.String(), "diagram.png")
	assert.Equal(t, 1, strings.Count(warn.String(), "skipped"), "the skipped file is not retried")
}
