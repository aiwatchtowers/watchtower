package db

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"watchtower/internal/config"
)

// ErrProjectFolderNotAllowed is returned for a folder a project must never be
// bound to: the agent working it would roam the whole disk, the whole home
// directory, or Watchtower's own data.
var ErrProjectFolderNotAllowed = errors.New("folder cannot be a project")

// checkProjectFolderAllowed refuses resolved when it is the filesystem root,
// the home directory or an ancestor of it, or a Watchtower data/config
// directory, anything inside one, or an ancestor of one.
func checkProjectFolderAllowed(resolved string) error {
	if resolved == string(filepath.Separator) {
		return fmt.Errorf("%s is the filesystem root: %w", resolved, ErrProjectFolderNotAllowed)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("checking folder %s: %w", resolved, err)
	}
	home = resolveIfExists(home)
	if pathWithin(home, resolved) {
		return fmt.Errorf("%s is the home directory or contains it: %w", resolved, ErrProjectFolderNotAllowed)
	}
	for _, dir := range watchtowerDirs(home) {
		if pathWithin(resolved, dir) || pathWithin(dir, resolved) {
			return fmt.Errorf("%s overlaps Watchtower's own data at %s: %w", resolved, dir, ErrProjectFolderNotAllowed)
		}
	}
	return nil
}

// watchtowerDirs lists the directories Watchtower keeps its own state in.
func watchtowerDirs(home string) []string {
	dirs := []string{
		filepath.Join(home, ".config", "watchtower"),
		filepath.Join(home, "Library", "Application Support", "Watchtower"),
	}
	if root, err := config.DataRoot(); err == nil {
		dirs = append(dirs, resolveIfExists(root))
	}
	return dirs
}

func resolveIfExists(p string) string {
	if r, err := filepath.EvalSymlinks(p); err == nil {
		return r
	}
	return filepath.Clean(p)
}

// pathWithin reports whether child is parent or lies inside it, comparing
// whole path components and ignoring case (APFS is case-insensitive).
func pathWithin(child, parent string) bool {
	c, p := strings.ToLower(filepath.Clean(child)), strings.ToLower(filepath.Clean(parent))
	return c == p || strings.HasPrefix(c, strings.TrimSuffix(p, string(filepath.Separator))+string(filepath.Separator))
}
