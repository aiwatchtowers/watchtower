package sessionhost

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
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

// DefaultSocket is the host socket: SocketEnv when set, else the shared
// Desktop socket in the user's temp folder.
func DefaultSocket() string {
	if s := os.Getenv(SocketEnv); s != "" {
		return s
	}
	return SocketPath(BundleID, os.TempDir())
}
