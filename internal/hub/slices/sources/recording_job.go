package sources

import (
	"context"
	"errors"
	"time"

	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/wire"
)

// The recording_job slice's caps (RecordingJobSlice).
const (
	recordingKeptAfterEnd = 7 * 24 * time.Hour
	maxRecordingJobs      = 100
	maxRecordingError     = 300
)

// RecordingJob is the recording_job slice (RecordingJobSlice, mobile POC spec
// §4.12), record recording_job-<upload id>: the hub-side progress of one phone
// upload, read from the sidecar's recording_jobs queue (ids, statuses and
// error classes; Task 5). The queue has four states, the wire more: queued is
// queued, claimed (Desktop took it) is Desktop's reported phase —
// transcribing (with its percent when reported; also before any report),
// diarizing or summarizing, as RecordingJobSlice —, done carries the
// transcript id, failed carries the error class as its error. A
// job is published until 7 days after it ended; an unfinished one stays. At
// most 100, the latest updated first. now nil is time.Now.
func RecordingJob(st *state.Store, now func() time.Time) (hubslices.Source, error) {
	if st == nil {
		return nil, errors.New("hub slices: recording_job needs the hub state")
	}
	if now == nil {
		now = time.Now
	}
	return &recordingJobSource{st: st, now: now}, nil
}

type recordingJobSource struct {
	st  *state.Store
	now func() time.Time
}

func (*recordingJobSource) Kind() hubslices.Kind { return "recording_job" }

// recordingJobPayload is the Kit mirror WatchtowerKit.RecordingJob.
type recordingJobPayload struct {
	ID           string    `json:"id"`
	Status       string    `json:"status"`
	Percent      *int      `json:"percent,omitempty"`
	TranscriptID *int64    `json:"transcript_id,omitempty"`
	Error        string    `json:"error,omitempty"`
	UpdatedAt    wire.Time `json:"updated_at"`
}

func (s *recordingJobSource) Items(ctx context.Context) ([]hubslices.Item, error) {
	jobs, err := s.st.RecordingJobs(ctx)
	if err != nil {
		return nil, err
	}
	now := s.now()
	var items []hubslices.Item
	for _, j := range jobs {
		updated := j.UpdatedAt()
		finished := j.Status == state.RecordingDone || j.Status == state.RecordingFailed
		if finished && now.Sub(updated) > recordingKeptAfterEnd {
			continue
		}
		if len(items) == maxRecordingJobs {
			break
		}
		p := recordingJobPayload{
			ID:        j.UploadID,
			UpdatedAt: wire.Time{Time: time.Unix(updated.Unix(), 0).UTC()}, // whole seconds
		}
		switch j.Status {
		case state.RecordingClaimed:
			// Desktop's phase; a claim it has not reported on yet transcribes.
			switch j.Phase {
			case state.PhaseDiarizing, state.PhaseSummarizing:
				p.Status = j.Phase
			default:
				p.Status, p.Percent = state.PhaseTranscribing, j.Percent
			}
		case state.RecordingDone:
			p.Status, p.TranscriptID = "done", j.TranscriptID
		case state.RecordingFailed:
			p.Status = "failed"
			p.Error, _ = clipText(state.ErrorClass(j.ErrorClass), maxRecordingError)
		default:
			p.Status = "queued"
		}
		b, err := wire.Marshal(p)
		if err != nil {
			return nil, err
		}
		items = append(items, hubslices.Item{ID: j.UploadID, Payload: b})
	}
	return items, nil
}
