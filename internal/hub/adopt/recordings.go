package adopt

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"strings"
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
// (one per upload, kept on a second run): in progress → failed/hub_moved,
// finished at the adoption (so the phone shows the text and the 31-day
// window starts now), its audio moved to <RecordingsDir>/<upload_id>.m4a;
// done → done with the transcript id; failed → failed with its error's
// class; created_at (and a done or failed job's finished_at) is the row's
// updated_at. Then the Swift rows' text is blanked on a secure_delete
// connection (error NULL; audio_path emptied unless the audio stayed where
// it was), and the counts and the next step are committed with the jobs.
// held_uploads gets no row.
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
	left := map[string]bool{}
	for _, s := range recs {
		if inProgress[s.status] && uploadIDRE.MatchString(s.id) && !r.moveAudio(s) {
			left[s.id] = true
		}
	}
	if err := hook("recordings:files"); err != nil {
		return err
	}
	var c Counts
	now := r.now()
	err = st.WithSecureDeleteTx(r.ctx, func(tx *sql.Tx) error {
		for _, s := range recs {
			j, ok := jobOf(s, now)
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
		for _, s := range recs {
			q := `UPDATE phone_recordings SET audio_path = '', error = NULL WHERE upload_id = ?`
			if left[s.id] {
				c.AudioLeft++
				q = `UPDATE phone_recordings SET error = NULL WHERE upload_id = ?`
			}
			if _, err := tx.Exec(q, s.id); err != nil {
				return err
			}
		}
		if err := tx.QueryRow(`SELECT COUNT(*) FROM devices`).Scan(&c.Devices); err != nil {
			return err
		}
		b, err := json.Marshal(c)
		if err != nil {
			return err
		}
		if err := state.SetMetaTx(tx, MetaAdoptCounts, string(b)); err != nil {
			return err
		}
		return state.SetMetaTx(tx, MetaAdoptStep, string(StepSettings))
	})
	if err != nil {
		return fmt.Errorf("adopt: importing the phone recordings: %w", err)
	}
	r.counts = c
	if c.AudioLeft > 0 {
		log.Printf("hub adopt: %d recordings' audio left where it was", c.AudioLeft)
	}
	return st.Checkpoint()
}

// jobOf maps one Swift row; ok is false for a row that is not imported (an
// id that is no file name, an unknown status).
func jobOf(s swiftRecording, adoptedAt time.Time) (state.RecordingJob, bool) {
	if !uploadIDRE.MatchString(s.id) {
		return state.RecordingJob{}, false
	}
	at := fromReal(s.updated)
	j := state.RecordingJob{UploadID: s.id, CreatedAt: at, FinishedAt: at}
	switch {
	case inProgress[s.status]:
		j.Status, j.ErrorClass, j.FinishedAt = state.RecordingFailed, state.ClassHubMoved, adoptedAt
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

// renameFile is os.Rename (a test seam for the cross-volume path).
var renameFile = os.Rename

// moveAudio moves an in-progress recording's audio to the path Go derives
// from its upload id, made durable. It reports false when the audio stays
// where it was (the row keeps its path): a file outside the transcriber's
// recordings dir, a symlink or other non-regular file, or a failed move
// (logged by class). A missing source or a destination already there (a
// resumed run) reports true: nothing is left behind.
func (r *run) moveAudio(s swiftRecording) bool {
	if s.audioPath == "" {
		return true
	}
	dst := filepath.Join(r.recordings, s.id+".m4a")
	if r.recordings != "" && exists(dst) {
		return true
	}
	fi, err := os.Lstat(s.audioPath)
	if errors.Is(err, fs.ErrNotExist) {
		return true
	}
	if err != nil || !fi.Mode().IsRegular() || r.recordings == "" || !under(r.recordings, s.audioPath) {
		return false
	}
	if err := os.Chmod(s.audioPath, 0o600); err != nil {
		log.Print("hub adopt: a recording's audio was not moved (chmod)")
		return false
	}
	err = renameFile(s.audioPath, dst)
	if errors.Is(err, syscall.EXDEV) {
		err = copyAcross(s.audioPath, dst)
	}
	if err != nil {
		log.Print("hub adopt: a recording's audio was not moved (failed)")
		return false
	}
	if err := syncFile(dst); err != nil {
		log.Print("hub adopt: a moved recording's audio was not synced")
	}
	if err := syncDir(r.recordings); err != nil {
		log.Print("hub adopt: the recordings dir was not synced")
	}
	return true
}

// copyAcross moves src to dst across volumes: copied to a temp file beside
// dst, synced, renamed into place, then src removed.
func copyAcross(src, dst string) error {
	tmp := filepath.Join(filepath.Dir(dst), ".adopt-"+filepath.Base(dst))
	if err := copyFile(src, tmp); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, dst); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	if err := syncDir(filepath.Dir(dst)); err != nil {
		return err
	}
	return os.Remove(src)
}

// under reports whether path's folder is dir or inside it, symlinks resolved.
func under(dir, path string) bool {
	d, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return false
	}
	p, err := filepath.EvalSymlinks(filepath.Dir(path))
	if err != nil {
		return false
	}
	rel, err := filepath.Rel(d, p)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

// pendingRecordings lists the in-progress Swift rows of the file at path,
// read-only: the upload id and the audio file's base name.
func pendingRecordings(path string, swift bool) ([]PendingRecording, error) {
	mode := openRO
	if swift {
		mode = openSwiftRO
	}
	db, err := rawOpen(path, mode)
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
	k := KeptRecordings{Dir: recordingsDir}
	// Mid-adoption the sidecar may not have its queue yet: nothing kept.
	if ready, err := st.RecordingQueueReady(); err != nil || !ready {
		return k, err
	}
	jobs, err := st.RecordingJobs(ctx)
	if err != nil {
		return KeptRecordings{}, err
	}
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
