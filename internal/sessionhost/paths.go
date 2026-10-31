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

	"golang.org/x/sys/unix"

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

// maxSocketPath is the longest socket path this platform's sockaddr_un takes
// with its terminating NUL (103 bytes on darwin, 107 on Linux).
var maxSocketPath = len(unix.RawSockaddrUnix{}.Path) - 1

// DefaultSocket is the host socket: SocketEnv when set, else the shared
// socket in socketDirFor's folder — the user's temp folder on darwin, the
// uid's /run/user folder or <data root>/.run elsewhere. Off darwin it may
// create <data root>/.run (0700), so the host and every client agree on one
// path; a data root that cannot be determined fails there before /run/user
// is tried (an ErrRunDirUnusable error).
func DefaultSocket() (string, error) {
	if s := os.Getenv(SocketEnv); s != "" {
		return s, nil
	}
	root := ""
	if runtime.GOOS != "darwin" { // darwin needs no data root
		r, err := config.DataRoot()
		if err != nil {
			return "", runDirError("no data root", err)
		}
		root = r
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
// /run/user/<uid> when stat (an lstat) passes usableRunUser, else
// <dataRoot>/.run, created 0700 and checked and tightened through one
// O_NOFOLLOW descriptor (no window between the check and the chmod). Never
// the shared temp folder: a fallback that cannot be made, is not ours, or
// whose socket path would not fit sockaddr_un is an ErrRunDirUnusable error.
func socketDirFor(goos, tempDir, dataRoot string, uid int, stat func(string) (os.FileInfo, error)) (string, error) {
	if goos == "darwin" {
		return tempDir, nil
	}
	runUser := "/run/user/" + strconv.Itoa(uid)
	if fi, err := stat(runUser); err == nil && usableRunUser(fi, uid) {
		return runUser, nil
	}
	if dataRoot == "" || !filepath.IsAbs(dataRoot) {
		return "", runDirError("no data root", nil)
	}
	dir := filepath.Join(dataRoot, runDirName)
	if n := len(SocketPath(BundleID, dir)); n > maxSocketPath {
		return "", runDirError(fmt.Sprintf("socket path too long (%d bytes, at most %d) under %s", n, maxSocketPath, dir), nil)
	}
	if err := os.MkdirAll(dataRoot, 0o700); err != nil {
		return "", runDirError("creating the data root", err)
	}
	if err := os.Mkdir(dir, 0o700); err != nil && !errors.Is(err, fs.ErrExist) {
		return "", runDirError("creating "+dir, err)
	}
	if err := tightenOwnDir(dir, uid); err != nil {
		return "", err
	}
	return dir, nil
}

// tightenOwnDir opens dir without following a symlink, refuses it unless it
// is a folder owned by uid, and sets mode 0700 on that same descriptor.
func tightenOwnDir(dir string, uid int) error {
	fd, err := unix.Open(dir, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return runDirError(dir+" is not a folder", err)
	}
	defer func() { _ = unix.Close(fd) }()
	var st unix.Stat_t
	if err := unix.Fstat(fd, &st); err != nil {
		return runDirError("reading "+dir, err)
	}
	if int(st.Uid) != uid {
		return runDirError(dir+" belongs to another user", nil)
	}
	if st.Mode&0o777 != 0o700 {
		if err := unix.Fchmod(fd, 0o700); err != nil {
			return runDirError("tightening "+dir, err)
		}
	}
	return nil
}

// runDirError is an ErrRunDirUnusable error; cause (may be nil) stays
// reachable through errors.Is/As.
func runDirError(why string, cause error) error {
	const prefix = "[Watchtower] the session host cannot use its socket folder: "
	if cause != nil {
		return fmt.Errorf(prefix+"%s: %w (%w)", why, cause, ErrRunDirUnusable)
	}
	return fmt.Errorf(prefix+"%s (%w)", why, ErrRunDirUnusable)
}

// usableRunUser: a real folder (lstat, so never a symlink) owned by uid with
// mode 0700.
func usableRunUser(fi os.FileInfo, uid int) bool {
	st, ok := fi.Sys().(*syscall.Stat_t)
	return ok && fi.Mode().Type() == fs.ModeDir && fi.Mode().Perm() == 0o700 && int(st.Uid) == uid
}
