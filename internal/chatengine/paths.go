package chatengine

import (
	"crypto/sha256"
	"encoding/hex"
	"path/filepath"
	"strconv"
	"strings"

	"watchtower/internal/platform"
)

// SocketName is the engine's socket in the workspace folder.
const SocketName = "chat.sock"

// fallbackPrefix names a workspace's socket folder under the temp folder.
const fallbackPrefix = "wtchat-"

// SocketPath is the engine's socket for the workspace folder: <workspace>/
// chat.sock, or — when that is longer than a socket path may be — the same
// name in <tempDir>/wtchat-<12 hex of sha256(workspace)>. The Swift twin is
// ChatSocketPaths; both read testdata/socket_paths.json. workspaceDir and
// tempDir are absolute; a trailing slash is ignored.
func SocketPath(workspaceDir, tempDir string) string {
	return socketPath(workspaceDir, tempDir, platform.MaxSocketPath)
}

// SessionSocketPath is conversation conv's session socket, by the same rule:
// <workspace>/chatengine/sessions/<conv>.sock, else <fallback>/sessions/
// <conv>.sock.
func SessionSocketPath(workspaceDir, tempDir string, conv int64) string {
	return sessionSocketPath(workspaceDir, tempDir, conv, platform.MaxSocketPath)
}

func socketPath(workspaceDir, tempDir string, limit int) string {
	if p := filepath.Join(workspaceDir, SocketName); len(p) <= limit {
		return p
	}
	return filepath.Join(fallbackDir(workspaceDir, tempDir), SocketName)
}

func sessionSocketPath(workspaceDir, tempDir string, conv int64, limit int) string {
	name := strconv.FormatInt(conv, 10) + ".sock"
	if p := filepath.Join(workspaceDir, "chatengine", "sessions", name); len(p) <= limit {
		return p
	}
	return filepath.Join(fallbackDir(workspaceDir, tempDir), "sessions", name)
}

// fallbackDir is the workspace's socket folder under tempDir.
func fallbackDir(workspaceDir, tempDir string) string {
	sum := sha256.Sum256([]byte(trimSlash(workspaceDir)))
	return filepath.Join(tempDir, fallbackPrefix+hex.EncodeToString(sum[:])[:12])
}

// trimSlash drops trailing slashes (not the root's).
func trimSlash(p string) string {
	if t := strings.TrimRight(p, "/"); t != "" {
		return t
	}
	return p
}
