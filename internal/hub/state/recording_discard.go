package state

import (
	"database/sql"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
)

// DiscardRecording is the owner's Discard of a failed phone recording
// (Settings → Mobile, plan 3 Task 23): the job's row and the audio the hub
// kept at <recordingsDir>/<upload_id>.m4a go now instead of at the 31-day
// prune. The status check and the DELETE are one write transaction, so a
// claim racing in (a retry) either sees no row or keeps its job; the file
// goes only after the DELETE matched. Only a failed job is discarded
// (ErrJobState otherwise); no such job is ErrNoRecordingJob. A missing
// audio file is no error; a file that cannot be removed is reported, the
// row already gone (nothing would ever prune it otherwise, so the error
// says so).
// discardAfterRead runs inside the Discard's transaction after its status
// read (a test seam: an interleaved claim).
var discardAfterRead = func() {}

func (s *Store) DiscardRecording(recordingsDir, uploadID string) error {
	err := s.write(func(tx *sql.Tx) error {
		job, err := recordingJobTx(tx, uploadID)
		if err != nil {
			return err
		}
		if job.Status != RecordingFailed {
			return ErrJobState
		}
		discardAfterRead()
		if _, err := tx.Exec(`DELETE FROM recording_jobs WHERE upload_id = ? AND status = 'failed'`, uploadID); err != nil {
			return fmt.Errorf("discarding a recording: %w", err)
		}
		return nil
	})
	if err != nil {
		return err
	}
	if recordingsDir == "" || uploadID == "" || filepath.Base(uploadID) != uploadID {
		return nil
	}
	if err := os.Remove(filepath.Join(recordingsDir, uploadID+".m4a")); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("removing a discarded recording's audio: %w", err)
	}
	return nil
}
