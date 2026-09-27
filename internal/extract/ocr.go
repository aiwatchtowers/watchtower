package extract

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// OCRTimeout bounds one OCR helper run (global constraints: 60 s). The
// Swift helper exits on its own 10 s later, so an orphan outliving a
// SIGKILLed daemon cannot run forever.
const OCRTimeout = 60 * time.Second

// helperEnv overrides where the OCR helper is looked up; helperName is
// the executable shipped next to the CLI (app bundle and CLI store).
const (
	helperEnv  = "WATCHTOWER_OCR_HELPER"
	helperName = "watchtower-ocr"
)

// maxOCROutput caps the helper's stdout: MaxOCRPages pages of text fit
// comfortably; more means a misbehaving helper. maxOCRStderr keeps enough
// of stderr for an error message.
const (
	maxOCROutput = 8 << 20
	maxOCRStderr = 4 << 10
)

// ErrOCRUnavailable is returned by an OCR that cannot run at all (its
// helper failed verification): the attachment is recorded ocr_unavailable,
// never ocr_pending, and is recognized once a valid helper appears.
var ErrOCRUnavailable = errors.New("extract: OCR unavailable")

// helperOCR runs the watchtower-ocr helper (Vision, on device) on a
// spooled file: `watchtower-ocr <file> [--pages 0,2,5]`, stdout
// {"pages":[{"index":0,"text":"…"}]}.
type helperOCR struct {
	path     string
	timeout  time.Duration
	verifier *helperVerifier
}

// NewHelperOCR returns the OCR backed by the helper at path, or a nil OCR
// (OCR unavailable) when path is empty — an untyped nil, so
// Extractor.HasOCR reports false. Before every run the helper's code
// signature is checked against our own (see helperVerifier).
func NewHelperOCR(path string, timeout time.Duration, opts ...HelperOption) OCR {
	if path == "" {
		return nil
	}
	h := &helperOCR{path: path, timeout: timeout, verifier: newHelperVerifier(nil)}
	for _, o := range opts {
		o(h)
	}
	return h
}

// Available reports whether the helper passes the signature check now
// (cached per file identity). Extractor.HasOCR consults it, so rows stored
// ocr_unavailable are not downloaded again while the helper is rejected.
func (h *helperOCR) Available(ctx context.Context) bool { return h.verifier.allowed(ctx, h.path) }

type ocrHelperOutput struct {
	Pages []struct {
		Index int    `json:"index"`
		Text  string `json:"text"`
	} `json:"pages"`
}

// Recognize runs the helper on path under the timeout. pages nil means an
// image (no --pages flag, only index 0 is kept); otherwise only the
// requested pages are kept. A helper failing the signature check is
// ErrOCRUnavailable and never runs. A timeout, crash, non-zero exit or
// malformed output is an error; a cancelled ctx returns ctx's error.
func (h *helperOCR) Recognize(ctx context.Context, path string, pages []int) (map[int]string, error) {
	if pages != nil && len(pages) == 0 {
		return map[int]string{}, nil // nothing asked; an image passes nil
	}
	if !h.Available(ctx) {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		return nil, ErrOCRUnavailable
	}
	out, err := h.run(ctx, path, pages)
	if err != nil {
		return nil, err
	}
	var res ocrHelperOutput
	if err := json.Unmarshal(out, &res); err != nil {
		return nil, fmt.Errorf("ocr helper: malformed output: %w", err)
	}
	want := map[int]bool{0: pages == nil}
	for _, p := range pages {
		want[p] = true
	}
	got := map[int]string{}
	for _, p := range res.Pages {
		if want[p.Index] {
			got[p.Index] = p.Text
		}
	}
	return got, nil
}

// run executes the helper and returns its stdout.
func (h *helperOCR) run(ctx context.Context, path string, pages []int) ([]byte, error) {
	cctx, cancel := context.WithTimeout(ctx, h.timeout)
	defer cancel()
	cmd := exec.CommandContext(cctx, h.path, helperArgs(path, pages)...) //nolint:gosec // the helper path is resolved by us, the file is our own temp file
	stdout := &cappedBuffer{max: maxOCROutput}
	stderr := &cappedBuffer{max: maxOCRStderr, truncate: true} // more stderr must not fail a good batch
	cmd.Stdout, cmd.Stderr = stdout, stderr
	cmd.WaitDelay = 5 * time.Second
	err := cmd.Run()
	switch {
	case ctx.Err() != nil:
		return nil, ctx.Err()
	case errors.Is(cctx.Err(), context.DeadlineExceeded):
		return nil, fmt.Errorf("ocr helper timed out after %s", h.timeout)
	case err != nil:
		return nil, fmt.Errorf("ocr helper: %w: %s", err, strings.TrimSpace(stderr.buf.String()))
	case stdout.overflow:
		return nil, errors.New("ocr helper: output exceeds the cap")
	}
	return stdout.buf.Bytes(), nil
}

// helperArgs is the helper's argument list; path is always an absolute
// temp file, never mistaken for a flag.
func helperArgs(path string, pages []int) []string {
	if len(pages) == 0 {
		return []string{path}
	}
	list := make([]string, len(pages))
	for i, p := range pages {
		list[i] = strconv.Itoa(p)
	}
	return []string{path, "--pages", strings.Join(list, ",")}
}

// ResolveHelperPath finds the OCR helper: $WATCHTOWER_OCR_HELPER when it
// names an executable, else watchtower-ocr next to this executable (the
// app bundle's Contents/MacOS, or the CLI store copy), also after
// resolving symlinks; "" when there is none (OCR unavailable).
func ResolveHelperPath() string {
	return resolveHelperPath(os.Getenv, os.Executable)
}

func resolveHelperPath(getenv func(string) string, executable func() (string, error)) string {
	if p := getenv(helperEnv); p != "" && isExecutableFile(p) {
		return p
	}
	exe, err := executable()
	if err != nil {
		return ""
	}
	candidates := []string{filepath.Join(filepath.Dir(exe), helperName)}
	if resolved, err := filepath.EvalSymlinks(exe); err == nil {
		candidates = append(candidates, filepath.Join(filepath.Dir(resolved), helperName))
	}
	for _, c := range candidates {
		if isExecutableFile(c) {
			return c
		}
	}
	return ""
}

func isExecutableFile(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.Mode().IsRegular() && fi.Mode().Perm()&0o111 != 0
}
