package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// transcriptMockGen is a mock digest.Generator for transcript CLI tests.
type transcriptMockGen struct {
	response        string
	err             error
	lastUserMessage string
}

func (m *transcriptMockGen) Generate(_ context.Context, _, userMessage, _ string) (string, *digest.Usage, string, error) {
	m.lastUserMessage = userMessage
	if m.err != nil {
		return "", nil, "", m.err
	}
	return m.response, &digest.Usage{InputTokens: 10, OutputTokens: 5, TotalAPITokens: 20}, "s1", nil
}

const transcriptMockRecapJSON = `{"summary":"s","key_decisions":["d"],"action_items":[],"open_questions":[]}`

// stubTranscriptGenerator swaps the generator factory seam for the test's
// duration.
func stubTranscriptGenerator(t *testing.T, gen digest.Generator) {
	t.Helper()
	old := transcriptGeneratorFactory
	t.Cleanup(func() { transcriptGeneratorFactory = old })
	transcriptGeneratorFactory = func(*config.Config) digest.Generator { return gen }
}

// resetTranscriptFlags restores the transcript command flag vars after a test.
func resetTranscriptFlags(t *testing.T) {
	t.Helper()
	t.Cleanup(func() {
		transcriptSaveFlagFile = ""
		transcriptSaveFlagAudio = ""
		transcriptSaveFlagEventID = ""
		transcriptSaveFlagTitle = ""
		transcriptSaveFlagLangStats = ""
		transcriptSaveFlagDuration = 0
		transcriptListFlagEventID = ""
	})
	transcriptSaveFlagFile = ""
	transcriptSaveFlagAudio = ""
	transcriptSaveFlagEventID = ""
	transcriptSaveFlagTitle = ""
	transcriptSaveFlagLangStats = ""
	transcriptSaveFlagDuration = 0
	transcriptListFlagEventID = ""
}

// writeTranscriptFile writes content into a temp transcript file and returns its path.
func writeTranscriptFile(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "transcript.txt")
	require.NoError(t, os.WriteFile(path, []byte(content), 0o600))
	return path
}

// transcriptEnvelope mirrors the frozen stdout contract consumed by the Swift
// TranscriptSaveService.
type transcriptEnvelope struct {
	TranscriptID int64  `json:"transcript_id"`
	EventID      string `json:"event_id"`
	Title        string `json:"title"`
	RecapOK      bool   `json:"recap_ok"`
	RecapError   string `json:"recap_error"`
}

func findPipelineRun(t *testing.T, database *db.DB, pipeline string) *db.PipelineRun {
	t.Helper()
	runs, err := database.GetPipelineRuns(20)
	require.NoError(t, err)
	for i := range runs {
		if runs[i].Pipeline == pipeline {
			return &runs[i]
		}
	}
	return nil
}

func TestTranscriptSaveRequiresFile(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)

	err := transcriptSaveCmd.RunE(transcriptSaveCmd, nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "--transcript-file")
}

func TestTranscriptSaveEmptyFileFails(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)

	transcriptSaveFlagFile = writeTranscriptFile(t, "   \n")

	err := transcriptSaveCmd.RunE(transcriptSaveCmd, nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "empty")

	database, err := openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()
	rows, err := database.ListMeetingTranscripts(db.MeetingTranscriptFilter{})
	require.NoError(t, err)
	assert.Empty(t, rows, "no transcript row must be inserted for an empty file")
}

func TestTranscriptSaveAdHocPersistsAndRecaps(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)
	stubTranscriptGenerator(t, &transcriptMockGen{response: transcriptMockRecapJSON})

	transcriptSaveFlagFile = writeTranscriptFile(t, "we agreed to ship v2 on friday")
	transcriptSaveFlagTitle = "Ad hoc"
	transcriptSaveFlagDuration = 60
	transcriptSaveFlagLangStats = `{"en":60}`

	var buf bytes.Buffer
	transcriptSaveCmd.SetOut(&buf)

	require.NoError(t, transcriptSaveCmd.RunE(transcriptSaveCmd, nil))

	var env transcriptEnvelope
	require.NoError(t, json.Unmarshal(buf.Bytes(), &env))
	assert.Greater(t, env.TranscriptID, int64(0))
	assert.Equal(t, "Ad hoc", env.Title)
	assert.Equal(t, "", env.EventID)
	assert.True(t, env.RecapOK)
	assert.Equal(t, "", env.RecapError)

	database, err := openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()

	rows, err := database.ListMeetingTranscripts(db.MeetingTranscriptFilter{})
	require.NoError(t, err)
	require.Len(t, rows, 1)
	assert.Equal(t, env.TranscriptID, rows[0].ID)
	assert.Equal(t, "Ad hoc", rows[0].Title)
	assert.Equal(t, 60, rows[0].DurationSec)
	assert.Equal(t, `{"en":60}`, rows[0].LangStats)
	require.True(t, rows[0].SummaryJSON.Valid, "ad-hoc recap must land in summary_json")
	assert.Contains(t, rows[0].SummaryJSON.String, `"summary":"s"`)

	run := findPipelineRun(t, database, "meeting_transcript")
	require.NotNil(t, run, "a meeting_transcript pipeline run must be recorded")
	assert.Equal(t, "done", run.Status)
}

func TestTranscriptSaveEventLinkedWritesMeetingRecaps(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)
	stubTranscriptGenerator(t, &transcriptMockGen{response: transcriptMockRecapJSON})

	database, err := openDBFromConfig()
	require.NoError(t, err)
	require.NoError(t, database.UpsertCalendar(db.CalendarCalendar{ID: "primary", Name: "Primary", IsPrimary: true, IsSelected: true}))
	require.NoError(t, database.UpsertCalendarEvent(db.CalendarEvent{
		ID:         "evt-1",
		CalendarID: "primary",
		Title:      "Weekly Sync",
		StartTime:  "2026-07-13T10:00:00Z",
		EndTime:    "2026-07-13T10:30:00Z",
	}))
	database.Close()

	transcriptText := "discussed roadmap; alice owns rollout"
	transcriptSaveFlagFile = writeTranscriptFile(t, transcriptText)
	transcriptSaveFlagEventID = "evt-1"

	var buf bytes.Buffer
	transcriptSaveCmd.SetOut(&buf)

	require.NoError(t, transcriptSaveCmd.RunE(transcriptSaveCmd, nil))

	var env transcriptEnvelope
	require.NoError(t, json.Unmarshal(buf.Bytes(), &env))
	assert.Equal(t, "evt-1", env.EventID)
	assert.Equal(t, "Weekly Sync", env.Title, "title should default to the event title")
	assert.True(t, env.RecapOK)

	database, err = openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()

	recap, err := database.GetMeetingRecap("evt-1")
	require.NoError(t, err)
	require.NotNil(t, recap, "event-linked recap must land in meeting_recaps")
	assert.Equal(t, transcriptText, recap.SourceText)
	assert.Contains(t, recap.RecapJSON, `"summary":"s"`)

	tr, err := database.GetMeetingTranscript(env.TranscriptID)
	require.NoError(t, err)
	require.NotNil(t, tr)
	assert.False(t, tr.SummaryJSON.Valid, "event-linked transcript must NOT get summary_json")
}

func TestTranscriptSaveRecapFailureStillPersists(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)
	stubTranscriptGenerator(t, &transcriptMockGen{err: errors.New("boom")})

	transcriptSaveFlagFile = writeTranscriptFile(t, "some transcript text")
	transcriptSaveFlagTitle = "Failing recap"

	var buf bytes.Buffer
	transcriptSaveCmd.SetOut(&buf)

	// Recap failure must still exit 0 — the transcript row was persisted.
	require.NoError(t, transcriptSaveCmd.RunE(transcriptSaveCmd, nil))

	var env transcriptEnvelope
	require.NoError(t, json.Unmarshal(buf.Bytes(), &env))
	assert.Greater(t, env.TranscriptID, int64(0))
	assert.False(t, env.RecapOK)
	assert.Contains(t, env.RecapError, "boom")

	database, err := openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()

	tr, err := database.GetMeetingTranscript(env.TranscriptID)
	require.NoError(t, err)
	require.NotNil(t, tr, "transcript row must survive a recap failure")
	assert.False(t, tr.SummaryJSON.Valid)

	run := findPipelineRun(t, database, "meeting_transcript")
	require.NotNil(t, run)
	assert.Equal(t, "error", run.Status)
}

func TestTranscriptRecapRetry(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)
	stubTranscriptGenerator(t, &transcriptMockGen{response: transcriptMockRecapJSON})

	database, err := openDBFromConfig()
	require.NoError(t, err)
	id, err := database.InsertMeetingTranscript(db.MeetingTranscript{
		Title:          "Retry me",
		TranscriptText: "transcript body for retry",
	})
	require.NoError(t, err)
	database.Close()

	var buf bytes.Buffer
	transcriptRecapCmd.SetOut(&buf)

	require.NoError(t, transcriptRecapCmd.RunE(transcriptRecapCmd, []string{fmt.Sprint(id)}))

	var env transcriptEnvelope
	require.NoError(t, json.Unmarshal(buf.Bytes(), &env))
	assert.Equal(t, id, env.TranscriptID)
	assert.True(t, env.RecapOK)
	assert.Equal(t, "", env.RecapError)

	database, err = openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()
	tr, err := database.GetMeetingTranscript(id)
	require.NoError(t, err)
	require.NotNil(t, tr)
	assert.True(t, tr.SummaryJSON.Valid, "retry must fill the missing summary")
}

func TestTranscriptListAndShow(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)

	database, err := openDBFromConfig()
	require.NoError(t, err)
	longText := strings.Repeat("word ", 100) // 500 chars — must be snipped in list
	id1, err := database.InsertMeetingTranscript(db.MeetingTranscript{
		Title:          "First",
		TranscriptText: longText,
	})
	require.NoError(t, err)
	_, err = database.InsertMeetingTranscript(db.MeetingTranscript{
		Title:          "Second",
		TranscriptText: "short text",
	})
	require.NoError(t, err)
	database.Close()

	var listBuf bytes.Buffer
	transcriptListCmd.SetOut(&listBuf)
	require.NoError(t, transcriptListCmd.RunE(transcriptListCmd, nil))

	var listed []map[string]any
	require.NoError(t, json.Unmarshal(listBuf.Bytes(), &listed))
	require.Len(t, listed, 2)
	titles := []string{listed[0]["title"].(string), listed[1]["title"].(string)}
	assert.ElementsMatch(t, []string{"First", "Second"}, titles)
	for _, row := range listed {
		_, hasFull := row["transcript_text"]
		assert.False(t, hasFull, "list must omit the full transcript text")
		snippet, ok := row["snippet"].(string)
		require.True(t, ok, "list rows must include a snippet")
		assert.LessOrEqual(t, len([]rune(snippet)), 200)
	}

	var showBuf bytes.Buffer
	transcriptShowCmd.SetOut(&showBuf)
	require.NoError(t, transcriptShowCmd.RunE(transcriptShowCmd, []string{fmt.Sprint(id1)}))

	var shown map[string]any
	require.NoError(t, json.Unmarshal(showBuf.Bytes(), &shown))
	assert.Equal(t, "First", shown["title"])
	assert.Equal(t, longText, shown["transcript_text"], "show must include the full transcript text")
}
