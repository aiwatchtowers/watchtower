package state

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"time"
)

// hub_meta keys of the Desktop heartbeat (spec §8 p. 4a): the last beat and
// whether any ever arrived. The same signal is "desktop host" for the
// clipboard fallback and "transcriber present" for recordings.
const (
	MetaDesktopAt   = "desktop_at"
	MetaDesktopSeen = "desktop_seen"
)

// DesktopFreshFor is how long a heartbeat counts as fresh (Desktop beats every
// 30 s).
const DesktopFreshFor = 90 * time.Second

// Recording job statuses.
const (
	RecordingQueued  = "queued"
	RecordingClaimed = "claimed"
	RecordingDone    = "done"
	RecordingFailed  = "failed"
)

// Errors of the job verbs.
var (
	ErrNoRecordingJob = errors.New("state: no such recording job")
	ErrJobState       = errors.New("state: the recording job is not in a state that allows this")
)

// RecordingJob is one queue row: ids, status, error class and times.
type RecordingJob struct {
	UploadID     string
	DeviceID     string
	Status       string
	TranscriptID *int64
	ErrorClass   string
	CreatedAt    time.Time
	ClaimedAt    time.Time
	FinishedAt   time.Time
}

// Heartbeat records a Desktop heartbeat at now and returns it.
func (s *Store) Heartbeat(now time.Time) error {
	return s.write(func(tx *sql.Tx) error {
		if err := SetMetaTx(tx, MetaDesktopAt, strconv.FormatFloat(toReal(now), 'f', 3, 64)); err != nil {
			return err
		}
		return SetMetaTx(tx, MetaDesktopSeen, "1")
	})
}

// DesktopHost reports whether Desktop's heartbeat is fresh (89 s old yes,
// 91 s old no) and whether any heartbeat ever arrived (stays true).
func (s *Store) DesktopHost(now time.Time) (fresh, everSeen bool, err error) {
	seen, ok, err := s.Meta(MetaDesktopSeen)
	if err != nil {
		return false, false, err
	}
	everSeen = ok && seen == "1"
	if !everSeen {
		return false, false, nil
	}
	raw, ok, err := s.Meta(MetaDesktopAt)
	if err != nil || !ok {
		return false, true, err
	}
	f, err := strconv.ParseFloat(raw, 64)
	if err != nil {
		return false, true, fmt.Errorf("reading the Desktop heartbeat: %w", err)
	}
	return now.Sub(fromReal(f)) <= DesktopFreshFor, true, nil
}

// DesktopHeartbeatAt is the last heartbeat; ok is false when none arrived.
func (s *Store) DesktopHeartbeatAt() (time.Time, bool, error) {
	raw, ok, err := s.Meta(MetaDesktopAt)
	if err != nil || !ok {
		return time.Time{}, false, err
	}
	f, err := strconv.ParseFloat(raw, 64)
	if err != nil {
		return time.Time{}, false, fmt.Errorf("reading the Desktop heartbeat: %w", err)
	}
	return fromReal(f), true, nil
}

// HasRecording reports whether the upload was ever ingested: a job row, or a
// phone_recordings row an adopted Swift sidecar holds.
func (s *Store) HasRecording(uploadID string) (bool, error) {
	var n int
	err := s.db.QueryRow(`SELECT
		(SELECT COUNT(*) FROM recording_jobs WHERE upload_id = ?) +
		(SELECT COUNT(*) FROM phone_recordings WHERE upload_id = ?)`, uploadID, uploadID).Scan(&n)
	if err != nil {
		return false, fmt.Errorf("reading the recording queue: %w", err)
	}
	return n > 0, nil
}

// QueueRecording adds a queued job; a second call for the same upload keeps
// the first row.
func (s *Store) QueueRecording(uploadID, deviceID string, now time.Time) error {
	return s.write(func(tx *sql.Tx) error {
		_, err := tx.Exec(`INSERT OR IGNORE INTO recording_jobs (upload_id, device_id, status, created_at)
			VALUES (?, ?, 'queued', ?)`, uploadID, deviceKey(deviceID), toReal(now))
		if err != nil {
			return fmt.Errorf("queueing a recording: %w", err)
		}
		return nil
	})
}

// ClaimRecording moves a queued job to claimed (Desktop took it). A claimed
// job claims again unchanged (Desktop restarted); a finished one is
// ErrJobState.
func (s *Store) ClaimRecording(uploadID string, now time.Time) (RecordingJob, error) {
	err := s.write(func(tx *sql.Tx) error {
		job, err := recordingJobTx(tx, uploadID)
		if err != nil {
			return err
		}
		switch job.Status {
		case RecordingClaimed:
			return nil
		case RecordingQueued:
			_, err = tx.Exec(`UPDATE recording_jobs SET status = 'claimed', claimed_at = ? WHERE upload_id = ?`,
				toReal(now), uploadID)
			return err
		}
		return ErrJobState
	})
	if err != nil {
		return RecordingJob{}, err
	}
	return s.RecordingJob(uploadID)
}

var errClassRE = regexp.MustCompile(`^[a-z][a-z0-9_]{0,39}$`)

// ErrorClass is what the queue keeps of an error: the class when it already
// is one (lower-case word with underscores), else "other". Text never lands
// in a row.
func ErrorClass(s string) string {
	if errClassRE.MatchString(s) {
		return s
	}
	return "other"
}

// FinishRecording ends a claimed job: failed with errClass (stored as its
// class only) when errClass is set, else done with the transcript id. A job
// finished already is ErrJobState (the same outcome again is a no-op).
func (s *Store) FinishRecording(uploadID string, transcriptID *int64, errClass string, now time.Time) (RecordingJob, error) {
	status, class := RecordingDone, ""
	if errClass != "" {
		status, class = RecordingFailed, ErrorClass(errClass)
		transcriptID = nil
	}
	err := s.write(func(tx *sql.Tx) error {
		job, err := recordingJobTx(tx, uploadID)
		if err != nil {
			return err
		}
		if job.Status == RecordingDone || job.Status == RecordingFailed {
			if job.Status == status && job.ErrorClass == class && equalID(job.TranscriptID, transcriptID) {
				return nil
			}
			return ErrJobState
		}
		var cls any
		if class != "" {
			cls = class
		}
		_, err = tx.Exec(`UPDATE recording_jobs SET status = ?, transcript_id = ?, error_class = ?, finished_at = ?
			WHERE upload_id = ?`, status, transcriptID, cls, toReal(now), uploadID)
		return err
	})
	if err != nil {
		return RecordingJob{}, err
	}
	return s.RecordingJob(uploadID)
}

func equalID(a, b *int64) bool {
	if a == nil || b == nil {
		return a == b
	}
	return *a == *b
}

// RecordingJob reads one job; ErrNoRecordingJob when absent.
func (s *Store) RecordingJob(uploadID string) (RecordingJob, error) {
	tx, err := s.db.BeginTx(context.Background(), &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return RecordingJob{}, fmt.Errorf("reading the recording queue: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	return recordingJobTx(tx, uploadID)
}

func recordingJobTx(tx *sql.Tx, uploadID string) (RecordingJob, error) {
	var (
		j                 RecordingJob
		tid               sql.NullInt64
		class             sql.NullString
		created           float64
		claimed, finished sql.NullFloat64
	)
	err := tx.QueryRow(`SELECT upload_id, device_id, status, transcript_id, error_class, created_at, claimed_at, finished_at
		FROM recording_jobs WHERE upload_id = ?`, uploadID).
		Scan(&j.UploadID, &j.DeviceID, &j.Status, &tid, &class, &created, &claimed, &finished)
	if errors.Is(err, sql.ErrNoRows) {
		return RecordingJob{}, ErrNoRecordingJob
	}
	if err != nil {
		return RecordingJob{}, fmt.Errorf("reading the recording queue: %w", err)
	}
	if tid.Valid {
		j.TranscriptID = &tid.Int64
	}
	j.ErrorClass = class.String
	j.CreatedAt = fromReal(created)
	if claimed.Valid {
		j.ClaimedAt = fromReal(claimed.Float64)
	}
	if finished.Valid {
		j.FinishedAt = fromReal(finished.Float64)
	}
	return j, nil
}
