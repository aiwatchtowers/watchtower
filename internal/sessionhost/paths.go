package sessionhost

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"

	"watchtower/internal/config"
)

// BundleID is the literal Desktop bundle id the host socket is derived from,
// so every build (and the Go hub) shares one host (PROJ-20).
const BundleID = "com.watchtower.desktop"

// SocketEnv overrides the host socket (the phase-1 test workspace never
// reaches the real host the Desktop uses).
const SocketEnv = "WATCHTOWER_SESSION_HOST_SOCKET"

// SocketPath is `<tempDir>/watchtower-sh-<first 8 hex of SHA-256(bundleID)>.sock`,
// short enough for sockaddr_un. tempDir may end with a slash or not. Swift
// twin: SessionHostPaths.socketPath (testdata/paths.json).
func SocketPath(bundleID, tempDir string) string {
	sum := sha256.Sum256([]byte(bundleID))
	dir := tempDir
	if !strings.HasSuffix(dir, "/") {
		dir += "/"
	}
	return dir + "watchtower-sh-" + hex.EncodeToString(sum[:4]) + ".sock"
}

// Scope is a workspace's session host scope: the first 16 hex of SHA-256 of
// its standardized database path. Swift twin: SessionHostPaths.scope over
// URL(fileURLWithPath:).standardizedFileURL, whose rules this repeats
// (testdata/paths.json pins both): a leading "~/" is the home folder (a bare
// "~" is a file of that name in the working folder, as in Foundation),
// the path is made absolute and cleaned, and a leading /private/var/automount,
// /var/automount or /private is dropped when what remains exists.
func Scope(dbPath string) string {
	sum := sha256.Sum256([]byte(standardizePath(dbPath)))
	return hex.EncodeToString(sum[:8])
}

// standardizePath mirrors Foundation's path standardizing (see Scope).
// "~user" forms are not expanded (Foundation would; no workspace uses one).
func standardizePath(p string) string {
	if strings.HasPrefix(p, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			p = home + p[1:]
		}
	}
	abs, err := filepath.Abs(p)
	if err != nil {
		abs = filepath.Clean(p)
	}
	for _, prefix := range []string{"/private/var/automount", "/var/automount", "/private"} {
		rest, ok := strings.CutPrefix(abs, prefix)
		if !ok || !strings.HasPrefix(rest, "/") {
			continue
		}
		if _, err := os.Stat(rest); err == nil {
			return rest
		}
		break
	}
	return abs
}

// ErrRunDirUnusable is the class of a Linux socket folder the host cannot
// use (no data root, <data root>/.run not creatable or not ours).
var ErrRunDirUnusable = errors.New("run_dir_unusable")

// runDirName is the Linux fallback socket folder under the data root.
const runDirName = ".run"

// DefaultSocket is the host socket: SocketEnv when set, else the shared
// socket in socketDirFor's folder (the user's temp folder on darwin, the
// uid's runtime folder or <data root>/.run elsewhere).
func DefaultSocket() (string, error) {
	if s := os.Getenv(SocketEnv); s != "" {
		return s, nil
	}
	root, err := config.DataRoot()
	if err != nil && runtime.GOOS != "darwin" { // darwin needs no data root
		return "", runDirError(err.Error())
	}
	dir, err := socketDirFor(runtime.GOOS, os.TempDir(), root, os.Getuid(), os.Lstat)
	if err != nil {
		return "", err
	}
	return SocketPath(BundleID, dir), nil
}

// socketDirFor is the folder of the host socket. darwin: tempDir, as the
// Desktop's Swift twin (testdata/paths.json). Elsewhere it is computed from
// the uid alone, the same in the host and in every client, and reads no
// environment variable (a caller's XDG_RUNTIME_DIR may be unset or differ):
// /run/user/<uid> when stat (an lstat: never a symlink) shows a folder owned
// by uid with mode 0700, else <dataRoot>/.run, created 0700 and tightened
// when looser. Never the shared temp folder: a fallback that cannot be made
// or is not ours is an ErrRunDirUnusable error.
func socketDirFor(goos, tempDir, dataRoot string, uid int, stat func(string) (os.FileInfo, error)) (string, error) {
	if goos == "darwin" {
		return tempDir, nil
	}
	runUser := "/run/user/" + strconv.Itoa(uid)
	if fi, err := stat(runUser); err == nil && fi.Mode().Type() == fs.ModeDir && fi.Mode().Perm() == 0o700 && ownedBy(fi, uid) {
		return runUser, nil
	}
	if dataRoot == "" || !filepath.IsAbs(dataRoot) {
		return "", runDirError("no data root")
	}
	dir := filepath.Join(dataRoot, runDirName)
	if err := os.MkdirAll(dataRoot, 0o700); err != nil {
		return "", runDirError(fmt.Sprintf("creating the data root: %v", err))
	}
	if err := os.Mkdir(dir, 0o700); err != nil && !errors.Is(err, fs.ErrExist) {
		return "", runDirError(fmt.Sprintf("creating %s: %v", dir, err))
	}
	fi, err := stat(dir)
	switch {
	case err != nil:
		return "", runDirError(fmt.Sprintf("reading %s: %v", dir, err))
	case fi.Mode().Type() != fs.ModeDir:
		return "", runDirError(dir + " is not a folder")
	case !ownedBy(fi, uid):
		return "", runDirError(dir + " belongs to another user")
	}
	if fi.Mode().Perm() != 0o700 {
		if err := os.Chmod(dir, 0o700); err != nil {
			return "", runDirError(fmt.Sprintf("tightening %s: %v", dir, err))
		}
	}
	return dir, nil
}

func runDirError(why string) error {
	return fmt.Errorf("[Watchtower] the session host cannot use its socket folder: %s (%w)", why, ErrRunDirUnusable)
}

// ownedBy reports whether fi's owner is uid.
func ownedBy(fi os.FileInfo, uid int) bool {
	st, ok := fi.Sys().(*syscall.Stat_t)
	return ok && int(st.Uid) == uid
}
