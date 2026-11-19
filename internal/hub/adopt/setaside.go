package adopt

import (
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
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

// setAsideRename is os.Rename; a test seam for a failure part-way.
var setAsideRename = os.Rename

// setAsideOrder is swiftOriginals in the order SetAside moves them: the
// sidecar's main file last, so a failure part-way leaves it in place, Status
// still answers swift_state present and a retry finishes the move.
func setAsideOrder() []string {
	order := make([]string, 0, len(swiftOriginals))
	for _, name := range swiftOriginals {
		if name != state.FileName {
			order = append(order, name)
		}
	}
	return append(order, state.FileName)
}

// SetAside is the way out of a Mac whose Swift hub state has no keys
// (Desktop's no_keys, an owner decision after confirming that the phones
// link again; go hub plan 3 Task 22 review): under the hub lock, MOVED is
// written first (durable, as the moved step does, so an older app never
// starts the Swift hub again), then every Swift hub file still in
// MobileHub/ is renamed into MobileHub/set-aside-<UTC time>/ — kept, never
// imported, never deleted; the sidecar's main file goes last. It is done
// only when none of those files is left: a move that failed part-way is
// finished by the next call, into the same folder. Afterwards Status
// answers swift_state absent and the Go hub starts fresh. A copy left by a
// refused adoption (adopt.tmp) is removed. Refused (ErrAdoptionStarted)
// once the Go dir holds an adoption's progress or its adopted state.
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
	var left []string
	for _, name := range setAsideOrder() {
		if _, err := os.Lstat(filepath.Join(mobileHubDir, name)); err == nil {
			left = append(left, name)
		} else if !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("adopt: reading the MobileHub dir: %w", err)
		}
	}
	if len(left) == 0 {
		return nil // nothing left: set aside (or there was nothing)
	}
	if err := r.writeMovedNote(); err != nil {
		return err
	}
	aside, err := setAsideDir(mobileHubDir, now)
	if err != nil {
		return err
	}
	for _, name := range left {
		if err := setAsideRename(filepath.Join(mobileHubDir, name), filepath.Join(aside, name)); err != nil {
			return fmt.Errorf("adopt: setting the Swift hub's files aside: %w", err)
		}
	}
	if err := syncDir(mobileHubDir); err != nil {
		return err
	}
	log.Printf("hub adopt: the Swift hub's state was set aside (%d file(s)), not imported", len(left))
	return nil
}

// setAsideDir is the folder a move finishes into: the newest set-aside
// folder when an earlier move stopped part-way (MOVED is there already),
// else a new one.
func setAsideDir(mobileHubDir string, now func() time.Time) (string, error) {
	if exists(filepath.Join(mobileHubDir, MovedName)) {
		earlier, err := filepath.Glob(filepath.Join(mobileHubDir, setAsideDirPrefix+"*"))
		if err != nil {
			return "", err
		}
		if len(earlier) > 0 {
			sort.Strings(earlier)
			return earlier[len(earlier)-1], nil
		}
	}
	dir := filepath.Join(mobileHubDir, setAsideDirPrefix+now().UTC().Format("20060102T150405Z"))
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", fmt.Errorf("adopt: the set-aside dir: %w", err)
	}
	return dir, nil
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
