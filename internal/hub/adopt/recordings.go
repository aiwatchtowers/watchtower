package adopt

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"syscall"
	"time"

	"watchtower/internal/hub/state"
)

// The Swift phone_recordings statuses (HubSyncState.PhoneRecordingJob).
// The in-progress ones become a failed hub_moved job (ask #843).
var inProgress = map[string]bool{"received": true, "queued": true, "transcribing": true, "diarizing": true, "summarizing": true}

const (
	swiftDone   = "done"
	swiftFailed = "failed"
)

// uploadIDRE is the Go intake's upload id rule (handlers.uploadIDRE): an id
// usable as a file name. A Swift row with another id is skipped.
var uploadIDRE = regexp.MustCompile(`^[A-Za-z0-9-]{1,64}$`)

type swiftRecording struct {
	id, audioPath, status string
	errText               sql.NullString
	transcriptID          sql.NullInt64
	updated               float64
}

const inProgressSQL = `('received', 'queued', 'transcribing', 'diarizing', 'summarizing')`

// importRecordings maps the Swift phone_recordings rows to recording_jobs
// (one per upload, kept on a second run): in progress → failed/hub_moved
// with its audio moved to <RecordingsDir>/<upload_id>.m4a, done → done with
// the transcript id, failed → failed with its error's class; created_at and
// finished_at are the row's updated_at. Then the Swift rows' text is blanked
// (audio_path emptied, error NULL, written over on disk) and the counts and
// the next step are committed with the jobs. held_uploads gets no row.
func (r *run) importRecordings() error {
	st, err := r.store()
	if err != nil {
		return err
	}
	var recs []swiftRecording
	err = st.WithTx(r.ctx, func(tx *sql.Tx) error {
		rows, err := tx.Query(`SELECT upload_id, audio_path, status, error, transcript_id, updated_at FROM phone_recordings ORDER BY upload_id`)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var s swiftRecording
			if err := rows.Scan(&s.id, &s.audioPath, &s.status, &s.errText, &s.transcriptID, &s.updated); err != nil {
				return err
			}
			recs = append(recs, s)
		}
		return rows.Err()
	})
	if err != nil {
		return fmt.Errorf("adopt: reading the phone recordings: %w", err)
	}
	for _, s := range recs {
		if inProgress[s.status] && uploadIDRE.MatchString(s.id) {
			r.moveAudio(s)
		}
	}
	if err := hook("recordings:files"); err != nil {
		return err
	}
	var c Counts
	err = r.inTx(StepSettings, func(tx *sql.Tx) error {
		// The blanked text must not stay in freed pages.
		if _, err := tx.Exec(`PRAGMA secure_delete = ON`); err != nil {
			return err
		}
		for _, s := range recs {
			j, ok := jobOf(s)
			if !ok {
				c.Skipped++
				continue
			}
			added, err := state.ImportRecordingJobTx(tx, j)
			if err != nil {
				return err
			}
			if added {
				c.Jobs++
			}
		}
		if _, err := tx.Exec(`UPDATE phone_recordings SET audio_path = '', error = NULL`); err != nil {
			return err
		}
		if err := tx.QueryRow(`SELECT COUNT(*) FROM devices`).Scan(&c.Devices); err != nil {
			return err
		}
		b, err := json.Marshal(c)
		if err != nil {
			return err
		}
		return state.SetMetaTx(tx, MetaAdoptCounts, string(b))
	})
	if err != nil {
		return fmt.Errorf("adopt: importing the phone recordings: %w", err)
	}
	r.counts = c
	return st.Checkpoint()
}

// jobOf maps one Swift row; ok is false for a row that is not imported (an
// id that is no file name, an unknown status).
func jobOf(s swiftRecording) (state.RecordingJob, bool) {
	if !uploadIDRE.MatchString(s.id) {
		return state.RecordingJob{}, false
	}
	at := fromReal(s.updated)
	j := state.RecordingJob{UploadID: s.id, CreatedAt: at, FinishedAt: at}
	switch {
	case inProgress[s.status]:
		j.Status, j.ErrorClass = state.RecordingFailed, state.ClassHubMoved
	case s.status == swiftDone:
		j.Status = state.RecordingDone
		if s.transcriptID.Valid {
			id := s.transcriptID.Int64
			j.TranscriptID = &id
		}
	case s.status == swiftFailed:
		j.Status, j.ErrorClass = state.RecordingFailed, state.ErrorClass(s.errText.String)
	default:
		return state.RecordingJob{}, false
	}
	return j, true
}

// moveAudio moves an in-progress recording's audio to the path Go derives
// from its upload id (rename, same volume). A missing source, a symlink or
// a destination already there (a resumed run) skips the move; a failure is
// logged by class and never stops the adoption.
func (r *run) moveAudio(s swiftRecording) {
	if r.recordings == "" || s.audioPath == "" {
		return
	}
	fi, err := os.Lstat(s.audioPath)
	if err != nil || !fi.Mode().IsRegular() {
		return
	}
	dst := filepath.Join(r.recordings, s.id+".m4a")
	if exists(dst) {
		return
	}
	if err := os.MkdirAll(r.recordings, 0o700); err != nil {
		log.Print("hub adopt: the recordings dir is unavailable")
		return
	}
	if err := os.Rename(s.audioPath, dst); err != nil {
		cls := "failed"
		if errors.Is(err, syscall.EXDEV) {
			cls = "cross_device"
		}
		log.Printf("hub adopt: a recording's audio was not moved (%s)", cls)
		return
	}
	_ = os.Chmod(dst, 0o600)
}

// pendingRecordings lists the in-progress Swift rows of the file at path,
// read-only: the upload id and the audio file's base name.
func pendingRecordings(path string) ([]PendingRecording, error) {
	db, err := rawOpen(path, true)
	if err != nil {
		return nil, err
	}
	defer func() { _ = db.Close() }()
	rows, err := db.Query(`SELECT upload_id, audio_path FROM phone_recordings WHERE status IN ` + inProgressSQL + ` ORDER BY upload_id`)
	if err != nil {
		return nil, fmt.Errorf("adopt: reading the phone recordings: %w", err)
	}
	defer rows.Close()
	out := []PendingRecording{}
	for rows.Next() {
		var id, audio string
		if err := rows.Scan(&id, &audio); err != nil {
			return nil, fmt.Errorf("adopt: reading the phone recordings: %w", err)
		}
		p := PendingRecording{UploadID: id}
		if audio != "" {
			p.AudioName = filepath.Base(audio)
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// KeptRecordings is `hub status`'s kept_recordings: the hub_moved jobs whose
// audio is still on the Mac, when the first is removed, and where they are.
type KeptRecordings struct {
	Count    int       `json:"count"`
	RemoveAt time.Time `json:"remove_at"`
	Dir      string    `json:"dir"`
}

// Kept counts the hub_moved jobs whose <recordingsDir>/<upload_id>.m4a
// exists; RemoveAt is the earliest finished_at + 31 days. Count 0 means
// there is nothing to show.
func Kept(ctx context.Context, st *state.Store, recordingsDir string) (KeptRecordings, error) {
	jobs, err := st.RecordingJobs(ctx)
	if err != nil {
		return KeptRecordings{}, err
	}
	k := KeptRecordings{Dir: recordingsDir}
	for _, j := range jobs {
		if j.Status != state.RecordingFailed || j.ErrorClass != state.ClassHubMoved || recordingsDir == "" {
			continue
		}
		if fi, err := os.Lstat(filepath.Join(recordingsDir, j.UploadID+".m4a")); err != nil || !fi.Mode().IsRegular() {
			continue
		}
		at := j.FinishedAt.Add(state.RecordingJobKeptFor).UTC()
		if k.Count == 0 || at.Before(k.RemoveAt) {
			k.RemoveAt = at
		}
		k.Count++
	}
	return k, nil
}

// fromReal reads the Swift hub's REAL seconds since 1970.
func fromReal(f float64) time.Time {
	sec, frac := math.Modf(f)
	return time.Unix(int64(sec), int64(math.Round(frac*1e9))).UTC()
}
