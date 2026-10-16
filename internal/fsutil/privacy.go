package fsutil

import (
	"os"
	"path/filepath"
	"strings"
)

// PrivacyProtected reports whether folder sits where macOS asks the user
// before an app reads it — the home locations the Desktop's New-workbench flow
// warns about, and any other volume (removable and network volumes are
// guarded too, and a dead network mount can block a stat for minutes).
// Paths compare case-insensitively, as on the default APFS volume.
func PrivacyProtected(folder string) bool {
	if HasPathPrefix(folder, "/Volumes") {
		return true
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return true // cannot tell: never risk a background prompt
	}
	homes := []string{home}
	if resolved, err := filepath.EvalSymlinks(home); err == nil && resolved != home {
		homes = append(homes, resolved)
	}
	for _, h := range homes {
		for _, rel := range []string{"Documents", "Desktop", "Downloads", "Library/CloudStorage", "Library/Mobile Documents"} {
			if HasPathPrefix(folder, filepath.Join(h, rel)) {
				return true
			}
		}
	}
	return false
}

// HasPathPrefix reports whether path is root or below it, ignoring case.
func HasPathPrefix(path, root string) bool {
	return strings.EqualFold(path, root) ||
		(len(path) > len(root) && path[len(root)] == filepath.Separator && strings.EqualFold(path[:len(root)], root))
}
