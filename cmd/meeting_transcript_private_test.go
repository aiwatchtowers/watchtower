package cmd

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// Guards for MEETPRIV-01/04/05 (docs/inventory/meetings.md) at the CLI.

func TestMeetPriv01_SavePrivateGeneratesNothing(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)
	gen := &transcriptMockGen{response: transcriptMockRecapJSON}
	stubTranscriptGenerator(t, gen)

	transcriptSaveFlagFile = writeTranscriptFile(t, longSegmentsFixtureText)
	transcriptSaveFlagSegments = writeSegmentsFile(t, longSegmentsFixtureJSON)
	transcriptSaveFlagTitle = "Private one"
	transcriptSaveFlagPrivate = true

	var buf bytes.Buffer
	transcriptSaveCmd.SetOut(&buf)
	require.NoError(t, transcriptSaveCmd.RunE(transcriptSaveCmd, nil))

	env := rawEnvelope(t, buf.Bytes())
	assert.Equal(t, false, env["recap_ok"])
	assert.Equal(t, true, env["recap_skipped"], "recap_skipped stays a Bool (the Swift decoder's type)")
	assert.Equal(t, "private", env["recap_skipped_reason"])
	assert.Equal(t, false, env["chapters_ok"])
	assert.Equal(t, true, env["chapters_skipped"])
	assert.Equal(t, "private", env["chapters_skipped_reason"])
	assert.Equal(t, true, env["segments_ok"])
	assert.Zero(t, gen.calls, "a private save must never call the generator")

	database, err := openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()
	tr, err := database.GetMeetingTranscript(int64(env["transcript_id"].(float64)))
	require.NoError(t, err)
	require.NotNil(t, tr)
	assert.True(t, tr.Private)
	assert.True(t, tr.SegmentsJSON.Valid, "the transcript itself is saved in full")
	assert.False(t, tr.SummaryJSON.Valid)
	assert.False(t, tr.ChaptersJSON.Valid)
	assert.Nil(t, findPipelineRun(t, database, "meeting_transcript"))
}

// TestMeetPriv01_SaveTooShortKeepsBoolSkip pins that the too-short skip keeps
// its original envelope: Bool recap_skipped, no reason and no chapters keys.
func TestMeetPriv01_SaveTooShortKeepsBoolSkip(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)
	stubTranscriptGenerator(t, &transcriptMockGen{response: transcriptMockRecapJSON})
	transcriptSaveFlagFile = writeTranscriptFile(t, "short")

	var buf bytes.Buffer
	transcriptSaveCmd.SetOut(&buf)
	require.NoError(t, transcriptSaveCmd.RunE(transcriptSaveCmd, nil))
	env := rawEnvelope(t, buf.Bytes())
	assert.Equal(t, true, env["recap_skipped"])
	assert.NotContains(t, env, "recap_skipped_reason")
	assert.NotContains(t, env, "chapters_skipped")
	assert.NotContains(t, env, "chapters_skipped_reason")
}

func TestMeetPriv01_AICommandsRefusePrivate(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)
	gen := &transcriptMockGen{response: transcriptMockRecapJSON}
	stubTranscriptGenerator(t, gen)

	database, err := openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()
	id := insertChapteredTranscript(t, database)
	_, err = database.SetMeetingTranscriptPrivate(id, true)
	require.NoError(t, err)
	before, err := database.GetMeetingTranscript(id)
	require.NoError(t, err)

	for _, c := range []*cobra.Command{transcriptRecapCmd, transcriptNotesCmd, transcriptChaptersCmd, transcriptFollowupCmd} {
		var out bytes.Buffer
		c.SetOut(&out)
		err := c.RunE(c, []string{fmt.Sprint(id)})
		require.Error(t, err, c.Name())
		assert.Equal(t, fmt.Sprintf("recording %d is private", id), err.Error(), c.Name())
		assert.Empty(t, out.String(), c.Name())
	}
	assert.Zero(t, gen.calls)

	after, err := database.GetMeetingTranscript(id)
	require.NoError(t, err)
	assert.Equal(t, before, after, "a refused command writes nothing")
	for _, p := range []string{"meeting_transcript", "meeting_notes", "meeting_chapters", "meeting_followup"} {
		assert.Nil(t, findPipelineRun(t, database, p), p)
	}
}

// TestMeetPriv01_SaveGeneratorsRefuseRowFlippedPrivate pins the save path's
// own check: a row the Desktop turns private after the insert but before the
// recap and chapters run reaches no generator and gets nothing written.
func TestMeetPriv01_SaveGeneratorsRefuseRowFlippedPrivate(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)
	gen := &transcriptMockGen{response: transcriptMockRecapJSON}
	stubTranscriptGenerator(t, gen)

	cfg, database, err := transcriptEnv()
	require.NoError(t, err)
	defer database.Close()
	id, err := database.InsertMeetingTranscript(db.MeetingTranscript{
		Title: "Flipped", DurationSec: 5, TranscriptText: longSegmentsFixtureText,
		SegmentsJSON: sql.NullString{String: longSegmentsFixtureJSON, Valid: true},
	})
	require.NoError(t, err)
	_, err = database.SetMeetingTranscriptPrivate(id, true)
	require.NoError(t, err)

	var errOut bytes.Buffer
	_, chaptersOutcome, recapErr := runSaveGenerations(context.Background(), database, cfg, id, longSegmentsFixtureText, true, &errOut)
	want := fmt.Sprintf("recording %d is private", id)
	require.Error(t, recapErr)
	assert.Equal(t, want, recapErr.Error())
	require.NotNil(t, chaptersOutcome)
	require.Error(t, *chaptersOutcome)
	assert.Equal(t, want, (*chaptersOutcome).Error())
	assert.Zero(t, gen.calls)

	tr, err := database.GetMeetingTranscript(id)
	require.NoError(t, err)
	assert.False(t, tr.SummaryJSON.Valid)
	assert.False(t, tr.ChaptersJSON.Valid)
	assert.Nil(t, findPipelineRun(t, database, "meeting_transcript"))
	assert.Nil(t, findPipelineRun(t, database, "meeting_chapters"))
}

func TestMeetPriv04_PrivateCommandTogglesAndShowReports(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)
	gen := &transcriptMockGen{response: transcriptMockRecapJSON}
	stubTranscriptGenerator(t, gen)

	database, err := openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()
	id := insertChapterTestTranscript(t, database)

	show := func() map[string]any {
		var buf bytes.Buffer
		transcriptShowCmd.SetOut(&buf)
		require.NoError(t, transcriptShowCmd.RunE(transcriptShowCmd, []string{fmt.Sprint(id)}))
		return rawEnvelope(t, buf.Bytes())
	}
	assert.Equal(t, false, show()["private"])

	for _, tc := range []struct {
		arg  string
		want bool
	}{{"on", true}, {"off", false}} {
		var buf bytes.Buffer
		transcriptPrivateCmd.SetOut(&buf)
		require.NoError(t, transcriptPrivateCmd.RunE(transcriptPrivateCmd, []string{fmt.Sprint(id), tc.arg}))
		assert.JSONEq(t, fmt.Sprintf(`{"id":%d,"private":%t}`, id, tc.want), buf.String())
		assert.Equal(t, tc.want, show()["private"])
	}

	err = transcriptPrivateCmd.RunE(transcriptPrivateCmd, []string{fmt.Sprint(id), "yes"})
	assert.ErrorContains(t, err, `invalid value "yes"`)
	err = transcriptPrivateCmd.RunE(transcriptPrivateCmd, []string{"999999", "on"})
	assert.EqualError(t, err, "transcript 999999 not found")

	// Turning private on and off generates nothing by itself.
	assert.Zero(t, gen.calls, "the private toggle must never call the generator")
	tr, err := database.GetMeetingTranscript(id)
	require.NoError(t, err)
	assert.False(t, tr.SummaryJSON.Valid)
	assert.False(t, tr.ChaptersJSON.Valid)

	// Turning private off re-enables the AI commands: chapters reaches the
	// generator instead of being refused.
	var out bytes.Buffer
	transcriptChaptersCmd.SetOut(&out)
	_ = transcriptChaptersCmd.RunE(transcriptChaptersCmd, []string{fmt.Sprint(id)})
	assert.Equal(t, 1, gen.calls, "chapters must reach the generator once private is off")
}

func TestMeetPriv05_ExportPrivateToFile0600(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)

	database, err := openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()
	id, err := database.InsertMeetingTranscript(db.MeetingTranscript{
		Title: "Private sync", DurationSec: 5, Private: true,
		TranscriptText: "[Я] привет",
		SegmentsJSON: sql.NullString{Valid: true, String: `[
			{"idx":0,"start_sec":0,"end_sec":2.5,"speaker":"Я","text":"привет","deleted":false},
			{"idx":1,"start_sec":2.5,"end_sec":5,"speaker":"Speaker 1","text":"удалено","deleted":true}]`},
	})
	require.NoError(t, err)

	out := filepath.Join(t.TempDir(), "sync.srt")
	transcriptExportFlagFormat, transcriptExportFlagOutput = "srt", out
	var stdout bytes.Buffer
	transcriptExportCmd.SetOut(&stdout)
	require.NoError(t, transcriptExportCmd.RunE(transcriptExportCmd, []string{fmt.Sprint(id)}))
	assert.Empty(t, stdout.String())

	info, err := os.Stat(out)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm())
	data, err := os.ReadFile(out)
	require.NoError(t, err)
	assert.Equal(t, "1\n00:00:00,000 --> 00:00:02,500\nЯ: привет\n\n", string(data))

	// stdout, json: the private flag travels with it.
	transcriptExportFlagFormat, transcriptExportFlagOutput = "json", ""
	stdout.Reset()
	require.NoError(t, transcriptExportCmd.RunE(transcriptExportCmd, []string{fmt.Sprint(id)}))
	var j map[string]any
	require.NoError(t, json.Unmarshal(stdout.Bytes(), &j))
	assert.Equal(t, true, j["private"])
	assert.Len(t, j["segments"], 1)
}

func TestTranscriptExport_SRTWithoutSegmentsFails(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)

	database, err := openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()
	id, err := database.InsertMeetingTranscript(db.MeetingTranscript{Title: "Legacy", TranscriptText: "flat"})
	require.NoError(t, err)

	transcriptExportFlagFormat = "srt"
	err = transcriptExportCmd.RunE(transcriptExportCmd, []string{fmt.Sprint(id)})
	assert.EqualError(t, err, "no timed segments")

	transcriptExportFlagFormat = "txt"
	var stdout bytes.Buffer
	transcriptExportCmd.SetOut(&stdout)
	require.NoError(t, transcriptExportCmd.RunE(transcriptExportCmd, []string{fmt.Sprint(id)}))
	assert.Equal(t, "flat\n", stdout.String())

	err = transcriptExportCmd.RunE(transcriptExportCmd, []string{"999999"})
	assert.EqualError(t, err, "transcript 999999 not found")
}
