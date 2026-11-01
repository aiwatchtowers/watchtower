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
// the first one (protocol §9; desktop_seen_at replaces Plan 1b's
// desktop_seen flag, which a sidecar may still hold). The same signal is
// "desktop host" for the clipboard fallback and "transcriber present" for
// recordings. MetaRecordings is the owner's recording switch, "on" | "off".
const (
	MetaDesktopAt     = "desktop_at"
	MetaDesktopSeen   = "desktop_seen"
	MetaDesktopSeenAt = "desktop_seen_at"
	MetaRecordings    = "recordings"
)

// The switch's stored values.
const (
	RecordingsOn  = "on"
	RecordingsOff = "off"
)

// ErrNoTranscriber refuses turning recordings on where no Desktop
// transcriber heartbeat ever arrived (a headless host never publishes on).
var ErrNoTranscriber = errors.New("this host has no transcriber")

// HeldUploadMaxAge is how long an upload may stay held after its first
// hold: then it gets the final failed/expired.
const HeldUploadMaxAge = 7 * 24 * time.Hour

// held_uploads.outcome values: how a hold ended.
const (
	HeldReceived     = "received"
	HeldNotSupported = "not_supported"
	HeldExpired      = "expired"
	HeldFailed       = "failed" // any other final failure (its class is in relay_processed)
)

// HeldUpload is one unsettled held_uploads row: ids and the first hold.
type HeldUpload struct {
	UploadID, DeviceID string
	HeldAt             time.Time
}

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

// The phases of a claimed job Desktop reports (RecordingProgress).
const (
	PhaseTranscribing = "transcribing"
	PhaseDiarizing    = "diarizing"
	PhaseSummarizing  = "summarizing"
)

// Errors of the job verbs.
var (
	ErrNoRecordingJob = errors.New("state: no such recording job")
	ErrJobState       = errors.New("state: the recording job is not in a state that allows this")
	// ErrBadProgress refuses an unknown phase, a percent outside 0...100 or a
	// percent with a phase other than transcribing.
	ErrBadProgress = errors.New("state: not a recording progress")
)

// RecordingJob is one queue row: ids, status, error class, Desktop's phase
// and percent of a claimed job, and times.
type RecordingJob struct {
	UploadID     string
	DeviceID     string
	Status       string
	TranscriptID *int64
	ErrorClass   string
	Phase        string // "" until Desktop reported one
	Percent      *int   // only while transcribing
	CreatedAt    time.Time
	ClaimedAt    time.Time
	FinishedAt   time.Time
}

func realMeta(t time.Time) string { return strconv.FormatFloat(toReal(t), 'f', 3, 64) }

// Heartbeat records a Desktop heartbeat at now; the first one also sets
// desktop_seen_at, which nothing clears.
func (s *Store) Heartbeat(now time.Time) error {
	return s.write(func(tx *sql.Tx) error {
		if err := SetMetaTx(tx, MetaDesktopAt, realMeta(now)); err != nil {
			return err
		}
		if _, ok, err := MetaTx(tx, MetaDesktopSeenAt); err != nil || ok {
			return err
		}
		return SetMetaTx(tx, MetaDesktopSeenAt, realMeta(now))
	})
}

// carryDesktopSeen gives a Plan 1b sidecar (desktop_seen = "1", no
// desktop_seen_at) its desktop_seen_at from desktop_at, once (Open).
func (s *Store) carryDesktopSeen() error {
	return s.write(func(tx *sql.Tx) error {
		if _, ok, err := MetaTx(tx, MetaDesktopSeenAt); err != nil || ok {
			return err
		}
		if seen, ok, err := MetaTx(tx, MetaDesktopSeen); err != nil || !ok || seen != "1" {
			return err
		}
		at, ok, err := MetaTx(tx, MetaDesktopAt)
		if err != nil || !ok {
			return err
		}
		return SetMetaTx(tx, MetaDesktopSeenAt, at)
	})
}

// DesktopSeenAt is the first Desktop heartbeat; ok is false when none ever
// arrived (a Plan 1b flag counts once an Open carried it over).
func (s *Store) DesktopSeenAt() (time.Time, bool, error) {
	raw, ok, err := s.Meta(MetaDesktopSeenAt)
	if err != nil || !ok {
		return time.Time{}, false, err
	}
	f, err := strconv.ParseFloat(raw, 64)
	if err != nil {
		return time.Time{}, false, fmt.Errorf("reading the first Desktop heartbeat: %w", err)
	}
	return fromReal(f), true, nil
}

// Recordings is the recording switch: the stored value when the owner set
// one (stored), else on iff a Desktop heartbeat ever arrived.
func (s *Store) Recordings() (on, stored bool, err error) {
	v, ok, err := s.Meta(MetaRecordings)
	if err != nil {
		return false, false, err
	}
	if ok {
		return v != RecordingsOff, true, nil
	}
	_, seen, err := s.DesktopSeenAt()
	return seen, false, err
}

// SetRecordings stores the switch. On is ErrNoTranscriber (nothing stored)
// when no Desktop heartbeat ever arrived.
func (s *Store) SetRecordings(on bool) error {
	return s.write(func(tx *sql.Tx) error {
		if !on {
			return SetMetaTx(tx, MetaRecordings, RecordingsOff)
		}
		_, seenAt, err := MetaTx(tx, MetaDesktopSeenAt)
		if err != nil {
			return err
		}
		if !seenAt {
			return ErrNoTranscriber
		}
		return SetMetaTx(tx, MetaRecordings, RecordingsOn)
	})
}

// HoldUpload records that uploadID was answered held at. An unsettled row
// keeps its first hold's time; a settled one (the phone sent the upload
// again) is held anew from at.
func HoldUpload(tx *sql.Tx, uploadID, deviceID string, at time.Time) error {
	_, err := tx.Exec(`INSERT INTO held_uploads (upload_id, device_id, held_at) VALUES (?, ?, ?)
		ON CONFLICT(upload_id) DO UPDATE SET device_id = excluded.device_id, held_at = excluded.held_at,
			outcome = NULL, settled_at = NULL
		WHERE held_uploads.outcome IS NOT NULL`, uploadID, deviceKey(deviceID), toReal(at))
	if err != nil {
		return fmt.Errorf("holding a recording upload: %w", err)
	}
	return nil
}

// SettleHeldUpload ends uploadID's hold with outcome (HeldReceived,
// HeldNotSupported, HeldExpired or HeldFailed; the column's CHECK refuses
// anything else). An upload not held, or settled already, is left as it is.
func SettleHeldUpload(tx *sql.Tx, uploadID, outcome string, at time.Time) error {
	_, err := tx.Exec(`UPDATE held_uploads SET outcome = ?, settled_at = ? WHERE upload_id = ? AND outcome IS NULL`,
		outcome, toReal(at), uploadID)
	if err != nil {
		return fmt.Errorf("settling a held recording upload: %w", err)
	}
	return nil
}

// HeldAt is the first hold of an upload still held; ok is false when it is
// not held (never, or settled).
func (s *Store) HeldAt(uploadID string) (time.Time, bool, error) {
	var at float64
	err := s.db.QueryRow(`SELECT held_at FROM held_uploads WHERE upload_id = ? AND outcome IS NULL`, uploadID).Scan(&at)
	if errors.Is(err, sql.ErrNoRows) {
		return time.Time{}, false, nil
	}
	if err != nil {
		return time.Time{}, false, fmt.Errorf("reading a held upload: %w", err)
	}
	return fromReal(at), true, nil
}

// HeldUploads lists the unsettled held uploads, first held first.
func (s *Store) HeldUploads() ([]HeldUpload, error) {
	rows, err := s.db.Query(`SELECT upload_id, device_id, held_at FROM held_uploads
		WHERE outcome IS NULL ORDER BY held_at, upload_id`)
	if err != nil {
		return nil, fmt.Errorf("reading the held uploads: %w", err)
	}
	defer rows.Close()
	var out []HeldUpload
	for rows.Next() {
		var (
			h  HeldUpload
			at float64
		)
		if err := rows.Scan(&h.UploadID, &h.DeviceID, &at); err != nil {
			return nil, fmt.Errorf("reading the held uploads: %w", err)
		}
		h.HeldAt = fromReal(at)
		out = append(out, h)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading the held uploads: %w", err)
	}
	return out, nil
}

// DesktopHost reports whether Desktop's heartbeat is fresh (89 s old yes,
// 91 s old no) and whether any heartbeat ever arrived (stays true).
func (s *Store) DesktopHost(now time.Time) (fresh, everSeen bool, err error) {
	_, everSeen, err = s.DesktopSeenAt()
	if err != nil {
		return false, false, err
	}
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

// FinishRecording ends a claimed job (a job never claimed is ErrJobState): failed with errClass (stored as its
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
		if job.Status == RecordingQueued {
			return ErrJobState
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
		_, err = tx.Exec(`UPDATE recording_jobs SET status = ?, transcript_id = ?, error_class = ?, finished_at = ?,
				phase = NULL, percent = NULL
			WHERE upload_id = ?`, status, transcriptID, cls, toReal(now), uploadID)
		return err
	})
	if err != nil {
		return RecordingJob{}, err
	}
	return s.RecordingJob(uploadID)
}

// RecordingProgress stores Desktop's phase of a claimed job: transcribing
// (with percent 0...100 when known), diarizing or summarizing. A percent with
// another phase, an unknown phase or a percent out of range is
// ErrBadProgress; a job not claimed is ErrJobState. A new phase drops the
// old percent. A phase is no new activity: the job's times stay (now is
// for the caller's clock only).
func (s *Store) RecordingProgress(uploadID, phase string, percent *int, _ time.Time) error {
	switch phase {
	case PhaseTranscribing:
		if percent != nil && (*percent < 0 || *percent > 100) {
			return ErrBadProgress
		}
	case PhaseDiarizing, PhaseSummarizing:
		if percent != nil {
			return ErrBadProgress
		}
	default:
		return ErrBadProgress
	}
	return s.write(func(tx *sql.Tx) error {
		job, err := recordingJobTx(tx, uploadID)
		if err != nil {
			return err
		}
		if job.Status != RecordingClaimed {
			return ErrJobState
		}
		var pct any
		if percent != nil {
			pct = *percent
		}
		if _, err := tx.Exec(`UPDATE recording_jobs SET phase = ?, percent = ? WHERE upload_id = ?`, phase, pct, uploadID); err != nil {
			return fmt.Errorf("storing a recording progress: %w", err)
		}
		return nil
	})
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
	j, err := scanRecordingJob(tx.QueryRow(`SELECT `+recordingJobColumns+` FROM recording_jobs WHERE upload_id = ?`, uploadID))
	if errors.Is(err, sql.ErrNoRows) {
		return RecordingJob{}, ErrNoRecordingJob
	}
	if err != nil {
		return RecordingJob{}, fmt.Errorf("reading the recording queue: %w", err)
	}
	return j, nil
}

const recordingJobColumns = `upload_id, device_id, status, transcript_id, error_class, phase, percent, created_at, claimed_at, finished_at`

// scanRecordingJob reads one row of recordingJobColumns.
func scanRecordingJob(r interface{ Scan(...any) error }) (RecordingJob, error) {
	var (
		j                 RecordingJob
		tid, pct          sql.NullInt64
		class, phase      sql.NullString
		created           float64
		claimed, finished sql.NullFloat64
	)
	if err := r.Scan(&j.UploadID, &j.DeviceID, &j.Status, &tid, &class, &phase, &pct, &created, &claimed, &finished); err != nil {
		return RecordingJob{}, err
	}
	if tid.Valid {
		j.TranscriptID = &tid.Int64
	}
	if pct.Valid {
		v := int(pct.Int64)
		j.Percent = &v
	}
	j.ErrorClass, j.Phase = class.String, phase.String
	j.CreatedAt = fromReal(created)
	if claimed.Valid {
		j.ClaimedAt = fromReal(claimed.Float64)
	}
	if finished.Valid {
		j.FinishedAt = fromReal(finished.Float64)
	}
	return j, nil
}

// RecordingJobs lists every queue row, latest activity first (finished, else
// claimed, else created; ties by upload id). It is the recording_job slice's
// source: ids, statuses and error classes only.
func (s *Store) RecordingJobs(ctx context.Context) ([]RecordingJob, error) {
	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return nil, fmt.Errorf("reading the recording queue: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	rows, err := tx.QueryContext(ctx, `SELECT `+recordingJobColumns+` FROM recording_jobs
		ORDER BY COALESCE(finished_at, claimed_at, created_at) DESC, upload_id`)
	if err != nil {
		return nil, fmt.Errorf("reading the recording queue: %w", err)
	}
	defer rows.Close()
	var out []RecordingJob
	for rows.Next() {
		j, err := scanRecordingJob(rows)
		if err != nil {
			return nil, fmt.Errorf("reading the recording queue: %w", err)
		}
		out = append(out, j)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading the recording queue: %w", err)
	}
	return out, nil
}

// UpdatedAt is the job's latest activity: finished, else claimed, else created.
func (j RecordingJob) UpdatedAt() time.Time {
	switch {
	case !j.FinishedAt.IsZero():
		return j.FinishedAt
	case !j.ClaimedAt.IsZero():
		return j.ClaimedAt
	}
	return j.CreatedAt
}
