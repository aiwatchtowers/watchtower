//go:build darwin

package backupexclude

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/unix"
)

// readAttr returns the exclusion attribute's value on path (following links),
// or nil when it is absent.
func readAttr(t *testing.T, path string) []byte {
	t.Helper()
	buf := make([]byte, 256)
	n, err := unix.Getxattr(path, Attr, buf)
	if errors.Is(err, unix.ENOATTR) {
		return nil
	}
	if err != nil {
		t.Fatalf("getxattr %s: %v", path, err)
	}
	return buf[:n]
}

func requireExcluded(t *testing.T, dir string) {
	t.Helper()
	if got := readAttr(t, dir); !bytes.Equal(got, fixture) {
		t.Fatalf("%s: attribute = %q, want the fixture bytes", dir, got)
	}
}

// countSetxattr wraps the seam and counts its calls.
func countSetxattr(t *testing.T) *int {
	t.Helper()
	calls := 0
	orig := setxattr
	setxattr = func(path, attr string, data []byte, flags int) error {
		calls++
		return orig(path, attr, data, flags)
	}
	t.Cleanup(func() { setxattr = orig })
	return &calls
}

func TestFixtureIsTheTmutilPlist(t *testing.T) {
	if !bytes.HasPrefix(fixture, []byte("bplist00")) || !bytes.Contains(fixture, []byte("com.apple.backupd")) {
		t.Fatalf("fixture is not the tmutil binary plist: %q", fixture)
	}
}

func TestBackup01_DataRootsExcluded(t *testing.T) {
	dirs := []string{t.TempDir(), t.TempDir(), t.TempDir()}
	if errs := Apply(dirs); len(errs) != 0 {
		t.Fatalf("Apply: %v", errs)
	}
	for _, d := range dirs {
		requireExcluded(t, d)
	}
	tm, err := exec.LookPath("tmutil")
	if err != nil {
		t.Logf("tmutil not found, skipping the oracle half: %v", err)
		return
	}
	for _, d := range dirs {
		out, err := exec.Command(tm, "isexcluded", d).CombinedOutput()
		if err != nil {
			t.Fatalf("tmutil isexcluded %s: %v\n%s", d, err, out)
		}
		if !strings.Contains(string(out), "[Excluded]") {
			t.Fatalf("tmutil isexcluded %s = %q, want [Excluded]", d, out)
		}
	}
}

func TestApply_SecondRunWritesNothing(t *testing.T) {
	dirs := []string{t.TempDir(), t.TempDir()}
	calls := countSetxattr(t)
	if errs := Apply(dirs); len(errs) != 0 {
		t.Fatalf("first Apply: %v", errs)
	}
	if *calls != 2 {
		t.Fatalf("first Apply wrote %d times, want 2", *calls)
	}
	*calls = 0
	if errs := Apply(dirs); len(errs) != 0 {
		t.Fatalf("second Apply: %v", errs)
	}
	if *calls != 0 {
		t.Fatalf("second Apply wrote %d times, want 0", *calls)
	}
}

func TestApply_RecreatedFolderExcludedAgain(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "root")
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if errs := Apply([]string{dir}); len(errs) != 0 {
		t.Fatalf("Apply: %v", errs)
	}
	if err := os.RemoveAll(dir); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if got := readAttr(t, dir); got != nil {
		t.Fatalf("recreated folder already has the attribute: %q", got)
	}
	if errs := Apply([]string{dir}); len(errs) != 0 {
		t.Fatalf("Apply after recreate: %v", errs)
	}
	requireExcluded(t, dir)
}

func TestApply_SymlinkTargetGetsAttr(t *testing.T) {
	base := t.TempDir()
	target := filepath.Join(base, "target")
	link := filepath.Join(base, "link")
	if err := os.Mkdir(target, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if errs := Apply([]string{link}); len(errs) != 0 {
		t.Fatalf("Apply: %v", errs)
	}
	requireExcluded(t, target)
	buf := make([]byte, 256)
	if _, err := unix.Lgetxattr(link, Attr, buf); !errors.Is(err, unix.ENOATTR) {
		t.Fatalf("lgetxattr on the link = %v, want ENOATTR", err)
	}
}

func TestApply_MissingDirSkipped(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "nope")
	if errs := Apply([]string{missing}); len(errs) != 0 {
		t.Fatalf("Apply on a missing dir: %v", errs)
	}
	if _, err := os.Lstat(missing); !os.IsNotExist(err) {
		t.Fatalf("missing dir was created: %v", err)
	}
}

func TestApply_OneFailureDoesNotStopOthers(t *testing.T) {
	dirs := []string{t.TempDir(), t.TempDir(), t.TempDir()}
	bad, err := filepath.EvalSymlinks(dirs[1])
	if err != nil {
		t.Fatal(err)
	}
	orig := setxattr
	setxattr = func(path, attr string, data []byte, flags int) error {
		if path == bad {
			return unix.ENOTSUP
		}
		return orig(path, attr, data, flags)
	}
	t.Cleanup(func() { setxattr = orig })

	errs := Apply(dirs)
	if len(errs) != 1 {
		t.Fatalf("Apply returned %d errors, want 1: %v", len(errs), errs)
	}
	if !errors.Is(errs[0], unix.ENOTSUP) || !strings.Contains(errs[0].Error(), dirs[1]) {
		t.Fatalf("error = %v, want ENOTSUP naming %s", errs[0], dirs[1])
	}
	requireExcluded(t, dirs[0])
	requireExcluded(t, dirs[2])
}

func TestApply_RewritesForeignValue(t *testing.T) {
	dir := t.TempDir()
	if err := unix.Setxattr(dir, Attr, []byte("x"), 0); err != nil {
		t.Fatal(err)
	}
	calls := countSetxattr(t)
	if errs := Apply([]string{dir}); len(errs) != 0 {
		t.Fatalf("Apply: %v", errs)
	}
	requireExcluded(t, dir)
	if *calls != 1 {
		t.Fatalf("Apply wrote %d times, want 1", *calls)
	}
	*calls = 0
	_ = Apply([]string{dir})
	if *calls != 0 {
		t.Fatalf("second Apply wrote %d times, want 0", *calls)
	}
}
