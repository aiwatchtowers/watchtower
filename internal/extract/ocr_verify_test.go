package extract

import (
	"bytes"
	"context"
	"errors"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// fakeCodesign answers `-dv` with self and `--verify` with verifyErr,
// recording every call.
type fakeCodesign struct {
	mu        sync.Mutex
	self      string
	selfErr   error
	verifyErr error
	calls     [][]string
}

func (f *fakeCodesign) run(_ context.Context, args ...string) ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, append([]string(nil), args...))
	if args[0] == "-dv" {
		return []byte(f.self), f.selfErr
	}
	if f.verifyErr != nil {
		return []byte("test-helper: code failed to satisfy specified code requirement(s)"), f.verifyErr
	}
	return nil, nil
}

func (f *fakeCodesign) verifyCalls() [][]string {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out [][]string
	for _, c := range f.calls {
		if c[0] == "--verify" {
			out = append(out, c)
		}
	}
	return out
}

const developerIDSelf = "Executable=/x/watchtower\nIdentifier=watchtower\nAuthority=Developer ID Application: Example (ABCDE12345)\nTeamIdentifier=ABCDE12345\n"

// verifiedHelper builds a helper OCR over a fake helper script whose
// signature checks go to cs; logs land in the returned buffer.
func verifiedHelper(t *testing.T, cs *fakeCodesign) (OCR, string, *bytes.Buffer) {
	t.Helper()
	helper, args := fakeHelper(t, `echo '{"pages":[{"index":0,"text":"words"}]}'`)
	var logs bytes.Buffer
	ocr := NewHelperOCR(helper, 10*time.Second, WithLogger(log.New(&logs, "", 0)))
	v := ocr.(*helperOCR).verifier
	v.run, v.goos = cs.run, "darwin"
	v.self = func() (string, error) { return "/x/watchtower", nil }
	return ocr, args, &logs
}

// TestHelperSignatureVerifiedAgainstOwnTeam (fix round 1, finding 3): with
// a Developer-ID signed own executable, the helper must satisfy that
// team's designated requirement before it runs.
func TestHelperSignatureVerifiedAgainstOwnTeam(t *testing.T) {
	cs := &fakeCodesign{self: developerIDSelf}
	ocr, args, _ := verifiedHelper(t, cs)
	got, err := ocr.Recognize(context.Background(), "/tmp/extract/att-1.png", nil)
	require.NoError(t, err)
	assert.Equal(t, map[int]string{0: "words"}, got)
	calls := cs.verifyCalls()
	require.Len(t, calls, 1)
	assert.Equal(t, []string{"--verify", "--strict",
		`-R=anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345"`,
		ocr.(*helperOCR).path}, calls[0])
	assert.FileExists(t, args, "the verified helper ran")
}

// TestHelperFailingSignatureNeverRuns: a helper that fails the check is
// never executed; OCR reports unavailable and the extractor answers
// ocr_unavailable (not ocr_pending, so nothing is retried against it).
func TestHelperFailingSignatureNeverRuns(t *testing.T) {
	cs := &fakeCodesign{self: developerIDSelf, verifyErr: errors.New("exit status 3")}
	ocr, args, logs := verifiedHelper(t, cs)
	_, err := ocr.Recognize(context.Background(), "/tmp/extract/att-1.png", nil)
	require.ErrorIs(t, err, ErrOCRUnavailable)
	assert.NoFileExists(t, args, "a rejected helper is never run")
	assert.Contains(t, logs.String(), "fails the signature check")

	x := newExtractor(t, ocr)
	assert.False(t, x.HasOCR(context.Background()))
	_, status := run(t, x, "image/png", "sample.png")
	assert.Equal(t, StatusOCRUnavailable, status)
	_, status = run(t, x, "application/pdf", "scanned.pdf")
	assert.Equal(t, StatusOCRUnavailable, status)
	assert.NoFileExists(t, args)
}

// TestHelperCheckSkippedForAdHocOwnExecutable: a dev build (own executable
// ad-hoc or unsigned) skips the check — logged once — and runs the helper.
func TestHelperCheckSkippedForAdHocOwnExecutable(t *testing.T) {
	for name, cs := range map[string]*fakeCodesign{
		"ad-hoc":   {self: "Executable=/x/watchtower\nSignature=adhoc\nTeamIdentifier=not set\n"},
		"unsigned": {self: "/x/watchtower: code object is not signed at all\n", selfErr: errors.New("exit status 1")},
	} {
		t.Run(name, func(t *testing.T) {
			ocr, args, logs := verifiedHelper(t, cs)
			for range 2 {
				_, err := ocr.Recognize(context.Background(), "/tmp/extract/att-1.png", nil)
				require.NoError(t, err)
			}
			assert.FileExists(t, args)
			assert.Empty(t, cs.verifyCalls())
			assert.Equal(t, 1, strings.Count(logs.String(), "skipping the helper signature check"), "logged once")
		})
	}
}

// TestHelperCheckFailsClosedWhenOwnSignatureUnreadable: when our own
// signature class cannot be read at all, OCR is unavailable.
func TestHelperCheckFailsClosedWhenOwnSignatureUnreadable(t *testing.T) {
	cs := &fakeCodesign{self: "codesign: something broke", selfErr: errors.New("exit status 2")}
	ocr, args, _ := verifiedHelper(t, cs)
	_, err := ocr.Recognize(context.Background(), "/tmp/extract/att-1.png", nil)
	require.ErrorIs(t, err, ErrOCRUnavailable)
	assert.NoFileExists(t, args)
}

// TestHelperVerdictCachedPerFileIdentity: one codesign call per helper
// change, not per attachment — a rewritten helper is verified again.
func TestHelperVerdictCachedPerFileIdentity(t *testing.T) {
	cs := &fakeCodesign{self: developerIDSelf}
	ocr, _, _ := verifiedHelper(t, cs)
	for range 5 {
		_, err := ocr.Recognize(context.Background(), "/tmp/extract/att-1.png", nil)
		require.NoError(t, err)
	}
	assert.True(t, ocr.(*helperOCR).Available(context.Background()))
	assert.Len(t, cs.verifyCalls(), 1, "five runs, one verification")

	path := ocr.(*helperOCR).path
	body, err := os.ReadFile(path) //nolint:gosec // test-owned path
	require.NoError(t, err)
	swapped := filepath.Join(filepath.Dir(path), "swapped")
	require.NoError(t, os.WriteFile(swapped, append(body, '\n'), 0o700)) //nolint:gosec // test script
	require.NoError(t, os.Rename(swapped, path))
	cs.verifyErr = errors.New("exit status 3")
	_, err = ocr.Recognize(context.Background(), "/tmp/extract/att-1.png", nil)
	require.ErrorIs(t, err, ErrOCRUnavailable, "the swapped file is verified again and rejected")
	assert.Len(t, cs.verifyCalls(), 2)
}

// TestHelperCheckSkippedOffDarwin: no code signing elsewhere (and no
// helper is shipped there); the check is skipped.
func TestHelperCheckSkippedOffDarwin(t *testing.T) {
	cs := &fakeCodesign{self: developerIDSelf}
	ocr, _, _ := verifiedHelper(t, cs)
	ocr.(*helperOCR).verifier.goos = "linux"
	_, err := ocr.Recognize(context.Background(), "/tmp/extract/att-1.png", nil)
	require.NoError(t, err)
	assert.Empty(t, cs.calls)
}

// blockingCodesign answers like fakeCodesign, except that while block is
// set every call waits for its ctx to end (a hung codesign).
type blockingCodesign struct {
	fakeCodesign
	block bool
}

func (b *blockingCodesign) run(ctx context.Context, args ...string) ([]byte, error) {
	b.mu.Lock()
	block := b.block
	b.mu.Unlock()
	if block {
		<-ctx.Done()
		return nil, ctx.Err()
	}
	return b.fakeCodesign.run(ctx, args...)
}

// TestHelperCheckStopsOnCancel: codesign runs under the caller's ctx, so a
// shutdown stops a hung check at once; the cut-short check caches nothing
// (neither our own signature class nor the helper's verdict), so a later
// call verifies normally instead of failing closed for good.
func TestHelperCheckStopsOnCancel(t *testing.T) {
	for _, stage := range []string{"own signature", "helper verify"} {
		t.Run(stage, func(t *testing.T) {
			cs := &blockingCodesign{fakeCodesign: fakeCodesign{self: developerIDSelf}}
			ocr, args, _ := verifiedHelper(t, &cs.fakeCodesign)
			v := ocr.(*helperOCR).verifier
			v.run = cs.run
			if stage == "helper verify" {
				v.ensureSelf(context.Background()) // our own class read; only the helper check hangs
			}
			cs.mu.Lock()
			cs.block = true
			cs.mu.Unlock()

			ctx, cancel := context.WithCancel(context.Background())
			go func() { time.Sleep(50 * time.Millisecond); cancel() }()
			start := time.Now()
			_, err := ocr.Recognize(ctx, "/tmp/extract/att-1.png", nil)
			require.ErrorIs(t, err, context.Canceled, "a cancelled check is not ErrOCRUnavailable")
			assert.Less(t, time.Since(start), 5*time.Second, "codesign was stopped by the cancel, not its own timeout")
			assert.NoFileExists(t, args)

			cs.mu.Lock()
			cs.block = false
			cs.mu.Unlock()
			got, err := ocr.Recognize(context.Background(), "/tmp/extract/att-1.png", nil)
			require.NoError(t, err, "nothing was cached by the cancelled check")
			assert.Equal(t, map[int]string{0: "words"}, got)
		})
	}
}

// TestRealBundleHelperSignature checks the real codesign path against a
// built app bundle when WATCHTOWER_OCR_E2E_BUNDLE names its
// Contents/MacOS directory: the bundled helper passes against the bundled
// CLI's team, and an ad-hoc re-signed copy is rejected.
func TestRealBundleHelperSignature(t *testing.T) {
	dir := os.Getenv("WATCHTOWER_OCR_E2E_BUNDLE")
	if dir == "" {
		t.Skip("set WATCHTOWER_OCR_E2E_BUNDLE to <app>/Contents/MacOS")
	}
	cli := filepath.Join(dir, "watchtower")
	newV := func() *helperVerifier {
		v := newHelperVerifier(log.New(os.Stderr, "", 0))
		v.self = func() (string, error) { return cli, nil }
		return v
	}
	assert.True(t, newV().allowed(context.Background(), filepath.Join(dir, "watchtower-ocr")))

	copyPath := filepath.Join(t.TempDir(), "watchtower-ocr")
	b, err := os.ReadFile(filepath.Join(dir, "watchtower-ocr")) //nolint:gosec // test input
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(copyPath, b, 0o700)) //nolint:gosec // test executable
	_, err = runCodesign(context.Background(), "--force", "--sign", "-", copyPath)
	require.NoError(t, err)
	assert.False(t, newV().allowed(context.Background(), copyPath), "an ad-hoc signed swap is rejected")
}
