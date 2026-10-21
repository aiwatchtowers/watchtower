package automations

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math/rand/v2"
	"sync"
	"time"

	"watchtower/internal/db"
)

// A run waiting when the daemon stops survives the restart (board #795, spec
// 2026-10-21-automation-wait-survives-restart-design.md): goja cannot save a
// paused VM, so the next daemon re-executes the run's recipe_snapshot from
// the start and answers every SDK call that had completed from the run's
// replay log (automation_run_replay) — nothing is executed again and no step
// is written — until the call the run waited in, which re-enters its wait on
// the ask, action or session it already has. A live run records that log as
// it goes: Replay is both the recorder and the player.

// MaxReplayResultBytes caps one call's recorded result; a larger one marks
// the run not resumable (a restart ends it as before). A var for tests.
var MaxReplayResultBytes = 1 << 20

// MaxReplayLogBytes caps a run's whole recorded log (results and clock
// reads); past it the run is not resumable. A var for tests.
var MaxReplayLogBytes = 16 << 20

// maxClockReadsPerCall caps the time reads recorded between two SDK calls;
// a script that reads the clock more often is not resumable.
const maxClockReadsPerCall = 10000

// errDaemonStopping is what a wait returns when the daemon stops while a
// resumable run waits: the run is left waiting, its step open, and the next
// daemon resumes it. The sandbox stops the script uncatchably on it.
var errDaemonStopping = errors.New("the daemon is stopping; the run stays waiting for a resume")

// replayDivergence ends a resumed run whose script did not make the calls
// its log recorded (step seq): nothing was executed, so nothing repeats.
type replayDivergence struct{ seq int }

func (d *replayDivergence) Error() string {
	return fmt.Sprintf("the recipe ran differently after the restart (step %d); it was not resumed", d.seq)
}

// Replay records a live run's calls and plays a resumed run's log back. A
// recorder (newRecorder) is live from the start; a player (newPlayer) is
// live once its script reached the call the run waited in.
type Replay struct {
	mu   sync.Mutex
	real func() time.Time

	// live recording: the clock reads since the last call (ms)
	reads    []int64
	overflow bool

	// playback
	live     bool
	records  []db.AutomationRunReplay // seq 1..wait, the last one pending
	steps    []db.AutomationRunStep   // the stored steps, same seqs
	pos      int                      // calls replayed so far
	segment  []int64                  // reads left before the next call
	diverged int                      // the seq a clock read diverged at (0 = none)
	onLive   func(replayed int)
}

func newRecorder() *Replay {
	return &Replay{real: time.Now, live: true}
}

// newPlayer is the replay of a resumed run: records and steps cover seq 1
// to the waiting step, every record but the last complete. onLive is called
// once the script reached the waiting call.
func newPlayer(records []db.AutomationRunReplay, steps []db.AutomationRunStep, onLive func(int)) (*Replay, error) {
	n := len(steps)
	if n == 0 || len(records) != n {
		return nil, fmt.Errorf("the replay log has %d records for %d steps", len(records), n)
	}
	for i := range n {
		if records[i].Seq != i+1 || steps[i].Seq != i+1 || records[i].Pending != (i == n-1) {
			return nil, fmt.Errorf("the replay log does not match the journal at step %d", i+1)
		}
	}
	last := steps[n-1]
	if last.FinishedAt != nil || last.Status != StepWaiting {
		return nil, fmt.Errorf("the run's last step is %s, not an open waiting step", last.Status)
	}
	r := &Replay{real: time.Now, records: records, steps: steps, onLive: onLive}
	seg, err := decodeClock(records[0].ClockJSON)
	if err != nil {
		return nil, err
	}
	r.segment = seg
	return r, nil
}

func decodeClock(text string) ([]int64, error) {
	if text == "" {
		return nil, nil
	}
	var reads []int64
	if err := json.Unmarshal([]byte(text), &reads); err != nil {
		return nil, fmt.Errorf("decoding a replay clock record: %w", err)
	}
	return reads, nil
}

// Live reports whether the run executes for real (a recorder, or a player
// past its waiting call).
func (r *Replay) Live() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.live
}

// Now is the script's clock (Date.now(), new Date(), Date()): live, the
// real time in whole milliseconds, recorded; during playback the recorded
// reads in order. A read past the recorded ones is a divergence, reported at
// the next call.
func (r *Replay) Now() time.Time {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.live {
		if len(r.segment) > 0 {
			v := r.segment[0]
			r.segment = r.segment[1:]
			return time.UnixMilli(v)
		}
		if r.diverged == 0 {
			r.diverged = r.pos + 1
		}
		return time.UnixMilli(r.real().UnixMilli())
	}
	ms := r.real().UnixMilli()
	switch {
	case r.overflow:
	case len(r.reads) >= maxClockReadsPerCall:
		r.overflow, r.reads = true, nil
	default:
		r.reads = append(r.reads, ms)
	}
	return time.UnixMilli(ms)
}

// takeClock returns the reads since the last call as JSON and starts a new
// segment; ok is false once the reads overflowed (the run is not resumable).
func (r *Replay) takeClock() (string, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.overflow {
		return "", false
	}
	reads := r.reads
	r.reads = nil
	if len(reads) == 0 {
		return "[]", true
	}
	raw, err := json.Marshal(reads)
	if err != nil {
		return "", false
	}
	return string(raw), true
}

// replayed is one call answered from the log.
type replayed struct {
	r   *Replay
	rec db.AutomationRunReplay
}

// value is what the recorded call gave the script: its result (nil =
// undefined) or the error it threw, rebuilt with the same name, message and
// needed.
func (p *replayed) value() (any, error) {
	if p.rec.ErrorJSON != "" {
		var e jsError
		if err := json.Unmarshal([]byte(p.rec.ErrorJSON), &e); err != nil {
			return nil, p.r.diverge(p.rec.Seq)
		}
		return nil, &SDKError{Name: e.Name, Message: e.Message, Needed: e.Needed}
	}
	if p.rec.ResultJSON == nil {
		return nil, nil
	}
	return encodedResult(*p.rec.ResultJSON), nil
}

// jsError is a thrown call's record: what the script's catch saw.
type jsError struct {
	Name    string `json:"name"`
	Message string `json:"message"`
	Needed  string `json:"needed,omitempty"`
}

// next answers the script's next call during playback: a recorded call
// returns its record (the journal gains the stored step in memory only); the
// waiting call returns the adopted open step and the player turns live. A
// call that does not match its record — kind, name (unless checkName is
// false: a keyed call), args hash or the clock reads before it — is a
// divergence.
func (r *Replay) next(j *Journal, kind, name, argsHash string, checkName bool) (*Step, *replayed, error) {
	r.mu.Lock()
	seq := r.pos + 1
	if r.diverged != 0 {
		r.mu.Unlock()
		return nil, nil, &replayDivergence{seq: r.diverged}
	}
	rec := r.records[seq-1]
	if rec.Kind != kind || (checkName && rec.Name != name) || rec.ArgsHash != argsHash || len(r.segment) != 0 {
		r.diverged = seq
		r.mu.Unlock()
		return nil, nil, &replayDivergence{seq: seq}
	}
	r.pos = seq
	if seq == len(r.records) {
		r.live = true
		onLive := r.onLive
		r.mu.Unlock()
		step := j.adopt(r.steps[seq-1], rec)
		if onLive != nil {
			onLive(seq - 1)
		}
		return step, nil, nil
	}
	seg, err := decodeClock(r.records[seq].ClockJSON)
	if err != nil {
		r.diverged = seq + 1
		r.mu.Unlock()
		return nil, nil, &replayDivergence{seq: seq + 1}
	}
	r.segment = seg
	r.mu.Unlock()
	j.appendStored(r.steps[seq-1], &rec)
	return nil, &replayed{r: r, rec: rec}, nil
}

// diverge records that the playback diverged at seq (the first one wins)
// and returns the divergence.
func (r *Replay) diverge(seq int) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.diverged == 0 {
		r.diverged = seq
	}
	return &replayDivergence{seq: r.diverged}
}

// replayPos is the seq the playback diverged or is at (the next call's seq).
func (r *Replay) replayPos() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.diverged != 0 {
		return r.diverged
	}
	return r.pos + 1
}

// argsHash is the sha256 of a call's whole args JSON (marshalForStep, not
// clipped).
func argsHash(args any) string {
	sum := sha256.Sum256([]byte(marshalForStep(args)))
	return hex.EncodeToString(sum[:])
}

// errorRecord is the JSON of what a thrown call showed the script.
func errorRecord(err error) string {
	name, msg, needed := jsErrorParts(err)
	raw, mErr := json.Marshal(jsError{Name: name, Message: msg, Needed: needed})
	if mErr != nil {
		return ""
	}
	return string(raw)
}

// runRandom is the run's Math.random: a PCG seeded with the run's seed, so
// a replay draws the same numbers.
func runRandom(run *db.AutomationRun) func() float64 {
	src := rand.New(rand.NewPCG(uint64(run.RandomSeed), uint64(run.ID)))
	var mu sync.Mutex
	return func() float64 {
		mu.Lock()
		defer mu.Unlock()
		return src.Float64()
	}
}
