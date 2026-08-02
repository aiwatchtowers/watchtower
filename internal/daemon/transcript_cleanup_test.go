package daemon

import (
	"database/sql"
	"log"
	"os"
	"path/filepath"
	"testing"
	"time"

	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// newCleanupTestDaemon builds a Daemon with a test DB, suitable for calling
// phaseTranscriptAudioCleanup directly.
func newCleanupTestDaemon(t *testing.T) (*Daemon, *db.DB) {
	t.Helper()
	orch, cfg, wsDir := testDaemonWithTempHome(t)

	database, err := db.Open(wsDir + "/watchtower.db")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })

	d := New(orch, cfg)
	d.SetLogger(log.New(os.Stderr, "[test-transcript-cleanup] ", 0))
	d.SetDB(database)
	return d, database
}

// insertTranscriptWithAudio inserts a transcript row pointing at audioPath and
// backdates created_at to the given timestamp.
func insertTranscriptWithAudio(t *testing.T, database *db.DB, title, audioPath, createdAt string) int64 {
	t.Helper()
	id, err := database.InsertMeetingTranscript(db.MeetingTranscript{
		Title:          title,
		AudioPath:      sql.NullString{String: audioPath, Valid: true},
		TranscriptText: "hello world",
	})
	require.NoError(t, err)
	_, err = database.Exec(`UPDATE meeting_transcripts SET created_at = ? WHERE id = ?`, createdAt, id)
	require.NoError(t, err)
	return id
}

func TestPhaseTranscriptAudioCleanup(t *testing.T) {
	d, database := newCleanupTestDaemon(t)
	d.config.Transcripts.AudioRetentionDays = 30

	audioDir := t.TempDir()
	oldFile := filepath.Join(audioDir, "old-meeting.m4a")
	freshFile := filepath.Join(audioDir, "fresh-meeting.m4a")
	require.NoError(t, os.WriteFile(oldFile, []byte("old audio"), 0o644))
	require.NoError(t, os.WriteFile(freshFile, []byte("fresh audio"), 0o644))

	oldID := insertTranscriptWithAudio(t, database, "Old meeting", oldFile, "2020-01-01T10:00:00Z")
	freshID := insertTranscriptWithAudio(t, database, "Fresh meeting", freshFile, "2099-01-01T10:00:00Z")

	d.phaseTranscriptAudioCleanup()

	// Expired: file removed from disk, audio_path NULLed, transcript text kept.
	_, statErr := os.Stat(oldFile)
	assert.True(t, os.IsNotExist(statErr), "expired audio file should be deleted")
	oldTr, err := database.GetMeetingTranscript(oldID)
	require.NoError(t, err)
	assert.False(t, oldTr.AudioPath.Valid, "expired transcript audio_path should be NULL")
	assert.Equal(t, "hello world", oldTr.TranscriptText)

	// Fresh: file intact, audio_path still set.
	_, statErr = os.Stat(freshFile)
	assert.NoError(t, statErr, "fresh audio file should be untouched")
	freshTr, err := database.GetMeetingTranscript(freshID)
	require.NoError(t, err)
	assert.True(t, freshTr.AudioPath.Valid, "fresh transcript audio_path should stay set")
	assert.Equal(t, freshFile, freshTr.AudioPath.String)
}

func TestPhaseTranscriptAudioCleanupMissingFileIdempotent(t *testing.T) {
	d, database := newCleanupTestDaemon(t)
	d.config.Transcripts.AudioRetentionDays = 30

	// Expired row whose audio file was already deleted manually.
	goneFile := filepath.Join(t.TempDir(), "already-gone.m4a")
	id := insertTranscriptWithAudio(t, database, "Gone meeting", goneFile, "2020-01-01T10:00:00Z")

	d.phaseTranscriptAudioCleanup()

	tr, err := database.GetMeetingTranscript(id)
	require.NoError(t, err)
	assert.False(t, tr.AudioPath.Valid, "audio_path should be NULLed even when the file is already gone")
	assert.Equal(t, "hello world", tr.TranscriptText)
}

func TestPhaseTranscriptAudioCleanupRemoveFailureKeepsAudioPath(t *testing.T) {
	d, database := newCleanupTestDaemon(t)
	d.config.Transcripts.AudioRetentionDays = 30

	// audio_path points at a NON-EMPTY directory, so os.Remove fails with a
	// real error (ENOTEMPTY), not IsNotExist.
	undeletable := filepath.Join(t.TempDir(), "rec_undeletable")
	require.NoError(t, os.MkdirAll(undeletable, 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(undeletable, "inner.txt"), []byte("x"), 0o644))

	id := insertTranscriptWithAudio(t, database, "Undeletable", undeletable, "2020-01-01T10:00:00Z")

	d.phaseTranscriptAudioCleanup()

	_, statErr := os.Stat(undeletable)
	assert.NoError(t, statErr, "the non-empty directory must survive the failed remove")
	tr, err := database.GetMeetingTranscript(id)
	require.NoError(t, err)
	assert.True(t, tr.AudioPath.Valid, "audio_path must be KEPT after a real remove failure so a later run retries")
	assert.Equal(t, undeletable, tr.AudioPath.String)
}

// writeAgedFile creates a file and backdates its modification time.
func writeAgedFile(t *testing.T, path string, mtime time.Time) {
	t.Helper()
	require.NoError(t, os.WriteFile(path, []byte("audio"), 0o644))
	require.NoError(t, os.Chtimes(path, mtime, mtime))
}

func TestPhaseTranscriptAudioCleanupOrphanScan(t *testing.T) {
	d, database := newCleanupTestDaemon(t)
	d.config.Transcripts.AudioRetentionDays = 30

	recDir := t.TempDir()
	d.config.Transcripts.RecordingsDir = recDir
	beyondRetention := time.Now().Add(-40 * 24 * time.Hour)

	// Orphan (no DB row) older than the retention window → deleted.
	oldOrphan := filepath.Join(recDir, "rec_2020-01-01_10-00-00.m4a")
	writeAgedFile(t, oldOrphan, beyondRetention)

	// Old file, but referenced by a fresh transcript row → kept.
	referenced := filepath.Join(recDir, "rec_referenced.caf")
	writeAgedFile(t, referenced, beyondRetention)
	insertTranscriptWithAudio(t, database, "Referenced", referenced, "2099-01-01T10:00:00Z")

	// Young orphan (inside the retention window) → kept.
	youngOrphan := filepath.Join(recDir, "rec_young.m4a")
	require.NoError(t, os.WriteFile(youngOrphan, []byte("audio"), 0o644))

	// Old file whose name does not match rec_* → kept.
	nonMatching := filepath.Join(recDir, "notes.m4a")
	writeAgedFile(t, nonMatching, beyondRetention)

	d.phaseTranscriptAudioCleanup()

	_, statErr := os.Stat(oldOrphan)
	assert.True(t, os.IsNotExist(statErr), "expired orphan recording must be deleted")
	assert.FileExists(t, referenced, "recording referenced by a transcript row must be kept")
	assert.FileExists(t, youngOrphan, "orphan younger than the retention window must be kept")
	assert.FileExists(t, nonMatching, "files not matching rec_* must never be touched")
}

func TestPhaseTranscriptAudioCleanupRetentionDisabled(t *testing.T) {
	d, database := newCleanupTestDaemon(t)
	d.config.Transcripts.AudioRetentionDays = 0 // disabled

	audioFile := filepath.Join(t.TempDir(), "keep-forever.m4a")
	require.NoError(t, os.WriteFile(audioFile, []byte("audio"), 0o644))
	id := insertTranscriptWithAudio(t, database, "Old but kept", audioFile, "2020-01-01T10:00:00Z")

	d.phaseTranscriptAudioCleanup()

	_, statErr := os.Stat(audioFile)
	assert.NoError(t, statErr, "retention disabled: file must not be deleted")
	tr, err := database.GetMeetingTranscript(id)
	require.NoError(t, err)
	assert.True(t, tr.AudioPath.Valid, "retention disabled: audio_path must stay set")
}
