package cmd

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/digest"
)

// dictateMockGen is a mock digest.Generator for dictate CLI tests. Same shape
// as transcriptMockGen.
type dictateMockGen struct {
	response        string
	err             error
	lastUserMessage string
	calls           int
}

func (m *dictateMockGen) Generate(_ context.Context, _, userMessage, _ string) (string, *digest.Usage, string, error) {
	m.calls++
	m.lastUserMessage = userMessage
	if m.err != nil {
		return "", nil, "", m.err
	}
	return m.response, &digest.Usage{InputTokens: 10, OutputTokens: 5, TotalAPITokens: 20}, "s1", nil
}

// stubDictateGenerator swaps the generator factory seam for the test's
// duration.
func stubDictateGenerator(t *testing.T, gen digest.Generator) {
	t.Helper()
	old := dictateGeneratorFactory
	t.Cleanup(func() { dictateGeneratorFactory = old })
	dictateGeneratorFactory = func(*config.Config) digest.Generator { return gen }
}

// resetDictateFlags restores the dictate command flag vars after a test.
func resetDictateFlags(t *testing.T) {
	t.Helper()
	t.Cleanup(func() {
		dictateCleanFlagMode = ""
		dictateCleanFlagFile = ""
	})
	dictateCleanFlagMode = ""
	dictateCleanFlagFile = ""
}

// writeTempTranscript writes content into a temp transcript file and returns
// its path.
func writeTempTranscript(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "dictation.txt")
	require.NoError(t, os.WriteFile(path, []byte(content), 0o600))
	return path
}

// rawEnvelopeFrom decodes stdout into a generic map (rawEnvelope needs a
// *testing.T and the raw bytes, defined in meeting_transcript_test.go).
func rawEnvelopeFrom(t *testing.T, data []byte) map[string]any {
	t.Helper()
	return rawEnvelope(t, data)
}

func TestDictateCleanIdeaMode(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetDictateFlags(t)
	gen := &dictateMockGen{response: `{"title":"Ship v2","body":"We should ship v2 next week."}`}
	stubDictateGenerator(t, gen)

	f := writeTempTranscript(t, "so um we should ship v2 next week I think")

	var buf bytes.Buffer
	dictateCleanCmd.SetOut(&buf)
	dictateCleanFlagMode = "idea"
	dictateCleanFlagFile = f
	require.NoError(t, dictateCleanCmd.RunE(dictateCleanCmd, nil))

	env := rawEnvelopeFrom(t, buf.Bytes())
	assert.Equal(t, "idea", env["mode"])
	assert.Equal(t, "Ship v2", env["title"])
	assert.Equal(t, "We should ship v2 next week.", env["body"])
	assert.Equal(t, 1, gen.calls)
	assert.Contains(t, gen.lastUserMessage, "ship v2 next week", "transcript must ride the USER message")
}

func TestDictateCleanNoteMode(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetDictateFlags(t)
	gen := &dictateMockGen{response: `{"markdown":"# Notes\n\n- one\n- two"}`}
	stubDictateGenerator(t, gen)

	f := writeTempTranscript(t, "notes about the meeting, first point, second point")

	var buf bytes.Buffer
	dictateCleanCmd.SetOut(&buf)
	dictateCleanFlagMode = "note"
	dictateCleanFlagFile = f
	require.NoError(t, dictateCleanCmd.RunE(dictateCleanCmd, nil))

	env := rawEnvelopeFrom(t, buf.Bytes())
	assert.Equal(t, "note", env["mode"])
	assert.Equal(t, "# Notes\n\n- one\n- two", env["markdown"])
	assert.Equal(t, 1, gen.calls)
}

// Chat fields deliver the raw transcript in the Desktop app and never call
// this CLI (owner call 2026-08-18) — the retired mode must be rejected, not
// silently accepted with an empty envelope.
func TestDictateCleanRejectsRetiredChatMode(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetDictateFlags(t)
	gen := &dictateMockGen{response: `{"text":"unused"}`}
	stubDictateGenerator(t, gen)

	f := writeTempTranscript(t, "um can you check the deploy status")

	dictateCleanFlagMode = "chat"
	dictateCleanFlagFile = f
	err := dictateCleanCmd.RunE(dictateCleanCmd, nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "invalid --mode")
	assert.Equal(t, 0, gen.calls)
}

func TestDictateCleanRejectsUnknownMode(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetDictateFlags(t)
	gen := &dictateMockGen{response: `{"text":"unused"}`}
	stubDictateGenerator(t, gen)

	f := writeTempTranscript(t, "irrelevant transcript text")

	dictateCleanFlagMode = "poem"
	dictateCleanFlagFile = f
	err := dictateCleanCmd.RunE(dictateCleanCmd, nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "idea")
	assert.Contains(t, err.Error(), "note")
	assert.NotContains(t, err.Error(), "chat")
	assert.Equal(t, 0, gen.calls)
}

func TestDictateCleanRequiresTranscriptFile(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetDictateFlags(t)
	gen := &dictateMockGen{response: `{"text":"unused"}`}
	stubDictateGenerator(t, gen)

	dictateCleanFlagMode = "note"
	dictateCleanFlagFile = ""
	err := dictateCleanCmd.RunE(dictateCleanCmd, nil)
	require.Error(t, err)
	assert.Equal(t, 0, gen.calls)
}

func TestDictateCleanEmptyTranscript(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetDictateFlags(t)
	gen := &dictateMockGen{response: `{"text":"unused"}`}
	stubDictateGenerator(t, gen)

	f := writeTempTranscript(t, "   \n\t  ")

	dictateCleanFlagMode = "note"
	dictateCleanFlagFile = f
	err := dictateCleanCmd.RunE(dictateCleanCmd, nil)
	require.Error(t, err)
	assert.Equal(t, 0, gen.calls)
}

func TestDictateCleanGeneratorFailure(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetDictateFlags(t)
	gen := &dictateMockGen{err: errors.New("boom")}
	stubDictateGenerator(t, gen)

	f := writeTempTranscript(t, "some dictation text")

	dictateCleanFlagMode = "note"
	dictateCleanFlagFile = f
	err := dictateCleanCmd.RunE(dictateCleanCmd, nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "boom")
}

func TestDictateCleanMissingRequiredKey(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetDictateFlags(t)
	gen := &dictateMockGen{response: `{"title":"x"}`}
	stubDictateGenerator(t, gen)

	f := writeTempTranscript(t, "some dictation text")

	dictateCleanFlagMode = "idea"
	dictateCleanFlagFile = f
	err := dictateCleanCmd.RunE(dictateCleanCmd, nil)
	require.Error(t, err)
	// D2: the error must never embed the raw model reply (dictated speech) —
	// only the failure category.
	assert.Contains(t, err.Error(), "title/body")
	assert.NotContains(t, err.Error(), `{"title":"x"}`)
}

func TestDictateCleanMissingMarkdownKeyNoteMode(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetDictateFlags(t)
	gen := &dictateMockGen{response: `{"text":"not markdown"}`}
	stubDictateGenerator(t, gen)

	f := writeTempTranscript(t, "some dictation text")

	dictateCleanFlagMode = "note"
	dictateCleanFlagFile = f
	err := dictateCleanCmd.RunE(dictateCleanCmd, nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "markdown")
}

func TestDictateCleanNonexistentTranscriptFile(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetDictateFlags(t)
	gen := &dictateMockGen{response: `{"text":"unused"}`}
	stubDictateGenerator(t, gen)

	dictateCleanFlagMode = "note"
	dictateCleanFlagFile = filepath.Join(t.TempDir(), "does-not-exist.txt")
	err := dictateCleanCmd.RunE(dictateCleanCmd, nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "reading transcript file")
	assert.Equal(t, 0, gen.calls)
}

func TestDictateCleanFencedJSON(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetDictateFlags(t)
	gen := &dictateMockGen{response: "```json\n{\"markdown\":\"cleaned up text\"}\n```"}
	stubDictateGenerator(t, gen)

	f := writeTempTranscript(t, "some dictation text")

	var buf bytes.Buffer
	dictateCleanCmd.SetOut(&buf)
	dictateCleanFlagMode = "note"
	dictateCleanFlagFile = f
	require.NoError(t, dictateCleanCmd.RunE(dictateCleanCmd, nil))

	env := rawEnvelopeFrom(t, buf.Bytes())
	assert.Equal(t, "cleaned up text", env["markdown"])
}
