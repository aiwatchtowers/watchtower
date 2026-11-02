package adopt

import (
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"time"

	"watchtower/internal/hub/state"
)

// ClassAdoptionStarted is SetAside's refusal of a Swift state whose adoption
// has begun (the Go dir holds its progress); Retry continues the adoption.
const ClassAdoptionStarted = "adoption_started"

// ErrAdoptionStarted is SetAside's refusal once an adoption began.
var ErrAdoptionStarted = errors.New("adopt: the adoption has started; the Swift state cannot be set aside")

// SetAsideAnswer is `hub adopt --set-aside --json`: "done" or the error class.
type SetAsideAnswer struct {
	SetAside string `json:"set_aside"`
}

// setAsideDirPrefix names the folder in MobileHub/ the Swift files move to.
const setAsideDirPrefix = "set-aside-"

// SetAside is the way out of a Mac whose Swift hub state has no keys
// (Desktop's no_keys, an owner decision after confirming that the phones
// link again; go hub plan 3 Task 22 review): under the hub lock, MOVED is
// written first (durable, as the moved step does, so an older app never
// starts the Swift hub again), then the Swift hub's files are renamed into
// MobileHub/set-aside-<UTC time>/ — kept, never imported, never deleted.
// Afterwards Status answers swift_state absent and the Go hub starts fresh.
// A copy left by a refused adoption (adopt.tmp) is removed; a Swift state
// already set aside or absent is no error. Refused (ErrAdoptionStarted) once
// the Go dir holds an adoption's progress or its adopted state.
func SetAside(mobileHubDir, hubDir string, now func() time.Time) error {
	if now == nil {
		now = time.Now
	}
	lock, err := state.AcquireLock(hubDir)
	if err != nil {
		return err
	}
	defer func() { _ = lock.Release() }()
	r := &run{mobile: mobileHubDir, hub: hubDir}
	if exists(r.goFile()) {
		m, err := readMeta(r.goFile(), false, MetaAdoptStep, MetaAdoptedAt)
		if err != nil {
			return err
		}
		if m[MetaAdoptStep] != "" || m[MetaAdoptedAt] != "" {
			return ErrAdoptionStarted
		}
	}
	if err := os.RemoveAll(r.tmpDir()); err != nil {
		return fmt.Errorf("adopt: removing a refused copy: %w", err)
	}
	if !exists(r.swiftFile()) {
		return nil
	}
	if err := r.writeMovedNote(); err != nil {
		return err
	}
	aside := filepath.Join(mobileHubDir, setAsideDirPrefix+now().UTC().Format("20060102T150405Z"))
	if err := os.MkdirAll(aside, 0o700); err != nil {
		return fmt.Errorf("adopt: the set-aside dir: %w", err)
	}
	moved := 0
	for _, name := range swiftOriginals {
		from := filepath.Join(mobileHubDir, name)
		if _, err := os.Lstat(from); errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err := os.Rename(from, filepath.Join(aside, name)); err != nil {
			return fmt.Errorf("adopt: setting the Swift hub's files aside: %w", err)
		}
		moved++
	}
	if err := syncDir(mobileHubDir); err != nil {
		return err
	}
	log.Printf("hub adopt: the Swift hub's state was set aside (%d file(s)), not imported", moved)
	return nil
}

// SetAsideClass is the answer's class for a SetAside error.
func SetAsideClass(err error) string {
	switch {
	case errors.Is(err, ErrAdoptionStarted):
		return ClassAdoptionStarted
	case errors.Is(err, state.ErrLocked):
		return ClassLocked
	}
	return ClassFailed
}
