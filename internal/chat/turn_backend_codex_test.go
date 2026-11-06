package chat

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/codex"
)

// codexStub is a stand-in codex binary that reads its stdin and prints
// jsonl, as `codex exec --json` does.
func codexStub(t *testing.T, jsonl string) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("shell-script fake CLI")
	}
	path := filepath.Join(t.TempDir(), "codex")
	body := "#!/bin/sh\ncat > /dev/null\ncat <<'__EOF__'\n" + jsonl + "\n__EOF__\n"
	require.NoError(t, os.WriteFile(path, []byte(body), 0o755))
	return path
}

// turnEvents collects the session's events up to the turn's terminal one.
func (h *harness) turnEvents() []Event {
	h.t.Helper()
	deadline := time.After(10 * time.Second)
	var out []Event
	for {
		select {
		case e, ok := <-h.events:
			require.True(h.t, ok, "session ended before the turn did")
			out = append(out, e)
			if e.Type == EventTurnDone || e.Type == EventError {
				return out
			}
		case <-deadline:
			h.t.Fatalf("turn did not end within 10s")
		}
	}
}

// A codex chat turn goes from codex's real JSONL through codex.Client and the
// turn backend: every tool call is a visible tool_start/tool_end step with
// its result (CHAT-02), the preamble is a separate paragraph, and the turn's
// usage reaches the message.
func TestTurnBackend_CodexToolCallsBecomeSteps(t *testing.T) {
	jsonl := strings.Join([]string{
		`{"type":"thread.started","thread_id":"th1"}`,
		`{"type":"turn.started"}`,
		`{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"I'll check the board."}}`,
		`{"type":"item.started","item":{"id":"item_1","type":"mcp_tool_call","server":"watchtower","tool":"list_targets","arguments":{"status":"open"},"result":null,"error":null,"status":"in_progress"}}`,
		`{"type":"item.completed","item":{"id":"item_1","type":"mcp_tool_call","server":"watchtower","tool":"list_targets","arguments":{"status":"open"},"result":{"content":[{"type":"text","text":"[]"}],"structured_content":null},"error":null,"status":"completed"}}`,
		`{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"No open targets."}}`,
		`{"type":"turn.completed","usage":{"input_tokens":1200,"cached_input_tokens":800,"output_tokens":90}}`,
	}, "\n")
	d, conv := seedConversation(t)
	b := NewTurnBackend(codex.NewClient("gpt-x", "", codexStub(t, jsonl)), d, conv)
	h := startSession(t, b, nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "why?"})

	evs := h.turnEvents()
	var types []string
	var text strings.Builder
	for _, e := range evs {
		types = append(types, e.Type)
		text.WriteString(e.Text)
	}
	assert.Equal(t, []string{EventTurnStart, EventTextDelta, EventToolStart, EventToolEnd, EventTextDelta, EventUsage, EventTurnDone}, types)
	assert.Equal(t, "I'll check the board.\n\nNo open targets.", text.String())

	start, end := evs[2], evs[3]
	assert.Equal(t, "list_targets", start.Name)
	assert.Equal(t, "item_1", start.ID)
	assert.JSONEq(t, `{"status":"open"}`, string(start.Args))
	assert.Equal(t, "item_1", end.ID)
	require.NotNil(t, end.OK)
	assert.True(t, *end.OK)
	assert.Equal(t, "[]", end.Summary)

	u := evs[5]
	assert.Equal(t, "gpt-x", u.Model)
	assert.Equal(t, 1200, u.TokensIn)
	assert.Equal(t, 90, u.TokensOut)
	assert.Equal(t, StatusComplete, evs[6].Status)
	require.NoError(t, h.finish())
}

// A codex run that exits cleanly without turn.completed is an error turn,
// never a blank or partial "complete" answer.
func TestTurnBackend_CodexExitWithoutTurnCompletedIsAnError(t *testing.T) {
	jsonl := `{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"I'll check the board."}}`
	d, conv := seedConversation(t)
	h := startSession(t, NewTurnBackend(codex.NewClient("gpt-x", "", codexStub(t, jsonl)), d, conv), nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "why?"})
	e := h.next(EventError)
	assert.Equal(t, "t2", e.TurnID)
	assert.Contains(t, e.Message, "without completing the turn")
	require.NoError(t, h.finish())
}

// recordingCodexStub is codexStub that also records its argv (one per line)
// to argvFile, its stdin to stdinFile, and copies every --image file it is
// given to <dir>/seen-<n>, so a test sees what the model was handed while
// the run lived.
func recordingCodexStub(t *testing.T, jsonl string) (bin, dir string) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("shell-script fake CLI")
	}
	dir = t.TempDir()
	bin = filepath.Join(dir, "codex")
	body := "#!/bin/sh\n" +
		"for a in \"$@\"; do printf '%s\\n' \"$a\" >> '" + dir + "/argv'; done\n" +
		"n=0; for a in \"$@\"; do case \"$a\" in --image=*) n=$((n+1)); cp \"${a#--image=}\" '" + dir + "/seen-'$n;; esac; done\n" +
		"cat > '" + dir + "/stdin'\n" +
		"cat <<'__EOF__'\n" + jsonl + "\n__EOF__\n"
	require.NoError(t, os.WriteFile(bin, []byte(body), 0o755))
	return bin, dir
}

const codexPlainTurn = `{"type":"thread.started","thread_id":"th1"}
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"A red square."}}
{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}`

// An image attachment on a codex turn travels as --image=<path> on the
// exec argv (CHAT-04: a path, never content), and stdin carries no base64.
func TestCodexTurn_ImageAttachmentPassedAsImageFlag(t *testing.T) {
	bin, dir := recordingCodexStub(t, codexPlainTurn)
	d, conv := seedConversation(t)
	h := startSession(t, NewTurnBackend(codex.NewClient("gpt-x", "", bin), d, conv), nil)
	h.next(EventSessionReady)
	p := writeAttachmentFixture(t, "shot.png", fixturePNG)
	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "what is this?",
		Attachments: []Attachment{{Path: p, Mime: "image/png", Name: "shot.png"}}})
	h.next(EventTurnDone)
	require.NoError(t, h.finish())

	argv, err := os.ReadFile(filepath.Join(dir, "argv"))
	require.NoError(t, err)
	var images []string
	for a := range strings.SplitSeq(string(argv), "\n") {
		if v, ok := strings.CutPrefix(a, "--image="); ok {
			images = append(images, v)
		}
	}
	require.Len(t, images, 1, "one --image flag: %s", argv)
	assert.NotEqual(t, p, images[0], "a private copy of the checked bytes, not the owner's path")
	assert.NoFileExists(t, images[0], "the turn's image copy is removed after the turn")
	stdin, err := os.ReadFile(filepath.Join(dir, "stdin"))
	require.NoError(t, err)
	assert.NotContains(t, string(stdin), base64.StdEncoding.EncodeToString(fixturePNG))
	assert.NotContains(t, string(stdin), "shot.png", "the image is not inlined as a file block")
}

// A PDF stays refused on codex, before any child starts.
func TestCodexTurn_PDFStillRefusedBeforeSpawn(t *testing.T) {
	bin, dir := recordingCodexStub(t, codexPlainTurn)
	d, conv := seedConversation(t)
	h := startSession(t, NewTurnBackend(codex.NewClient("gpt-x", "", bin), d, conv), nil)
	h.next(EventSessionReady)
	p := writeAttachmentFixture(t, "doc.pdf", fixturePDF)
	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "read this",
		Attachments: []Attachment{{Path: p, Mime: "application/pdf", Name: "doc.pdf"}}})
	e := h.next(EventError)
	assert.Equal(t, CodeAttachmentUnsupported, e.Code)
	assert.Contains(t, e.Message, "PDF")
	require.NoError(t, h.finish())
	assert.NoFileExists(t, filepath.Join(dir, "argv"), "codex never started")
}

// The image codex is handed holds the attachment's bytes while the run
// lives: the model gets the picture the owner attached.
func TestTurnBackend_CodexImageAttachmentReachesTheModel(t *testing.T) {
	bin, dir := recordingCodexStub(t, codexPlainTurn)
	d, conv := seedConversation(t)
	h := startSession(t, NewTurnBackend(codex.NewClient("gpt-x", "", bin), d, conv), nil)
	h.next(EventSessionReady)
	p := writeAttachmentFixture(t, "shot.png", fixturePNG)
	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "what is this?",
		Attachments: []Attachment{{Path: p, Mime: "image/png", Name: "shot.png"}}})
	evs := h.turnEvents()
	assert.Equal(t, StatusComplete, evs[len(evs)-1].Status)
	seen, err := os.ReadFile(filepath.Join(dir, "seen-1"))
	require.NoError(t, err, "codex was handed a readable image")
	assert.Equal(t, fixturePNG, seen)

	// The session's next turn carries no image: SetImages is per turn.
	require.NoError(t, os.Remove(filepath.Join(dir, "argv")))
	h.send(Command{Type: CommandTurn, TurnID: "t3", Text: "and now?"})
	h.next(EventTurnDone)
	require.NoError(t, h.finish())
	argv, err := os.ReadFile(filepath.Join(dir, "argv"))
	require.NoError(t, err)
	assert.NotContains(t, string(argv), "--image")
}

// A failed codex turn still removes its image copy, after codex had it.
func TestCodexTurn_FailedTurnRemovesItsImage(t *testing.T) {
	bin, dir := recordingCodexStub(t, `{"type":"turn.started"}
{"type":"turn.failed","error":{"message":"model overloaded"}}`)
	d, conv := seedConversation(t)
	h := startSession(t, NewTurnBackend(codex.NewClient("gpt-x", "", bin), d, conv), nil)
	h.next(EventSessionReady)
	p := writeAttachmentFixture(t, "shot.png", fixturePNG)
	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "what is this?",
		Attachments: []Attachment{{Path: p, Mime: "image/png", Name: "shot.png"}}})
	h.next(EventError)
	require.NoError(t, h.finish())
	seen, err := os.ReadFile(filepath.Join(dir, "seen-1"))
	require.NoError(t, err, "codex had the image while it ran")
	assert.Equal(t, fixturePNG, seen)
	argv, err := os.ReadFile(filepath.Join(dir, "argv"))
	require.NoError(t, err)
	for a := range strings.SplitSeq(string(argv), "\n") {
		if v, ok := strings.CutPrefix(a, "--image="); ok {
			assert.NoFileExists(t, v, "the failed turn's image copy is removed")
		}
	}
}
