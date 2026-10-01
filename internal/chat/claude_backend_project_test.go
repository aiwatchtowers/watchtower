package chat

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// first drops projectBlocks' over-cap names.
func first(blocks []json.RawMessage, _ []string) []json.RawMessage { return blocks }

func TestClaudeBackend_ProjectBlocksOnlyWhilePending(t *testing.T) {
	att, marker := projectFixture(t)
	b := &claudeBackend{opts: ClaudeOptions{ProjectAttachments: []Attachment{att}}}
	b.projectPending = initialProjectPending(b.opts)

	blocks := first(b.projectBlocks(MaxTurnAttachmentEncodedBytes))
	require.Len(t, blocks, 1)
	assert.Contains(t, string(blocks[0]), marker)
	// Not cleared until a turn carrying it ended with turn_done.
	require.Len(t, first(b.projectBlocks(MaxTurnAttachmentEncodedBytes)), 1, "an unsent first turn still carries the project file")
	b.projectSent()
	assert.Empty(t, first(b.projectBlocks(MaxTurnAttachmentEncodedBytes)), "later turns carry no project files")
	// A replay / session_lost restart is a fresh provider session again.
	b.markFreshSession()
	assert.Len(t, first(b.projectBlocks(MaxTurnAttachmentEncodedBytes)), 1, "after a fresh restart the project file is re-attached")
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
	blocks, overCap := b.projectBlocks(MaxTurnAttachmentEncodedBytes)
	require.Len(t, blocks, 1)
	assert.Empty(t, overCap, "a missing or invalid file is not a cap overflow")
	assert.Contains(t, string(blocks[0]), marker)
	assert.Contains(t, warn.String(), "gone.pdf")
	assert.Contains(t, warn.String(), "notreally.png")
}

// Project files only get what the per-message encoded cap leaves after the
// owner's own files: one that no longer fits is skipped with a warning, and
// a smaller one after it still goes.
func TestClaudeBackend_ProjectBlocksFitTheMessageCap(t *testing.T) {
	att, marker := projectFixture(t)
	big := filepath.Join(t.TempDir(), "big.png")
	bigData := append(append([]byte{}, fixturePNG...), make([]byte, 64)...)
	require.NoError(t, os.WriteFile(big, bigData, 0o600))
	var warn bytes.Buffer
	b := &claudeBackend{opts: ClaudeOptions{Warn: &warn, ProjectAttachments: []Attachment{
		{Path: big, Mime: "image/png", Name: "big.png"}, att,
	}}}
	b.markFreshSession()
	pdfSize := int64(base64.StdEncoding.EncodedLen(len(fixturePDF)))
	require.Greater(t, int64(base64.StdEncoding.EncodedLen(len(bigData))), pdfSize, "the PNG must be the bigger file")

	blocks, overCap := b.projectBlocks(pdfSize)
	require.Len(t, blocks, 1)
	assert.Equal(t, []string{"big.png"}, overCap, "only a file over the cap is reported for the turn's note")
	assert.Contains(t, string(blocks[0]), marker, "the file that fits still goes")
	assert.Contains(t, warn.String(), "big.png")
	assert.Contains(t, warn.String(), "MB one message carries")

	warn.Reset()
	blocks, overCap = b.projectBlocks(0)
	assert.Empty(t, blocks, "nothing fits once the owner's files used the whole cap")
	assert.Equal(t, []string{"big.png", "spec.pdf"}, overCap)
	assert.Contains(t, warn.String(), "spec.pdf")
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

// A turn that ends in an error may never have reached the model (the
// provider can reject the whole request): the next turn carries the project
// files again instead of dropping them for the rest of the session.
func TestClaudeBackend_FailedTurnKeepsProjectFilesPending(t *testing.T) {
	opts, f := fakeClaude(t, "error_once")
	att, marker := projectFixture(t)
	opts.ProjectAttachments = []Attachment{att}
	h := startSession(t, NewClaudeBackend(opts), nil)
	h.next(EventSessionReady)

	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "first"})
	h.next(EventError)
	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "retry"})
	assert.Equal(t, StatusComplete, h.next(EventTurnDone).Status)
	h.send(Command{Type: CommandTurn, TurnID: "t3", Text: "third"})
	assert.Equal(t, StatusComplete, h.next(EventTurnDone).Status)
	require.NoError(t, h.finish())

	lines := stdinLines(t, f.stdin)
	require.Len(t, lines, 3)
	assert.Contains(t, lines[0], marker)
	assert.Contains(t, lines[1], marker, "the retry after the failed turn still carries the project file")
	assert.NotContains(t, lines[2], marker, "once a turn completed, the files are in the session")
}

// A file the provider keeps refusing must not fail every turn: the files
// ride one retry after a failed turn, then they are given up (named on Warn).
func TestClaudeBackend_ProjectFilesGivenUpAfterTwoFailedTurns(t *testing.T) {
	opts, f := fakeClaude(t, "error_always")
	att, marker := projectFixture(t)
	var warn bytes.Buffer
	opts.Warn = &warn
	opts.ProjectAttachments = []Attachment{att}
	h := startSession(t, NewClaudeBackend(opts), nil)
	h.next(EventSessionReady)
	// The app replays after every failed turn: each retry is a fresh session.
	for i, id := range []string{"t1", "t2", "t3", "t4"} {
		h.send(Command{Type: CommandTurn, TurnID: id, Text: "q", Replay: i > 0})
		h.next(EventError)
	}
	require.NoError(t, h.finish())

	lines := stdinLines(t, f.stdin)
	require.Len(t, lines, 4)
	assert.Contains(t, lines[0], marker)
	assert.Contains(t, lines[1], marker, "one retry after a failed turn")
	assert.NotContains(t, lines[2], marker, "then the files no longer fail the turns")
	assert.NotContains(t, lines[3], marker, "not even on a fresh (replayed) session")
	assert.Contains(t, warn.String(), "given up")
}

// A fresh session killed after a cancel already holds the files (its turn
// was streaming): the respawn resumes that session and does not send them
// again.
func TestClaudeBackend_CancelKillDoesNotResendProjectFiles(t *testing.T) {
	opts, f := fakeClaude(t, "ignore_interrupt")
	opts.Env = append(opts.Env, "FAKE_INIT_SID=sess-new")
	att, marker := projectFixture(t)
	opts.ProjectAttachments = []Attachment{att}
	h := startSession(t, NewClaudeBackend(opts), nil)
	h.next(EventSessionReady)

	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "long"})
	h.next(EventTextDelta)
	h.send(Command{Type: CommandCancel})
	assert.Equal(t, StatusInterrupted, h.next(EventTurnDone).Status)
	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "next"})
	h.next(EventTurnDone)
	require.NoError(t, h.finish())

	runs := argvRuns(t, f.argv)
	last := runs[len(runs)-1]
	require.True(t, contains(last, "--resume"))
	lines := stdinLines(t, f.stdin)
	require.Len(t, lines, 3, "turn 1, the interrupt, turn 2")
	assert.Contains(t, lines[0], marker)
	assert.NotContains(t, lines[2], marker, "the resumed session already holds the files")
}

// The owner's own files leave too little of the cap for the project file:
// it is left out of the line and the turn says so — the prompt had listed it
// as attached. (Built without a child: the fake's shell reads a 30 MB line
// too slowly.)
func TestClaudeBackend_OwnerFilesLeaveNoRoomForAProjectFile(t *testing.T) {
	var warn bytes.Buffer
	dir := t.TempDir()
	// ≈ 29.4 MB base64: under the cap alone, too much with the project PDF.
	ownPath := filepath.Join(dir, "own.pdf")
	require.NoError(t, os.WriteFile(ownPath, append([]byte("%PDF-1.4\n"), make([]byte, 22<<20)...), 0o600))
	projPath := filepath.Join(dir, "project.pdf")
	require.NoError(t, os.WriteFile(projPath, append([]byte("%PDF-1.4\n"), make([]byte, 2<<20)...), 0o600))
	b := &claudeBackend{opts: ClaudeOptions{Warn: &warn,
		ProjectAttachments: []Attachment{{Path: projPath, Mime: "application/pdf", Name: "project.pdf"}}}}
	b.markFreshSession()

	line, err := b.userLine("read both", []Attachment{{Path: ownPath, Mime: "application/pdf", Name: "own.pdf"}})
	require.NoError(t, err, "the turn is not rejected")
	assert.LessOrEqual(t, int64(len(line)), MaxTurnAttachmentEncodedBytes+(1<<10), "the line stays within the cap")
	assert.Equal(t, 1, strings.Count(string(line), `"type":"document"`), "only the owner's own PDF is sent")
	assert.Contains(t, string(line), "Project files not attached to this message")
	assert.Contains(t, string(line), "project.pdf")
	assert.Contains(t, warn.String(), "project.pdf")

	// Without the owner's file the project file goes, with no note.
	line, err = b.userLine("just the project", nil)
	require.NoError(t, err)
	assert.Equal(t, 1, strings.Count(string(line), `"type":"document"`))
	assert.NotContains(t, string(line), "not attached")
}
