// Package gitbin finds a real git binary without ever touching the macOS
// /usr/bin/git shim: on a Mac without the developer tools that shim (an
// xcrun stub) pops the "install Command Line Tools" dialog in the owner's
// face. Locating git spawns no process — it reads an environment variable,
// one symlink and file modes.
package gitbin

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sync"
)

// ErrUnavailable means no git binary was found outside the shim.
var ErrUnavailable = errors.New("git is not available (no Command Line Tools)")

// shim is the xcrun stub every darwin install has; never run.
const shim = "/usr/bin/git"

// xcodeSelectLink is what `xcode-select -p` reads: a symlink to the active
// developer directory.
const xcodeSelectLink = "/var/db/xcode_select_link"

// Locator looks for git. A nil field falls back to the real system call.
type Locator struct {
	GOOS         string
	Getenv       func(string) string
	Readlink     func(string) (string, error)
	IsExecutable func(string) bool
	LookPath     func(string) (string, error)
}

// Locate returns git's absolute path. On darwin it checks, in order,
// $DEVELOPER_DIR, the xcode-select link's target, the Command Line Tools,
// Xcode.app, then Homebrew (arm64, then Intel) — never /usr/bin/git and
// never a PATH lookup, which would find the shim. Elsewhere it is a PATH
// lookup.
func (l Locator) Locate() (string, bool) {
	l = l.withDefaults()
	if l.GOOS != "darwin" {
		p, err := l.LookPath("git")
		return p, err == nil && p != ""
	}
	for _, c := range l.candidates() {
		if c = filepath.Clean(c); c != shim && filepath.IsAbs(c) && l.IsExecutable(c) {
			return c, true
		}
	}
	return "", false
}

func (l Locator) candidates() []string {
	var cs []string
	if dev := l.Getenv("DEVELOPER_DIR"); dev != "" {
		cs = append(cs, filepath.Join(dev, "usr/bin/git"))
	}
	if target, err := l.Readlink(xcodeSelectLink); err == nil && target != "" {
		if !filepath.IsAbs(target) {
			target = filepath.Join(filepath.Dir(xcodeSelectLink), target)
		}
		cs = append(cs, filepath.Join(target, "usr/bin/git"))
	}
	return append(cs,
		"/Library/Developer/CommandLineTools/usr/bin/git",
		"/Applications/Xcode.app/Contents/Developer/usr/bin/git",
		"/opt/homebrew/bin/git",
		"/usr/local/bin/git",
	)
}

func (l Locator) withDefaults() Locator {
	if l.GOOS == "" {
		l.GOOS = runtime.GOOS
	}
	if l.Getenv == nil {
		l.Getenv = os.Getenv
	}
	if l.Readlink == nil {
		l.Readlink = os.Readlink
	}
	if l.IsExecutable == nil {
		l.IsExecutable = isExecutable
	}
	if l.LookPath == nil {
		l.LookPath = exec.LookPath
	}
	return l
}

// isExecutable: path is an executable regular file that is not the shim
// behind a symlink.
func isExecutable(path string) bool {
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil || resolved == shim {
		return false
	}
	fi, err := os.Stat(resolved)
	return err == nil && fi.Mode().IsRegular() && fi.Mode().Perm()&0o111 != 0
}

var located = sync.OnceValues(Locator{}.Locate)

// Locate is the system Locator's answer, looked up once per process.
func Locate() (string, bool) { return located() }

// InsideRepository reports whether dir or one of its parents holds a .git
// entry (a directory, or a linked worktree's gitdir file). It runs no git:
// callers use it before any git call so a plain folder never spawns one.
func InsideRepository(dir string) bool {
	abs, err := filepath.Abs(dir)
	if err != nil {
		return false
	}
	for cur := abs; ; cur = filepath.Dir(cur) {
		if _, err := os.Lstat(filepath.Join(cur, ".git")); err == nil {
			return true
		}
		if filepath.Dir(cur) == cur {
			return false
		}
	}
}
