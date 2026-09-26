package extract

import (
	"bytes"
	"context"
	"fmt"
	"log"
	"os"
	"os/exec"
	"regexp"
	"runtime"
	"sync"
	"syscall"
	"time"
)

// The OCR helper lives next to the CLI in the store directory
// (~/Library/Application Support/Watchtower/bin), which is user-writable.
// The Desktop re-checks the store CLI's code signature on every resolution
// (CLIBinaryStore.resolvedInstalledPath); the Go side applies the same gate
// to the helper before every exec, so a same-uid swap of the file cannot
// run arbitrary code under the app's TCC responsibility chain.
//
// The signature class follows our own executable: Developer-ID signed with
// Team ID T → the helper must satisfy the Team-ID designated requirement
// for T (the requirement string CLIBinaryStore uses); ad-hoc or unsigned
// (a dev build), or a platform without code signing → the check is skipped
// and that is logged once. A failed check makes OCR unavailable; the helper
// is never run.

// codesignRunner runs codesign with args — exec, no shell — and returns
// its combined output. A seam for tests.
type codesignRunner func(ctx context.Context, args ...string) ([]byte, error)

func runCodesign(ctx context.Context, args ...string) ([]byte, error) {
	return exec.CommandContext(ctx, "/usr/bin/codesign", args...).CombinedOutput()
}

// codesignTimeout bounds one codesign call.
const codesignTimeout = 20 * time.Second

var (
	teamIDLine   = regexp.MustCompile(`(?m)^TeamIdentifier=(.+)$`)
	validTeamID  = regexp.MustCompile(`^[A-Z0-9]{10}$`)
	notSignedMsg = []byte("code object is not signed at all")
)

// helperVerifier decides whether a helper file may be executed, caching
// the verdict per file identity (path, inode, mtime, size): one codesign
// call per helper change, not per attachment.
type helperVerifier struct {
	run    codesignRunner
	self   func() (string, error) // our own executable (os.Executable)
	goos   string
	logger *log.Logger

	once    sync.Once
	team    string // our Team ID; "" with skip or selfErr
	skip    bool   // our own executable is ad-hoc/unsigned: no check
	selfErr error  // our signature class could not be read: fail closed

	mu      sync.Mutex
	cache   map[string]verdict // by path
	skipLog sync.Once
}

type verdict struct {
	key fileKey
	ok  bool
}

type fileKey struct {
	ino         uint64
	mtime, size int64
}

func newHelperVerifier(logger *log.Logger) *helperVerifier {
	return &helperVerifier{run: runCodesign, self: os.Executable, goos: runtime.GOOS, logger: logger}
}

func (v *helperVerifier) logf(format string, args ...any) {
	if v.logger != nil {
		v.logger.Printf(format, args...)
	}
}

// allowed reports whether the helper at path may be executed.
func (v *helperVerifier) allowed(path string) bool {
	v.once.Do(v.readSelf)
	switch {
	case v.selfErr != nil:
		return false
	case v.skip:
		v.skipLog.Do(func() {
			v.logf("ocr helper: own executable is not Developer-ID signed; skipping the helper signature check (dev build)")
		})
		return true
	}
	key, err := statKey(path)
	if err != nil {
		v.logf("ocr helper %s: %v; OCR unavailable", path, err)
		return false
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	if c, ok := v.cache[path]; ok && c.key == key {
		return c.ok
	}
	ok := v.verify(path)
	if v.cache == nil {
		v.cache = map[string]verdict{}
	}
	v.cache[path] = verdict{key: key, ok: ok}
	return ok
}

// verify runs the Team-ID requirement check on path.
func (v *helperVerifier) verify(path string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), codesignTimeout)
	defer cancel()
	req := fmt.Sprintf(`-R=anchor apple generic and certificate leaf[subject.OU] = "%s"`, v.team)
	out, err := v.run(ctx, "--verify", "--strict", req, path)
	if err != nil {
		v.logf("ocr helper %s fails the signature check for team %s (%v: %s); OCR unavailable",
			path, v.team, err, bytes.TrimSpace(out))
		return false
	}
	return true
}

// readSelf reads our own signature class once.
func (v *helperVerifier) readSelf() {
	if v.goos != "darwin" {
		v.skip = true
		return
	}
	exe, err := v.self()
	if err != nil {
		v.fail(fmt.Errorf("locating own executable: %w", err))
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), codesignTimeout)
	defer cancel()
	out, err := v.run(ctx, "-dv", "--verbose=2", exe)
	if m := teamIDLine.FindSubmatch(out); m != nil {
		team := string(bytes.TrimSpace(m[1]))
		switch {
		case team == "not set": // ad-hoc signed
			v.skip = true
		case validTeamID.MatchString(team):
			v.team = team
		default:
			v.fail(fmt.Errorf("unexpected Team ID %q", team))
		}
		return
	}
	if bytes.Contains(out, notSignedMsg) {
		v.skip = true
		return
	}
	v.fail(fmt.Errorf("reading own signature: %v: %s", err, bytes.TrimSpace(out)))
}

func (v *helperVerifier) fail(err error) {
	v.selfErr = err
	v.logf("ocr helper: %v; OCR unavailable", err)
}

// statKey identifies the file's current content well enough to re-verify
// after any replacement (a rename changes the inode, a rewrite the mtime).
func statKey(path string) (fileKey, error) {
	fi, err := os.Stat(path)
	if err != nil {
		return fileKey{}, err
	}
	k := fileKey{mtime: fi.ModTime().UnixNano(), size: fi.Size()}
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		k.ino = uint64(st.Ino) //nolint:unconvert // Ino is int-sized on some platforms
	}
	return k, nil
}

// HelperOption configures NewHelperOCR.
type HelperOption func(*helperOCR)

// WithLogger routes the helper's verification messages to logger.
func WithLogger(logger *log.Logger) HelperOption {
	return func(h *helperOCR) { h.verifier.logger = logger }
}
