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
// its database path, made absolute and cleaned. Swift twin:
// SessionHostPaths.scope, whose standardizing also drops a leading /private
// of an existing path and expands ~; workspace database paths have neither.
func Scope(dbPath string) string {
	p, err := filepath.Abs(dbPath)
	if err != nil {
		p = filepath.Clean(dbPath)
	}
	sum := sha256.Sum256([]byte(p))
	return hex.EncodeToString(sum[:8])
}

// DefaultSocket is the host socket: SocketEnv when set, else the shared
// Desktop socket in the user's temp folder.
func DefaultSocket() string {
	if s := os.Getenv(SocketEnv); s != "" {
		return s
	}
	return SocketPath(BundleID, os.TempDir())
}
