package sessionhost

import (
	"encoding/json"
	"errors"
	"io/fs"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"watchtower/internal/config"
)

type pathsFixture struct {
	Socket []struct {
		BundleID string `json:"bundle_id"`
		TempDir  string `json:"temp_dir"`
		Want     string `json:"want"`
	} `json:"socket"`
	Scope []struct {
		DBPath string `json:"db_path"`
		Want   string `json:"want"`
	} `json:"scope"`
	// Home cases depend on the machine's home folder: the scope of db_path
	// must equal the scope of home + home_suffix.
	Home []struct {
		DBPath     string `json:"db_path"`
		HomeSuffix string `json:"home_suffix"`
	} `json:"home"`
}

// TestPathsFixture pins SocketPath and Scope to testdata/paths.json, which
// the Swift twin (SessionHostPathsFixtureTests) reads too.
func TestPathsFixture(t *testing.T) {
	b, err := os.ReadFile("testdata/paths.json")
	if err != nil {
		t.Fatal(err)
	}
	var f pathsFixture
	if err := json.Unmarshal(b, &f); err != nil {
		t.Fatal(err)
	}
	if len(f.Socket) == 0 || len(f.Scope) == 0 || len(f.Home) == 0 {
		t.Fatal("fixture has no cases")
	}
	for _, c := range f.Socket {
		if got := SocketPath(c.BundleID, c.TempDir); got != c.Want {
			t.Errorf("SocketPath(%q, %q) = %q, want %q", c.BundleID, c.TempDir, got, c.Want)
		}
	}
	for _, c := range f.Scope {
		if got := Scope(c.DBPath); got != c.Want {
			t.Errorf("Scope(%q) = %q, want %q", c.DBPath, got, c.Want)
		}
	}
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range f.Home {
		if got, want := Scope(c.DBPath), Scope(home+c.HomeSuffix); got != want {
			t.Errorf("Scope(%q) = %q, want the scope of home%s %q", c.DBPath, got, c.HomeSuffix, want)
		}
		if Scope(c.DBPath) == Scope(filepath.Join(os.TempDir(), c.DBPath)) {
			t.Errorf("Scope(%q) did not expand the home folder", c.DBPath)
		}
	}
}

func TestDefaultSocket(t *testing.T) {
	t.Setenv("HOME", shortTemp(t))
	t.Setenv(SocketEnv, "/tmp/hubtest-x.sock")
	if got, err := DefaultSocket(); err != nil || got != "/tmp/hubtest-x.sock" {
		t.Fatalf("DefaultSocket with override = %q, %v", got, err)
	}
	t.Setenv(SocketEnv, "")
	root, err := config.DataRoot()
	if err != nil {
		t.Fatal(err)
	}
	dir, err := socketDirFor(runtime.GOOS, os.TempDir(), root, os.Getuid(), os.Lstat)
	if err != nil {
		t.Fatal(err)
	}
	if got, err := DefaultSocket(); err != nil || got != SocketPath(BundleID, dir) {
		t.Fatalf("DefaultSocket = %q, %v, want %q", got, err, SocketPath(BundleID, dir))
	}
	if runtime.GOOS == "darwin" && dir != os.TempDir() {
		t.Fatalf("darwin socket dir = %q, want the temp folder", dir)
	}
}

// shortTemp is a private folder under /tmp, short enough for a socket path
// below it on darwin (sockaddr_un).
func shortTemp(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "shd")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = os.Chmod(dir, 0o700)
		_ = os.RemoveAll(dir)
	})
	return dir
}

// fakeInfo is an lstat answer for /run/user/<uid>, which a test cannot make.
type fakeInfo struct {
	mode fs.FileMode
	uid  int
}

func (f fakeInfo) Name() string       { return "x" }
func (f fakeInfo) Size() int64        { return 0 }
func (f fakeInfo) Mode() fs.FileMode  { return f.mode }
func (f fakeInfo) ModTime() time.Time { return time.Time{} }
func (f fakeInfo) IsDir() bool        { return f.mode.IsDir() }
func (f fakeInfo) Sys() any           { return &syscall.Stat_t{Uid: uint32(f.uid)} }

// me is the test's own uid: the fallback folders a test makes are its own.
var me = os.Getuid()

func runUser(uid int) string { return "/run/user/" + strconv.Itoa(uid) }

// runUserIs is the stat seam: socketDirFor lstats only /run/user/<uid>,
// answered with fi (nil = missing).
func runUserIs(t *testing.T, uid int, fi os.FileInfo) func(string) (os.FileInfo, error) {
	return func(p string) (os.FileInfo, error) {
		if p != runUser(uid) {
			t.Errorf("stat %q, want only %q", p, runUser(uid))
		}
		if fi == nil {
			return nil, fs.ErrNotExist
		}
		return fi, nil
	}
}

func TestSocketDirDarwinUnchanged(t *testing.T) {
	root := shortTemp(t)
	got, err := socketDirFor("darwin", "/var/folders/x/T/", root, me, func(string) (os.FileInfo, error) {
		t.Fatal("darwin must not stat anything")
		return nil, nil
	})
	if err != nil || got != "/var/folders/x/T/" {
		t.Fatalf("darwin = %q, %v, want the temp folder", got, err)
	}
	if _, err := os.Stat(filepath.Join(root, runDirName)); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("darwin created %s: %v", runDirName, err)
	}
}

func TestSocketDirLinuxUsesRunUserUID(t *testing.T) {
	root := shortTemp(t)
	got, err := socketDirFor("linux", os.TempDir(), root, me, runUserIs(t, me, fakeInfo{mode: fs.ModeDir | 0o700, uid: me}))
	if err != nil || got != runUser(me) {
		t.Fatalf("linux = %q, %v, want %q", got, err, runUser(me))
	}
	if _, err := os.Stat(filepath.Join(root, runDirName)); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("the fallback was created though /run/user/<uid> is usable: %v", err)
	}
}

func TestSocketDirLinuxIgnoresXDGRuntimeDir(t *testing.T) {
	root := shortTemp(t)
	other := shortTemp(t)
	for _, fi := range []os.FileInfo{fakeInfo{mode: fs.ModeDir | 0o700, uid: me}, nil} {
		// t.Setenv first registers the cleanup that restores the caller's
		// value; os.Unsetenv then makes it truly unset, not empty.
		t.Setenv("XDG_RUNTIME_DIR", "")
		_ = os.Unsetenv("XDG_RUNTIME_DIR")
		unset, err := socketDirFor("linux", os.TempDir(), root, me, runUserIs(t, me, fi))
		if err != nil {
			t.Fatal(err)
		}
		t.Setenv("XDG_RUNTIME_DIR", other)
		set, err := socketDirFor("linux", os.TempDir(), root, me, runUserIs(t, me, fi))
		if err != nil {
			t.Fatal(err)
		}
		if set != unset || set == other {
			t.Fatalf("XDG_RUNTIME_DIR changed the answer: unset %q, set %q", unset, set)
		}
	}
}

func TestSocketDirLinuxMissingRunUserFallsBack(t *testing.T) {
	root := shortTemp(t)
	got, err := socketDirFor("linux", os.TempDir(), root, me, runUserIs(t, me, nil))
	if want := filepath.Join(root, runDirName); err != nil || got != want {
		t.Fatalf("missing /run/user/<uid> = %q, %v, want %q", got, err, want)
	}
}

// Review Focus 3: a runtime folder another user could reach is never used.
func TestSocketDirLinuxRefusesAForeignOrLooseRuntimeDir(t *testing.T) {
	for name, fi := range map[string]os.FileInfo{
		"missing":       nil,
		"another owner": fakeInfo{mode: fs.ModeDir | 0o700, uid: me + 1},
		"mode 0755":     fakeInfo{mode: fs.ModeDir | 0o755, uid: me},
		"a symlink":     fakeInfo{mode: fs.ModeSymlink | 0o700, uid: me},
		"a file":        fakeInfo{mode: 0o700, uid: me},
	} {
		t.Run(name, func(t *testing.T) {
			root := shortTemp(t)
			got, err := socketDirFor("linux", os.TempDir(), root, me, runUserIs(t, me, fi))
			if want := filepath.Join(root, runDirName); err != nil || got != want {
				t.Fatalf("%s = %q, %v, want %q", name, got, err, want)
			}
		})
	}
}

func TestSocketDirLinuxFallbackIsPrivate(t *testing.T) {
	t.Run("created 0700", func(t *testing.T) {
		dir, err := socketDirFor("linux", os.TempDir(), shortTemp(t), me, runUserIs(t, me, nil))
		if err != nil {
			t.Fatal(err)
		}
		assertMode(t, dir, 0o700)
	})
	t.Run("a looser folder is tightened", func(t *testing.T) {
		root := shortTemp(t)
		dir := filepath.Join(root, runDirName)
		if err := os.Mkdir(dir, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if _, err := socketDirFor("linux", os.TempDir(), root, me, runUserIs(t, me, nil)); err != nil {
			t.Fatal(err)
		}
		assertMode(t, dir, 0o700)
	})
	t.Run("a symlink is refused", func(t *testing.T) {
		root := shortTemp(t)
		target := shortTemp(t)
		if err := os.Chmod(target, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(target, filepath.Join(root, runDirName)); err != nil {
			t.Fatal(err)
		}
		if _, err := socketDirFor("linux", os.TempDir(), root, me, runUserIs(t, me, nil)); !errors.Is(err, ErrRunDirUnusable) {
			t.Fatalf("a symlinked fallback = %v, want ErrRunDirUnusable", err)
		}
		assertMode(t, target, 0o755) // the symlink's target was never touched
	})
}

func TestSocketDirLinuxUnusableFallbackIsAnErrorNotTmp(t *testing.T) {
	before := hostSocketsInTemp(t)
	// uid is the uid socketDirFor is asked for; root the data root.
	cases := map[string]func(t *testing.T) (root string, uid int){
		"no data root":       func(*testing.T) (string, int) { return "", me },
		"a relative root":    func(*testing.T) (string, int) { return "rel/root", me },
		"a read-only parent": readOnlyRoot,
		"a file": func(t *testing.T) (string, int) {
			root := shortTemp(t)
			if err := os.WriteFile(filepath.Join(root, runDirName), nil, 0o600); err != nil {
				t.Fatal(err)
			}
			return root, me
		},
		// The folder the test makes is its own, so for another uid it is a
		// folder of another owner.
		"another owner": func(t *testing.T) (string, int) { return shortTemp(t), me + 1 },
	}
	for name, mk := range cases {
		t.Run(name, func(t *testing.T) {
			root, uid := mk(t)
			dir, err := socketDirFor("linux", os.TempDir(), root, uid, runUserIs(t, uid, nil))
			if !errors.Is(err, ErrRunDirUnusable) {
				t.Fatalf("%s = %q, %v, want ErrRunDirUnusable", name, dir, err)
			}
			if !strings.HasPrefix(err.Error(), "[Watchtower] the session host cannot use its socket folder: ") {
				t.Fatalf("message %q", err.Error())
			}
		})
	}
	if after := hostSocketsInTemp(t); !slices.Equal(before, after) {
		t.Fatalf("a host socket appeared in the temp folder: %v → %v", before, after)
	}
}

// A data root whose socket path cannot fit sockaddr_un is refused by name
// before anything is created.
func TestSocketDirLinuxTooLongSocketPathIsRefused(t *testing.T) {
	root := filepath.Join(shortTemp(t), strings.Repeat("d", maxSocketPath))
	_, err := socketDirFor("linux", os.TempDir(), root, me, runUserIs(t, me, nil))
	if !errors.Is(err, ErrRunDirUnusable) || !strings.Contains(err.Error(), "socket path too long") {
		t.Fatalf("a too-long socket path = %v, want ErrRunDirUnusable naming the length", err)
	}
	if _, err := os.Lstat(root); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("the data root was created: %v", err)
	}
	// The longest root that still fits is accepted.
	fit := shortTemp(t)
	fit = filepath.Join(fit, strings.Repeat("d", maxSocketPath-len(SocketPath(BundleID, filepath.Join(fit, "x", runDirName)))+1))
	dir, err := socketDirFor("linux", os.TempDir(), fit, me, runUserIs(t, me, nil))
	if err != nil || len(SocketPath(BundleID, dir)) != maxSocketPath {
		t.Fatalf("a socket path of exactly %d bytes = %q, %v", maxSocketPath, dir, err)
	}
	l, err := Listen(SocketPath(BundleID, dir))
	if err != nil {
		t.Fatalf("listen at the longest allowed path: %v", err)
	}
	_ = l.Close()
}

// readOnlyRoot is a data root whose folder cannot take a new entry.
func readOnlyRoot(t *testing.T) (string, int) {
	root := shortTemp(t)
	if err := os.Chmod(root, 0o500); err != nil {
		t.Fatal(err)
	}
	if os.Geteuid() == 0 {
		t.Skip("root ignores folder modes")
	}
	return root, me
}

func hostSocketsInTemp(t *testing.T) []string {
	t.Helper()
	m, err := filepath.Glob(filepath.Join(os.TempDir(), "watchtower-sh-*"))
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func assertMode(t *testing.T, p string, want fs.FileMode) {
	t.Helper()
	fi, err := os.Lstat(p)
	if err != nil {
		t.Fatal(err)
	}
	if !fi.IsDir() || fi.Mode().Perm() != want {
		t.Fatalf("%s mode %v, want a folder %v", p, fi.Mode(), want)
	}
}

// runDirSocket is the host socket in a fresh Linux fallback folder.
func runDirSocket(t *testing.T) string {
	t.Helper()
	dir, err := socketDirFor("linux", os.TempDir(), shortTemp(t), me, runUserIs(t, me, nil))
	if err != nil {
		t.Fatal(err)
	}
	return SocketPath(BundleID, dir)
}

// A stale socket from a dead host in the Linux fallback folder is replaced
// under the .lock rule.
func TestListenRebindsAStaleSocketInTheRunDir(t *testing.T) {
	path := runDirSocket(t)
	old, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	old.(*net.UnixListener).SetUnlinkOnClose(false)
	_ = old.Close()
	l, err := Listen(path)
	if err != nil {
		t.Fatalf("Listen over a stale socket in the run dir: %v", err)
	}
	t.Cleanup(func() { _ = l.Close() })
	c, err := net.Dial("unix", path)
	if err != nil {
		t.Fatalf("dial the rebound socket: %v", err)
	}
	_ = c.Close()
}

// A live host in the Linux fallback folder is never displaced.
func TestListenRefusesWhileALiveHostHoldsTheLock(t *testing.T) {
	path := runDirSocket(t)
	l, err := Listen(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = l.Close() })
	if _, err := Listen(path); !errors.Is(err, ErrHostRunning) {
		t.Fatalf("second Listen = %v, want ErrHostRunning", err)
	}
	c, err := net.Dial("unix", path)
	if err != nil {
		t.Fatalf("the live host lost its socket: %v", err)
	}
	_ = c.Close()
}
