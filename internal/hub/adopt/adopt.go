// Package adopt moves the Swift hub's state (MobileHub/) into the Go hub's
// dir once, so no phone re-pairs (Go hub spec §12, §12.1–§12.3): the
// sidecar with its devices, ledger, epochs and slice hashes, the slice assets
// and the CloudKit transport state, the phone recordings and the owner's
// settings. The keys are a separate hand-over (phase 3 Task 16).
//
// Run is resumable: every step commits the next step to run (hub_meta
// adopt_step) before that step starts, so a process killed anywhere finishes
// the same adoption on the next run — never a second import, never a new
// hub_id. Before the sidecar is renamed into the hub dir everything lives in
// <hub dir>/adopt.tmp/ and a run starts over from the copy; the rename of
// hubstate.db is the commit point. Once adopted_at is set, a MobileHub/ that
// appears later (a pre-guard app after a downgrade) is never read, imported
// or deleted.
//
// Logs carry counts and error classes only (FILES-01): never a path, a
// name or an id.
package adopt

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"watchtower/internal/hub/state"
)

// Step is one adoption step, in order.
type Step string

// The steps.
const (
	StepCopy       Step = "copy"
	StepVerify     Step = "verify"
	StepRename     Step = "rename"
	StepMigrate    Step = "migrate"
	StepRecordings Step = "recordings"
	StepSettings   Step = "settings"
	StepTransport  Step = "transport"
	StepMoved      Step = "moved"
	StepDone       Step = "done"
)

var order = []Step{StepCopy, StepVerify, StepRename, StepMigrate, StepRecordings, StepSettings, StepTransport, StepMoved, StepDone}

// hub_meta keys of the adoption. MetaAdoptCounts holds the imported Counts
// (JSON); MetaIdentity is the key hand-over's state (none until Task 16
// stages it: staged|adopted|confirmed).
const (
	MetaAdoptStep, MetaAdoptedAt, MetaAdoptError = "adopt_step", "adopted_at", "adopt_error"
	MetaAdoptCounts                              = "adopt_counts"
	MetaIdentity                                 = "identity_adoption"
)

// File names. MovedName is the note left in MobileHub/ (the Swift hub's
// downgrade guard reads it, MobileHubMovedGuard).
const (
	MovedName      = "MOVED"
	tmpDirName     = "adopt.tmp"
	swiftAssetsDir = "SliceAssets"
	goAssetsDir    = "assets"
	cloudKitDir    = "cloudkit"
	transportFile  = "transport.db"
)

// LaterMobileHubLog is the one line logged when a MobileHub/ shows up after
// the adoption.
const LaterMobileHubLog = "hub: ignoring a later MobileHub (pre-guard app)"

// Errors.
var (
	// ErrSwiftSchema: the Swift file's schema is one the migrations cannot
	// take (a base column missing, a folded-in column that cannot be added);
	// refused before the commit point, nothing is moved.
	ErrSwiftSchema = errors.New("adopt: the Swift hub's file has a schema this hub cannot take")
	// ErrSwiftHubID: the Swift file has no valid hub_meta.hub_id.
	ErrSwiftHubID = errors.New("adopt: the Swift hub's file has no hub id")
	// ErrSwiftBusy: another connection holds the Swift file (the Swift hub
	// still runs): its WAL could not be checkpointed or its lock taken.
	ErrSwiftBusy = errors.New("adopt: the Swift hub's file is in use")
	// ErrSwiftCorrupt: the copy fails PRAGMA integrity_check.
	ErrSwiftCorrupt = errors.New("adopt: the Swift hub's file is damaged")
	// ErrAlreadyAdopted: adopted_at is set; nothing is done.
	ErrAlreadyAdopted = errors.New("adopt: already adopted")
	// ErrLaterMobileHub: a MobileHub/ sidecar appeared after the Go hub
	// had its own state; it is never read.
	ErrLaterMobileHub = errors.New("adopt: a later MobileHub is ignored")
	// ErrNothingToAdopt: no Swift sidecar and no adoption in progress.
	ErrNothingToAdopt = errors.New("adopt: no Swift hub state to adopt")
)

// Error classes (Result.Error, hub_meta.adopt_error).
const (
	ClassSwiftSchema    = "swift_schema"
	ClassSwiftCorrupt   = "swift_corrupt"
	ClassSwiftHubID     = "swift_hub_id"
	ClassSwiftBusy      = "swift_busy"
	ClassAlreadyAdopted = "already_adopted"
	ClassLaterMobileHub = "later_mobile_hub"
	ClassNothingToAdopt = "no_swift_state"
	ClassLocked         = "locked"
	ClassFailed         = "failed"
	identityNone        = "none"
	swiftPresent        = "present"
	swiftAbsent         = "absent"
	swiftIgnored        = "ignored"
)

// Settings is what Desktop reads from its defaults and sends on stdin.
type Settings struct {
	Enabled            bool            `json:"enabled"`
	StartSessionAllows map[string]bool `json:"start_session_allows"` // device id → the owner's grant
}

// Counts is what the adoption took over.
type Counts struct {
	Devices int `json:"devices"`
	Jobs    int `json:"jobs"`
	Skipped int `json:"skipped"`
	// AudioLeft counts the in-progress recordings whose audio was not moved
	// (outside the transcriber's recordings dir, or the move failed): their
	// Swift row keeps its audio path and their audio stays where it was.
	AudioLeft int `json:"audio_left"`
}

// Result is where an adoption stands: the step reached (done when finished,
// else the step that failed or will run next), the imported counts and an
// error class.
type Result struct {
	Step     Step   `json:"step"`
	Imported Counts `json:"imported"`
	Error    string `json:"error"`
}

// PendingRecording is a Swift phone recording still in progress before the
// recordings step: its upload id and its audio file's base name (output
// only, never stored).
type PendingRecording struct {
	UploadID  string `json:"upload_id"`
	AudioName string `json:"audio_name"`
}

// Report is Status' answer: the Result plus what Desktop needs before and
// during the hand-over.
type Report struct {
	Result
	HubID    string `json:"hub_id"`
	Identity string `json:"identity"` // none|staged|adopted|confirmed
	// SwiftState: present = a Swift sidecar waits in MobileHub/ and Run
	// would adopt it; ignored = one is there but Run refuses it (a later
	// MobileHub beside the Go hub's own state); absent = none.
	SwiftState        string             `json:"swift_state"`
	PendingRecordings []PendingRecording `json:"pending_recordings"`
}

// stepHook is the test seam of the kill-point matrix: called after each
// step (and inside the multi-file steps) has committed; an error stops Run
// there as a kill would, with nothing cleaned up or recorded.
var stepHook = func(point string) error { return nil }

type hookError struct{ err error }

func (e hookError) Error() string { return e.err.Error() }
func (e hookError) Unwrap() error { return e.err }

func hook(point string) error {
	if err := stepHook(point); err != nil {
		return hookError{err}
	}
	return nil
}

// Run adopts mobileHubDir's Swift hub state into hubDir under the hub lock,
// from the step hub_meta.adopt_step records. recordingsDir is where a
// recording mid-transcription keeps its audio (<upload_id>.m4a). now nil is
// time.Now.
func Run(ctx context.Context, mobileHubDir, hubDir, recordingsDir string, s Settings, now func() time.Time) (Result, error) {
	if now == nil {
		now = time.Now
	}
	lock, err := state.AcquireLock(hubDir)
	if err != nil {
		cls := ClassFailed
		if errors.Is(err, state.ErrLocked) {
			cls = ClassLocked
		}
		return Result{Error: cls}, err
	}
	defer func() { _ = lock.Release() }()

	r := &run{ctx: ctx, mobile: mobileHubDir, hub: hubDir, recordings: recordingsDir, settings: s, now: now}
	defer r.close()
	first, err := r.startStep()
	if err != nil {
		res := Result{Error: classOf(err)}
		if errors.Is(err, ErrAlreadyAdopted) || errors.Is(err, ErrLaterMobileHub) {
			res.Step = StepDone
		}
		return res, err
	}
	start := 0
	for i, st := range order {
		if st == first {
			start = i
		}
	}
	for _, step := range order[start:] {
		if err := r.do(step); err != nil {
			var h hookError
			if errors.As(err, &h) {
				return Result{Step: step}, err
			}
			cls := classOf(err)
			r.recordError(cls)
			log.Printf("hub adopt: step %s failed (%s)", step, cls)
			return Result{Step: step, Error: cls}, err
		}
		if err := hook(string(step)); err != nil {
			return Result{Step: step}, err
		}
	}
	log.Printf("hub adopt: done, %d phones, %d recording jobs, %d skipped", r.counts.Devices, r.counts.Jobs, r.counts.Skipped)
	return Result{Step: StepDone, Imported: r.counts}, nil
}

// startStep is the step a run starts at, or why it does not run.
func (r *run) startStep() (Step, error) {
	if !exists(r.goFile()) {
		if exists(r.swiftFile()) {
			return StepCopy, nil
		}
		// The Swift sidecar is gone but a verified copy waits: go on with it.
		if exists(r.tmpFile()) {
			if m, err := readMeta(r.tmpFile(), false, MetaAdoptStep); err == nil && m[MetaAdoptStep] == string(StepRename) {
				return StepRename, nil
			}
		}
		return "", ErrNothingToAdopt
	}
	m, err := readMeta(r.goFile(), false, MetaAdoptedAt, MetaAdoptStep)
	if err != nil {
		return "", err
	}
	if m[MetaAdoptedAt] != "" || m[MetaAdoptStep] == "" {
		// Adopted, or a Go hub that never adopted (it ran first): a Swift
		// sidecar beside it is a later one, never read.
		if exists(r.swiftFile()) {
			log.Print(LaterMobileHubLog)
			return "", ErrLaterMobileHub
		}
		if m[MetaAdoptedAt] != "" {
			return "", ErrAlreadyAdopted
		}
		return "", ErrNothingToAdopt
	}
	step := Step(m[MetaAdoptStep])
	for _, s := range order {
		if s == step {
			return step, nil
		}
	}
	return "", fmt.Errorf("adopt: unknown step in the hub state")
}

func classOf(err error) string {
	switch {
	case errors.Is(err, ErrSwiftSchema):
		return ClassSwiftSchema
	case errors.Is(err, ErrSwiftCorrupt):
		return ClassSwiftCorrupt
	case errors.Is(err, ErrSwiftHubID):
		return ClassSwiftHubID
	case errors.Is(err, ErrSwiftBusy):
		return ClassSwiftBusy
	case errors.Is(err, ErrAlreadyAdopted):
		return ClassAlreadyAdopted
	case errors.Is(err, ErrLaterMobileHub):
		return ClassLaterMobileHub
	case errors.Is(err, ErrNothingToAdopt):
		return ClassNothingToAdopt
	}
	return ClassFailed
}

// Status reads where the adoption stands, read-only: nothing is created and
// no lock is taken.
func Status(mobileHubDir, hubDir string) (Report, error) {
	r := &run{mobile: mobileHubDir, hub: hubDir}
	rep := Report{Identity: identityNone, SwiftState: swiftAbsent, PendingRecordings: []PendingRecording{}}
	keys := []string{MetaAdoptStep, MetaAdoptedAt, MetaAdoptError, MetaAdoptCounts, MetaIdentity, state.MetaHubID}
	var pendingFrom string
	pendingSwift := false
	if exists(r.goFile()) {
		m, err := readMeta(r.goFile(), false, keys...)
		if err != nil {
			return Report{}, err
		}
		rep.Step, rep.Error, rep.HubID = Step(m[MetaAdoptStep]), m[MetaAdoptError], m[state.MetaHubID]
		if v := m[MetaIdentity]; v != "" {
			rep.Identity = v
		}
		if c := m[MetaAdoptCounts]; c != "" {
			if err := json.Unmarshal([]byte(c), &rep.Imported); err != nil {
				return Report{}, fmt.Errorf("adopt: reading the imported counts: %w", err)
			}
		}
		if rep.Step == StepRename || rep.Step == StepMigrate || rep.Step == StepRecordings {
			pendingFrom = r.goFile()
		}
		if exists(r.swiftFile()) {
			// Adopted, or a Go hub of its own: Run refuses it (ErrLaterMobileHub).
			rep.SwiftState = swiftIgnored
			if m[MetaAdoptedAt] == "" && rep.Step != "" {
				rep.SwiftState = swiftPresent // an adoption in progress
			}
		}
	} else {
		if exists(r.tmpFile()) {
			// A copy in progress or refused: its step and error, when readable.
			if m, err := readMeta(r.tmpFile(), false, MetaAdoptStep, MetaAdoptError); err == nil {
				rep.Step, rep.Error = Step(m[MetaAdoptStep]), m[MetaAdoptError]
			}
		}
		if exists(r.swiftFile()) {
			m, err := readMeta(r.swiftFile(), true, state.MetaHubID)
			if err != nil {
				return Report{}, err
			}
			rep.HubID = m[state.MetaHubID]
			rep.SwiftState = swiftPresent
			pendingFrom, pendingSwift = r.swiftFile(), true
		}
	}
	if pendingFrom != "" {
		p, err := pendingRecordings(pendingFrom, pendingSwift)
		if err != nil {
			return Report{}, err
		}
		rep.PendingRecordings = p
	}
	return rep, nil
}

// run is one Run's state.
type run struct {
	ctx                     context.Context
	mobile, hub, recordings string
	settings                Settings
	now                     func() time.Time
	st                      *state.Store
	counts                  Counts
}

func (r *run) goFile() string    { return filepath.Join(r.hub, state.FileName) }
func (r *run) swiftFile() string { return filepath.Join(r.mobile, state.FileName) }
func (r *run) tmpDir() string    { return filepath.Join(r.hub, tmpDirName) }
func (r *run) tmpFile() string   { return filepath.Join(r.tmpDir(), state.FileName) }

func (r *run) close() {
	if r.st != nil {
		_ = r.st.Close()
		r.st = nil
	}
}

// store is the migrated Go sidecar, opened once (state.Open migrates; it is
// idempotent, so a resumed run opens it again).
func (r *run) store() (*state.Store, error) {
	if r.st == nil {
		st, err := state.Open(r.hub)
		if err != nil {
			return nil, err
		}
		r.st = st
	}
	return r.st, nil
}

func (r *run) do(step Step) error {
	switch step {
	case StepCopy:
		return r.copy()
	case StepVerify:
		return r.verify()
	case StepRename:
		return r.rename()
	case StepMigrate:
		// A run killed right after the rename left the emptied copy.
		if err := os.RemoveAll(r.tmpDir()); err != nil {
			return fmt.Errorf("adopt: removing the copy: %w", err)
		}
		st, err := r.store()
		if err != nil {
			return err
		}
		return st.SetMeta(MetaAdoptStep, string(StepRecordings))
	case StepRecordings:
		return r.importRecordings()
	case StepSettings:
		return r.applySettings()
	case StepTransport:
		return r.inTx(StepMoved, func(tx *sql.Tx) error { return state.SetMetaTx(tx, state.MetaTransport, "cloudkit") })
	case StepMoved:
		return r.moved()
	case StepDone:
		return r.done()
	}
	return fmt.Errorf("adopt: unknown step")
}

// inTx runs fn and records next as the step to run, in one transaction.
func (r *run) inTx(next Step, fn func(*sql.Tx) error) error {
	st, err := r.store()
	if err != nil {
		return err
	}
	return st.WithTx(r.ctx, func(tx *sql.Tx) error {
		if err := fn(tx); err != nil {
			return err
		}
		return state.SetMetaTx(tx, MetaAdoptStep, string(next))
	})
}

func (r *run) done() error {
	at := strconv.FormatFloat(float64(r.now().UnixNano())/1e9, 'f', 3, 64)
	err := r.inTx(StepDone, func(tx *sql.Tx) error {
		if _, err := tx.Exec(`DELETE FROM hub_meta WHERE key = ?`, MetaAdoptError); err != nil {
			return err
		}
		return state.SetMetaTx(tx, MetaAdoptedAt, at)
	})
	if err != nil {
		return err
	}
	return r.loadCounts()
}

func (r *run) loadCounts() error {
	st, err := r.store()
	if err != nil {
		return err
	}
	v, ok, err := st.Meta(MetaAdoptCounts)
	if err != nil || !ok {
		return err
	}
	return json.Unmarshal([]byte(v), &r.counts)
}

// recordError writes the error class where Status reads it: the Go sidecar
// once it is in place, else the copy (gone with the next run's copy).
func (r *run) recordError(class string) {
	if exists(r.goFile()) {
		if st, err := r.store(); err == nil {
			_ = st.SetMeta(MetaAdoptError, class)
		}
		return
	}
	if exists(r.tmpFile()) {
		_ = writeRawMeta(r.tmpFile(), map[string]string{MetaAdoptError: class})
	}
}

func exists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil || !errors.Is(err, fs.ErrNotExist)
}
