package cmd

import (
	"bytes"
	"context"
	"database/sql"
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
	"watchtower/internal/meeting"
)

// transcriptMockGen is a mock digest.Generator for transcript CLI tests.
// When responses is non-empty it is consumed in call order (save makes two
// AI calls — recap then chapters — that need different payloads); otherwise
// every call returns response.
type transcriptMockGen struct {
	response        string
	responses       []string
	err             error
	lastUserMessage string
}

func (m *transcriptMockGen) Generate(_ context.Context, _, userMessage, _ string) (string, *digest.Usage, string, error) {
	m.lastUserMessage = userMessage
	if m.err != nil {
		return "", nil, "", m.err
	}
	out := m.response
	if len(m.responses) > 0 {
		out = m.responses[0]
		m.responses = m.responses[1:]
	}
	return out, &digest.Usage{InputTokens: 10, OutputTokens: 5, TotalAPITokens: 20}, "s1", nil
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
		transcriptSaveFlagSegments = ""
		transcriptSaveFlagAudio = ""
		transcriptSaveFlagEventID = ""
		transcriptSaveFlagTitle = ""
		transcriptSaveFlagLangStats = ""
		transcriptSaveFlagDuration = 0
		transcriptListFlagEventID = ""
		transcriptFollowupChapter = -1
	})
	transcriptSaveFlagFile = ""
	transcriptSaveFlagSegments = ""
	transcriptSaveFlagAudio = ""
	transcriptSaveFlagEventID = ""
	transcriptSaveFlagTitle = ""
	transcriptSaveFlagLangStats = ""
	transcriptSaveFlagDuration = 0
	transcriptListFlagEventID = ""
	transcriptFollowupChapter = -1
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
	require.NoError(t, database.UpsertCalendar(0, db.CalendarCalendar{ID: "primary", Name: "Primary", IsPrimary: true, IsSelected: true}))
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

func TestTranscriptSaveEventWithExistingRecapKeepsIt(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)
	stubTranscriptGenerator(t, &transcriptMockGen{response: transcriptMockRecapJSON})

	const existingRecapJSON = `{"summary":"manual recap","key_decisions":[],"action_items":[],"open_questions":[]}`
	const existingSourceText = "recap the user pasted earlier"

	database, err := openDBFromConfig()
	require.NoError(t, err)
	require.NoError(t, database.UpsertCalendar(0, db.CalendarCalendar{ID: "primary", Name: "Primary", IsPrimary: true, IsSelected: true}))
	require.NoError(t, database.UpsertCalendarEvent(db.CalendarEvent{
		ID:         "evt-recap",
		CalendarID: "primary",
		Title:      "Planning",
		StartTime:  "2026-07-13T11:00:00Z",
		EndTime:    "2026-07-13T11:30:00Z",
	}))
	require.NoError(t, database.UpsertMeetingRecap("evt-recap", existingSourceText, existingRecapJSON))
	database.Close()

	transcriptSaveFlagFile = writeTranscriptFile(t, "transcript recorded after the pasted recap")
	transcriptSaveFlagEventID = "evt-recap"

	var buf bytes.Buffer
	transcriptSaveCmd.SetOut(&buf)

	require.NoError(t, transcriptSaveCmd.RunE(transcriptSaveCmd, nil))

	var env transcriptEnvelope
	require.NoError(t, json.Unmarshal(buf.Bytes(), &env))
	assert.True(t, env.RecapOK)
	assert.Equal(t, "evt-recap", env.EventID)

	database, err = openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()

	// The pre-existing recap must be untouched (collision guard, mirrors
	// Swift MeetingTranscriptQueries.linkToEvent).
	recap, err := database.GetMeetingRecap("evt-recap")
	require.NoError(t, err)
	require.NotNil(t, recap)
	assert.Equal(t, existingRecapJSON, recap.RecapJSON, "existing recap_json must not be overwritten")
	assert.Equal(t, existingSourceText, recap.SourceText, "existing source_text must not be overwritten")

	// The generated recap lands in the transcript's own summary_json instead.
	tr, err := database.GetMeetingTranscript(env.TranscriptID)
	require.NoError(t, err)
	require.NotNil(t, tr)
	require.True(t, tr.SummaryJSON.Valid, "generated recap must land in summary_json when the event already has a recap")
	assert.Contains(t, tr.SummaryJSON.String, `"summary":"s"`)
}

// segmentsFixtureJSON renders to exactly "[Я] привет\n[Speaker 1] ответ" —
// the transcript text used by the segments save tests (the invariant
// transcript_text = render(segments) must hold at save time).
const segmentsFixtureJSON = `[
	{"idx":0,"start_sec":0,"end_sec":2.5,"speaker":"Я","text":"привет","deleted":false},
	{"idx":1,"start_sec":2.5,"end_sec":5,"speaker":"Speaker 1","text":"ответ","deleted":false}
]`

const segmentsFixtureText = "[Я] привет\n[Speaker 1] ответ"

// writeSegmentsFile writes content into a temp segments file and returns its path.
func writeSegmentsFile(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "segments.json")
	require.NoError(t, os.WriteFile(path, []byte(content), 0o600))
	return path
}

func TestTranscriptSaveWithSegmentsPersistsColumn(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)
	stubTranscriptGenerator(t, &transcriptMockGen{response: transcriptMockRecapJSON})

	transcriptSaveFlagFile = writeTranscriptFile(t, segmentsFixtureText)
	transcriptSaveFlagSegments = writeSegmentsFile(t, segmentsFixtureJSON)
	transcriptSaveFlagTitle = "With segments"

	var buf bytes.Buffer
	transcriptSaveCmd.SetOut(&buf)
	require.NoError(t, transcriptSaveCmd.RunE(transcriptSaveCmd, nil))

	var env transcriptEnvelope
	require.NoError(t, json.Unmarshal(buf.Bytes(), &env))
	assert.True(t, env.RecapOK)

	database, err := openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()
	tr, err := database.GetMeetingTranscript(env.TranscriptID)
	require.NoError(t, err)
	require.NotNil(t, tr)
	require.True(t, tr.SegmentsJSON.Valid, "segments_json must be persisted when --segments-file is valid")
	utterances, err := meeting.ParseTranscriptSegments([]byte(tr.SegmentsJSON.String))
	require.NoError(t, err)
	assert.Equal(t, tr.TranscriptText, meeting.RenderTranscriptSegments(utterances),
		"invariant: transcript_text = render(segments where !deleted)")
}

func TestTranscriptSaveWithoutSegmentsLeavesColumnNULL(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)
	stubTranscriptGenerator(t, &transcriptMockGen{response: transcriptMockRecapJSON})

	transcriptSaveFlagFile = writeTranscriptFile(t, "plain transcript, old caller")

	var buf bytes.Buffer
	transcriptSaveCmd.SetOut(&buf)
	require.NoError(t, transcriptSaveCmd.RunE(transcriptSaveCmd, nil))

	var env transcriptEnvelope
	require.NoError(t, json.Unmarshal(buf.Bytes(), &env))

	database, err := openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()
	tr, err := database.GetMeetingTranscript(env.TranscriptID)
	require.NoError(t, err)
	require.NotNil(t, tr)
	assert.False(t, tr.SegmentsJSON.Valid, "no --segments-file → NULL column, legacy behavior")
}

func TestTranscriptSaveMalformedSegmentsStillPersistsTranscript(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)
	stubTranscriptGenerator(t, &transcriptMockGen{response: transcriptMockRecapJSON})

	cases := map[string]string{
		"not json":        `{{{not json`,
		"empty array":     `[]`,
		"render mismatch": `[{"idx":0,"start_sec":0,"end_sec":1,"speaker":"Я","text":"другой текст","deleted":false}]`,
	}
	for name, payload := range cases {
		t.Run(name, func(t *testing.T) {
			resetTranscriptFlags(t)
			transcriptSaveFlagFile = writeTranscriptFile(t, segmentsFixtureText)
			transcriptSaveFlagSegments = writeSegmentsFile(t, payload)
			transcriptSaveFlagTitle = "Malformed " + name

			var out, errBuf bytes.Buffer
			transcriptSaveCmd.SetOut(&out)
			transcriptSaveCmd.SetErr(&errBuf)

			// Exit-0 envelope semantics preserved: the transcript row saved.
			require.NoError(t, transcriptSaveCmd.RunE(transcriptSaveCmd, nil))
			assert.Contains(t, errBuf.String(), "warning:", "a bad segments file must warn on stderr")

			var env transcriptEnvelope
			require.NoError(t, json.Unmarshal(out.Bytes(), &env))
			assert.Greater(t, env.TranscriptID, int64(0))

			database, err := openDBFromConfig()
			require.NoError(t, err)
			defer database.Close()
			tr, err := database.GetMeetingTranscript(env.TranscriptID)
			require.NoError(t, err)
			require.NotNil(t, tr, "transcript must persist despite a bad segments file")
			assert.Equal(t, segmentsFixtureText, tr.TranscriptText)
			assert.False(t, tr.SegmentsJSON.Valid, "bad segments file → NULL column")
		})
	}
}

func TestTranscriptSaveMissingSegmentsFileStillPersistsTranscript(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)
	stubTranscriptGenerator(t, &transcriptMockGen{response: transcriptMockRecapJSON})

	transcriptSaveFlagFile = writeTranscriptFile(t, "text without segments")
	transcriptSaveFlagSegments = filepath.Join(t.TempDir(), "does-not-exist.json")

	var out, errBuf bytes.Buffer
	transcriptSaveCmd.SetOut(&out)
	transcriptSaveCmd.SetErr(&errBuf)

	require.NoError(t, transcriptSaveCmd.RunE(transcriptSaveCmd, nil))
	assert.Contains(t, errBuf.String(), "warning:")

	var env transcriptEnvelope
	require.NoError(t, json.Unmarshal(out.Bytes(), &env))

	database, err := openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()
	tr, err := database.GetMeetingTranscript(env.TranscriptID)
	require.NoError(t, err)
	require.NotNil(t, tr)
	assert.False(t, tr.SegmentsJSON.Valid)
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

func TestTranscriptNotesGeneratesAndStores(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)
	stubTranscriptGenerator(t, &transcriptMockGen{response: "# Sync\n\n## Summary\nShipped v2."})

	database, err := openDBFromConfig()
	require.NoError(t, err)
	id, err := database.InsertMeetingTranscript(db.MeetingTranscript{
		Title:          "Sync",
		TranscriptText: "we shipped v2",
	})
	require.NoError(t, err)
	database.Close()

	var buf bytes.Buffer
	transcriptNotesCmd.SetOut(&buf)
	require.NoError(t, transcriptNotesCmd.RunE(transcriptNotesCmd, []string{fmt.Sprint(id)}))

	var env struct {
		TranscriptID int64  `json:"transcript_id"`
		NotesMD      string `json:"notes_md"`
	}
	require.NoError(t, json.Unmarshal(buf.Bytes(), &env))
	assert.Equal(t, id, env.TranscriptID)
	assert.Contains(t, env.NotesMD, "## Summary")

	database, err = openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()
	tr, err := database.GetMeetingTranscript(id)
	require.NoError(t, err)
	require.True(t, tr.NotesMD.Valid, "notes_md must be persisted")
	assert.Equal(t, env.NotesMD, tr.NotesMD.String)

	run := findPipelineRun(t, database, "meeting_notes")
	require.NotNil(t, run, "a meeting_notes pipeline run must be recorded")
	assert.Equal(t, "done", run.Status)
}

func TestTranscriptNotesGenerationFailureExitsNonZeroAndStoresNothing(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)
	stubTranscriptGenerator(t, &transcriptMockGen{err: errors.New("boom")})

	database, err := openDBFromConfig()
	require.NoError(t, err)
	id, err := database.InsertMeetingTranscript(db.MeetingTranscript{
		Title:          "Sync",
		TranscriptText: "we shipped v2",
	})
	require.NoError(t, err)
	database.Close()

	err = transcriptNotesCmd.RunE(transcriptNotesCmd, []string{fmt.Sprint(id)})
	require.Error(t, err, "notes failure must flip the exit code — nothing was persisted")
	assert.Contains(t, err.Error(), "boom")

	database, err = openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()
	tr, err := database.GetMeetingTranscript(id)
	require.NoError(t, err)
	assert.False(t, tr.NotesMD.Valid, "failed generation must not write notes_md")

	run := findPipelineRun(t, database, "meeting_notes")
	require.NotNil(t, run)
	assert.Equal(t, "error", run.Status)
}

func TestTranscriptNotesUnknownIDFails(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)
	stubTranscriptGenerator(t, &transcriptMockGen{response: "# n"})

	err := transcriptNotesCmd.RunE(transcriptNotesCmd, []string{"9999"})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "not found")
}

// transcriptMockChaptersJSON stays within the segmentsFixture timecodes
// (0-5s) so duration validation passes for any --duration.
const transcriptMockChaptersJSON = `{"overall_summary":"o","chapters":[{"title":"Intro","start_sec":0,"end_sec":5,"participants":["Я","Speaker 1"],"summary":"s","decisions":["d1"],"action_items":["a1"],"open_questions":[]}]}`

// chaptersEnvelope extends transcriptEnvelope with the additive chapters keys
// (pointers so their absence is distinguishable from false/"").
type chaptersEnvelope struct {
	transcriptEnvelope
	ChaptersOK    *bool   `json:"chapters_ok"`
	ChaptersError *string `json:"chapters_error"`
}

// insertChapterTestTranscript seeds a transcript row with valid segments and
// returns its id.
func insertChapterTestTranscript(t *testing.T, database *db.DB) int64 {
	t.Helper()
	id, err := database.InsertMeetingTranscript(db.MeetingTranscript{
		Title:          "Chaptered",
		DurationSec:    5,
		TranscriptText: segmentsFixtureText,
		SegmentsJSON:   sql.NullString{String: segmentsFixtureJSON, Valid: true},
	})
	require.NoError(t, err)
	return id
}

func TestTranscriptSaveWithSegmentsAutoGeneratesChapters(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)
	// Save makes two AI calls in order: recap, then chapters.
	stubTranscriptGenerator(t, &transcriptMockGen{responses: []string{transcriptMockRecapJSON, transcriptMockChaptersJSON}})

	transcriptSaveFlagFile = writeTranscriptFile(t, segmentsFixtureText)
	transcriptSaveFlagSegments = writeSegmentsFile(t, segmentsFixtureJSON)
	transcriptSaveFlagTitle = "Auto chapters"
	transcriptSaveFlagDuration = 5

	var buf bytes.Buffer
	transcriptSaveCmd.SetOut(&buf)
	require.NoError(t, transcriptSaveCmd.RunE(transcriptSaveCmd, nil))

	var env chaptersEnvelope
	require.NoError(t, json.Unmarshal(buf.Bytes(), &env))
	assert.True(t, env.RecapOK)
	require.NotNil(t, env.ChaptersOK, "chapters_ok must be reported when segments exist")
	assert.True(t, *env.ChaptersOK)
	require.NotNil(t, env.ChaptersError)
	assert.Equal(t, "", *env.ChaptersError)

	database, err := openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()
	tr, err := database.GetMeetingTranscript(env.TranscriptID)
	require.NoError(t, err)
	require.NotNil(t, tr)
	require.True(t, tr.ChaptersJSON.Valid, "chapters_json must be persisted after auto-generation")
	chapters, err := meeting.ParseChapters([]byte(tr.ChaptersJSON.String))
	require.NoError(t, err)
	assert.Equal(t, "Intro", chapters.Chapters[0].Title)

	run := findPipelineRun(t, database, "meeting_chapters")
	require.NotNil(t, run, "a meeting_chapters pipeline run must be recorded")
	assert.Equal(t, "done", run.Status)
}

func TestTranscriptSaveChaptersFailureKeepsExitZero(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)
	// Recap succeeds; the chapters call returns garbage → chapters fail,
	// but the envelope semantics stay exit-0 (the transcript row persisted).
	stubTranscriptGenerator(t, &transcriptMockGen{responses: []string{transcriptMockRecapJSON, `not json`}})

	transcriptSaveFlagFile = writeTranscriptFile(t, segmentsFixtureText)
	transcriptSaveFlagSegments = writeSegmentsFile(t, segmentsFixtureJSON)
	transcriptSaveFlagTitle = "Chapters fail"

	var buf bytes.Buffer
	transcriptSaveCmd.SetOut(&buf)
	require.NoError(t, transcriptSaveCmd.RunE(transcriptSaveCmd, nil))

	var env chaptersEnvelope
	require.NoError(t, json.Unmarshal(buf.Bytes(), &env))
	assert.True(t, env.RecapOK)
	require.NotNil(t, env.ChaptersOK)
	assert.False(t, *env.ChaptersOK)
	require.NotNil(t, env.ChaptersError)
	assert.NotEqual(t, "", *env.ChaptersError)

	database, err := openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()
	tr, err := database.GetMeetingTranscript(env.TranscriptID)
	require.NoError(t, err)
	require.NotNil(t, tr)
	assert.True(t, tr.SegmentsJSON.Valid, "segments must survive a chapters failure")
	assert.False(t, tr.ChaptersJSON.Valid, "failed generation must leave chapters_json NULL")
}

func TestTranscriptSaveWithoutSegmentsSkipsChapters(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)
	stubTranscriptGenerator(t, &transcriptMockGen{response: transcriptMockRecapJSON})

	transcriptSaveFlagFile = writeTranscriptFile(t, "plain transcript, no segments")

	var buf bytes.Buffer
	transcriptSaveCmd.SetOut(&buf)
	require.NoError(t, transcriptSaveCmd.RunE(transcriptSaveCmd, nil))

	var env chaptersEnvelope
	require.NoError(t, json.Unmarshal(buf.Bytes(), &env))
	assert.Nil(t, env.ChaptersOK, "no segments → chapters not attempted → no chapters_ok key")
	assert.Nil(t, env.ChaptersError)

	database, err := openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()
	run := findPipelineRun(t, database, "meeting_chapters")
	assert.Nil(t, run, "no meeting_chapters run must be recorded without segments")
}

func TestTranscriptChaptersGeneratesAndStores(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)
	mock := &transcriptMockGen{response: transcriptMockChaptersJSON}
	stubTranscriptGenerator(t, mock)

	database, err := openDBFromConfig()
	require.NoError(t, err)
	id := insertChapterTestTranscript(t, database)
	database.Close()

	var buf bytes.Buffer
	transcriptChaptersCmd.SetOut(&buf)
	require.NoError(t, transcriptChaptersCmd.RunE(transcriptChaptersCmd, []string{fmt.Sprint(id)}))

	var env struct {
		TranscriptID int64  `json:"transcript_id"`
		ChaptersJSON string `json:"chapters_json"`
	}
	require.NoError(t, json.Unmarshal(buf.Bytes(), &env))
	assert.Equal(t, id, env.TranscriptID)
	assert.Contains(t, env.ChaptersJSON, `"Intro"`)

	// The timecoded transcript (with speakers) travels in the user message.
	assert.Contains(t, mock.lastUserMessage, "[0:00] [Я] привет")

	database, err = openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()
	tr, err := database.GetMeetingTranscript(id)
	require.NoError(t, err)
	require.True(t, tr.ChaptersJSON.Valid, "chapters_json must be persisted")
	assert.Equal(t, env.ChaptersJSON, tr.ChaptersJSON.String)

	run := findPipelineRun(t, database, "meeting_chapters")
	require.NotNil(t, run)
	assert.Equal(t, "done", run.Status)
}

func TestTranscriptChaptersFailureExitsNonZeroAndStoresNothing(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)
	stubTranscriptGenerator(t, &transcriptMockGen{err: errors.New("boom")})

	database, err := openDBFromConfig()
	require.NoError(t, err)
	id := insertChapterTestTranscript(t, database)
	database.Close()

	err = transcriptChaptersCmd.RunE(transcriptChaptersCmd, []string{fmt.Sprint(id)})
	require.Error(t, err, "chapters failure must flip the exit code — nothing was persisted")
	assert.Contains(t, err.Error(), "boom")

	database, err = openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()
	tr, err := database.GetMeetingTranscript(id)
	require.NoError(t, err)
	assert.False(t, tr.ChaptersJSON.Valid, "failed generation must not write chapters_json")

	run := findPipelineRun(t, database, "meeting_chapters")
	require.NotNil(t, run)
	assert.Equal(t, "error", run.Status)
}

func TestTranscriptChaptersWithoutSegmentsFails(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)
	mock := &transcriptMockGen{response: transcriptMockChaptersJSON}
	stubTranscriptGenerator(t, mock)

	database, err := openDBFromConfig()
	require.NoError(t, err)
	id, err := database.InsertMeetingTranscript(db.MeetingTranscript{
		Title:          "Legacy",
		TranscriptText: "no segments here",
	})
	require.NoError(t, err)
	database.Close()

	err = transcriptChaptersCmd.RunE(transcriptChaptersCmd, []string{fmt.Sprint(id)})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no segments")
	assert.Equal(t, "", mock.lastUserMessage, "the AI must not be called without segments")
}

func TestTranscriptChaptersUnknownIDFails(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)
	stubTranscriptGenerator(t, &transcriptMockGen{response: transcriptMockChaptersJSON})

	err := transcriptChaptersCmd.RunE(transcriptChaptersCmd, []string{"9999"})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "not found")
}

// insertChapteredTranscript seeds a transcript row that already has chapters.
func insertChapteredTranscript(t *testing.T, database *db.DB) int64 {
	t.Helper()
	id, err := database.InsertMeetingTranscript(db.MeetingTranscript{
		Title:          "Weekly Sync",
		DurationSec:    5,
		TranscriptText: segmentsFixtureText,
		SegmentsJSON:   sql.NullString{String: segmentsFixtureJSON, Valid: true},
	})
	require.NoError(t, err)
	require.NoError(t, database.SetMeetingTranscriptChapters(id, transcriptMockChaptersJSON))
	return id
}

func TestTranscriptFollowupChapter(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)
	mock := &transcriptMockGen{response: "Team, per the sync: shipping d1; a1 owned."}
	stubTranscriptGenerator(t, mock)

	database, err := openDBFromConfig()
	require.NoError(t, err)
	id := insertChapteredTranscript(t, database)
	database.Close()

	transcriptFollowupChapter = 0
	var buf bytes.Buffer
	transcriptFollowupCmd.SetOut(&buf)
	require.NoError(t, transcriptFollowupCmd.RunE(transcriptFollowupCmd, []string{fmt.Sprint(id)}))

	var env struct {
		TranscriptID int64  `json:"transcript_id"`
		Chapter      *int   `json:"chapter"`
		Draft        string `json:"draft"`
	}
	require.NoError(t, json.Unmarshal(buf.Bytes(), &env))
	assert.Equal(t, id, env.TranscriptID)
	require.NotNil(t, env.Chapter)
	assert.Equal(t, 0, *env.Chapter)
	assert.Contains(t, env.Draft, "shipping d1")

	// Stated content only — the chapter's decisions and action items.
	assert.Contains(t, mock.lastUserMessage, "d1")
	assert.Contains(t, mock.lastUserMessage, "a1")

	// Nothing is persisted by a followup draft.
	database, err = openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()
	tr, err := database.GetMeetingTranscript(id)
	require.NoError(t, err)
	assert.Equal(t, transcriptMockChaptersJSON, tr.ChaptersJSON.String, "followup must not modify chapters_json")

	run := findPipelineRun(t, database, "meeting_followup")
	require.NotNil(t, run)
	assert.Equal(t, "done", run.Status)
}

func TestTranscriptFollowupWholeMeeting(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)
	mock := &transcriptMockGen{response: "whole-meeting draft"}
	stubTranscriptGenerator(t, mock)

	database, err := openDBFromConfig()
	require.NoError(t, err)
	id := insertChapteredTranscript(t, database)
	database.Close()

	// No --chapter → whole meeting (chapter null in the envelope).
	var buf bytes.Buffer
	transcriptFollowupCmd.SetOut(&buf)
	require.NoError(t, transcriptFollowupCmd.RunE(transcriptFollowupCmd, []string{fmt.Sprint(id)}))

	var env struct {
		Chapter *int   `json:"chapter"`
		Draft   string `json:"draft"`
	}
	require.NoError(t, json.Unmarshal(buf.Bytes(), &env))
	assert.Nil(t, env.Chapter, "whole-meeting draft must report chapter null")
	assert.Equal(t, "whole-meeting draft", env.Draft)
	assert.Contains(t, mock.lastUserMessage, "d1")
}

func TestTranscriptFollowupChapterOutOfRangeFails(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)
	stubTranscriptGenerator(t, &transcriptMockGen{response: "draft"})

	database, err := openDBFromConfig()
	require.NoError(t, err)
	id := insertChapteredTranscript(t, database)
	database.Close()

	transcriptFollowupChapter = 5
	err = transcriptFollowupCmd.RunE(transcriptFollowupCmd, []string{fmt.Sprint(id)})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "out of range")
}

func TestTranscriptFollowupNoChaptersFails(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)
	stubTranscriptGenerator(t, &transcriptMockGen{response: "draft"})

	database, err := openDBFromConfig()
	require.NoError(t, err)
	id := insertChapterTestTranscript(t, database) // segments, but no chapters
	database.Close()

	err = transcriptFollowupCmd.RunE(transcriptFollowupCmd, []string{fmt.Sprint(id)})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no chapters")
}

func TestTranscriptFollowupAIFailureExitsNonZero(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)
	stubTranscriptGenerator(t, &transcriptMockGen{err: errors.New("boom")})

	database, err := openDBFromConfig()
	require.NoError(t, err)
	id := insertChapteredTranscript(t, database)
	database.Close()

	err = transcriptFollowupCmd.RunE(transcriptFollowupCmd, []string{fmt.Sprint(id)})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "boom")

	database, err = openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()
	run := findPipelineRun(t, database, "meeting_followup")
	require.NotNil(t, run)
	assert.Equal(t, "error", run.Status)
}
