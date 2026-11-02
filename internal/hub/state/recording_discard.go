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
// (Settings → Mobile, plan 3 Task 23): the audio the hub kept at
// <recordingsDir>/<upload_id>.m4a and the job's row go now instead of at
// the 31-day prune. Only a failed job is discarded (ErrJobState otherwise:
// a queued, claimed or done job is left as it is); no such job is
// ErrNoRecordingJob. A missing audio file is no error. The file goes first,
// as in PruneRecordingJobs, so a crash between the two leaves a row the
// next Discard or prune finishes.
func (s *Store) DiscardRecording(recordingsDir, uploadID string) error {
	job, err := s.RecordingJob(uploadID)
	if err != nil {
		return err
	}
	if job.Status != RecordingFailed {
		return ErrJobState
	}
	if recordingsDir != "" && uploadID != "" && filepath.Base(uploadID) == uploadID {
		if err := os.Remove(filepath.Join(recordingsDir, uploadID+".m4a")); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return fmt.Errorf("removing a recording's audio: %w", err)
		}
	}
	return s.write(func(tx *sql.Tx) error {
		res, err := tx.Exec(`DELETE FROM recording_jobs WHERE upload_id = ? AND status = 'failed'`, uploadID)
		if err != nil {
			return fmt.Errorf("discarding a recording: %w", err)
		}
		if n, err := res.RowsAffected(); err == nil && n == 0 {
			return ErrJobState // it changed state meanwhile
		}
		return nil
	})
}
