package extract

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// fakeHelper writes an executable shell script standing in for
// watchtower-ocr. It records its arguments in args.txt next to itself.
func fakeHelper(t *testing.T, body string) (path, argsFile string) {
	t.Helper()
	dir := t.TempDir()
	path = filepath.Join(dir, "watchtower-ocr")
	argsFile = filepath.Join(dir, "args.txt")
	script := "#!/bin/sh\necho \"$@\" > '" + argsFile + "'\n" + body + "\n"
	require.NoError(t, os.WriteFile(path, []byte(script), 0o700)) //nolint:gosec // a test script must be executable
	return path, argsFile
}

func readArgs(t *testing.T, file string) string {
	t.Helper()
	b, err := os.ReadFile(file) //nolint:gosec // test-owned path
	require.NoError(t, err)
	return strings.TrimSpace(string(b))
}

func TestHelperOCRParsesPages(t *testing.T) {
	helper, args := fakeHelper(t, `echo '{"pages":[{"index":0,"text":" first "},{"index":2,"text":"third"},{"index":7,"text":"not asked"}]}'`)
	ocr := NewHelperOCR(helper, 10*time.Second)
	require.NotNil(t, ocr)

	got, err := ocr.Recognize(context.Background(), "/tmp/extract/att-1.pdf", []int{0, 2, 5})
	require.NoError(t, err)
	assert.Equal(t, map[int]string{0: " first ", 2: "third"}, got, "only the requested pages are kept")
	assert.Equal(t, "/tmp/extract/att-1.pdf --pages 0,2,5", readArgs(t, args))
}

func TestHelperOCRImageHasNoPagesFlag(t *testing.T) {
	helper, args := fakeHelper(t, `echo '{"pages":[{"index":0,"text":"whiteboard"},{"index":1,"text":"x"}]}'`)
	got, err := NewHelperOCR(helper, 10*time.Second).Recognize(context.Background(), "/tmp/extract/att-2.png", nil)
	require.NoError(t, err)
	assert.Equal(t, map[int]string{0: "whiteboard"}, got, "an image is page 0 only")
	assert.Equal(t, "/tmp/extract/att-2.png", readArgs(t, args))
}

func TestHelperOCRTimeout(t *testing.T) {
	helper, _ := fakeHelper(t, "exec sleep 5")
	start := time.Now()
	_, err := NewHelperOCR(helper, 200*time.Millisecond).Recognize(context.Background(), "/tmp/x.png", nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "timed out")
	assert.Less(t, time.Since(start), 4*time.Second, "the helper is killed at the timeout")
}

func TestHelperOCRExitError(t *testing.T) {
	helper, _ := fakeHelper(t, "echo 'cannot read file' >&2; exit 2")
	_, err := NewHelperOCR(helper, 10*time.Second).Recognize(context.Background(), "/tmp/x.png", nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "cannot read file", "the helper's stderr is in the error")
}

func TestHelperOCRMalformedOutput(t *testing.T) {
	helper, _ := fakeHelper(t, "echo 'not json'")
	_, err := NewHelperOCR(helper, 10*time.Second).Recognize(context.Background(), "/tmp/x.png", nil)
	require.Error(t, err)
}

func TestHelperOCRCancelledContext(t *testing.T) {
	helper, _ := fakeHelper(t, "exec sleep 5")
	ctx, cancel := context.WithCancel(context.Background())
	go func() { time.Sleep(100 * time.Millisecond); cancel() }()
	_, err := NewHelperOCR(helper, 10*time.Second).Recognize(ctx, "/tmp/x.png", nil)
	require.ErrorIs(t, err, context.Canceled)
}

// TestNewHelperOCRNilWhenNoPath: an empty path is "no OCR" — a nil
// interface, not a typed nil, so Extractor.HasOCR reports false.
func TestNewHelperOCRNilWhenNoPath(t *testing.T) {
	ocr := NewHelperOCR("", time.Second)
	assert.Nil(t, ocr)
	assert.False(t, (&Extractor{OCR: ocr}).HasOCR())
}

func TestOCRTimeoutIsSixtySeconds(t *testing.T) {
	assert.Equal(t, 60*time.Second, OCRTimeout)
}

func TestResolveHelperPath(t *testing.T) {
	exeDir := t.TempDir()
	exe := filepath.Join(exeDir, "watchtower")
	require.NoError(t, os.WriteFile(exe, []byte("#!/bin/sh\n"), 0o700)) //nolint:gosec // test executable
	nextTo := filepath.Join(exeDir, "watchtower-ocr")
	executable := func() (string, error) { return exe, nil }
	env := map[string]string{}
	getenv := func(k string) string { return env[k] }

	assert.Empty(t, resolveHelperPath(getenv, executable), "no helper anywhere")

	require.NoError(t, os.WriteFile(nextTo, []byte("#!/bin/sh\n"), 0o600)) //nolint:gosec // deliberately not executable
	assert.Empty(t, resolveHelperPath(getenv, executable), "a non-executable file is not a helper")
	require.NoError(t, os.Chmod(nextTo, 0o700)) //nolint:gosec // test executable
	assert.Equal(t, nextTo, resolveHelperPath(getenv, executable), "next to the executable")

	override, _ := fakeHelper(t, "true")
	env[helperEnv] = override
	assert.Equal(t, override, resolveHelperPath(getenv, executable), "the env var wins")

	env[helperEnv] = filepath.Join(t.TempDir(), "missing")
	assert.Equal(t, nextTo, resolveHelperPath(getenv, executable), "an unusable env var falls back")
}

// TestResolveHelperPathFollowsSymlink: a CLI started through a symlink
// (e.g. on PATH) still finds the helper next to the real binary.
func TestResolveHelperPathFollowsSymlink(t *testing.T) {
	realDir, linkDir := t.TempDir(), t.TempDir()
	exe := filepath.Join(realDir, "watchtower")
	require.NoError(t, os.WriteFile(exe, []byte("#!/bin/sh\n"), 0o700))                                      //nolint:gosec // test executable
	require.NoError(t, os.WriteFile(filepath.Join(realDir, "watchtower-ocr"), []byte("#!/bin/sh\n"), 0o700)) //nolint:gosec // test executable
	link := filepath.Join(linkDir, "watchtower")
	require.NoError(t, os.Symlink(exe, link))
	got := resolveHelperPath(func(string) string { return "" }, func() (string, error) { return link, nil })
	want, err := filepath.EvalSymlinks(filepath.Join(realDir, "watchtower-ocr"))
	require.NoError(t, err)
	gotReal, err := filepath.EvalSymlinks(got)
	require.NoError(t, err)
	assert.Equal(t, want, gotReal)
}

// TestExtractWithRealOCRHelper runs the real Swift helper end to end when
// WATCHTOWER_OCR_E2E_HELPER names it (e.g. WatchtowerDesktop/.build/debug/
// watchtower-ocr): a scan PDF and an image with no words come back ok —
// OCR ran and found nothing — never ocr_pending.
func TestExtractWithRealOCRHelper(t *testing.T) {
	helper := os.Getenv("WATCHTOWER_OCR_E2E_HELPER")
	if helper == "" {
		t.Skip("set WATCHTOWER_OCR_E2E_HELPER to the built watchtower-ocr")
	}
	x := newExtractor(t, NewHelperOCR(helper, OCRTimeout))
	_, status := run(t, x, "application/pdf", "scanned.pdf")
	assert.Equal(t, StatusOK, status)
	_, status = run(t, x, "image/png", "sample.png")
	assert.Equal(t, StatusOK, status)
}

// TestPDFHelperDeadlineIsTimeoutPlusMargin: the helper's own exit comes
// 10 s after the parent's kill, never before it.
func TestPDFHelperDeadlineIsTimeoutPlusMargin(t *testing.T) {
	assert.Equal(t, 70*time.Second, PDFHelperDeadline())
}
